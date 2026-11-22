import XCTest

final class ScheduleTests: XCTestCase {
    private let feed = """
    BEGIN:VCALENDAR
    VERSION:2.0
    X-WR-CALNAME:LAPLACE
    BEGIN:VEVENT
    UID:stream
    SUMMARY:游戏：影之刃
     2
    DTSTART:20261122T110000Z
    DURATION:PT4H
    END:VEVENT
    END:VCALENDAR
    """

    func testLaplaceTimesAndWeekBoundaries() throws {
        var local = ScheduleWeek.calendar
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let doc = try ScheduleDocument(feed.replacingOccurrences(of: "\n", with: "\r\n"))
        let event = try XCTUnwrap(doc.calendar.events.first)
        XCTAssertEqual(event.title, "游戏：影之刃2")
        XCTAssertEqual(local.component(.hour, from: event.start), 19)
        XCTAssertEqual(local.component(.hour, from: event.end), 23)
        let week = ScheduleWeek.interval(containing: event.start, calendar: local)
        XCTAssertEqual(local.component(.day, from: week.start), 16)
        XCTAssertEqual(local.component(.day, from: week.end), 23)
        let url = try ScheduleDocument.url(from: " webcal://LAPLACE.live/schedule.ics\n")
        XCTAssertEqual(url.absoluteString, "https://laplace.live/schedule.ics")
        let sub = ScheduleSubscription(record: .init(id: UUID(), url: url, channelID: 42, updated: Date(), text: feed), document: doc)
        XCTAssertEqual(ScheduleWeek.entries([sub], in: week, calendar: local).map(\.occurrence.event.title), [event.title])
        XCTAssertThrowsError(try ScheduleDocument.url(from: "file:///private/test.ics"))
        XCTAssertThrowsError(try ScheduleDocument("<html>not a calendar</html>"))
        XCTAssertThrowsError(try ScheduleDocument(String(feed.dropLast(13))))
    }

    func testRecurringAllDayAndCancelledEntries() throws {
        let doc = try ScheduleDocument("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:weekly
        DTSTART;VALUE=DATE:20261102
        RRULE:FREQ=WEEKLY;COUNT=5
        EXDATE;VALUE=DATE:20261123
        SUMMARY:每周安排
        END:VEVENT
        BEGIN:VEVENT
        UID:cancelled
        STATUS:CANCELLED
        DTSTART:20261117T120000Z
        END:VEVENT
        END:VCALENDAR
        """)
        let calendar = ScheduleWeek.calendar
        let week = ScheduleWeek.interval(containing: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))))
        let sub = ScheduleSubscription(record: .init(id: UUID(), url: URL(string: "https://example.com")!, channelID: nil, updated: Date(), text: doc.text), document: doc)
        let repeating = ScheduleWeek.entries([sub], in: week)
        XCTAssertEqual(repeating.count, 1)
        XCTAssertTrue(try XCTUnwrap(repeating.first).occurrence.isAllDay)
        XCTAssertTrue(ScheduleWeek.entries([sub], in: ScheduleWeek.interval(containing: week.end)).isEmpty)
    }

    func testSharedTimelineKeepsEachRecurringStreamsTimeZone() throws {
        let ny = try ScheduleDocument("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:same
        DTSTART;TZID="America/New_York":20261025T200000
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:纽约直播
        END:VEVENT
        END:VCALENDAR
        """)
        let china = try ScheduleDocument(ny.text
            .replacingOccurrences(of: "America/New_York", with: "Asia/Shanghai")
            .replacingOccurrences(of: "纽约直播", with: "上海直播"))
        var calendar = ScheduleWeek.calendar
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let sunday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let week = ScheduleWeek.interval(containing: sunday, calendar: calendar)
        let feeds = [ny, china].map { doc in
            ScheduleSubscription(record: .init(id: UUID(), url: URL(string: "https://example.com")!,
                                              channelID: nil, updated: Date(), text: doc.text), document: doc)
        }
        let entries = ScheduleWeek.entries(feeds, in: week, calendar: calendar)
        XCTAssertEqual(entries.map(\.occurrence.event.title), ["纽约直播", "上海直播"])
        XCTAssertEqual(calendar.component(.hour, from: entries[0].occurrence.start), 8)
        let next = ScheduleWeek.interval(containing: week.end, calendar: calendar)
        let following = try XCTUnwrap(ScheduleWeek.entries(feeds, in: next, calendar: calendar).first)
        XCTAssertEqual(following.occurrence.event.title, "纽约直播")
        XCTAssertEqual(calendar.component(.hour, from: following.occurrence.start), 9)
    }

