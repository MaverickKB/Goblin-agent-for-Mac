import SwiftUI

struct HistoryRotationSettingsView: View {
    @Bindable var store: GoblinStore
    var hasUnsavedChanges: Bool
    var onApplied: (JSONValue) -> Void
    @State private var histories: [JSONValue] = []
    @State private var selectedID = ""
    @State private var activeID = ""
    @State private var busy = false
    @State private var notice = ""

    private var changesUnavailable: Bool {
        busy || !store.isConnected || store.busy || store.approval != nil || hasUnsavedChanges
    }

    var body: some View {
        DisclosureGroup("Advanced: session history") {
            Text("Start fresh keeps your identity, settings, selected memory core and autonomy setup. Earlier histories remain available for recall; their exact messages, attachments and summaries are retained.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Retained history", selection: $selectedID) {
                Text("Choose a history").tag("")
                ForEach(histories, id: \.self) { history in
                    let id = history["id"].stringValue
                    let label = history["label"].stringValue
                    Text((label.isEmpty ? id : label) + (id == activeID ? " (current)" : "")).tag(id)
                }
            }.accessibilityIdentifier("history-retained-picker")
            HStack {
                Button("Start fresh history") { Task { await change("history/rotate", params: [:]) } }
                    .disabled(changesUnavailable).accessibilityIdentifier("history-start-fresh")
                Button("Recall selected history") {
                    Task { await change("history/select", params: ["id": .string(selectedID)]) }
                }.disabled(changesUnavailable || selectedID.isEmpty || selectedID == activeID)
                    .accessibilityIdentifier("history-recall-selected")
                Button("Refresh list") { Task { await load() } }
                    .disabled(busy || !store.isConnected)
            }
            Text("Running work and approvals finish before a history switch. These controls do not stop work. Save pending settings edits before switching.")
                .font(.caption).foregroundStyle(.secondary)
            if !notice.isEmpty { Text(notice).font(.caption).textSelection(.enabled) }
        }.task(id: store.isConnected) { if store.isConnected { await load() } }
    }

    private func load() async {
        guard store.isConnected else { return }
        let generation = store.connectionGeneration
        busy = true
        defer { if generation == store.connectionGeneration { busy = false } }
        do {
            let result = try await store.rpc("history/list", [:])
            guard generation == store.connectionGeneration, store.isConnected else { return }
            histories = result["histories"].arrayValue
            activeID = result["history_id"].stringValue
            var found = false
            for history in histories where history["id"].stringValue == selectedID { found = true }
            if !found { selectedID = activeID }
        } catch {
            if generation == store.connectionGeneration { notice = error.localizedDescription }
        }
    }

    private func change(_ method: String, params: [String: JSONValue]) async {
        guard !changesUnavailable else { return }
        let generation = store.connectionGeneration
        busy = true
        defer { if generation == store.connectionGeneration { busy = false } }
        do {
            let result = try await store.rpc(method, params)
            guard generation == store.connectionGeneration, store.isConnected else { return }
            onApplied(result)
            selectedID = result["history_id"].stringValue
            notice = "History selected. Earlier histories and the memory core are retained."
            await store.refresh()
            guard generation == store.connectionGeneration, store.isConnected else { return }
            await load()
        } catch {
            if generation == store.connectionGeneration { notice = error.localizedDescription }
        }
    }
}

struct AutonomySetupSettingsView: View {
    @Bindable var store: GoblinStore
    var hasUnsavedChanges: Bool
    var onApplied: (JSONValue) -> Void
    @State private var templates: [JSONValue] = []
    @State private var setups: [JSONValue] = []
    @State private var selectedID = ""
    @State private var activeID = ""
    @State private var name = ""
    @State private var busy = false
    @State private var notice = ""

    private var changesUnavailable: Bool {
        busy || !store.isConnected || store.busy || store.approval != nil || hasUnsavedChanges
    }

