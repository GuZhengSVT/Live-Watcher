import XCTest

final class StationTests: XCTestCase {
    private let time = Date(timeIntervalSinceReferenceDate: 1000)
    private func room(_ status: Int, _ start: Int64 = 0, category: Int = 9, subgroup: Int? = nil) -> Room {
        Room(uid: 7, roomID: 42, name: "测试", title: "直播标题", status: status, started: start,
             categoryID: category, category: "虚拟主播", subcategory: "虚拟日常", face: nil, subcategoryID: subgroup)
    }
    func testFollowInputAndRoomRouting() throws {
        XCTAssertEqual(try FollowTarget(" 007\n"), .uid(7))
        XCTAssertEqual(try FollowTarget("https://space.bilibili.com/7/dynamic?x=2"), .uid(7))
        XCTAssertEqual(try FollowTarget("live.bilibili.com/6?from=abc#here"), .room(6))
        for input in ["0", "-1", "", "a", "https://www.example.com/7", "https://live.bilibili.com/0"] {
            XCTAssertThrowsError(try FollowTarget(input))
        }
        XCTAssertEqual(RoomRoute.destination(for: room(1).widgetURL), room(1).webURL)
        XCTAssertNil(RoomRoute.destination(for: URL(string: "livewatcher://room/0")!))
    }
    func testDynamicURLUsesCreatorUID() {
        XCTAssertEqual(room(0).dynamicURL.absoluteString, "https://space.bilibili.com/7/dynamic")
    }
    func testBaselineAndDistinctBroadcasts() {
        var channel = Channel(room: room(1, 100), checked: time)
        XCTAssertFalse(channel.update(with: room(1, 100), at: time, preferences: Preferences()))
        XCTAssertTrue(channel.update(with: room(1, 110), at: time, preferences: Preferences()))
        XCTAssertFalse(channel.update(with: room(2), at: time, preferences: Preferences()))
        XCTAssertTrue(channel.update(with: room(1, 120), at: time, preferences: Preferences()))
        XCTAssertFalse(channel.update(with: room(1, 0), at: time, preferences: Preferences()))
    }
    func testCategoryGlobalAndChannelFiltersKeepLiveStatus() {
        for (global, local, categories, expected): (Bool, Bool, Set<Int>?, Bool) in [
            (true,true,nil,true), (true,true,[9],true), (true,true,[5],false),
            (true,true,[],false), (false,true,nil,false), (true,false,nil,false)
        ] {
            var channel = Channel(room: room(0), alerts: local, checked: time)
            var prefs = Preferences(); prefs.alerts = global; prefs.categories = categories
            XCTAssertEqual(channel.update(with: room(1, 100), at: time, preferences: prefs), expected)
            XCTAssertTrue(channel.room.isLive)
        }
    }
    func testCategoryRulesApplyChildBeforeParentAndResetOnParentChange() {
        var rules = CategoryRules()
        XCTAssertTrue(rules.allows(9, 100))
        rules.setGroup(9, allowed: false)
        rules.setSubgroup(100, in: 9, allowed: true)
        rules.setSubgroup(100, in: 5, allowed: false)
        XCTAssertFalse(rules.allows(9))
        XCTAssertTrue(rules.allows(9, 100))
        XCTAssertFalse(rules.allows(9, 101))
        XCTAssertFalse(rules.allows(5, 100))
        XCTAssertTrue(rules.allows(5, 101))
        rules.setGroup(9, allowed: false)
        XCTAssertFalse(rules.allows(9, 100))
        XCTAssertFalse(rules.allows(5, 100))
        rules.setSubgroup(100, in: 5, allowed: true)
        XCTAssertTrue(rules.allows(5, 100))
        XCTAssertNil(rules.subgroups[5])
    }
    func testCategoryOverrideReplacesGlobalRulesButNotAlertSwitches() {
        var globalRules = CategoryRules()
        globalRules.setSubgroup(100, in: 9, allowed: false)
        let localRules = CategoryRules(defaultAllowed: false, subgroups: [9: [100: true]])
        let cases: [(Bool, Bool, CategoryRules?, Int?, Bool)] = [
            (true, true, nil, 100, false), (true, true, nil, 101, true),
            (true, true, localRules, 100, true), (true, true, localRules, 101, false),
            (true, true, localRules, nil, false), (false, true, localRules, 100, false),
            (true, false, localRules, 100, false)
        ]
        for (global, local, override, subgroup, expected) in cases {
            var prefs = Preferences()
            prefs.alerts = global
            prefs.effectiveRules = globalRules
            var channel = Channel(room: room(0), alerts: local, checked: time, categoryRules: override)
            XCTAssertEqual(channel.update(with: room(1, 100, subgroup: subgroup), at: time, preferences: prefs), expected)
            XCTAssertTrue(channel.room.isLive)
        }
    }
    func testLegacyStationJSONAndSettingsRoundTrip() throws {
        let legacy = """
        {
          "channels": [{"room": {"uid": 7, "room_id": 42, "uname": "测试", "title": "", "live_status": 0,
            "live_time": 0, "area_v2_parent_id": 9, "area_v2_parent_name": "虚拟主播", "area_v2_name": "虚拟日常"},
            "alerts": true, "checked": 1000, "unavailable": false}],
          "preferences": {"interval": 120, "alerts": true, "sound": false, "categories": [9]},
          "lastCheck": 1000
        }
        """
        let decoder = JSONDecoder()
        var state = try decoder.decode(Station.self, from: Data(legacy.utf8))
        XCTAssertEqual(state.preferences.appearance, Appearance())
        XCTAssertEqual(state.preferences.interval, 120)
        XCTAssertFalse(state.preferences.sound)
        XCTAssertEqual(state.lastCheck, time)
        XCTAssertEqual(state.channels[0].room.displayTitle, "测试的直播间")
        XCTAssertNil(state.channels[0].categoryRules)
        XCTAssertNil(state.channels[0].room.signature)
        XCTAssertNil(state.channels[0].room.keyframe)
        XCTAssertNil(state.channels[0].room.cover)
        XCTAssertNil(state.channels[0].room.subcategoryID)
        XCTAssertNil(state.channels[0].room.onlineRankCount)
        XCTAssertTrue(state.preferences.effectiveRules.allows(9, 100))
        XCTAssertFalse(state.preferences.effectiveRules.allows(5))
        let empty = try decoder.decode(Station.self, from: Data(legacy.replacingOccurrences(of: "[9]", with: "[]").utf8))
        XCTAssertFalse(empty.preferences.effectiveRules.allows(9))
        let unrestricted = legacy.replacingOccurrences(of: ", \"categories\": [9]", with: "")
        XCTAssertTrue(try decoder.decode(Station.self, from: Data(unrestricted.utf8)).preferences.effectiveRules.allows(5))

        state.preferences.effectiveRules.setSubgroup(100, in: 9, allowed: false)
        XCTAssertNil(state.preferences.categories)
        state.preferences.appearance = Appearance(fontSize: 18, mode: .dark, palette: .winter)
        state.channels[0].categoryRules = CategoryRules(defaultAllowed: false, subgroups: [9: [100: true]])
        state.channels[0].room.signature = "简介"
        state.channels[0].room.cover = "https://example.com/cover.jpg"
        state.channels[0].room.subcategoryID = 100
        let restored = try decoder.decode(Station.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertFalse(restored.preferences.effectiveRules.allows(9, 100))
        XCTAssertTrue(restored.preferences.effectiveRules.allows(9, 101))
    }
    func testRefreshKeepsProfileButNeverCarriesAnOldFrameForward() {
        var previous = room(1, 100)
        previous.name = "  昵称  "
        previous.face = "https://example.com/avatar.jpg"
        previous.signature = "简介"
        previous.keyframe = "https://example.com/frame.jpg"
        var state = Station(channels: [Channel(room: previous, checked: time)])
        var sameSession = room(1, 100)
        sameSession.name = " \n"
        sameSession.face = "\n"
        sameSession.signature = " "
        XCTAssertEqual(sameSession.displayName, "UID 7")
        XCTAssertTrue(state.merge([7: sameSession], requested: [7], since: time, at: time).isEmpty)
        var expected = previous
        expected.keyframe = nil
        XCTAssertEqual(state.channels[0].room, expected)

        sameSession.keyframe = "https://example.com/new-frame.jpg"
        XCTAssertTrue(state.merge([7: sameSession], requested: [7], since: time, at: time).isEmpty)
        XCTAssertEqual(state.channels[0].room.keyframe, sameSession.keyframe)

        var newSession = room(1, 110)
        newSession.name = ""
        let events = state.merge([7: newSession], requested: [7], since: time, at: time)
        XCTAssertEqual(events, [state.channels[0].room])
        XCTAssertEqual(events.first?.displayName, "昵称")
        XCTAssertEqual(events.first?.face, previous.face)
        XCTAssertEqual(events.first?.signature, previous.signature)
        XCTAssertNil(events.first?.keyframe)
        XCTAssertTrue(state.merge([7: newSession], requested: [7], since: time, at: time).isEmpty)
    }
    func testRefreshDistinguishesKnownEmptySignatureFromUnknown() {
        var channel = Channel(room: room(0), checked: time)
        var noSignature = room(0)
        noSignature.signature = ""
        XCTAssertFalse(channel.update(with: noSignature, at: time, preferences: Preferences()))
        XCTAssertEqual(channel.room.signature, "")
        XCTAssertFalse(channel.update(with: room(0), at: time, preferences: Preferences()))
        XCTAssertEqual(channel.room.signature, "")
    }
    func testFailedObservationAndRecovery() {
        var state = Station(channels: [Channel(room: room(1, 100), checked: time)])
        XCTAssertTrue(state.merge([:], requested: [7], since: time, at: time).isEmpty)
        XCTAssertTrue(state.live.isEmpty)
        XCTAssertTrue(state.channels[0].unavailable)
        XCTAssertTrue(state.merge([7:room(1, 100)], requested: [7], since: time, at: time).isEmpty)
        XCTAssertFalse(state.channels[0].unavailable)
        XCTAssertEqual(state.live.count, 1)
    }
    func testMissedStartDuringOutageAndStaleBatch() throws {
        var state = Station(channels: [Channel(room: room(0), checked: time)])
        _ = state.merge([:], requested: [7], since: time, at: time)
        let later = time.addingTimeInterval(10)
        XCTAssertEqual(state.merge([7: room(1, 5)], requested: [7], since: time, at: later).count, 1)
        XCTAssertTrue(state.merge([7: room(0)], requested: [7], since: time, at: later).isEmpty)
        XCTAssertTrue(state.channels[0].room.isLive)
        let restored = try JSONDecoder().decode(Station.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }

    func testOnlineRankCountIsOptionalAndNeverCarriesForward() throws {
        var initial = room(1, 100)
        initial.onlineRankCount = 12_345
        var channel = Channel(room: initial, checked: time)
        let restored = try JSONDecoder().decode(Channel.self, from: JSONEncoder().encode(channel))
        XCTAssertEqual(restored.room.onlineRankCount, 12_345)
        XCTAssertFalse(channel.update(with: room(1, 100), at: time, preferences: Preferences()))
        XCTAssertNil(channel.room.onlineRankCount)
        XCTAssertEqual(Room.onlineRankLabel(channel.room.onlineRankCount), "同接 —")

        var zero = room(1, 100)
        zero.onlineRankCount = 0
        XCTAssertFalse(channel.update(with: zero, at: time, preferences: Preferences()))
        XCTAssertEqual(channel.room.onlineRankCount, 0)
        XCTAssertEqual(Room.onlineRankLabel(channel.room.onlineRankCount), "同接 \(0.formatted())")
        var replay = room(2)
        replay.onlineRankCount = 99
        XCTAssertFalse(channel.update(with: replay, at: time, preferences: Preferences()))
        XCTAssertNil(channel.room.onlineRankCount)
    }

    private func widgetChannel(_ id: Int64, status: Int = 1, unavailable: Bool = false) -> Channel {
        let room = Room(uid: id, roomID: id, name: "UP \(id)", title: "直播标题", status: status, started: id,
                        categoryID: 9, category: "虚拟主播", subcategory: "虚拟日常", face: nil)
        return Channel(room: room, checked: time, unavailable: unavailable)
    }

    func testWidgetPageUsesLiveChannelsInStationOrder() {
        let station = Station(channels: [widgetChannel(1), widgetChannel(4, status: 2), widgetChannel(6),
                                         widgetChannel(9, unavailable: true), widgetChannel(8, status: 0)])
        let page = WidgetLivePage(live: station.live, pageSize: 2, requestedIndex: 0)
        XCTAssertEqual(page.channels.map(\.id), [6, 1])
        XCTAssertEqual(page.liveCount, 2)
        XCTAssertEqual(page.pageCount, 1)
    }

    func testWidgetPageSlicesEachSize() {
        let live = Station(channels: (1...11).map { widgetChannel(Int64($0)) }).live
        for (size, count, ids): (Int, Int, [Int64]) in [(1, 11, [10]), (2, 6, [9, 8]), (5, 3, [6, 5, 4, 3, 2])] {
            let page = WidgetLivePage(live: live, pageSize: size, requestedIndex: 1)
            XCTAssertEqual(page.index, 1)
            XCTAssertEqual(page.pageCount, count)
            XCTAssertEqual(page.liveCount, 11)
            XCTAssertEqual(page.channels.map(\.id), ids)
        }
    }

    func testWidgetPageClampsWhenLiveCountShrinks() {
        let live = [widgetChannel(3), widgetChannel(2), widgetChannel(1)]
        let lastPage = WidgetLivePage(live: live, pageSize: 2, requestedIndex: Int.max)
        XCTAssertEqual(lastPage.index, 1)
        XCTAssertEqual(lastPage.channels.map(\.id), [1])
        let firstPage = WidgetLivePage(live: live, pageSize: 2, requestedIndex: Int.min)
        XCTAssertEqual(firstPage.index, 0)
        XCTAssertEqual(firstPage.channels.map(\.id), [3, 2])
        let empty = WidgetLivePage(live: [], pageSize: 2, requestedIndex: 1)
        XCTAssertEqual(empty.index, 0)
        XCTAssertEqual(empty.pageCount, 0)
        XCTAssertEqual(empty.liveCount, 0)
        XCTAssertTrue(empty.channels.isEmpty)
    }
}
