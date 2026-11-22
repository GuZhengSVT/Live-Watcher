import AppKit
import CryptoKit
import SwiftUI

enum ArtworkKind: Hashable {
    case avatar, preview
}

struct ArtworkImage<Content: View, Placeholder: View>: View {
    private struct Source: Equatable {
        let primary: URL?
        let fallback: URL?
        let kind: ArtworkKind
    }

    private let source: Source
    private let content: (Image, Bool) -> Content
    private let placeholder: Placeholder
    @State private var loaded: (source: Source, image: NSImage, usedFallback: Bool)?

    init(url: String?, kind: ArtworkKind, fallbackURL: String?,
         @ViewBuilder content: @escaping (Image, Bool) -> Content,
         @ViewBuilder placeholder: () -> Placeholder) {
        source = Source(primary: Self.webURL(url), fallback: Self.webURL(fallbackURL), kind: kind)
        self.content = content
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let loaded, loaded.source == source {
                content(Image(nsImage: loaded.image), loaded.usedFallback)
            } else {
                placeholder
            }
        }
        .task(id: source) {
            loaded = nil
            if let url = source.primary, let image = await ArtworkLoader.image(at: url, kind: source.kind) {
                guard !Task.isCancelled else { return }
                loaded = (source, image, false)
            } else if !Task.isCancelled, let url = source.fallback, url != source.primary,
                      let image = await ArtworkLoader.image(at: url, kind: source.kind), !Task.isCancelled {
                loaded = (source, image, true)
            }
        }
    }

    private static func webURL(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              var components = URLComponents(string: value.hasPrefix("//") ? "https:" + value : value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.host != nil else { return nil }
        components.scheme = "https"
        return components.url
    }
}

struct FilledArtworkImage: View {
    let image: Image
    var body: some View { image.resizable().scaledToFill() }
}

extension ArtworkImage where Content == FilledArtworkImage {
    init(url: String?, kind: ArtworkKind, @ViewBuilder placeholder: () -> Placeholder) {
        self.init(url: url, kind: kind, fallbackURL: nil, content: { image, _ in
            FilledArtworkImage(image: image)
        }, placeholder: placeholder)
    }
}

private enum ArtworkLoader {
    // Live previews should never inherit an old image from URLSession's disk cache.
    private static let session = URLSession(configuration: .ephemeral)
    private static let avatarDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "LiveWatcher", isDirectory: true)
        .appendingPathComponent("Avatars", isDirectory: true)

    static func image(at url: URL, kind: ArtworkKind) async -> NSImage? {
        let cached = kind == .avatar ? avatarFile(for: url) : nil
        if let cached, let image = NSImage(contentsOf: cached), image.isValid { return image }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = NSImage(data: data), image.isValid else { return nil }
        if let cached {
            try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cached, options: .atomic)
        }
        return image
    }

    private static func avatarFile(for url: URL) -> URL? {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return avatarDirectory?.appendingPathComponent(key)
    }
}
