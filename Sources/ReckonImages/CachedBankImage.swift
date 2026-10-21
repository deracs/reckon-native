import AppKit
import SwiftUI

/// Cached bank and merchant images render immediately when a tab recreates their views.
@MainActor
public struct CachedBankImage<Content: View>: View {
    private struct LoadedLogo {
        let url: URL
        let image: NSImage
    }
    private let url: URL?
    private let cache: BankLogoImageCache
    private let content: (Image?) -> Content
    @State private var loaded: LoadedLogo?

    /// The content receives nil for missing, failed, or still-loading logos; URLs must use HTTPS.
    public init(url: URL?, @ViewBuilder content: @escaping (Image?) -> Content) {
        self.init(url: url, cache: .shared, content: content)
    }

    init(url: URL?, cache: BankLogoImageCache, @ViewBuilder content: @escaping (Image?) -> Content) {
        self.url = url
        self.cache = cache
        self.content = content
        let cached = cache.cachedLogo(for: url)
        _loaded = State(initialValue: url.flatMap { url in cached.map { LoadedLogo(url: url, image: $0) } })
    }

    /// A warm logo skips the placeholder on its first frame, without a fade animation.
    public var body: some View {
        let image = loaded.flatMap { $0.url == url ? $0.image : nil } ?? cache.cachedLogo(for: url)
        content(image.map { Image(nsImage: $0) })
            .task(id: url) {
                guard let url else { loaded = nil; return }
                let image = await cache.loadLogo(for: url)
                guard !Task.isCancelled else { return }
                loaded = image.map { LoadedLogo(url: url, image: $0) }
            }
    }
}
