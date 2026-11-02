import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MemoryCoreDraft {
    static func selectingLocalProject(_ project: String, in text: String) throws -> String {
        guard !project.isEmpty else { throw GoblinError(message: "Created core path was not returned.") }
        var object = try SettingsAdvancedDraft.parseObject(text)
        var connection: [String: JSONValue] = [:]
        if let existing = object["aethermind"], existing != .null {
            guard case .object(let fields) = existing else {
                throw GoblinError(message: "AetherMind configuration must be a JSON object.")
            }
            connection = fields
        }
        connection["mode"] = .string("embedded")
        connection["local_project"] = .string(project)
        object["aethermind"] = .object(connection)
        return JSONValue.object(object).formatted
    }
}

@MainActor
enum MemoryCoreFilePanel {
    static func present(_ panel: NSSavePanel, for window: NSWindow,
                        selection: @escaping @MainActor (URL?) -> Void) {
        panel.beginSheetModal(for: window) { result in
            selection(result == .OK ? panel.url : nil)
        }
    }
}

struct MemoryCoreSettingsView: View {
    @Bindable var store: GoblinStore
    @Binding var advancedText: String
    @Binding var notice: String
    @State private var busy = false
    @State private var report: JSONValue = .null
    @State private var importedProject = ""

    private var connection: [String: JSONValue] {
        guard let object = try? SettingsAdvancedDraft.parseObject(advancedText),
              case .object(let fields) = object["aethermind"] else { return [:] }
        return fields
    }

    private var inspectionTitle: String {
        if report["mode"].stringValue == "remote" {
            return report["compatible"].boolValue ? "Remote core connection verified" : "Remote core connection needs attention"
        }
        return report["compatible"].boolValue ? "Compatible memory format" : "Format requires a supported adapter"
    }

