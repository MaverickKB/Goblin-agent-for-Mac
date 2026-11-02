import Foundation
import XCTest
@testable import Goblin

final class SettingsConnectionsTests: XCTestCase {
    func testAccountOptionsComeOnlyFromManifestReportsInTheirOrder() {
        let reports = [
            AccountReport(.object([
                "provider": .string("xai"),
                "name": .string("xAI"),
                "status": .string("signed_in")
            ])),
            AccountReport(.object([
                "provider": .string("openai-codex"),
                "name": .string("OpenAI"),
                "status": .string("missing")
            ]))
        ]
        let options = AccountConnectionOptions.accountOptions(reports: reports, selected: "custom")
        XCTAssertEqual(options.map(\.id), ["xai", "openai-codex"])
        XCTAssertEqual(options.map(\.label), ["xAI", "OpenAI"])
    }

    func testSavedAccountSelectionSurvivesBeforeReportsLoad() {
        let beforeLoad = AccountConnectionOptions.accountOptions(reports: [], selected: "openai-codex")
        XCTAssertEqual(beforeLoad.map(\.id), ["openai-codex"])
        XCTAssertEqual(beforeLoad.first?.label, "openai-codex")

        let reports = [
            AccountReport(.object([
                "provider": .string("openai-codex"),
                "name": .string("OpenAI")
            ]))
        ]
        let afterLoad = AccountConnectionOptions.accountOptions(reports: reports, selected: "openai-codex")
        XCTAssertEqual(afterLoad.map(\.id), ["openai-codex"])
        XCTAssertEqual(afterLoad.first?.label, "OpenAI")
    }

    func testCustomConnectionDoesNotInventAnAccountOption() {
        let reports = [
            AccountReport(.object(["provider": .string("xai"), "name": .string("xAI")])),
            AccountReport(.object(["provider": .string("custom"), "name": .string("Ignored")]))
        ]
        let options = AccountConnectionOptions.accountOptions(reports: reports, selected: "")
        XCTAssertEqual(options.map(\.id), ["xai"])
    }

    func testDraftLoadsModelConnectionWithoutReplacingCustomRoute() throws {
        let settings = JSONValue.object([
            "model_connection": .string("openai-codex"),
            "model": .string("chat-model"),
            "model_base_url": .string("https://chat.example/v1"),
            "api_kind": .string("responses"),
            "advanced": .object([
                "tools": .object(["mode": .string("ask")]),
                "compactor": .object([
                    "workers": .number(2),
                    "connection": .string("xai"),
                    "model": .string("grok-compact"),
                    "model_base_url": .string("https://compact.example/v1"),
                    "api_kind": .string("responses")
                ])
            ])
        ])
        let draft = SettingsFormDraft.loaded(from: settings, revision: 11)
        XCTAssertEqual(draft.modelConnection, "openai-codex")
        XCTAssertEqual(draft.model, "chat-model")
        XCTAssertEqual(draft.endpoint, "https://chat.example/v1")
        XCTAssertEqual(draft.apiKind, "responses")

        let compactor = try SettingsCompactorDraft.values(in: draft.advancedText)
        XCTAssertEqual(compactor.connection, "xai")
        XCTAssertEqual(compactor.model, "grok-compact")
        XCTAssertEqual(compactor.endpoint, "https://compact.example/v1")
        XCTAssertEqual(compactor.apiKind, "responses")
    }

    func testSelectingAccountConnectionKeepsCustomChatValuesInTheSaveRequest() throws {
        var draft = SettingsFormDraft()
        draft.revision = 3
        draft.model = "chat-model"
        draft.endpoint = "https://chat.example/v1"
        draft.apiKind = "chat_completions"
        draft.modelConnection = "xai"
        let request = try draft.saveRequest()
        XCTAssertEqual(request.settings["model_connection"], .string("xai"))
        XCTAssertEqual(request.settings["model"], .string("chat-model"))
        XCTAssertEqual(request.settings["model_base_url"], .string("https://chat.example/v1"))
        XCTAssertEqual(request.settings["api_kind"], .string("chat_completions"))
    }

    func testCompactorMergeWritesOnlyCompressionKeys() throws {
        let advanced = JSONValue.object([
            "tools": .object(["mode": .string("ask")]),
            "autonomy": .object(["enabled": .bool(true), "interval": .number(30)]),
            "compactor": .object([
                "workers": .number(2),
                "judge_threshold": .number(0.9)
            ])
        ])
        var values = try SettingsCompactorDraft.values(in: advanced.formatted)
        XCTAssertEqual(values.connection, "")
        XCTAssertEqual(values.model, "")
        XCTAssertEqual(values.apiKind, "chat_completions")

        values.connection = "custom"
        values.model = "cheap-compactor"
        values.endpoint = "https://compact.example/v1"
        values.apiKind = "responses"
        let mergedText = try SettingsCompactorDraft.applying(values, to: advanced.formatted)
        let merged = try SettingsAdvancedDraft.parseObject(mergedText)
        XCTAssertEqual(merged["tools"]?["mode"], .string("ask"))
        XCTAssertEqual(merged["autonomy"]?["enabled"], .bool(true))
        XCTAssertEqual(merged["autonomy"]?["interval"], .number(30))
        XCTAssertEqual(merged["compactor"]?["workers"], .number(2))
        XCTAssertEqual(merged["compactor"]?["judge_threshold"], .number(0.9))
        XCTAssertEqual(merged["compactor"]?["connection"], .string("custom"))
        XCTAssertEqual(merged["compactor"]?["model"], .string("cheap-compactor"))
        XCTAssertEqual(merged["compactor"]?["model_base_url"], .string("https://compact.example/v1"))
        XCTAssertEqual(merged["compactor"]?["api_kind"], .string("responses"))
    }

