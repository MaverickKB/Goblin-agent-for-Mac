import Foundation
import XCTest
@testable import Goblin

final class ModelCatalogTests: XCTestCase {
    func testCompactionDefaultIsANonReasoningXaiModel() {
        let id = ModelCatalog.defaultCompactionModel(for: AccountProvider.xai)
        XCTAssertEqual(id, "grok-4.20-0309-non-reasoning")
        let model = ModelCatalog.xai.first { $0.id == id }
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.reasoning, false)
    }

    func testCatalogCarriesTheDocumentedXaiIds() {
        let ids = Set(ModelCatalog.xai.map(\.id))
        for id in ["grok-4.7", "grok-4.6", "grok-4.5", "grok-4.3",
                   "grok-4.20-0309-reasoning", "grok-4.20-0309-non-reasoning",
                   "grok-4.20-multi-agent-0309", "grok-build-0.1"] {
            XCTAssertTrue(ids.contains(id), "missing documented id \(id)")
        }
    }

    func testProviderWithoutCatalogHasNoCompactionDefault() {
        XCTAssertNil(ModelCatalog.defaultCompactionModel(for: "openai-codex"))
        XCTAssertTrue(ModelCatalog.models(for: "openai-codex").isEmpty)
    }

    func testUnknownSavedIdIsPreservedAsItsOwnRow() {
        let fetched = [AccountModel(.object(["id": .string("grok-4.7"), "name": .string("Grok 4.7")]))]
        let choices = ModelSelection.rows(provider: AccountProvider.xai, saved: "grok-4-7", fetched: fetched)
        XCTAssertEqual(choices.savedNotInCatalog, "grok-4-7")
        XCTAssertEqual(choices.rows.map(\.id), ["grok-4.7"])
    }

    func testKnownSavedIdIsNotDuplicatedAsAMismatchRow() {
        let fetched = [AccountModel(.object(["id": .string("grok-4.7"), "name": .string("Grok 4.7")]))]
        let choices = ModelSelection.rows(provider: AccountProvider.xai, saved: "grok-4.7", fetched: fetched)
        XCTAssertNil(choices.savedNotInCatalog)
    }

    func testEmptyFetchFallsBackToTheSeedCatalog() {
        let choices = ModelSelection.rows(provider: AccountProvider.xai, saved: "", fetched: [])
        XCTAssertTrue(choices.usedSeed)
        XCTAssertEqual(choices.rows.count, ModelCatalog.xai.count)
        XCTAssertNil(choices.savedNotInCatalog)
    }

    func testSuggestionNamesTheClosestCatalogIdForATypo() {
        XCTAssertEqual(ModelCatalog.suggestion(for: "grok-4-7", in: ModelCatalog.xai), "grok-4.7")
        XCTAssertNil(ModelCatalog.suggestion(for: "grok-4.7", in: ModelCatalog.xai))
        XCTAssertNil(ModelCatalog.suggestion(for: "", in: ModelCatalog.xai))
    }

    func testCompactionDefaultOnlyFillsAnEmptyChoice() {
        var draft = CompactorDraft()
        draft.applyCompactionDefault(inheriting: AccountProvider.xai)
        XCTAssertEqual(draft.selectedModel(inheriting: AccountProvider.xai), "grok-4.20-0309-non-reasoning")

        var saved = CompactorDraft()
        saved.setSelectedModel("grok-4-7", inheriting: AccountProvider.xai)
        saved.applyCompactionDefault(inheriting: AccountProvider.xai)
        XCTAssertEqual(saved.selectedModel(inheriting: AccountProvider.xai), "grok-4-7",
                       "a saved id must survive the default")

        var cleared = CompactorDraft()
        cleared.setSelectedModel("", inheriting: AccountProvider.xai)
        cleared.applyCompactionDefault(inheriting: AccountProvider.xai)
        XCTAssertEqual(cleared.selectedModel(inheriting: AccountProvider.xai), "",
                       "an operator-cleared entry must stay cleared")

        var custom = CompactorDraft()
        custom.applyCompactionDefault(inheriting: AccountConnectionOptions.customID)
        XCTAssertEqual(custom.selectedModel(inheriting: AccountConnectionOptions.customID), "")
    }
}
