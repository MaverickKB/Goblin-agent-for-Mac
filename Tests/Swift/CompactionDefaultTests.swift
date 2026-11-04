import Foundation
import XCTest
@testable import Goblin

final class CompactionDefaultTests: XCTestCase {
    private func loaded(settings: [String: JSONValue]) throws -> SettingsFormDraft {
        var draft = SettingsFormDraft.loaded(from: .object(settings), revision: 1)
        var compactor = try SettingsCompactorDraft.values(in: draft.advancedText)
        compactor.applyCompactionDefault(inheriting: draft.modelConnection)
        draft.advancedText = try SettingsCompactorDraft.applying(compactor, to: draft.advancedText)
        return draft
    }

    func testFreshXaiSetupGetsTheNonReasoningCompactionDefault() throws {
        let form = try loaded(settings: [
            "model_connection": .string(AccountProvider.xai),
            "account_models": .object([AccountProvider.xai: .object(["model": .string("grok-4.7")])])
        ])
        let compactor = try SettingsCompactorDraft.values(in: form.advancedText)
        XCTAssertEqual(compactor.selectedModel(inheriting: AccountProvider.xai), "grok-4.20-0309-non-reasoning")
    }

    func testSavedCompactionModelIsNotOverwrittenOnLoad() throws {
        let form = try loaded(settings: [
            "model_connection": .string(AccountProvider.xai),
            "advanced": .object(["compactor": .object([
                "account_models": .object([AccountProvider.xai: .object(["model": .string("grok-4.3")])])
            ])])
        ])
        let compactor = try SettingsCompactorDraft.values(in: form.advancedText)
        XCTAssertEqual(compactor.selectedModel(inheriting: AccountProvider.xai), "grok-4.3")
    }

    func testCustomChatConnectionGetsNoCompactionDefault() throws {
        let form = try loaded(settings: [
            "model_connection": .string(AccountConnectionOptions.customID),
            "model": .string("local-model")
        ])
        let compactor = try SettingsCompactorDraft.values(in: form.advancedText)
        XCTAssertEqual(compactor.selectedModel(inheriting: AccountConnectionOptions.customID), "")
    }

    func testExplicitCompactorConnectionDrivesItsOwnDefault() throws {
        let form = try loaded(settings: [
            "model_connection": .string(AccountConnectionOptions.customID),
            "model": .string("local-model"),
            "advanced": .object(["compactor": .object(["connection": .string(AccountProvider.xai)])])
        ])
        let compactor = try SettingsCompactorDraft.values(in: form.advancedText)
        XCTAssertEqual(compactor.selectedModel(inheriting: AccountConnectionOptions.customID),
                       "grok-4.20-0309-non-reasoning")
    }
}