    var body: some View {
        DisclosureGroup("Advanced: autonomy setups and reset") {
            Text("Each setup includes all autonomy configuration, World View, the full floor definition and its own schedules and live state. Recall preserves the outgoing setup. The template catalog is shared; each Goblin owns its live setup state independently.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Template name", text: $name).accessibilityIdentifier("autonomy-template-name")
            Button("Save saved settings as template") {
                Task { await change("autonomy/template/save", params: ["name": .string(name)], apply: false) }
            }.disabled(changesUnavailable || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("autonomy-template-save")
            Text("Save settings edits first. Saving a template uses the saved setup, including its schedules; it does not apply unsaved fields.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Saved template or setup", selection: $selectedID) {
                Text("Choose a template or setup").tag("")
                ForEach(setups, id: \.self) { setup in
                    let id = setup["id"].stringValue
                    Text("Setup: " + displayName(setup) + (id == activeID ? " (current)" : "")).tag("setup:" + id)
                }
                ForEach(templates, id: \.self) { template in
                    Text("Template: " + displayName(template)).tag("template:" + template["id"].stringValue)
                }
            }.accessibilityIdentifier("autonomy-template-picker")
            HStack {
                Button("Recall selected") {
                    let prefix = selectedID.hasPrefix("setup:") ? "setup:" : "template:"
                    let id = String(selectedID.dropFirst(prefix.count))
                    Task { await change("autonomy/template/select", params: ["id": .string(id)], apply: true) }
                }.disabled(changesUnavailable || selectedID.isEmpty || selectedID == "setup:" + activeID)
                    .accessibilityIdentifier("autonomy-template-recall")
                Button("Reset to defaults") { Task { await change("autonomy/reset", params: [:], apply: true) } }
                    .disabled(changesUnavailable).accessibilityIdentifier("autonomy-reset-defaults")
                Button("Refresh list") { Task { await load() } }
                    .disabled(busy || !store.isConnected)
            }
            Text("Running jobs and approvals finish before recall or reset. Your outgoing setup, selected core and history remain retained. Reset creates default autonomy settings, not a new memory core or history.")
                .font(.caption).foregroundStyle(.secondary)
            if !notice.isEmpty { Text(notice).font(.caption).textSelection(.enabled) }
        }.task(id: store.isConnected) { if store.isConnected { await load() } }
    }

    private func displayName(_ item: JSONValue) -> String {
        let name = item["name"].stringValue
        return name.isEmpty ? item["id"].stringValue : name
    }

    private func load() async {
        guard store.isConnected else { return }
        let generation = store.connectionGeneration
        busy = true
        defer { if generation == store.connectionGeneration { busy = false } }
        do {
            let result = try await store.rpc("autonomy/templates", [:])
            guard generation == store.connectionGeneration, store.isConnected else { return }
            templates = result["templates"].arrayValue
            setups = result["setups"].arrayValue
            activeID = result["active_id"].stringValue
            var found = false
            for item in templates where "template:" + item["id"].stringValue == selectedID { found = true }
            for item in setups where "setup:" + item["id"].stringValue == selectedID { found = true }
            if !found {
                selectedID = ""
                for item in setups where item["id"].stringValue == activeID {
                    selectedID = "setup:" + activeID
                }
                if selectedID.isEmpty {
                    for item in templates where item["id"].stringValue == activeID {
                        selectedID = "template:" + activeID
                    }
                }
            }
        } catch {
            if generation == store.connectionGeneration { notice = error.localizedDescription }
        }
    }

    private func change(_ method: String, params: [String: JSONValue], apply: Bool) async {
        guard !changesUnavailable else { return }
        let generation = store.connectionGeneration
        var arguments = params
        arguments["expected_revision"] = .number(Double(store.settingsRevision))
        busy = true
        defer { if generation == store.connectionGeneration { busy = false } }
        do {
            let result = try await store.rpc(method, arguments)
            guard generation == store.connectionGeneration, store.isConnected else { return }
            if apply {
                onApplied(result)
                await store.refresh()
            }
            guard generation == store.connectionGeneration, store.isConnected else { return }
            notice = apply ? "Autonomy setup applied. The outgoing setup is retained." : "Saved setup copied to the template catalog."
            await load()
        } catch {
            if generation == store.connectionGeneration { notice = error.localizedDescription }
        }
    }
}
