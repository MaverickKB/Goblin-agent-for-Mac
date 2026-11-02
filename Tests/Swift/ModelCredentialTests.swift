import XCTest
@testable import Goblin

private let endpointA = "https://provider-a.example/v1"
private let endpointB = "https://provider-b.example/v1"
private let service = "app.model"

/// In-memory stand-in so these tests never touch the real Keychain. The actor
/// keeps the store safe while the helpers call it across an await.
private actor MemoryKeychainItemStore: KeychainItemStore {
    private var items: [String: String] = [:]
    private var itemReads = 0

    private func key(service: String, account: String) -> String {
        return service + "\u{0}" + account
    }

    func item(service: String, account: String) async throws -> String? {
        itemReads += 1
        return items[key(service: service, account: account)]
    }

    func store(value: String, service: String, account: String) async throws {
        items[key(service: service, account: account)] = value
    }

    func remove(service: String, account: String) async throws {
        items.removeValue(forKey: key(service: service, account: account))
    }

    func hasItem(service: String, account: String) async throws -> Bool {
        return items[key(service: service, account: account)] != nil
    }

    func storedValue(service: String, account: String) -> String? {
        return items[key(service: service, account: account)]
    }

    func readCount() -> Int {
        return itemReads
    }

    func resetReadCount() {
        itemReads = 0
    }
}

final class ModelCredentialTests: XCTestCase {
    func testModelAccountMatchesTheRuntimeContract() {
        XCTAssertEqual(KeychainStore.modelAccount(endpoint: endpointA), endpointA)
        XCTAssertEqual(KeychainStore.modelAccount(endpoint: "  " + endpointA + "//  "), endpointA)
        XCTAssertEqual(KeychainStore.modelAccount(endpoint: "https://provider.example"), "https://provider.example")
        XCTAssertEqual(KeychainStore.modelAccount(endpoint: "https://"), "")
        XCTAssertEqual(KeychainStore.modelAccount(endpoint: "provider.example/v1"), "")
        XCTAssertEqual(KeychainStore.modelAccount(endpoint: ""), "")
    }

    func testKeysAreBoundToTheirEndpoint() async throws {
        let store = MemoryKeychainItemStore()
        try await KeychainStore.saveModelKey("key-a-probe", service: service, endpoint: endpointA, store: store)
        try await KeychainStore.saveModelKey("key-b-probe", service: service, endpoint: endpointB, store: store)
        let stateA = try await KeychainStore.modelKeyState(service: service, endpoint: endpointA, store: store)
        let stateB = try await KeychainStore.modelKeyState(service: service, endpoint: endpointB, store: store)
        XCTAssertEqual(stateA, .present)
        XCTAssertEqual(stateB, .present)
        let storedA = await store.storedValue(service: service, account: endpointA)
        let storedB = await store.storedValue(service: service, account: endpointB)
        XCTAssertEqual(storedA, "key-a-probe")
        XCTAssertEqual(storedB, "key-b-probe")
    }

    func testUnsavedDraftBindsToTheDisplayedEndpoint() async throws {
        let store = MemoryKeychainItemStore()
        try await KeychainStore.saveModelKey("key-b-probe", service: service, endpoint: endpointB, store: store)
        let state = try await KeychainStore.modelKeyState(service: service, endpoint: endpointA, store: store)
        XCTAssertEqual(state, .missing)
    }

    func testStatusAndRemovalNeverReadTheSecret() async throws {
        let store = MemoryKeychainItemStore()
        try await KeychainStore.saveModelKey("key-a-probe", service: service, endpoint: endpointA, store: store)
        await store.resetReadCount()
        let present = try await KeychainStore.modelKeyState(service: service, endpoint: endpointA, store: store)
        XCTAssertEqual(present, .present)
        let readsAfterStatus = await store.readCount()
        XCTAssertEqual(readsAfterStatus, 0)
        try await KeychainStore.deleteModelKey(service: service, endpoint: endpointA, store: store)
        let missing = try await KeychainStore.modelKeyState(service: service, endpoint: endpointA, store: store)
        XCTAssertEqual(missing, .missing)
        let readsAfterRemoval = await store.readCount()
        XCTAssertEqual(readsAfterRemoval, 0)
    }

    func testRemovingOneEndpointKeepsTheOther() async throws {
        let store = MemoryKeychainItemStore()
        try await KeychainStore.saveModelKey("key-a-probe", service: service, endpoint: endpointA, store: store)
        try await KeychainStore.saveModelKey("key-b-probe", service: service, endpoint: endpointB, store: store)
        try await KeychainStore.deleteModelKey(service: service, endpoint: endpointA, store: store)
        let stateA = try await KeychainStore.modelKeyState(service: service, endpoint: endpointA, store: store)
        let stateB = try await KeychainStore.modelKeyState(service: service, endpoint: endpointB, store: store)
        XCTAssertEqual(stateA, .missing)
        XCTAssertEqual(stateB, .present)
    }

    func testTrailingSlashDraftUsesTheSameAccount() async throws {
        let store = MemoryKeychainItemStore()
        try await KeychainStore.saveModelKey("key-a-probe", service: service, endpoint: endpointA + "/", store: store)
        let state = try await KeychainStore.modelKeyState(service: service, endpoint: endpointA, store: store)
        XCTAssertEqual(state, .present)
    }

    func testBlankEndpointIsRejectedByEveryHelper() async {
        let store = MemoryKeychainItemStore()
        await expectGoblinError("Enter an API base URL before checking the model key.") {
            _ = try await KeychainStore.modelKeyState(service: service, endpoint: "  ", store: store)
        }
        await expectGoblinError("Enter an API base URL before saving the model key.") {
            try await KeychainStore.saveModelKey("probe", service: service, endpoint: "", store: store)
        }
        await expectGoblinError("Enter an API base URL before removing the model key.") {
            try await KeychainStore.deleteModelKey(service: service, endpoint: "", store: store)
        }
    }

    func testEmptyKeyIsRejected() async {
        let store = MemoryKeychainItemStore()
        await expectGoblinError("The model API key is empty.") {
            try await KeychainStore.saveModelKey("", service: service, endpoint: endpointA, store: store)
        }
        let stored = await store.storedValue(service: service, account: endpointA)
        XCTAssertNil(stored)
    }

    private func expectGoblinError(_ message: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line,
                                   _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected an error: " + message, file: file, line: line)
        } catch let error as GoblinError {
            XCTAssertEqual(error.message, message, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: " + error.localizedDescription, file: file, line: line)
        }
    }
}
