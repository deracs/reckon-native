import Foundation
import ReckonCore

struct ReckonUpdateFeedTests {
    func restrictsUpdateDownloadsToThisRepository() throws {
        try bankExpect(ReckonUpdateFeed.isAllowedDownload(URL(string: "https://api.github.com/repos/deracs/reckon-native/releases/assets/123456")!))
        for text in [
            "http://api.github.com/repos/deracs/reckon-native/releases/assets/123",
            "https://api.github.com/repos/other/reckon-native/releases/assets/123",
            "https://api.github.com/repos/deracs/other/releases/assets/123",
            "https://api.github.com.evil.invalid/repos/deracs/reckon-native/releases/assets/123",
            "https://api.github.com:8443/repos/deracs/reckon-native/releases/assets/123",
            "https://user:password@api.github.com/repos/deracs/reckon-native/releases/assets/123",
            "https://api.github.com/repos/deracs/reckon-native/releases/assets/123?token=fixture",
            "https://api.github.com/repos/deracs/reckon-native/releases/assets/123#fragment",
            "https://api.github.com/repos/deracs/reckon-native/releases/assets/123/extra",
            "https://api.github.com/repos/deracs/reckon-native/releases/assets/",
            "file:///tmp/Reckon.zip"
        ] {
            try bankExpect(!ReckonUpdateFeed.isAllowedDownload(URL(string: text)!))
        }
        try bankExpect(ReckonUpdateFeed.feedURL.scheme == "https")
        try bankExpect(ReckonUpdateFeed.feedURL.host == "api.github.com")
        try bankExpect(ReckonUpdateFeed.feedURL.user == nil && ReckonUpdateFeed.feedURL.password == nil)
        #if arch(arm64)
        try bankExpect(ReckonUpdateFeed.feedURL.path.hasSuffix("appcast-arm64.xml"))
        #else
        try bankExpect(ReckonUpdateFeed.feedURL.path.hasSuffix("appcast-x86_64.xml"))
        #endif
    }
}
