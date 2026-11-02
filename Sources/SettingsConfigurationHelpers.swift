import SwiftUI

struct CustomModelDraft: Equatable, Identifiable {
    var id: String
    var name = "New model"
    var endpoint = ""
    var model = ""
    var apiKind = "chat_completions"
    var cliCommand = ""
    var reasoning = "low"
    var thinkingBudget = 0

    init(id: String = UUID().uuidString) { self.id = id }

    init(id: String, value: JSONValue) {
        self.id = id
        name = value["name"].stringValue
        endpoint = value["model_base_url"].stringValue
        model = value["model"].stringValue
        apiKind = value["api_kind"].stringValue
        cliCommand = value["cli_command"].stringValue
        reasoning = value["reasoning"].stringValue
        thinkingBudget = Int(value["thinking_budget"].numberValue)
    }

    var value: JSONValue {
        .object(["name": .string(name), "model_base_url": .string(endpoint), "model": .string(model),
                 "api_kind": .string(apiKind), "cli_command": .string(cliCommand),
                 "reasoning": .string(reasoning), "thinking_budget": .number(Double(thinkingBudget))])
    }
}

extension SettingsFormDraft {
    mutating func useCustomModelForChat(_ preset: CustomModelDraft) {
        modelConnection = AccountConnectionOptions.customID
        model = preset.model
        endpoint = preset.endpoint
        apiKind = preset.apiKind
        cliCommand = preset.cliCommand
        reasoning = preset.reasoning
        thinkingBudget = preset.thinkingBudget
    }
}

enum SettingsConfiguration {
    static func objectSection(_ key: String, in root: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let value = root[key], value != .null else { return [:] }
        guard case .object(let fields) = value else { throw GoblinError(message: key + " must be a JSON object.") }
        return fields
    }

    static func setTool(_ name: String, enabled: Bool, in text: String) throws -> String {
        try setTools([name], enabled: enabled, in: text)
    }

    static func toolEnabled(_ name: String, in text: String) -> Bool {
        guard let root = try? SettingsAdvancedDraft.parseObject(text) else { return false }
        return !(root["tools"]?["disabled"].arrayValue ?? []).contains(.string(name))
    }

    static func actingToolNames(_ tools: [JSONValue]) -> [String] {
        var names: [String] = []
        for tool in tools {
            let name = tool["name"].stringValue
            let actingClass = tool["approval_classes"].arrayValue.contains(.string("acting"))
            if !name.isEmpty && (tool["risky"].boolValue || actingClass) {
                names.append(name)
            }
        }
        return names
    }

    static func setTools(_ names: [String], enabled: Bool, in text: String) throws -> String {
        var root = try SettingsAdvancedDraft.parseObject(text)
        var tools = try objectSection("tools", in: root)
        if let value = tools["disabled"] {
            guard case .array = value else { throw GoblinError(message: "tools.disabled must be an array.") }
        }
        var disabled: [JSONValue] = []
        for value in tools["disabled"]?.arrayValue ?? [] {
            if !names.contains(value.stringValue) { disabled.append(value) }
        }
        if !enabled {
            for name in names where !name.isEmpty {
                if !disabled.contains(.string(name)) { disabled.append(.string(name)) }
            }
        }
        tools["disabled"] = .array(disabled)
        root["tools"] = .object(tools)
        return JSONValue.object(root).formatted
    }

    static func toolAuthority(_ tool: JSONValue) -> String {
        var details = [tool["enabled"].boolValue ? "Runtime enabled" : "Runtime disabled"]
        if tool["risky"] != .null {
            details.append(tool["risky"].boolValue ? "marked risky" : "not marked risky")
        }
        let rule = tool["approval_rule"].stringValue
        if !rule.isEmpty { details.append("approval rule: " + rule) }
        for value in tool["approval_classes"].arrayValue {
            details.append("class: " + value.stringValue)
        }
        let origin = tool["origin"].stringValue
        if !origin.isEmpty { details.append("origin: " + origin) }
        return details.joined(separator: " · ")
    }

    static func setServer(_ name: String, value: JSONValue?, in text: String) throws -> String {
        var root = try SettingsAdvancedDraft.parseObject(text)
        var servers = try objectSection("mcp_servers", in: root)
        servers[name] = value
        root["mcp_servers"] = .object(servers)
        return JSONValue.object(root).formatted
    }

    static func setFloorRule(_ index: Int, enabled: Bool, in text: String) throws -> String {
        var root = try SettingsAdvancedDraft.parseObject(text)
        guard case .array(var rules) = root["rules"], rules.indices.contains(index),
              case .object(var rule) = rules[index] else {
            throw GoblinError(message: "Read a JSON floor definition before using guided controls.")
        }
        rule["enabled"] = .bool(enabled)
        rules[index] = .object(rule)
        root["rules"] = .array(rules)
        return JSONValue.object(root).formatted
    }

