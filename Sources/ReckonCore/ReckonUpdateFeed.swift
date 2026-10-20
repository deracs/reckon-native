import Foundation

/// Restricts software updates to this repository; credentials never appear in URLs.
public enum ReckonUpdateFeed {
    public static var feedURL: URL {
        #if arch(arm64)
        URL(string: "https://raw.githubusercontent.com/deracs/reckon-native/main/updates/appcast-arm64.xml")!
        #else
        URL(string: "https://raw.githubusercontent.com/deracs/reckon-native/main/updates/appcast-x86_64.xml")!
        #endif
    }

    public static func isAllowedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "api.github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let prefix = "/repos/deracs/reckon-native/releases/assets/"
        guard url.path.hasPrefix(prefix) else { return false }
        let assetID = url.path.dropFirst(prefix.count)
        return !assetID.isEmpty && assetID.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
