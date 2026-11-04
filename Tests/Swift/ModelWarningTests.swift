import Foundation
import XCTest
@testable import Goblin

final class ModelWarningTests: XCTestCase {
    private func draft(chat: String, compactor: [String: JSONValue]) -> SettingsFormDraft {
        var draft = SettingsFormDraft()
        draft.modelConnection = AccountProvider.xai
        draft.selectedModel = chat
        draft.advancedText = JSONValue.object(["compactor": .object(compactor)]).formatted
        return draft
    }

    func testGuessedCompactorIdWarnsWithoutBlockingTheSave() throws {
        let form = draft(chat: "grok-4.7",
                             compactor: ["account_models": .object([
                                AccountProvider.xai: .object(["model": .string("grok-4-7")])
                             ])])
        let warnings = form.modelWarnings()
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("grok-4-7"))
        XCTAssertTrue(warnings[0].contains("grok-4.7"))
        XCTAssertTrue(warnings[0].contains("Compression"))
        XCTAssertNoThrow(try form.saveRequest())
    }

    func testCatalogIdsProduceNoWarning() throws {
        let form = draft(chat: "grok-4.7",
                             compactor: ["account_models": .object([
                                AccountProvider.xai: .object(["model": .string("grok-4.20-0309-non-reasoning")])
                             ])])
        XCTAssertTrue(form.modelWarnings().isEmpty)
    }

    func testCustomEndpointIsNotWarnedAbout() throws {
        var form = SettingsFormDraft()
        form.modelConnection = AccountConnectionOptions.customID
        form.model = "anything-local"
        XCTAssertTrue(form.modelWarnings().isEmpty)
    }
}
