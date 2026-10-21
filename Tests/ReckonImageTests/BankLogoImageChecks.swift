import AppKit
import Foundation
import SwiftUI
@testable import ReckonImages

private struct LogoCheckFailure: Error { let message: String }
private func expectLogo(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw LogoCheckFailure(message: message) }
}

private final class LogoFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: Data] = [:]
    private var reads: [URLRequest] = []
    func reset(images: [String: Data]) { lock.withLock { self.images = images; reads = [] } }
    func record(_ request: URLRequest) -> Data {
        lock.withLock { reads.append(request); return images[request.url?.lastPathComponent ?? ""] ?? Data("invalid image".utf8) }
    }
    var requests: [URLRequest] { lock.withLock { reads } }
}

private final class LogoFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = LogoFixtureState()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "logo-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.state.record(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            guard !lock.withLock({ stopped }), let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: url.lastPathComponent == "missing" ? 404 : 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png", "Cache-Control": "no-store"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@main struct BankLogoImageChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await runChecks()
                exit(0)
            } catch let failure as LogoCheckFailure {
                print("FAIL \(failure.message)")
                exit(1)
            } catch {
                print("FAIL Logo image checks encountered an unexpected error.")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func fixtureImage(_ color: NSColor, size: Int = 32) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { throw LogoCheckFailure(message: "Could not create a fixture image.") }
        for x in 0..<size { for y in 0..<size { bitmap.setColor(color, atX: x, y: y) } }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LogoCheckFailure(message: "Could not encode a fixture image.") }
        return png
    }

    @MainActor private static func fixtureCache() -> BankLogoImageCache {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogoFixtureProtocol.self]
        configuration.urlCache = nil
        return BankLogoImageCache(session: URLSession(configuration: configuration))
    }

    @MainActor private static func logoView(_ url: URL?, cache: BankLogoImageCache) -> AnyView {
        AnyView(CachedBankImage(url: url, cache: cache) { image in
            if let image { image.resizable().scaledToFit() }
            else { Color.gray }
        }.frame(width: 64, height: 64))
    }

    @MainActor private static func mount(_ url: URL?, cache: BankLogoImageCache, window: NSWindow) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: logoView(url, cache: cache))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor private static func showsLogo(_ host: NSView, blue: Bool = false) -> Bool {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
        return blue ? color.blueComponent - max(color.redComponent, color.greenComponent) > 0.4
            : color.redComponent - max(color.greenComponent, color.blueComponent) > 0.4
    }

    @MainActor private static func waitForLogo(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw LogoCheckFailure(message: "A fixture logo did not reach its expected state.")
    }

    @MainActor private static func runChecks() async throws {
        let red = try fixtureImage(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        let blue = try fixtureImage(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        let large = try fixtureImage(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), size: 512)
        let redURL = URL(string: "https://logo-fixture.invalid/red")!
        let blueURL = URL(string: "https://logo-fixture.invalid/blue")!
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 64, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }

        LogoFixtureProtocol.state.reset(images: ["red": red, "blue": blue, "large": large])
        let cache = fixtureCache()
        let first = mount(redURL, cache: cache, window: window)
        try expectLogo(!showsLogo(first), "A cold image must show its fallback before completion.")
        try await waitForLogo { showsLogo(first) }
        for _ in 0..<20 {
            let remounted = mount(redURL, cache: cache, window: window)
            try expectLogo(showsLogo(remounted), "A tab switch flashed the placeholder for a cached logo.")
        }
        try await Task.sleep(for: .milliseconds(100))
        try expectLogo(LogoFixtureProtocol.state.requests.count == 1, "Tab switches refetched a cached logo.")
        print("PASS Twenty tab recreations show the image on their first frame with one total request")

        let changing = mount(redURL, cache: cache, window: window)
        changing.rootView = logoView(blueURL, cache: cache)
        try expectLogo(!showsLogo(changing), "A changed URL briefly displayed the previous logo.")
        try await waitForLogo { showsLogo(changing, blue: true) }
        print("PASS A changed logo URL cannot display the previous image")

        LogoFixtureProtocol.state.reset(images: ["red": red])
        let sharedCache = fixtureCache()
        let readers = (0..<10).map { _ in Task { @MainActor in await sharedCache.loadLogo(for: redURL) != nil } }
        for reader in readers {
            let loaded = await reader.value
            try expectLogo(loaded, "A concurrent logo reader failed.")
        }
        try expectLogo(LogoFixtureProtocol.state.requests.count == 1, "Concurrent rows duplicated the same image request.")
        print("PASS Ten concurrent rows share one image request")

        LogoFixtureProtocol.state.reset(images: ["red": red])
        let interruptedCache = fixtureCache()
        _ = mount(redURL, cache: interruptedCache, window: window)
        try await waitForLogo { LogoFixtureProtocol.state.requests.count == 1 }
        window.contentView = NSView()
        let returned = mount(redURL, cache: interruptedCache, window: window)
        try await waitForLogo { showsLogo(returned) }
        try expectLogo(LogoFixtureProtocol.state.requests.count == 1, "A tab switch interrupted and restarted a shared read.")
        print("PASS Switching tabs during an image request preserves the shared read")

        LogoFixtureProtocol.state.reset(images: [:])
        let failureCache = fixtureCache()
        for path in ["missing", "corrupt"] {
            let url = URL(string: "https://logo-fixture.invalid/\(path)")!
            let firstFailure = await failureCache.loadLogo(for: url)
            let secondFailure = await failureCache.loadLogo(for: url)
            try expectLogo(firstFailure == nil && secondFailure == nil, "An unavailable logo did not retain its fallback.")
        }
        try expectLogo(LogoFixtureProtocol.state.requests.count == 2, "Unavailable logos were retried on every view recreation.")
        for raw in ["http://logo-fixture.invalid/red", "https://user:password@logo-fixture.invalid/red", "file:///tmp/logo.png"] {
            let image = await failureCache.loadLogo(for: URL(string: raw)!)
            try expectLogo(image == nil, "A logo with an unsafe URL was accepted.")
        }
        try expectLogo(LogoFixtureProtocol.state.requests.count == 2, "An invalid URL started a request.")
        print("PASS Missing or corrupt logos keep their fallback and unsafe URLs never load")

        LogoFixtureProtocol.state.reset(images: ["large": large])
        let thumbnailCache = fixtureCache()
        let thumbnail = await thumbnailCache.loadLogo(for: URL(string: "https://logo-fixture.invalid/large")!)
        guard let representation = thumbnail?.representations.first else { throw LogoCheckFailure(message: "A large fixture image did not decode.") }
        try expectLogo(representation.pixelsWide <= 128 && representation.pixelsHigh <= 128, "A logo retained its full source resolution.")
        print("PASS Large logo images become small decoded thumbnails")
        print("6/6 image checks passed")
    }
}
