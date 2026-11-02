import Foundation
import XCTest
@testable import Goblin

final class SettingsRevisionTests: XCTestCase {
    @MainActor
    func testOwnAutonomyToggleMergesOnlyReturnedChangeAndPreservesUnsavedFields() throws {
        var form = SettingsFormDraft()
        form.revision = 4
        form.agentName = "Unsaved name"
        form.workspace = "/tmp/unsaved workspace"
        form.instructions = "Unsaved instructions"
        form.advancedText = "{\"tools\": {\"mode\": \"ask\"}, \"autonomy\": {\"enabled\": false, \"interval\": 30}}"
        let outcome = SettingsMutationOutcome(ReleaseRepairTestSupport.snapshot(
            revision: 6, settingsRevision: 5, autonomy: true))
        XCTAssertEqual(outcome.revision, 5)
        XCTAssertTrue(outcome.autonomyEnabled == true)
        try form.adoptAutonomy(enabled: outcome.autonomyEnabled ?? false, revision: outcome.revision)
        XCTAssertEqual(form.revision, 5)
        XCTAssertEqual(form.agentName, "Unsaved name")
        XCTAssertEqual(form.workspace, "/tmp/unsaved workspace")
        XCTAssertEqual(form.instructions, "Unsaved instructions")
        let advanced = try SettingsAdvancedDraft.parseObject(form.advancedText)
        XCTAssertEqual(advanced["autonomy"]?["enabled"], .bool(true))
        XCTAssertEqual(advanced["autonomy"]?["interval"], .number(30))
        XCTAssertEqual(advanced["tools"]?["mode"], .string("ask"))
        XCTAssertEqual(try form.saveRequest().expectedRevision, 5)
    }

    @MainActor
    func testMalformedAdvancedJSONBlocksTheToggleWithoutMutation() {
        var form = SettingsFormDraft()
        form.revision = 3
        form.agentName = "Unsaved name"
        form.advancedText = "{\"tools\":"
        let before = form
        XCTAssertThrowsError(try form.validateAdvancedForAutonomy())
        XCTAssertThrowsError(try form.adoptAutonomy(enabled: true, revision: 9))
        XCTAssertEqual(form, before)
        form.advancedText = "{\"autonomy\": \"on\"}"
        XCTAssertThrowsError(try form.validateAdvancedForAutonomy())
        XCTAssertEqual(form.advancedText, "{\"autonomy\": \"on\"}")
    }

    @MainActor
    func testStaleAcknowledgementAdoptsItsOwnRevisionAndStillProtectsNewerSettings() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.apply(ReleaseRepairTestSupport.snapshot(revision: 12, settingsRevision: 9,
            agentName: "External"))
        var form = SettingsFormDraft()
        form.revision = 9
        form.agentName = "External"
        form.advancedText = "{}"
        let acknowledgement = ReleaseRepairTestSupport.snapshot(revision: 8, settingsRevision: 8,
            autonomy: true, agentName: "Acknowledged")
        let outcome = store.adoptSettingsMutation(acknowledgement)
        XCTAssertEqual(outcome.revision, 8)
        XCTAssertEqual(Int(store.snapshot["settings_revision"].numberValue), 9)
        XCTAssertEqual(store.name, "External")
        try form.adoptAutonomy(enabled: outcome.autonomyEnabled ?? false, revision: outcome.revision)
        XCTAssertEqual(form.revision, 8)
        XCTAssertEqual(form.agentName, "External")
        let request = try form.saveRequest()
        XCTAssertEqual(request.expectedRevision, 8)
        store.rpc = { method, params in
            let expected = Int(params["expected_revision"]?.numberValue ?? -1)
            if method == "settings/save" && expected != 9 {
                throw GoblinError(message: "Settings changed since this form was loaded")
            }
            return acknowledgement
        }
        do {
            _ = try await store.saveSettings(request.settings, expectedRevision: request.expectedRevision)
            XCTFail("A stale acknowledged revision must not overwrite newer settings")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Settings changed since this form was loaded")
        }
        XCTAssertEqual(form.revision, 8)
    }

    @MainActor
    func testPostCommitSettingsIssueKeepsReturnedRevisionAndClearsOnLaterSuccess() throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let failed = ReleaseRepairTestSupport.snapshot(revision: 4, settingsRevision: 6,
            ready: false, settingsIssue: "Autonomy worker did not start")
        let failedOutcome = store.adoptSettingsMutation(failed)
        XCTAssertEqual(failedOutcome.revision, 6)
        XCTAssertEqual(failedOutcome.saveNotice, "Saved; not applied: Autonomy worker did not start")
        XCTAssertEqual(store.settingsIssue, "Autonomy worker did not start")
        XCTAssertEqual(store.setupIssue, "Autonomy worker did not start")
        XCTAssertFalse(store.ready)
        let repaired = ReleaseRepairTestSupport.snapshot(revision: 5, settingsRevision: 7, ready: true)
        let repairedOutcome = store.adoptSettingsMutation(repaired)
        XCTAssertEqual(repairedOutcome.revision, 7)
        XCTAssertEqual(repairedOutcome.saveNotice, "Saved")
        XCTAssertEqual(store.settingsIssue, "")
        XCTAssertTrue(store.ready)
    }

    @MainActor
    func testAutonomyAndSaveWireUseTheLoadedRevisionAndToolbarOmitsIt() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        let probe = RPCProbe()
        let acknowledgement = ReleaseRepairTestSupport.snapshot(revision: 3, settingsRevision: 3,
            autonomy: true)
        store.rpc = { method, params in
            probe.record(method, params)
            return acknowledgement
        }
        _ = try await store.setAutonomy(true, expectedRevision: 2)
        let autonomyParams = probe.lastParameters(for: "autonomy/set")
        XCTAssertEqual(autonomyParams?["expected_revision"]?.numberValue, 2)
        XCTAssertEqual(autonomyParams?["enabled"], .bool(true))
        await store.setAutonomy(false)
        let toolbarParams = probe.lastParameters(for: "autonomy/set")
        XCTAssertEqual(toolbarParams?["enabled"], .bool(false))
        XCTAssertNil(toolbarParams?["expected_revision"])
        _ = try await store.saveSettings(["agent_name": .string("A")], expectedRevision: 7)
        let saveParams = probe.lastParameters(for: "settings/save")
        XCTAssertEqual(saveParams?["expected_revision"]?.numberValue, 7)
        XCTAssertEqual(saveParams?["settings"]?["agent_name"], .string("A"))
    }

    @MainActor
    func testRevisionConflictLeavesDraftRevisionAndAdvancedIntact() async throws {
        let store = try ReleaseRepairTestSupport.makeStore()
        defer { ReleaseRepairTestSupport.removeStore(store) }
        store.rpc = { _, _ in
            throw GoblinError(message: "Settings changed since this form was loaded")
        }
        var form = SettingsFormDraft()
        form.revision = 4
        form.agentName = "Unsaved name"
        form.advancedText = "{\"tools\": {\"mode\": \"safe\"}}"
        let before = form
        do {
            _ = try await store.setAutonomy(true, expectedRevision: form.revision)
            XCTFail("A stale revision must fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Settings changed since this form was loaded")
        }
        XCTAssertEqual(form, before)
    }
}
