import AppKit
import Foundation


struct Product: Decodable {
    let name: String
    let vendor: String
    let version: String
    let bundleID: String
    let defaultAvatar: String
    let keychainServices: [String: String]

    static func load(from resources: URL) throws -> Product {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Product.self, from: Data(contentsOf: resources.appendingPathComponent("product.json")))
    }

    enum CodingKeys: String, CodingKey {
        case name, vendor, version
        case bundleID = "bundleId"
        case defaultAvatar, keychainServices
    }
}

struct Avatar: Decodable, Identifiable {
    let id: String
    let name: String
    let file: String
    let standingFile: String

    enum CodingKeys: String, CodingKey {
        case id, name, file
        case standingFile = "standing_file"
    }
}

enum KeychainStore {
    static func read(service: String, account: String = "default") async throws -> String? {
        let response = try await KeychainBridge.request(KeychainRequest(operation: "get", service: service, account: account, value: nil))
        if response["state"] == "missing" { return nil }
        return response["value"]
    }

    static func save(_ value: String, service: String, account: String = "default") async throws {
        let response = try await KeychainBridge.request(KeychainRequest(operation: "put", service: service, account: account, value: value))
        guard response["state"] == "saved" else {
            throw GoblinError(message: "Credential save did not complete.")
        }
    }

    static func delete(service: String, account: String = "default") async throws {
        let response = try await KeychainBridge.request(KeychainRequest(operation: "delete", service: service, account: account, value: nil))
        guard response["state"] == "deleted" else {
            throw GoblinError(message: "Credential removal did not complete.")
        }
    }

    static func exists(service: String, account: String = "default") async throws -> Bool {
        let response = try await KeychainBridge.request(KeychainRequest(operation: "exists", service: service, account: account, value: nil))
        return response["state"] == "found"
    }
}

enum ModelKeyState: Equatable, Sendable {
    case present
    case missing
}

/// The Keychain operations the model credential helpers need. The live store
/// calls the bundled helper; tests use an in-memory store and never touch
/// Keychain. Every operation is async because the helper runs off the caller.
protocol KeychainItemStore: Sendable {
    func item(service: String, account: String) async throws -> String?
    func store(value: String, service: String, account: String) async throws
    func remove(service: String, account: String) async throws
    func hasItem(service: String, account: String) async throws -> Bool
}

struct SecurityKeychainItemStore: KeychainItemStore {
    func item(service: String, account: String) async throws -> String? {
        return try await KeychainStore.read(service: service, account: account)
    }

    func store(value: String, service: String, account: String) async throws {
        try await KeychainStore.save(value, service: service, account: account)
    }

    func remove(service: String, account: String) async throws {
        try await KeychainStore.delete(service: service, account: account)
    }

    func hasItem(service: String, account: String) async throws -> Bool {
        return try await KeychainStore.exists(service: service, account: account)
    }
}

extension KeychainStore {
    /// The account text for a model endpoint. It must match
    /// `canonical_model_endpoint` in Runtime/goblin_core/keychain.py exactly:
    /// trim surrounding whitespace, then remove trailing slashes after the host.
    static func modelAccount(endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = trimmed.range(of: "://") else { return "" }
        var end = trimmed.endIndex
        while end > scheme.upperBound, trimmed[trimmed.index(before: end)] == "/" {
            end = trimmed.index(before: end)
        }
        if end <= scheme.upperBound { return "" }
        return String(trimmed[..<end])
    }

    static func modelKeyState(service: String, endpoint: String,
                              store: KeychainItemStore = SecurityKeychainItemStore()) async throws -> ModelKeyState {
        let account = modelAccount(endpoint: endpoint)
        guard !account.isEmpty else {
            throw GoblinError(message: "Enter an API base URL before checking the model key.")
        }
        if try await store.hasItem(service: service, account: account) {
            return .present
        }
        return .missing
    }

    static func saveModelKey(_ value: String, service: String, endpoint: String,
                             store: KeychainItemStore = SecurityKeychainItemStore()) async throws {
        let account = modelAccount(endpoint: endpoint)
        guard !account.isEmpty else {
            throw GoblinError(message: "Enter an API base URL before saving the model key.")
        }
        guard !value.isEmpty else {
            throw GoblinError(message: "The model API key is empty.")
        }
        try await store.store(value: value, service: service, account: account)
    }

    static func deleteModelKey(service: String, endpoint: String,
                               store: KeychainItemStore = SecurityKeychainItemStore()) async throws {
        let account = modelAccount(endpoint: endpoint)
        guard !account.isEmpty else {
            throw GoblinError(message: "Enter an API base URL before removing the model key.")
        }
        try await store.remove(service: service, account: account)
    }
}
