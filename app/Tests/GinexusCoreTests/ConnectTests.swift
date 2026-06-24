import XCTest
@testable import GinexusCore

final class ConnectTests: XCTestCase {
    func testMcpServerConfigRoundTrip() throws {
        let cfg = McpServerConfig(name: "notion", command: "npx -y @notionhq/notion-mcp-server",
                                  enabled: true, tokenEnv: "NOTION_TOKEN", credentialRef: "mcp.notion.token")
        let enc = JSONEncoder(), dec = JSONDecoder()
        let back = try dec.decode(McpServerConfig.self, from: enc.encode(cfg))
        XCTAssertEqual(back.name, "notion")
        XCTAssertEqual(back.command, "npx -y @notionhq/notion-mcp-server")
        XCTAssertEqual(back.tokenEnv, "NOTION_TOKEN")
        XCTAssertEqual(back.credentialRef, "mcp.notion.token")
        XCTAssertTrue(back.enabled)
    }

    func testSettingsCarryMcpServersAndBackCompat() throws {
        // Settings with servers round-trips.
        var s = GinexusSettings()
        s.mcpServers = [McpServerConfig(name: "notion", command: "npx notion")]
        let enc = JSONEncoder(), dec = JSONDecoder()
        let back = try dec.decode(GinexusSettings.self, from: enc.encode(s))
        XCTAssertEqual(back.mcpServers.count, 1)
        XCTAssertEqual(back.mcpServers.first?.name, "notion")

        // Legacy settings.json without mcpServers/voiceEnabled still decodes (defaults applied).
        let legacy = #"{"defaultModel":"auto","ollamaBase":"http://127.0.0.1:11434/v1"}"#
        let old = try dec.decode(GinexusSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.mcpServers, [])
        XCTAssertTrue(old.voiceEnabled)   // default
    }
}
