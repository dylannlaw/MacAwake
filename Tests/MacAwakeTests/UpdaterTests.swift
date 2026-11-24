import Testing
import Foundation
@testable import MacAwake

struct UpdaterTests {
    @Test func components() {
        #expect(Updater.components("v1.0.42") == [1, 0, 42])
        #expect(Updater.components("1.0-dev") == [1, 0])
        #expect(Updater.components("") == nil)
        #expect(Updater.components("abc") == nil)
        #expect(Updater.components("1.2.3.4.5") == nil)
        #expect(Updater.components("1..2") == nil)
        #expect(Updater.components("1.-2") == nil)
    }

    @Test func isNewer() {
        #expect(Updater.isNewer("v1.0.10", than: "1.0.9"))
        #expect(Updater.isNewer("1.1", than: "1.0.5"))
        #expect(!(Updater.isNewer("1.0.0", than: "1.0")))
        #expect(!(Updater.isNewer("1.0.1", than: "1.0.1")))
        #expect(!(Updater.isNewer("1.0.1", than: "1.0.2")))
        #expect(!(Updater.isNewer("junk", than: "1.0")))
    }

    @Test func allowedDownloads() {
        let base = "https://github.com/dylannlaw/MacAwake/releases/download/v1.0.1/MacAwake.zip"
        #expect(Updater.isAllowedDownload(URL(string: base)!))
        #expect(!(Updater.isAllowedDownload(URL(string: "http://github.com/dylannlaw/MacAwake/releases/download/v1/x")!)))
        #expect(!(Updater.isAllowedDownload(URL(string: "https://evil.com/dylannlaw/MacAwake/releases/download/v1/x")!)))
        #expect(!(Updater.isAllowedDownload(URL(string: "https://github.com/other/repo/releases/download/v1/x")!)))
        #expect(!(Updater.isAllowedDownload(URL(fileURLWithPath: "/tmp/x.zip"))))
    }
}
