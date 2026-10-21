import AppKit
import Foundation
import ImageIO

@MainActor
private final class BankLogoCacheEntry {
    enum Content {
        case image(NSImage)
        case failed(until: ContinuousClock.Instant)
    }
    let content: Content
    init(_ content: Content) { self.content = content }
}

private enum BankLogoReadError: Error, Sendable {
    case unavailable
    case invalidImage
}

private final class BankLogoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { BankLogoImageCache.acceptsLogoURL($0) ? request : nil })
    }
}

/// The app shares decoded logo thumbnails and active reads across recreated views, using memory only.
@MainActor
final class BankLogoImageCache {
    static let shared = BankLogoImageCache()
    private let images = NSCache<NSURL, BankLogoCacheEntry>()
    private var pending: [URL: Task<Result<BankLogoCacheEntry, BankLogoReadError>, Never>] = [:]
    private let session: URLSession

    init(session: URLSession? = nil) {
        images.totalCostLimit = 8 * 1024 * 1024
        images.countLimit = 256
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 0)
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration, delegate: BankLogoRedirects(), delegateQueue: nil)
        }
    }

    deinit {
        for task in pending.values { task.cancel() }
        session.invalidateAndCancel()
    }

    nonisolated static func acceptsLogoURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    func cachedLogo(for url: URL?) -> NSImage? {
        guard let url, let entry = images.object(forKey: url as NSURL), case .image(let image) = entry.content else { return nil }
        return image
    }

    func loadLogo(for url: URL) async -> NSImage? {
        guard Self.acceptsLogoURL(url) else { return nil }
        if let entry = images.object(forKey: url as NSURL) {
            switch entry.content {
            case .image(let image): return image
            case .failed(let until) where ContinuousClock.now < until: return nil
            case .failed: images.removeObject(forKey: url as NSURL)
            }
        }
        if let task = pending[url] { return image(from: await task.value) }
        let session = session
        // A disappearing row cancels its view task, but other rows and tabs still need this read.
        let task = Task { @MainActor in
            let result = await Self.readLogoData(from: url, session: session)
            switch result {
            case .success(let data):
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 128,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return Result<BankLogoCacheEntry, BankLogoReadError>.failure(.invalidImage) }
                let representation = NSBitmapImageRep(cgImage: thumbnail)
                let image = NSImage(size: representation.size)
                image.addRepresentation(representation)
                return .success(BankLogoCacheEntry(.image(image)))
            case .failure(let error): return .failure(error)
            }
        }
        pending[url] = task
        let result = await task.value
        pending[url] = nil
        switch result {
        case .success(let entry):
            if case .image(let image) = entry.content,
               let representation = image.representations.first {
                images.setObject(entry, forKey: url as NSURL, cost: representation.pixelsWide * representation.pixelsHigh * 4)
            }
        case .failure:
            images.setObject(BankLogoCacheEntry(.failed(until: ContinuousClock.now.advanced(by: .seconds(60)))), forKey: url as NSURL)
        }
        return image(from: result)
    }

    private func image(from result: Result<BankLogoCacheEntry, BankLogoReadError>) -> NSImage? {
        guard case .success(let entry) = result, case .image(let image) = entry.content else { return nil }
        return image
    }

    private nonisolated static func readLogoData(from url: URL, session: URLSession) async -> Result<Data, BankLogoReadError> {
        do {
            var request = URLRequest(url: url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            request.httpShouldHandleCookies = false
            let (bytes, response) = try await session.bytes(for: request)
            let limit = 2 * 1024 * 1024
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= limit else { return .failure(.unavailable) }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < limit else { return .failure(.invalidImage) }
                data.append(byte)
            }
            return .success(data)
        } catch { return .failure(.unavailable) }
    }
}
