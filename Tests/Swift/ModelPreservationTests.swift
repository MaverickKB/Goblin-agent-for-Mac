import Foundation
import XCTest
@testable import Goblin

final class ModelPreservationTests: XCTestCase {
    private func reloaded(_ draft: SettingsFormDraft) throws -> SettingsFormDraft {
        let request = try draft.saveRequest()
        let data = try JSONEncoder().encode(JSONValue.object(request.settings))
        let saved = try JSONDecoder().decode(JSONValue.self, from: data)
        return SettingsFormDraft.loaded(from: saved, revision: request.expectedRevision + 1)
    }

    func testLocalSettingsSurviveEditingBothCloudAccountsAndReloading() throws {
        var draft = SettingsFormDraft()
        draft.model = "fixture-local"
        draft.endpoint = "http://127.0.0.1:12345/v1"
        draft.apiKind = "responses"
        draft.cliCommand = "fixture-command"
        draft.reasoning = "medium"
        draft.thinkingBudget = 512
        let local = draft
        for provider in ["xai", "openai-codex"] {
            draft.modelConnection = provider
            XCTAssertEqual(draft.selectedModel, "")
            draft.selectedModel = "fixture-" + provider
            draft.selectedReasoning = "high"
            draft.selectedThinkingBudget = 4096
            draft = try reloaded(draft)
        }
        draft.modelConnection = "custom"
        draft = try reloaded(draft)
        XCTAssertEqual(draft.selectedModel, local.model)
        XCTAssertEqual(draft.selectedReasoning, local.reasoning)
        XCTAssertEqual(draft.selectedThinkingBudget, local.thinkingBudget)
        XCTAssertEqual(draft.endpoint, local.endpoint)
        XCTAssertEqual(draft.apiKind, local.apiKind)
        XCTAssertEqual(draft.cliCommand, local.cliCommand)
        for provider in ["xai", "openai-codex"] {
            draft.modelConnection = provider
            XCTAssertEqual(draft.selectedModel, "fixture-" + provider)
            XCTAssertEqual(draft.selectedReasoning, "high")
            XCTAssertEqual(draft.selectedThinkingBudget, 4096)
        }
    }

    func testCliConfigurationSurvivesTheAccountSwitch() throws {
        var draft = SettingsFormDraft()
        draft.model = "fixture-local-cli"
        draft.apiKind = "cli_worker"
        draft.cliCommand = "fixture-command --mode local"
        draft.modelConnection = "xai"
        draft.selectedModel = "fixture-cloud"
        draft = try reloaded(draft)
        draft.modelConnection = "custom"
        XCTAssertEqual(draft.selectedModel, "fixture-local-cli")
        XCTAssertEqual(draft.apiKind, "cli_worker")
        XCTAssertEqual(draft.cliCommand, "fixture-command --mode local")
    }

    func testCompressionStoresEachConnectionWithoutChangingChat() throws {
        var form = SettingsFormDraft()
        form.model = "fixture-chat"
        var draft = CompactorDraft()
        draft.connection = "custom"
        draft.model = "fixture-local-summary"
        draft.endpoint = "http://127.0.0.1:12346/v1"
        draft.apiKind = "responses"
        draft.connection = ""
        draft.setSelectedModel("fixture-inherited-local", inheriting: "custom")
        for provider in ["xai", "openai-codex"] {
            draft.connection = provider
            draft.setSelectedModel("summary-" + provider, inheriting: "custom")
        }
        form.advancedText = try SettingsCompactorDraft.applying(draft, to: form.advancedText)
        form = try reloaded(form)
        draft = try SettingsCompactorDraft.values(in: form.advancedText)
        draft.connection = "custom"
        XCTAssertEqual(draft.selectedModel(inheriting: "custom"), "fixture-local-summary")
        XCTAssertEqual(draft.endpoint, "http://127.0.0.1:12346/v1")
        XCTAssertEqual(draft.apiKind, "responses")
        XCTAssertEqual(form.model, "fixture-chat")
        draft.connection = ""
        XCTAssertEqual(draft.selectedModel(inheriting: "custom"), "fixture-inherited-local")
        for provider in ["xai", "openai-codex"] {
            XCTAssertEqual(draft.selectedModel(inheriting: provider), "summary-" + provider)
        }
    }

    func testLocalInheritanceOverrideDoesNotBecomeACloudModel() {
        var draft = CompactorDraft()
        draft.inheritModel = "fixture-local-only"
        XCTAssertEqual(draft.selectedModel(inheriting: "custom"), "fixture-local-only")
        XCTAssertEqual(draft.selectedModel(inheriting: "xai"), "")
        draft.setSelectedModel("fixture-cloud", inheriting: "xai")
        XCTAssertEqual(draft.selectedModel(inheriting: "xai"), "fixture-cloud")
        XCTAssertEqual(draft.selectedModel(inheriting: "custom"), "fixture-local-only")
    }
}
