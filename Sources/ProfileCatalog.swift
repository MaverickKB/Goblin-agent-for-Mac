import Foundation

struct GoblinProfile: Codable, Equatable, Identifiable {
    let id: String
    static let defaultProfile = GoblinProfile(id: "default")
}

struct ProfileChoice: Equatable, Identifiable {
    let id: String
    let name: String
}

final class ProfileCatalog {
    let applicationHome: URL
    private var path: URL { applicationHome.appendingPathComponent("profiles.json") }

    init(applicationHome: URL) { self.applicationHome = applicationHome }

    func profiles() throws -> [GoblinProfile] {
        if !FileManager.default.fileExists(atPath: path.path) { return [.defaultProfile] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: path))
        guard document.version == 1 else { throw GoblinError(message: "Unsupported profile catalog version.") }
        var profiles: [GoblinProfile] = [.defaultProfile]
        for profile in document.profiles {
            _ = try home(for: profile)
            if !profiles.contains(profile) { profiles.append(profile) }
        }
        return profiles
    }

    func home(for profile: GoblinProfile) throws -> URL {
        if profile == .defaultProfile { return applicationHome }
        guard UUID(uuidString: profile.id) != nil else { throw GoblinError(message: "Invalid Goblin profile ID.") }
        return applicationHome.appendingPathComponent("profiles").appendingPathComponent(profile.id)
    }

    func prepare() throws -> GoblinProfile {
        let profile = GoblinProfile(id: UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: home(for: profile), withIntermediateDirectories: true)
        return profile
    }

    func publish(_ profile: GoblinProfile) throws {
        var profiles = try profiles()
        if profiles.contains(profile) { return }
        _ = try home(for: profile)
        profiles.append(profile)
        let data = try JSONEncoder().encode(Document(version: 1, profiles: profiles))
        try FileManager.default.createDirectory(at: applicationHome, withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    func name(for profile: GoblinProfile, defaultName: String) -> String {
        guard let home = try? home(for: profile),
              let data = try? Data(contentsOf: home.appendingPathComponent("config.json")),
              let settings = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return profile == .defaultProfile ? defaultName : profile.id
        }
        let name = settings["agent_name"].stringValue
        if !name.isEmpty { return name }
        return profile == .defaultProfile ? defaultName : profile.id
    }

    private struct Document: Codable {
        let version: Int
        let profiles: [GoblinProfile]
    }
}