    private func field(_ name: String, default fallback: String = "") -> Binding<String> {
        Binding(get: { connection[name]?.stringValue ?? fallback }, set: { value in
            do {
                var object = try SettingsAdvancedDraft.parseObject(advancedText)
                var fields: [String: JSONValue] = [:]
                if let value = object["aethermind"], value != .null {
                    guard case .object(let existing) = value else {
                        throw GoblinError(message: "AetherMind configuration must be a JSON object.")
                    }
                    fields = existing
                }
                fields[name] = .string(value)
                object["aethermind"] = .object(fields)
                advancedText = JSONValue.object(object).formatted
            } catch { notice = error.localizedDescription }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The embedded core keeps this Goblin's memory on this Mac. You can use an independent project core or connect to an existing core.")
                .font(.caption).foregroundStyle(.secondary)
            if store.snapshot["memory"]["foundation"]["status"].stringValue == "unavailable" {
                Text(store.snapshot["memory"]["foundation"]["error"].stringValue)
                    .font(.caption).foregroundStyle(.orange)
            }
            if store.snapshot["memory"]["pending_change"].boolValue {
                Text("Core change saved for the next turn. The running turn keeps its current memory.")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("AetherMind core connection") {
                Picker("Core", selection: field("mode", default: "embedded")) {
                    Text("Embedded / local core").tag("embedded")
                    Text("Existing remote core (MCP)").tag("remote")
                }.accessibilityIdentifier("memory-core-mode")
                if field("mode", default: "embedded").wrappedValue == "remote" {
                    SettingsTextField("MCP endpoint", text: field("endpoint"), identifier: "memory-endpoint")
                    SettingsTextField("Remote project root or key", text: field("project"), identifier: "memory-project")
                    SettingsTextField("Token environment variable (optional)", text: field("token_env"), identifier: "memory-token-env")
                    Text("Use the project path or key on the server that owns the core. The optional variable names a token supplied when Goblin starts; it does not store the token here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        SettingsTextField("Local project folder", text: field("local_project"), identifier: "memory-local-project")
                        Button("Choose…") { chooseLocalCore() }.accessibilityIdentifier("memory-choose-local")
                    }
                    Text("Leave blank for the embedded default. An existing core's project folder contains .aethermind.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Save settings to change cores. Running work keeps its current client and capture target until it finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Inspect compatibility") { Task { await inspect() } }
                    .disabled(busy).accessibilityIdentifier("memory-inspect")
            }
            HStack {
                Button("Export active local core…") { exportCore() }
                    .disabled(busy || store.snapshot["memory"]["mode"].stringValue == "remote")
                    .accessibilityIdentifier("memory-export")
                Button("Import core backup…") { importCore() }
                    .disabled(busy).accessibilityIdentifier("memory-import")
            }
            Text("Backups preserve native memory files. Imports create a separate copy, preserve the original, and inspect compatibility before use. Remote cores use their existing MCP interface; this export copies local stores.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Advanced core rotation") {
                Text("Create a separate core with generic foundations or clean, empty memory. The previous core is retained. Save settings to activate the new core.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Create core with generic foundations") { Task { await createCore(seeded: true) } }
                        .disabled(busy).accessibilityIdentifier("memory-create-seeded")
                    Button("Create clean empty core") { Task { await createCore(seeded: false) } }
                        .disabled(busy).accessibilityIdentifier("memory-create-empty")
                }
                Text("Other settings and shared skills are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if report != .null {
                VStack(alignment: .leading, spacing: 4) {
                    if report["compatible"] != .null {
                        Text(inspectionTitle)
                            .foregroundStyle(report["compatible"].boolValue ? Color.secondary : .orange)
                    }
                    Text(report["project_root"].stringValue).font(.caption).textSelection(.enabled)
                    ForEach(Array(report["issues"].arrayValue.enumerated()), id: \.offset) { _, issue in
                        Text(issue["file"].stringValue + ": " + issue["message"].stringValue)
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if report["derived_tree"]["rebuild_pending"].boolValue {
                        Text("The summary tree needs rebuilding. Its bytes and the authored memory are preserved.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    DisclosureGroup("Inspection details") {
                        Text(report.formatted).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.accessibilityIdentifier("memory-inspection-result")
            }
            if !importedProject.isEmpty {
                Text("Imported copy: " + importedProject).font(.caption).textSelection(.enabled)
                Button("Use imported copy") {
                    field("local_project").wrappedValue = importedProject
                    field("mode", default: "embedded").wrappedValue = "embedded"
                    notice = "Imported copy selected. Save settings to use it. The source remains unchanged."
                }.accessibilityIdentifier("memory-use-import")
            }
        }
    }

    private func createCore(seeded: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await store.engine.call("memory/create", ["seeded": .bool(seeded)])
            report = result["inspection"]
            advancedText = try MemoryCoreDraft.selectingLocalProject(result["project_root"].stringValue, in: advancedText)
            notice = seeded
                ? "New core with generic foundations selected in this draft. Save settings to activate it. The previous core is retained."
                : "New empty core selected in this draft. Save settings to activate it. The previous core is retained."
        } catch { notice = error.localizedDescription }
    }

    private func chooseLocalCore() {
        guard let window = store.presentationWindow else {
            notice = "The companion window is not available."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose the project folder containing .aethermind."
        busy = true
        MemoryCoreFilePanel.present(panel, for: window) { url in
            busy = false
            guard let url else { return }
            field("local_project").wrappedValue = url.path
        }
    }

    private func inspect() async {
        busy = true
        report = .null
        let inspectedConnection = connection
        defer { busy = false }
        do {
            let result = try await store.engine.call("memory/inspect", ["connection": .object(inspectedConnection)])
            guard connection == inspectedConnection else {
                notice = "Connection draft changed. Inspect the current values again."
                return
            }
            report = result
            notice = result["healthy"] == .bool(false) ? "Inspection found issues. Review the report." : "Compatibility inspection complete."
        } catch { notice = error.localizedDescription }
    }

    private func exportCore() {
        guard let window = store.presentationWindow else {
            notice = "The companion window is not available."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = store.name + "-AetherMind.zip"
        panel.allowedContentTypes = [.zip]
        busy = true
        MemoryCoreFilePanel.present(panel, for: window) { url in
            guard let url else {
                busy = false
                return
            }
            Task { @MainActor in
                defer { busy = false }
                do {
                    _ = try await store.engine.call("memory/export", ["destination": .string(url.path)])
                    notice = "Core backup saved to " + url.path
                } catch { notice = error.localizedDescription }
            }
        }
    }

    private func importCore() {
        guard let window = store.presentationWindow else {
            notice = "The companion window is not available."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        busy = true
        MemoryCoreFilePanel.present(panel, for: window) { url in
            guard let url else {
                busy = false
                return
            }
            Task { @MainActor in
                defer { busy = false }
                do {
                    let result = try await store.engine.call("memory/import", ["archive": .string(url.path)])
                    importedProject = result["project_root"].stringValue
                    report = result["inspection"]
                    notice = "Core imported as a separate copy. Review the inspection before selecting it."
                } catch { notice = error.localizedDescription }
            }
        }
    }
}
