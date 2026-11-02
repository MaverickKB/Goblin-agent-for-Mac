import Foundation
import XCTest
@testable import Goblin

final class HelpCatalogTests: XCTestCase {
    func testManualLinksStayInCatalogAndExternalLinksRemainExternal() {
        let documents = [HelpDocument(id: "concepts", title: "Concepts", audience: "user", file: "concepts.md")]
        XCTAssertEqual(HelpLinkDestination.resolve(URL(string: "concepts.md")!, documents: documents), .document("concepts"))
        XCTAssertEqual(HelpLinkDestination.resolve(URL(string: "concepts.md#history")!, documents: documents), .document("concepts"))
        XCTAssertEqual(HelpLinkDestination.resolve(URL(string: "https://example.com/manual")!, documents: documents), .external)
        XCTAssertEqual(HelpLinkDestination.resolve(URL(string: "file:///private/secret")!, documents: documents), .unavailable)
        XCTAssertEqual(HelpLinkDestination.resolve(URL(string: "../concepts.md")!, documents: documents), .unavailable)
        XCTAssertEqual(HelpLinkDestination.resolve(URL(string: "unknown.md")!, documents: documents), .unavailable)
    }

    func testFencedExampleRetainsBlankLinesAndLiteralHeadings() {
        let source = "# Manual\n\n```markdown\n## Example\n\nBody\n```\n\n## Real heading"
        let blocks = HelpMarkdown.blocks(source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(HelpMarkdown.codeText(blocks[1]), "## Example\n\nBody")
        XCTAssertEqual(blocks[2], "## Real heading")
    }

    func testManualCatalogReadsCanonicalDocumentAndRejectsEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"documents\":[{\"id\":\"user\",\"title\":\"User guide\",\"audience\":\"user\",\"file\":\"user.md\"}]}".utf8).write(to: root.appendingPathComponent("index.json"))
        try "# Guide\nGist and memory".write(to: root.appendingPathComponent("user.md"), atomically: true, encoding: .utf8)
        let catalog = try HelpCatalog.load(from: root)
        XCTAssertEqual(try catalog.read("user", from: root), "# Guide\nGist and memory")
        XCTAssertThrowsError(try catalog.read("../private", from: root))
        try Data("{\"documents\":[{\"id\":\"bad\",\"title\":\"Bad\",\"audience\":\"user\",\"file\":\"../private\"}]}".utf8).write(to: root.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try HelpCatalog.load(from: root))
    }
}
