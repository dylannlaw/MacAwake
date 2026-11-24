import Testing
import Foundation
@testable import MacAwake

struct WatchedItemTests {
    @Test func cleanCommandName() {
        #expect(WatchedItem.cleanCommandName("Claude") == "claude")
        #expect(WatchedItem.cleanCommandName("  /usr/local/bin/Node ") == "node")
        #expect(WatchedItem.cleanCommandName("cursor-agent") == "cursor-agent")
        #expect(WatchedItem.cleanCommandName("") == nil)
        #expect(WatchedItem.cleanCommandName("bad name") == nil)
        #expect(WatchedItem.cleanCommandName("rm;ls") == nil)
        #expect(WatchedItem.cleanCommandName(String(repeating: "a", count: 65)) == nil)
    }

    @Test func presets() {
        #expect(WatchedItem.aiAgentPresets.count == 6)
        #expect(WatchedItem.aiAgentPresets.allSatisfy { $0.kind == .command })
    }
}