    static func setFloorGuidance(_ value: String, in text: String) throws -> String {
        var root = try SettingsAdvancedDraft.parseObject(text)
        var compose = try objectSection("compose", in: root)
        compose["quiet_paragraph"] = .string(value)
        root["compose"] = .object(compose)
        return JSONValue.object(root).formatted
    }

    static func applyingCompression(_ preset: CustomModelDraft, to text: String) throws -> String {
        guard preset.apiKind != "cli_worker" else { throw GoblinError(message: "Compression uses an HTTP model endpoint.") }
        var values = try SettingsCompactorDraft.values(in: text)
        values.connection = AccountConnectionOptions.customID
        values.model = preset.model
        values.endpoint = preset.endpoint
        values.apiKind = preset.apiKind
        return try SettingsCompactorDraft.applying(values, to: text)
    }
}

struct CustomModelEditor: View {
    @Binding var preset: CustomModelDraft
    let useChat: () -> Void
    let useCompression: () -> Void
    let remove: () -> Void

    var body: some View {
        DisclosureGroup(preset.name.isEmpty ? "Unnamed model" : preset.name) {
            SettingsTextField("Name", text: $preset.name, identifier: "preset-name-" + preset.id)
            Picker("Protocol", selection: $preset.apiKind) {
                Text("OpenAI-compatible").tag("chat_completions")
                Text("Responses API").tag("responses")
                Text("CLI worker").tag("cli_worker")
            }
            if preset.apiKind == "cli_worker" {
                SettingsTextField("CLI command", text: $preset.cliCommand, identifier: "preset-command-" + preset.id)
            } else {
                SettingsTextField("API base URL", text: $preset.endpoint, identifier: "preset-endpoint-" + preset.id)
            }
            SettingsTextField("Model", text: $preset.model, identifier: "preset-model-" + preset.id)
            Picker("Reasoning", selection: $preset.reasoning) {
                ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            TextField("Thinking budget", value: $preset.thinkingBudget, format: .number)
            HStack {
                Button("Use for chat", action: useChat)
                Button("Use for compression", action: useCompression).disabled(preset.apiKind == "cli_worker")
                Spacer()
                Button("Remove saved model", role: .destructive, action: remove)
            }
            if preset.apiKind == "cli_worker" {
                Text("Compression uses an HTTP model endpoint.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MCPServerDraft {
    var name = ""
    var url = ""
    var command = ""
    var usesCommand = false

    func value() throws -> JSONValue {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoblinError(message: "Give the integration a name.")
        }
        if usesCommand {
            guard let data = command.data(using: .utf8),
                  let argv = try? JSONDecoder().decode([String].self, from: data), !argv.isEmpty else {
                throw GoblinError(message: "Enter a JSON command array, such as [\"/path/to/server\", \"--stdio\"].")
            }
            var values: [JSONValue] = []
            for argument in argv { values.append(.string(argument)) }
            return .object(["command": .array(values), "enabled": .bool(true), "session_tools": .bool(true)])
        }
        guard let endpoint = URL(string: url), ["http", "https"].contains(endpoint.scheme ?? ""), endpoint.host != nil else {
            throw GoblinError(message: "Enter the integration’s HTTP or HTTPS URL.")
        }
        return .object(["url": .string(url), "enabled": .bool(true), "session_tools": .bool(true)])
    }
}

struct AssistedSettingsDraft: View {
    let kind: String
    @Binding var destination: String
    @Environment(\.dismiss) private var dismiss
    @State private var purpose = ""
    @State private var priorities = ""
    @State private var boundaries = ""
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create " + kind).font(.title2)
            Text("Use these prompts to create a starting draft. You can freely edit every word afterward.").font(.caption)
            TextField(kind == "personality" ? "Voice and character" : "What matters in your world", text: $purpose)
            TextField(kind == "personality" ? "How to work with you" : "Priorities and useful initiative", text: $priorities)
            TextField("Boundaries and preferences", text: $boundaries)
            Button("Create editable preview") {
                preview = "## " + (kind == "personality" ? "Voice and character" : "World and purpose") + "\n" + purpose
                    + "\n\n## " + (kind == "personality" ? "Working together" : "Priorities and initiative") + "\n" + priorities
                    + "\n\n## Boundaries and preferences\n" + boundaries
            }
            SettingsTextEditor(text: $preview, label: "Editable draft preview").frame(minHeight: 220)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Use this draft") { destination = preview; dismiss() }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 540, height: 470)
    }
}