    func testAgendaClassifiesTimedAndInstantEventsAtTheirBoundaries() throws {
        let doc = try ScheduleDocument(feed)
        let event = try XCTUnwrap(doc.calendar.events.first)
        let record = ScheduleSubscription.Record(id: UUID(), url: URL(string: "https://example.com")!,
                                                 channelID: 7, updated: Date(), text: feed)
        let week = ScheduleWeek.interval(containing: event.start)
        let entry = try XCTUnwrap(ScheduleWeek.entries([.init(record: record, document: doc)], in: week).first)
        XCTAssertFalse(entry.hasEnded(at: event.start))
        XCTAssertTrue(entry.isOngoing(at: event.start))
        XCTAssertFalse(entry.isOngoing(at: event.end))
        XCTAssertTrue(entry.hasEnded(at: event.end))

        let instant = try ScheduleDocument(feed.replacingOccurrences(of: "DURATION:PT4H\n", with: ""))
        let point = try XCTUnwrap(ScheduleWeek.entries([.init(record: record, document: instant)], in: week).first)
        XCTAssertFalse(point.isOngoing(at: event.start))
        XCTAssertFalse(point.hasEnded(at: event.start))
        XCTAssertTrue(point.hasEnded(at: event.start.addingTimeInterval(1)))
    }

    @MainActor
    func testTimelineSelectionPersistsByChannelAndByIndependentFeed() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appending(path: "schedules.json")
        let store = ScheduleStore(file: file, defaults: defaults) { _ in try ScheduleDocument(self.feed) }
        for (index, channel) in ([7, 7, 8, nil, nil] as [Int64?]).enumerated() {
            try await store.save(input: "https://example.com/\(index).ics", channelID: channel, editing: nil)
        }
        XCTAssertTrue(store.subscriptions.allSatisfy(store.showsOnTimeline))
        store.setTimelineVisible(false, for: store.subscriptions[0])
        store.setTimelineVisible(false, for: store.subscriptions[3])
        try await store.save(input: "https://example.com/new.ics", channelID: 7, editing: nil)
        let reopened = ScheduleStore(file: file, defaults: defaults)
        reopened.start()
        XCTAssertEqual(reopened.subscriptions.map(reopened.showsOnTimeline), [false, false, true, false, true, false])
        reopened.setTimelineVisible(true, for: reopened.subscriptions[1])
        XCTAssertEqual(reopened.subscriptions.map(reopened.showsOnTimeline), [true, true, true, false, true, true])
    }

    @MainActor
    func testSubscriptionRefreshPersistenceAndRemoval() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "schedules.json")
        var response = feed
        let store = ScheduleStore(file: file) { _ in try ScheduleDocument(response) }
        store.start()
        let input = "https://laplace.live/schedule.ics"
        try await store.save(input: input, channelID: 7, editing: nil)
        let original = try XCTUnwrap(store.subscriptions.first)
        do {
            try await store.save(input: input, channelID: 8, editing: nil)
            XCTFail("Duplicate URL accepted")
        } catch {}
        response = feed.replacingOccurrences(of: "游戏：影之刃", with: "新安排")
        await store.refresh(channelID: 8)
        XCTAssertEqual(store.subscriptions.first?.record.text, feed)
        await store.refresh(channelID: 7)
        XCTAssertEqual(store.subscriptions.first?.record.text, response)
        let cached = store.subscriptions.first?.record.updated
        response = "offline"
        await store.refresh()
        XCTAssertNotNil(store.errors[original.id])
        XCTAssertEqual(store.subscriptions.first?.record.updated, cached)
        try await store.save(input: input, channelID: 8, editing: original.id)
        XCTAssertEqual(store.subscriptions.first?.record.updated, cached)
        let reopened = ScheduleStore(file: file)
        reopened.start()
        XCTAssertEqual(reopened.subscriptions.first?.record.channelID, 8)
        XCTAssertEqual(reopened.subscriptions.first?.document.calendar.events.first?.title, "新安排2")
        try reopened.remove(original.id)
        XCTAssertTrue(reopened.subscriptions.isEmpty)
    }
}