    func testCompactorSelectionRoundTripsThroughSaveWithoutChangingChatModel() throws {
        var draft = SettingsFormDraft()
        draft.revision = 5
        draft.modelConnection = "custom"
        draft.model = "chat-model"
        draft.endpoint = "https://chat.example/v1"
        var values = try SettingsCompactorDraft.values(in: draft.advancedText)
        values.connection = "openai-codex"
        values.model = "compact-model"
        values.endpoint = "https://compact.example/v1"
        draft.advancedText = try SettingsCompactorDraft.applying(values, to: draft.advancedText)
        let request = try draft.saveRequest()
        XCTAssertEqual(request.settings["model"], .string("chat-model"))
        XCTAssertEqual(request.settings["model_base_url"], .string("https://chat.example/v1"))
        XCTAssertEqual(request.settings["model_connection"], .string("custom"))
        let advancedValue = request.settings["advanced"] ?? .null
        let saved = try SettingsAdvancedDraft.parseObject(advancedValue.formatted)
        XCTAssertEqual(saved["compactor"]?["connection"], .string("openai-codex"))
        XCTAssertEqual(saved["compactor"]?["model"], .string("compact-model"))
        XCTAssertEqual(saved["compactor"]?["model_base_url"], .string("https://compact.example/v1"))
    }

    func testChangingCompactionConnectionPreservesModelAndEndpoint() {
        var draft = CompactorDraft()
        draft.connection = "custom"
        draft.model = "compact-model"
        draft.endpoint = "https://compact.example/v1"
        draft.apiKind = "responses"
        let preserved = draft
        draft.connection = ""
        XCTAssertEqual(draft.model, preserved.model)
        XCTAssertEqual(draft.endpoint, preserved.endpoint)
        XCTAssertEqual(draft.apiKind, preserved.apiKind)
    }

    func testAccountAttemptGateRejectsAnOlderCompletion() {
        var gate = AccountAttemptGate()
        let first = gate.beginAction()
        XCTAssertTrue(gate.isCurrent(first))
        let second = gate.beginAction()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testWaitingAccountReportDrivesVisibleActionsWithoutGrantInternals() {
        let report = AccountReport(.object([
            "provider": .string("openai-codex"),
            "name": .string("OpenAI"),
            "status": .string("waiting"),
            "verification_url": .string("https://auth.openai.com/codex/device"),
            "user_code": .string("ABCD-1234"),
            "message": .string("Approve this code in the browser."),
            "grant": .object([
                "state": .string("missing")
            ])
        ]))
        XCTAssertEqual(report.statusLabel, "Waiting for approval")
        XCTAssertEqual(report.actionTitle, "Connect")
        XCTAssertTrue(report.canCancel)
        XCTAssertTrue(report.canOpenPage)
        XCTAssertEqual(report.userCode, "ABCD-1234")
    }

    func testAccountPageRequiresHTTPS() {
        var report = AccountReport()
        report.verificationURL = "http://auth.example/device"
        XCTAssertFalse(report.canOpenPage)
        report.verificationURL = "https://auth.example/device"
        XCTAssertTrue(report.canOpenPage)
    }

    func testAccountCheckKeepsOnlyNamedModels() {
        let check = AccountCheck(.object([
            "provider": .string("xai"),
            "ok": .bool(true),
            "message": .string(""),
            "models": .array([
                .object(["id": .string("grok-4"), "name": .string("Grok 4")]),
                .object(["name": .string("No identifier")])
            ])
        ]))
        XCTAssertEqual(check.provider, "xai")
        XCTAssertEqual(check.models.count, 1)
        XCTAssertEqual(check.models.first?.id, "grok-4")
        XCTAssertEqual(check.models.first?.displayName, "Grok 4")
        XCTAssertEqual(check.summary, "Connection OK")
    }

    func testUnconfiguredAccountDoesNotInventAReasoningSelection() {
        var draft = SettingsFormDraft()
        draft.modelConnection = "openai-codex"
        XCTAssertEqual(draft.selectedReasoning, "")
        draft.selectedModel = "gpt-6.1-terra"
        XCTAssertEqual(draft.selectedReasoning, "low")
        draft.selectedReasoning = "high"
        XCTAssertEqual(draft.selectedReasoning, "high")
        XCTAssertEqual(draft.accountModels["openai-codex"]?.model, "gpt-6.1-terra")
        XCTAssertEqual(draft.accountModels["openai-codex"]?.reasoning, "high")
    }

    func testUnconfiguredAccountSavesNoAccountModelSlot() throws {
        var draft = SettingsFormDraft()
        draft.revision = 4
        draft.modelConnection = "openai-codex"
        let request = try draft.saveRequest()
        XCTAssertEqual(request.settings["account_models"], .object([:]))
        XCTAssertEqual(request.settings["model_connection"], .string("openai-codex"))
    }
}
