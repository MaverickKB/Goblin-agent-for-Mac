import AppKit
import SwiftUI

enum SettingsAdvancedDraft {
    static func parseObject(_ text: String) throws -> [String: JSONValue] {
        let data = Data(text.utf8)
        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw GoblinError(message: "Advanced configuration must be valid JSON.")
        }
        guard case .object(let object) = decoded else {
            throw GoblinError(message: "Advanced configuration must be a JSON object.")
        }
        return object
    }

    static func autonomyObject(in object: [String: JSONValue]) throws -> [String: JSONValue] {
        let value = object["autonomy"] ?? .null
        if value == .null { return [:] }
        guard case .object(let autonomy) = value else {
            throw GoblinError(message: "Advanced autonomy configuration must be a JSON object.")
        }
        return autonomy
    }

    static func mergingAutonomy(_ enabled: Bool, into text: String) throws -> String {
        var object = try parseObject(text)
        var autonomy = try autonomyObject(in: object)
        autonomy["enabled"] = .bool(enabled)
        object["autonomy"] = .object(autonomy)
        return JSONValue.object(object).formatted
    }
}

struct AccountModelDraft: Equatable {
    var model = ""
    var reasoning = "low"
    var thinkingBudget = 0
}

enum SettingsAccountModels {
    static func values(_ value: JSONValue) -> [String: AccountModelDraft] {
        var slots: [String: AccountModelDraft] = [:]
        guard case .object(let fields) = value else { return slots }
        for (provider, settings) in fields {
            var choice = AccountModelDraft()
            choice.model = settings["model"].stringValue
            if !settings["reasoning"].stringValue.isEmpty {
                choice.reasoning = settings["reasoning"].stringValue
            }
            choice.thinkingBudget = Int(settings["thinking_budget"].numberValue)
            slots[provider] = choice
        }
        return slots
    }

    static func object(_ slots: [String: AccountModelDraft]) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for (provider, choice) in slots {
            fields[provider] = .object([
                "model": .string(choice.model),
                "reasoning": .string(choice.reasoning),
                "thinking_budget": .number(Double(choice.thinkingBudget))
            ])
        }
        return .object(fields)
    }
}

struct CompactorDraft: Equatable {
    var connection = ""
    var model = ""
    var endpoint = ""
    var apiKind = "chat_completions"
    var inheritModel = ""
    var accountModels: [String: AccountModelDraft] = [:]

    func selectedModel(inheriting connection: String) -> String {
        if self.connection == AccountConnectionOptions.customID { return model }
        let selected = self.connection.isEmpty ? connection : self.connection
        if selected == AccountConnectionOptions.customID { return inheritModel }
        return accountModels[selected]?.model ?? ""
    }

    mutating func setSelectedModel(_ value: String, inheriting connection: String) {
        if self.connection == AccountConnectionOptions.customID {
            model = value
            return
        }
        let selected = self.connection.isEmpty ? connection : self.connection
        if selected == AccountConnectionOptions.customID {
            inheritModel = value
            return
        }
        var choice = accountModels[selected] ?? AccountModelDraft()
        choice.model = value
        accountModels[selected] = choice
    }

    /// Seed the operator's requested default: a fast non-reasoning model from
    /// the provider's catalog. Only an absent entry is seeded; an entry the
    /// operator saved, even one cleared to empty, is left alone.
    mutating func applyCompactionDefault(inheriting connection: String) {
        guard self.connection != AccountConnectionOptions.customID else { return }
        let selected = self.connection.isEmpty ? connection : self.connection
        guard selected != AccountConnectionOptions.customID, !selected.isEmpty else { return }
        guard accountModels[selected] == nil else { return }
        guard let model = ModelCatalog.defaultCompactionModel(for: selected) else { return }
        var choice = AccountModelDraft()
        choice.model = model
        accountModels[selected] = choice
    }
}

enum SettingsCompactorDraft {
    static func values(in object: [String: JSONValue]) -> CompactorDraft {
        let compactor = object["compactor"] ?? .null
        var values = CompactorDraft()
        values.connection = compactor["connection"].stringValue
        values.model = compactor["model"].stringValue
        values.endpoint = compactor["model_base_url"].stringValue
        values.inheritModel = compactor["inherit_model"].stringValue
        values.accountModels = SettingsAccountModels.values(compactor["account_models"])
        let kind = compactor["api_kind"].stringValue
        if !kind.isEmpty { values.apiKind = kind }
        return values
    }

    static func values(in text: String) throws -> CompactorDraft {
        let object = try SettingsAdvancedDraft.parseObject(text)
        return values(in: object)
    }


    static func applying(_ values: CompactorDraft, to text: String) throws -> String {
        var object = try SettingsAdvancedDraft.parseObject(text)
        let existing = object["compactor"] ?? .null
        var compactor: [String: JSONValue]
        if existing == .null {
            compactor = [:]
        } else {
            guard case .object(let fields) = existing else {
                throw GoblinError(message: "Advanced compression configuration must be a JSON object.")
            }
            compactor = fields
        }
        compactor["connection"] = .string(values.connection)
        compactor["model"] = .string(values.model)
        compactor["model_base_url"] = .string(values.endpoint)
        compactor["api_kind"] = .string(values.apiKind)
        compactor["inherit_model"] = .string(values.inheritModel)
        compactor["account_models"] = SettingsAccountModels.object(values.accountModels)
        object["compactor"] = .object(compactor)
        return JSONValue.object(object).formatted
    }
}

struct SettingsSaveRequest {
    let settings: [String: JSONValue]
    let expectedRevision: Int
}

struct SettingsFormDraft: Equatable {
    var revision = 0
    var agentName = ""
    var workspace = ""
    var instructions = ""
    var endpoint = ""
    var model = ""
    var apiKind = "chat_completions"
    var modelConnection = AccountConnectionOptions.customID
    var accountModels: [String: AccountModelDraft] = [:]
    var cliCommand = ""
    var reasoning = "low"
    var thinkingBudget = 0
    var approval = "ask"
    var worldView = ""
    var floorInterval: Double = 60
    var voiceModel = ""
    var voiceName = ""
    var voiceAuth = "oauth"
    var advancedText = "{}"
    var customModels: [String: CustomModelDraft] = [:]

    var selectedModel: String {
        get {
            if modelConnection == AccountConnectionOptions.customID { return model }
            return accountModels[modelConnection]?.model ?? ""
        }
        set {
            if modelConnection == AccountConnectionOptions.customID {
                model = newValue
            } else {
                var choice = accountModels[modelConnection] ?? AccountModelDraft()
                choice.model = newValue
                accountModels[modelConnection] = choice
            }
        }
    }

    var selectedReasoning: String {
        get {
            if modelConnection == AccountConnectionOptions.customID { return reasoning }
            guard let choice = accountModels[modelConnection] else { return "" }
            return choice.reasoning
        }
        set {
            if modelConnection == AccountConnectionOptions.customID {
                reasoning = newValue
            } else if !newValue.isEmpty {
                var choice = accountModels[modelConnection] ?? AccountModelDraft()
                choice.reasoning = newValue
                accountModels[modelConnection] = choice
            }
        }
    }

    var selectedThinkingBudget: Int {
        get {
            if modelConnection == AccountConnectionOptions.customID { return thinkingBudget }
            return accountModels[modelConnection]?.thinkingBudget ?? 0
        }
        set {
            if modelConnection == AccountConnectionOptions.customID {
                thinkingBudget = newValue
            } else {
                var choice = accountModels[modelConnection] ?? AccountModelDraft()
                choice.thinkingBudget = newValue
                accountModels[modelConnection] = choice
            }
        }
    }

    static func canonicalApproval(_ value: String) -> String {
        switch value {
        case "unleashed", "yolo":
            return "unleashed"
        default:
            return "ask"
        }
    }

    static func approvalLabel(_ value: String) -> String {
        canonicalApproval(value) == "unleashed" ? "Unleashed" : "Ask when needed"
    }

    static func loaded(from settings: JSONValue, revision: Int) -> SettingsFormDraft {
        var draft = SettingsFormDraft()
        draft.revision = revision
        draft.agentName = settings["agent_name"].stringValue
        draft.workspace = settings["workspace"].stringValue
        draft.instructions = settings["user_instructions"].stringValue
        draft.endpoint = settings["model_base_url"].stringValue
        draft.model = settings["model"].stringValue
        if !settings["api_kind"].stringValue.isEmpty { draft.apiKind = settings["api_kind"].stringValue }
        if !settings["model_connection"].stringValue.isEmpty { draft.modelConnection = settings["model_connection"].stringValue }
        draft.accountModels = SettingsAccountModels.values(settings["account_models"])
        for (id, value) in settings["custom_models"].objectValue {
            draft.customModels[id] = CustomModelDraft(id: id, value: value)
        }
        draft.cliCommand = settings["cli_command"].stringValue
        if !settings["reasoning"].stringValue.isEmpty { draft.reasoning = settings["reasoning"].stringValue }
        draft.thinkingBudget = Int(settings["thinking_budget"].numberValue)
        if !settings["approval"].stringValue.isEmpty {
            draft.approval = SettingsFormDraft.canonicalApproval(settings["approval"].stringValue)
        }
        draft.worldView = settings["world_view"].stringValue
        if settings["floor_interval_seconds"].numberValue > 0 {
            draft.floorInterval = settings["floor_interval_seconds"].numberValue
        }
        draft.voiceModel = settings["voice_model"].stringValue
        draft.voiceName = settings["voice_name"].stringValue
        if !settings["voice_auth"].stringValue.isEmpty { draft.voiceAuth = settings["voice_auth"].stringValue }
        if settings["advanced"] != .null { draft.advancedText = settings["advanced"].formatted }
        return draft
    }

    func saveRequest() throws -> SettingsSaveRequest {
        let advanced = try SettingsAdvancedDraft.parseObject(advancedText)
        var savedModels: [String: JSONValue] = [:]
        for (id, model) in customModels { savedModels[id] = model.value }
        let settings: [String: JSONValue] = [
            "agent_name": .string(agentName),
            "workspace": .string(workspace),
            "user_instructions": .string(instructions),
            "model_base_url": .string(endpoint),
            "model": .string(model),
            "api_kind": .string(apiKind),
            "model_connection": .string(modelConnection),
            "account_models": SettingsAccountModels.object(accountModels),
            "custom_models": .object(savedModels),
            "cli_command": .string(cliCommand),
            "reasoning": .string(reasoning),
            "thinking_budget": .number(Double(thinkingBudget)),
            "approval": .string(approval),
            "world_view": .string(worldView),
            "floor_interval_seconds": .number(floorInterval),
            "voice_model": .string(voiceModel),
            "voice_name": .string(voiceName),
            "voice_auth": .string(voiceAuth),
            "advanced": .object(advanced)
        ]
        return SettingsSaveRequest(settings: settings, expectedRevision: revision)
    }

    /// Non-blocking: an id the catalog does not know may simply be a model the
    /// provider shipped after this build. Name the closest match so a typo is
    /// visible without stopping the save.
    func modelWarnings() -> [String] {
        var warnings: [String] = []
        func check(_ provider: String, _ id: String, _ what: String) {
            guard provider != AccountConnectionOptions.customID, !provider.isEmpty else { return }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let suggestion = ModelCatalog.suggestion(for: trimmed, in: ModelCatalog.models(for: provider)) else { return }
            warnings.append("\(what) model \"\(trimmed)\" is not in the known \(provider) catalog. Closest match: \(suggestion).")
        }
        if modelConnection != AccountConnectionOptions.customID {
            check(modelConnection, selectedModel, "Chat")
        }
        let compactor = (try? SettingsCompactorDraft.values(in: advancedText)) ?? CompactorDraft()
        let compactorProvider = compactor.connection.isEmpty ? modelConnection : compactor.connection
        check(compactorProvider, compactor.selectedModel(inheriting: modelConnection), "Compression")
        return warnings
    }

    func validateAdvancedForAutonomy() throws {
        let object = try SettingsAdvancedDraft.parseObject(advancedText)
        _ = try SettingsAdvancedDraft.autonomyObject(in: object)
    }

    mutating func adoptAutonomy(enabled: Bool, revision: Int) throws {
        let merged = try SettingsAdvancedDraft.mergingAutonomy(enabled, into: advancedText)
        advancedText = merged
        self.revision = revision
    }
}

struct SettingsView: View {
    @Bindable var store: GoblinStore
    @State private var form = SettingsFormDraft()
    @State private var didLoadForm = false
    @State private var loadedForm = SettingsFormDraft()
    @State private var staleRevision = false
    @State private var floorDefinition = ""
    @State private var loadedFloorDefinition = ""
    @State private var accountReports: [AccountReport] = []
    @State private var accountChecks: [String: AccountCheck] = [:]
    @State private var accountChecking: Set<String> = []
    @State private var autoCheckedProviders: Set<String> = []
    @State private var credentialAuthorizing = false
    @State private var accountAttempts = AccountAttemptGate()
    @State private var accountActionsInFlight = 0
    @State private var accountListRequest = 0
    @State private var accountPollFailures = 0
    @State private var accountNotice = ""
    @State private var modelKey = ""
    @State private var modelKeyPresent = false
    @State private var modelKeyNotice = ""
    @State private var modelKeySaving = false
    @State private var modelKeyCheck = 0
    @State private var compactorKey = ""
    @State private var compactorKeyNotice = ""
    @State private var compactorKeySaving = false
    @State private var compactorKeyCheck = 0
    @State private var voiceAuthChecking = false
    @State private var voiceAuthMessage = ""
    @State private var voiceKey = ""
    @State private var voiceKeySaving = false
    @State private var notice = ""
    @State private var saving = false
    @State private var creationKind: String?
    @State private var newServer = MCPServerDraft()
    @State private var floorExpanded = false
    @State private var autonomyBusy = false
    @AppStorage("settingsSection") private var section = "Goblin"

    init(store: GoblinStore) {
        self.store = store
        _section = AppStorage(wrappedValue: "Goblin", "settingsSection", store: store.defaults)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(["Goblin", "Connections", "Autonomy", "Continuity", "Tools"], id: \.self) { name in
                    Text(name).tag(name)
                }
            }.pickerStyle(.segmented).padding(16).accessibilityIdentifier("settings-sections")
            if staleRevision {
                HStack(spacing: 8) {
                    Text("Settings changed outside this form. Reload to see the current values.").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Reload") { load() }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            Group {
                switch section {
                case "Connections": connections
                case "Autonomy": autonomy
                case "Continuity": continuity
                case "Tools": tools
                default: general
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(!store.settingsLoaded)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if !store.settingsIssue.isEmpty {
                    Text("Not applied: " + store.settingsIssue).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("settings-issue")
                }
                HStack {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Reload saved settings") { load() }.disabled(!store.settingsLoaded || saving || autonomyBusy)
                        .accessibilityIdentifier("reload-settings")
                    Button("Save settings") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(saving || autonomyBusy || !store.settingsLoaded)
                        .keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("save-settings")
                }
            }.padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultAppStorage(store.defaults).onAppear { if !didLoadForm { load() } }
        .onChange(of: store.settingsLoaded) { if store.settingsLoaded && !didLoadForm { load() } }
        .onChange(of: store.settingsRevision) { revision in
            if revision == loadedForm.revision {
                staleRevision = false
                return
            }
            if form != loadedForm { staleRevision = true }
            else { load() }
        }
        .sheet(isPresented: Binding(get: { creationKind != nil }, set: { if !$0 { creationKind = nil } })) {
            if creationKind == "personality" {
                AssistedSettingsDraft(kind: "personality", destination: $form.instructions)
            } else {
                AssistedSettingsDraft(kind: "world view", destination: $form.worldView)
            }
        }
        .task(id: form.endpoint) { await refreshModelKeyState() }
        .task(id: compactorDraft.endpoint) { await refreshCompactorKeyState() }
        .task { _ = await refreshAccounts(quiet: true) }
        .task(id: accountPollKey) { await pollAccounts() }
        .task(id: form.modelConnection) { await autoCheck(form.modelConnection) }
        .task(id: compactorDraft.connection.isEmpty ? form.modelConnection : compactorDraft.connection) {
            await autoCheck(compactorDraft.connection.isEmpty ? form.modelConnection : compactorDraft.connection)
        }
    }

    private var general: some View {
        Form {
            Button("Goblin profiles…") { store.showProfiles?() }
                .accessibilityIdentifier("goblin-profiles")
            SettingsTextField("Name", text: $form.agentName, identifier: "agent-name")
            HStack {
                SettingsTextField("Workspace", text: $form.workspace, identifier: "workspace-path")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { form.workspace = url.path }
                }
            }
            CompanionOptions(preferences: store.preferences)
            Section("Avatar") {
                AccessibleButton(title: "Import custom avatar…", identifier: "import-avatar", enabled: true) { store.importAvatar() }
                    .frame(height: 28)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(store.avatars) { avatar in
                        Button { store.chooseAvatar(avatar.id) } label: {
                            AvatarImage(store: store, size: 58, id: avatar.id, standing: true)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(store.selectedAvatar == avatar.id ? Color.accentColor : .clear, lineWidth: 3))
                        }.buttonStyle(.plain).help(avatar.name).accessibilityLabel(avatar.name + " avatar")
                    }
                }.padding(.vertical, 8)
            }
            Section("Persona and instructions") {
                Text("Personality is your freely editable guidance for voice and working together.").font(.caption).foregroundStyle(.secondary)
                SettingsTextEditor(text: $form.instructions, label: "Persona and instructions").frame(minHeight: 140)
                Button("Create personality draft…") { creationKind = "personality" }
            }
        }.formStyle(.grouped)
    }

    private var connections: some View {
        Form {
            localModels
            Section("Chat model") {
                Picker("Connection", selection: $form.modelConnection) {
                    Text("Custom endpoint").tag(AccountConnectionOptions.customID)
                    ForEach(chatAccountOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }.accessibilityIdentifier("model-connection")
                if form.modelConnection == AccountConnectionOptions.customID {
                    Picker("Protocol", selection: $form.apiKind) {
                        Text("OpenAI-compatible").tag("chat_completions")
                        Text("Responses API").tag("responses")
                        Text("CLI worker").tag("cli_worker")
                    }.accessibilityIdentifier("model-api-kind")
                    if form.apiKind == "cli_worker" { SettingsTextField("CLI command", text: $form.cliCommand, identifier: "cli-command") }
                    else { SettingsTextField("API base URL", text: $form.endpoint, identifier: "model-endpoint") }
                    SettingsTextField("Model", text: $form.model, identifier: "model-name")
                    HStack {
                        SecureField("Model API key", text: $modelKey)
                        Button("Save key") { Task { await commitModelKey() } }.disabled(modelKey.isEmpty || modelKeySaving)
                        Button("Remove key") { Task { await removeModelKey() } }.disabled(!modelKeyPresent || modelKeySaving)
                            .accessibilityIdentifier("remove-model-key")
                    }
                    HStack {
                        Text(modelKeyNotice).font(.caption).accessibilityIdentifier("model-key-state")
                        Button("Check key") { Task { await refreshModelKeyState() } }.accessibilityIdentifier("check-model-key")
                        AccessibleButton(title: "Allow Keychain access", identifier: "model-authorize-key",
                                         enabled: !credentialAuthorizing && !KeychainStore.modelAccount(endpoint: form.endpoint).isEmpty) {
                            Task { await authorizeCredential(role: "model", endpoint: form.endpoint) }
                        }.frame(height: 28)
                    }
                } else {
                    ModelPickerField(model: $form.selectedModel,
                                     provider: form.modelConnection,
                                     choices: modelChoices(for: form.modelConnection, saved: form.selectedModel),
                                     loading: accountChecking.contains(form.modelConnection),
                                     error: modelError(for: form.modelConnection),
                                     identifier: "model-name").id(form.modelConnection)
                    if !modelSelectionReady {
                        Text("No model is selected for this account. Chat stays unready until you choose one.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Local model settings are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Reasoning", selection: $form.selectedReasoning) {
                    if form.modelConnection != AccountConnectionOptions.customID && form.accountModels[form.modelConnection] == nil {
                        Text("Not set").tag("")
                    }
                    ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .disabled(!modelSelectionReady)
                .accessibilityIdentifier("model-reasoning")
                SettingsTextField("Thinking budget", text: thinkingBudgetText, identifier: "thinking-budget")
                    .disabled(!modelSelectionReady)
                if !modelSelectionReady {
                    Text("Choose a model first. Reasoning and budget have no effect until a model is selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Compression") {
                Picker("Connection", selection: compactorConnection) {
                    Text("Same as chat").tag("")
                    Text("Custom endpoint").tag(AccountConnectionOptions.customID)
                    ForEach(compactorAccountOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }.accessibilityIdentifier("compactor-connection")
                if compactorShowsCustomFields || (compactorDraft.connection.isEmpty && form.modelConnection == AccountConnectionOptions.customID) {
                    SettingsTextField(compactorModelLabel, text: compactorModel, identifier: "compactor-model")
                }
                if compactorShowsCustomFields {
                    SettingsTextField("API base URL", text: compactorEndpoint, identifier: "compactor-endpoint")
                    Picker("Protocol", selection: compactorAPIKind) {
                        Text("OpenAI-compatible").tag("chat_completions")
                        Text("Responses API").tag("responses")
                    }.accessibilityIdentifier("compactor-api-kind")
                    HStack(spacing: 8) {
                        SecureField("Compactor API key", text: $compactorKey)
                        AccessibleButton(title: "Save key",
                                         identifier: "save-compactor-key",
                                         enabled: !compactorKey.isEmpty && !compactorEndpointAccount.isEmpty && !compactorKeySaving) {
                            Task { await commitCompactorKey() }
                        }.frame(height: 28)
                        AccessibleButton(title: "Check key",
                                         identifier: "check-compactor-key",
                                         enabled: true) {
                            Task { await refreshCompactorKeyState() }
                        }.frame(height: 28)
                        AccessibleButton(title: "Allow Keychain access", identifier: "compactor-authorize-key",
                                         enabled: !credentialAuthorizing && !compactorEndpointAccount.isEmpty) {
                            Task { await authorizeCredential(role: "model", endpoint: compactorDraft.endpoint) }
                        }.frame(height: 28)
                    }
                    Text(compactorKeyNotice).font(.caption).accessibilityIdentifier("compactor-key-state")

                } else if compactorDraft.connection.isEmpty {
                    if form.modelConnection != AccountConnectionOptions.customID {
                        ModelPickerField(model: compactorModel,
                                         provider: form.modelConnection,
                                         choices: modelChoices(for: form.modelConnection, saved: compactorModel.wrappedValue),
                                         loading: accountChecking.contains(form.modelConnection),
                                         error: modelError(for: form.modelConnection),
                                         identifier: "compactor-model").id(form.modelConnection)
                    }
                    Text("The chat account supplies the endpoint and protocol. A model here overrides only the model.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ModelPickerField(model: compactorModel,
                                     provider: compactorDraft.connection,
                                     choices: modelChoices(for: compactorDraft.connection, saved: compactorModel.wrappedValue),
                                     loading: accountChecking.contains(compactorDraft.connection),
                                     error: modelError(for: compactorDraft.connection),
                                     identifier: "compactor-model").id(compactorDraft.connection)
                    Text("The " + AccountConnectionOptions.label(for: compactorDraft.connection, in: compactorAccountOptions) + " account supplies the endpoint and protocol. Chat settings stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Compression will use: " + (compactorEffectiveModel.isEmpty ? "no model (unready)" : compactorEffectiveModel))
                    .font(.caption).foregroundStyle(compactorEffectiveModel.isEmpty ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("compactor-effective-model")
            }
            Section("Accounts") {
                ConnectionAccountsSection(
                    reports: accountReports,
                    checks: accountChecks,
                    checking: accountChecking,
                    notice: accountNotice,
                    authorizing: credentialAuthorizing,
                    authorize: { provider in Task { await authorizeCredential(role: "account", provider: provider) } },
                    connect: { provider in Task { await startAccount(provider) } },
                    cancel: { provider in Task { await cancelAccount(provider) } },
                    openPage: { provider in openAccountPage(provider) },
                    checkConnection: { provider in Task { await checkAccount(provider) } },
                    refresh: { Task { _ = await refreshAccounts(quiet: false) } }
                ).accessibilityIdentifier("connection-accounts")
            }
            Section("xAI duplex voice") {
                Picker("Voice account", selection: $form.voiceAuth) {
                    Text("xAI account").tag("oauth")
                    Text("API key").tag("api_key")
                }.accessibilityIdentifier("voice-account")
                if form.voiceAuth == "oauth" {
                    LabeledContent("xAI account", value: xaiAccountReport?.statusLabel ?? "Not checked")
                        .accessibilityIdentifier("voice-account-status")
                    Text("Voice uses the xAI account connected in Accounts.").font(.caption).foregroundStyle(.secondary)
                    AccessibleButton(title: "Check voice auth",
                                     identifier: "voice-auth-check",
                                     enabled: !voiceAuthChecking) {
                        Task { await checkVoiceAuth() }
                    }.frame(height: 28)
                    Text(voiceAuthMessage).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice-auth-message")
                } else {
                    HStack {
                        SecureField("xAI voice API key", text: $voiceKey)
                        Button("Save key") { Task { await commitVoiceKey() } }.disabled(voiceKey.isEmpty || voiceKeySaving)
                        AccessibleButton(title: "Allow Keychain access", identifier: "voice-authorize-key",
                                         enabled: !credentialAuthorizing) {
                            Task { await authorizeCredential(role: "voice") }
                        }.frame(height: 28)
                    }
                }
                SettingsTextField("Model", text: $form.voiceModel, identifier: "voice-model")
                SettingsTextField("Voice", text: $form.voiceName, identifier: "voice-name")
                Toggle("Allow built-in speakers", isOn: $store.voice.allowSpeakers)
                    .onChange(of: store.voice.allowSpeakers) { store.defaults.set(store.voice.allowSpeakers, forKey: "allowSpeakers") }
                Text(store.voice.outputDeviceName).font(.caption).foregroundStyle(.secondary)
            }
            Section("Tools") {
                Picker("Approval", selection: $form.approval) {
                    Text("Ask when needed").tag("ask")
                    Text("Unleashed").tag("unleashed")
                }
            }
        }.formStyle(.grouped)
    }

    private var autonomy: some View {
        Form {
            HStack {
                Label(store.autonomous ? "Running" : "Paused", systemImage: store.autonomous ? "sparkle" : "pause.circle")
                Spacer()
                Button(store.autonomous ? "Pause" : "Start") { Task { await toggleAutonomy(!store.autonomous) } }
                    .disabled(autonomyBusy || saving)
                    .accessibilityIdentifier("autonomy-setting-toggle")
            }
            if !store.standDownNote.isEmpty {
                Text(store.standDownNote).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("autonomy-stand-down")
            }
            Section("World view") {
                Text("Describe what matters to you, useful initiative, and boundaries. This is natural-language context for autonomous work.").font(.caption).foregroundStyle(.secondary)
                SettingsTextEditor(text: $form.worldView, label: "Autonomy world view").frame(minHeight: 130)
                Button("Create world view draft…") { creationKind = "world view" }
            }
            TextField("Floor interval (seconds)", value: $form.floorInterval, format: .number)
            Text("Idle floor wakes use this interval. Pressure wakes do not wait for it. Delivered wakes also stay at least min_wake_gap_seconds apart. Hourly and daily caps are in the expert autonomy settings. A cap of 0 means no cap.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Floor definition", isExpanded: $floorExpanded) {
                Text("The floor contains rules and text used to prepare autonomous wakes. Shipped defaults work before you save a custom definition. Runtime timers, tasks, and wake history are generated state and belong outside this editor.").font(.caption).foregroundStyle(.secondary)
                Text("JSON and TOML are supported. Read the current definition first to preserve existing rules. The compose.world_view field holds world-view text; rules contain named signals, conditions, and wake behavior.").font(.caption).foregroundStyle(.secondary)
                guidedFloorControls
                DisclosureGroup("JSON or TOML definition") {
                    SettingsTextEditor(text: $floorDefinition, label: "Floor definition", monospaced: true).frame(minHeight: 180)
                }
                Button("Prepare setup in chat") {
                    store.draft = "Help me configure Goblin’s autonomy floor. Read the current floor definition, explain the existing rules and available signals, and help me create a validated definition that preserves useful rules. Ask about my priorities and boundaries before proposing changes."
                    store.showChat?()
                }
                Text("This opens an editable chat draft. It does not send a message or change running work.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Read floor") { Task { await readFloor() } }
                    Button("Apply definition") { Task { await saveFloor() } }
                }
            }.onChange(of: floorExpanded) { expanded in
                if expanded && floorDefinition.isEmpty { Task { await readFloor() } }
            }
            AutonomySetupSettingsView(store: store, hasUnsavedChanges: hasUnsavedSetupChanges,
                                      onApplied: applyRotation)
        }.formStyle(.grouped)
    }

    private var guidedFloorControls: some View {
        let definition = try? SettingsAdvancedDraft.parseObject(floorDefinition)
        return Group {
            if let definition {
                Text("Enable the rules in this definition. Turning a rule off keeps it for later.").font(.caption).foregroundStyle(.secondary)
                let rules = definition["rules"]?.arrayValue ?? []
                ForEach(rules.indices, id: \.self) { index in
                    Toggle(rules[index]["name"].stringValue.isEmpty ? rules[index]["id"].stringValue : rules[index]["name"].stringValue, isOn: Binding(
                        get: { rules[index]["enabled"] != .bool(false) },
                        set: { enabled in
                            do { floorDefinition = try SettingsConfiguration.setFloorRule(index, enabled: enabled, in: floorDefinition) }
                            catch { notice = error.localizedDescription }
                        }))
                }
                Text("Quiet-time guidance").font(.headline)
                SettingsTextEditor(text: Binding(
                    get: { definition["compose"]?["quiet_paragraph"].stringValue ?? "" },
                    set: { value in
                        do { floorDefinition = try SettingsConfiguration.setFloorGuidance(value, in: floorDefinition) }
                        catch { notice = error.localizedDescription }
                    }), label: "Quiet-time floor guidance").frame(height: 90)
                Text("These controls preserve the other conditions, thresholds, and rule data. Apply definition validates the complete floor before saving.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Read the floor to use guided controls, or edit JSON or TOML and apply it. Apply stores JSON.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var continuity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("AetherMind", systemImage: "tree").font(.headline)
                    Spacer()
                    Text(store.snapshot["memory"]["state"].stringValue).foregroundStyle(.secondary)
                    Button("Refresh") { Task { await store.refresh() } }
                }
                MemoryCoreSettingsView(store: store, advancedText: $form.advancedText, notice: $notice)
                HistoryRotationSettingsView(store: store, hasUnsavedChanges: hasUnsavedSetupChanges,
                                            onApplied: applyRotation)
                if store.snapshot["memory"]["layers"] != .null {
                    LabeledContent("Layers", value: String(Int(store.snapshot["memory"]["layers"].numberValue)))
                }
                LabeledContent("Write debt", value: String(Int(store.snapshot["memory"]["debt"].numberValue)))
                LabeledContent("Messages", value: String(store.messages.count))
                LabeledContent("Turns", value: String(store.turns.count))
                LabeledContent("Session data", value: store.home.path).textSelection(.enabled)
                Divider()
                Text("Session gist").font(.headline)
                let compaction = store.compactionStatus
                if compaction != .null {
                    LabeledContent("Context", value: compaction["ready"].boolValue ? "Ready" : "Compacting")
                    LabeledContent("Gist bytes", value: String(Int(compaction["bytes"].numberValue)))
                    LabeledContent("Pending summaries", value: String(Int(compaction["pending"].numberValue)))
                    LabeledContent("Workers", value: String(Int(compaction["workers"].numberValue)))
                    LabeledContent("Active summaries", value: String(Int(compaction["active"].numberValue)))
                    LabeledContent("Completed this run", value: String(Int(compaction["completed"].numberValue)))
                    DisclosureGroup("Worker details") {
                        Text(compaction.formatted).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !compaction["failures"].arrayValue.isEmpty {
                        Text("Compaction retry pending").foregroundStyle(.orange)
                    }
                }
                Button(store.loadingGist ? "Reading summaries…" : "Read session summaries") { Task { await store.loadGistPreview() } }
                    .disabled(store.loadingGist).accessibilityIdentifier("refresh-gist-preview")
                Text(store.gist.isEmpty ? "Read the saved session summaries." : store.gist).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("session-gist")
            }.padding(16)
        }
    }

    private var localModels: some View {
        Section("Local or custom models") {
            Text("Save reusable model connections here, then choose one for chat or compression. Role selections copy the saved values; Save settings applies your draft. Keys remain associated with the endpoint.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(form.customModels.keys.sorted(), id: \.self) { id in
                CustomModelEditor(preset: Binding(
                    get: { form.customModels[id] ?? CustomModelDraft(id: id) },
                    set: { form.customModels[id] = $0 }),
                    useChat: { usePresetForChat(id) },
                    useCompression: { usePresetForCompression(id) },
                    remove: { form.customModels.removeValue(forKey: id) })
            }
            HStack {
                Button("Add saved model") {
                    let preset = CustomModelDraft()
                    form.customModels[preset.id] = preset
                }.accessibilityIdentifier("add-custom-model")
                if form.modelConnection == AccountConnectionOptions.customID {
                    Button("Save current chat as a model") {
                        var preset = CustomModelDraft()
                        preset.name = form.model.isEmpty ? "Current chat" : form.model
                        preset.endpoint = form.endpoint
                        preset.model = form.model
                        preset.apiKind = form.apiKind
                        preset.cliCommand = form.cliCommand
                        preset.reasoning = form.reasoning
                        preset.thinkingBudget = form.thinkingBudget
                        form.customModels[preset.id] = preset
                    }
                }
            }
        }
    }

    private func usePresetForChat(_ id: String) {
        guard let preset = form.customModels[id] else { return }
        form.useCustomModelForChat(preset)
        notice = "Chat draft updated. Save settings to apply."
    }

    private func usePresetForCompression(_ id: String) {
        guard let preset = form.customModels[id] else { return }
        do {
            form.advancedText = try SettingsConfiguration.applyingCompression(preset, to: form.advancedText)
            notice = "Compression endpoint, protocol, and model updated. Save settings to apply."
        } catch { notice = error.localizedDescription }
    }

    private var tools: some View {
        Form {
            Section("Current runtime access") {
                Text("Current approval mode: " + SettingsFormDraft.approvalLabel(store.snapshot["settings"]["approval"].stringValue))
                Text("Draft approval mode: " + SettingsFormDraft.approvalLabel(form.approval) + ". Tool toggles below are draft choices until Save settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Ask when needed applies existing approval rules to tools marked risky. Unleashed runs enabled tools without asking. Disabled tools stay disabled in either mode.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Registered descriptions below show file, shell, web, desktop and MCP capabilities. File tools can accept absolute paths. Enabled web requests remain outbound; shell and MCP tools can provide broader access. These controls do not isolate the process or prevent data from leaving through enabled tools or model requests.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Pause acting tools") {
                        do {
                            let names = SettingsConfiguration.actingToolNames(store.tools)
                            form.advancedText = try SettingsConfiguration.setTools(names, enabled: false, in: form.advancedText)
                            notice = "Draft disables \(names.count) registered tools marked risky or in the acting class. Approval mode is unchanged. Automatic memory capture continues. Review and Save settings to apply."
                        } catch { notice = error.localizedDescription }
                    }.accessibilityIdentifier("tools-pause-acting")
                    Button("Enable all registered tools") {
                        do {
                            var names: [String] = []
                            for tool in store.tools { names.append(tool["name"].stringValue) }
                            form.advancedText = try SettingsConfiguration.setTools(names, enabled: true, in: form.advancedText)
                            notice = "Draft enables all currently registered tools. Approval mode is unchanged. Review and Save settings to apply."
                        } catch { notice = error.localizedDescription }
                    }.accessibilityIdentifier("tools-enable-registered")
                }
                Text("Pause acting tools uses current registry metadata. Remaining tools can still read files or make web requests when enabled. Later registrations are controlled separately. Re-enable any tool below or use Enable all registered tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tool access") {
                Text("Enable or disable registered tools here. Changes apply when you save settings. Built-in tools stay installed; integrations below own added tools.").font(.caption).foregroundStyle(.secondary)
                ForEach(store.tools, id: \.self) { tool in
                    let name = tool["name"].stringValue
                    Toggle(isOn: Binding(
                        get: { SettingsConfiguration.toolEnabled(name, in: form.advancedText) },
                        set: { enabled in
                            do { form.advancedText = try SettingsConfiguration.setTool(name, enabled: enabled, in: form.advancedText) }
                            catch { notice = error.localizedDescription }
                        })) {
                        VStack(alignment: .leading) {
                            Text(name)
                            Text(tool["description"].stringValue).font(.caption).foregroundStyle(.secondary)
                            Text(SettingsConfiguration.toolAuthority(tool)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("tool-enabled-" + name)
                }
            }
            integrationSettings
            Section {
                DisclosureGroup("Expert: full runtime configuration") {
                    Text("This JSON contains tools, integrations, compression, and other runtime options. Saved model fields may be inactive when another connection or inherited model is selected. Normal editing preserves your text; formatting is explicit.").font(.caption).foregroundStyle(.secondary)
                    SettingsTextEditor(text: $form.advancedText, label: "Advanced tool and integration configuration", monospaced: true).frame(height: 240)
                    HStack {
                        Button("Validate JSON") {
                            do { _ = try SettingsAdvancedDraft.parseObject(form.advancedText); notice = "Valid JSON object. Save settings validates runtime fields." }
                            catch { notice = error.localizedDescription }
                        }
                        Button("Format JSON") {
                            do { form.advancedText = JSONValue.object(try SettingsAdvancedDraft.parseObject(form.advancedText)).formatted }
                            catch { notice = error.localizedDescription }
                        }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var integrationSettings: some View {
        Section("Tool integrations") {
            Text("Add an existing MCP server using its HTTP URL or stdio command. Keep credentials in the existing secret environment or Keychain setup; this form does not copy secrets.").font(.caption).foregroundStyle(.secondary)
            let servers = (try? SettingsAdvancedDraft.parseObject(form.advancedText))?["mcp_servers"]?.objectValue ?? [:]
            ForEach(servers.keys.sorted(), id: \.self) { name in
                DisclosureGroup(name) {
                    Toggle("Enabled", isOn: Binding(
                        get: { servers[name]?["enabled"] != .bool(false) },
                        set: { enabled in
                            var values = servers[name]?.objectValue ?? [:]
                            values["enabled"] = .bool(enabled)
                            setServer(name, value: .object(values))
                        }))
                    Text(servers[name]?["url"].stringValue ?? "").textSelection(.enabled)
                    if !(servers[name]?["command"].arrayValue ?? []).isEmpty {
                        Text(servers[name]?["command"].formatted ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button("Remove integration", role: .destructive) { setServer(name, value: nil) }
                }
            }
            DisclosureGroup("Add integration") {
                TextField("Name", text: $newServer.name)
                Toggle("Use a stdio command", isOn: $newServer.usesCommand)
                if newServer.usesCommand {
                    SettingsTextEditor(text: $newServer.command, label: "Command argument array", monospaced: true).frame(height: 70)
                    Text("Enter a JSON argument array, for example [\"/path/to/server\", \"--stdio\"].").font(.caption)
                } else { TextField("HTTP or HTTPS URL", text: $newServer.url) }
                Button("Add integration to draft") {
                    do {
                        let value = try newServer.value()
                        guard servers[newServer.name] == nil else { throw GoblinError(message: "An integration already uses that name.") }
                        form.advancedText = try SettingsConfiguration.setServer(newServer.name, value: value, in: form.advancedText)
                        newServer = MCPServerDraft()
                    } catch { notice = error.localizedDescription }
                }
            }
        }
    }

    private func setServer(_ name: String, value: JSONValue?) {
        do { form.advancedText = try SettingsConfiguration.setServer(name, value: value, in: form.advancedText) }
        catch { notice = error.localizedDescription }
    }

    private func load() {
        guard store.settingsLoaded else { notice = "Loading settings"; return }
        let revision = Int(store.snapshot["settings_revision"].numberValue)
        form = SettingsFormDraft.loaded(from: store.snapshot["settings"], revision: revision)
        var compactor = (try? SettingsCompactorDraft.values(in: form.advancedText)) ?? CompactorDraft()
        compactor.applyCompactionDefault(inheriting: form.modelConnection)
        if let text = try? SettingsCompactorDraft.applying(compactor, to: form.advancedText) {
            form.advancedText = text
        }
        loadedForm = form
        didLoadForm = true
        staleRevision = false
        notice = ""
    }

    private var hasUnsavedSetupChanges: Bool {
        form != loadedForm || floorDefinition != loadedFloorDefinition
    }

    private func applyRotation(_ result: JSONValue) {
        let value = result["snapshot"] == .null ? result : result["snapshot"]
        if !value["settings"].objectValue.isEmpty { store.apply(value) }
        load()
        floorDefinition = ""
        loadedFloorDefinition = ""
        Task { await readFloor() }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let request = try form.saveRequest()
            let outcome = try await store.saveSettings(request.settings, expectedRevision: request.expectedRevision)
            let warnings = form.modelWarnings()
            load()
            notice = warnings.isEmpty ? outcome.saveNotice : outcome.saveNotice + " " + warnings.joined(separator: " ")
        } catch { notice = error.localizedDescription }
    }

    private func toggleAutonomy(_ enabled: Bool) async {
        do {
            try form.validateAdvancedForAutonomy()
        } catch {
            notice = error.localizedDescription
            return
        }
        let wasDirty = form != loadedForm
        autonomyBusy = true
        defer { autonomyBusy = false }
        do {
            let outcome = try await store.setAutonomy(enabled, expectedRevision: form.revision)
            guard let reported = outcome.autonomyEnabled else {
                form.revision = outcome.revision
                staleRevision = true
                notice = "Autonomy status was not returned. Reload saved settings before saving."
                return
            }
            form.revision = outcome.revision
            do {
                try form.adoptAutonomy(enabled: reported, revision: outcome.revision)
            } catch {
                staleRevision = true
                notice = "Autonomy updated; advanced configuration was edited and not merged. Reload saved settings before saving."
                return
            }
            if !wasDirty { load() }
            else { staleRevision = true }
            if !outcome.settingsIssue.isEmpty {
                notice = "Autonomy updated; not applied: " + outcome.settingsIssue
            } else if !outcome.setupIssue.isEmpty {
                notice = "Autonomy updated. " + outcome.setupIssue
            } else {
                notice = ""
            }
        } catch { notice = error.localizedDescription }
    }


    private var chatAccountOptions: [AccountConnectionOption] {
        return AccountConnectionOptions.accountOptions(reports: accountReports, selected: form.modelConnection)
    }

    private var compactorAccountOptions: [AccountConnectionOption] {
        return AccountConnectionOptions.accountOptions(reports: accountReports, selected: compactorDraft.connection)
    }

    private var xaiAccountReport: AccountReport? {
        return accountReport(for: AccountProvider.xai)
    }

    private var accountPollKey: String {
        var active: [String] = []
        for report in accountReports {
            if report.isActive { active.append(report.provider) }
        }
        return "\(accountAttempts.current):" + active.joined(separator: ",")
    }

    private var compactorDraft: CompactorDraft {
        do {
            return try SettingsCompactorDraft.values(in: form.advancedText)
        } catch {
            return CompactorDraft()
        }
    }

    private var modelSelectionReady: Bool {
        if form.modelConnection == AccountConnectionOptions.customID { return true }
        return !form.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var thinkingBudgetText: Binding<String> {
        Binding(
            get: {
                if form.modelConnection == AccountConnectionOptions.customID {
                    return String(form.thinkingBudget)
                }
                if form.accountModels[form.modelConnection] == nil { return "" }
                return String(form.selectedThinkingBudget)
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if form.modelConnection == AccountConnectionOptions.customID {
                    if trimmed.isEmpty { form.thinkingBudget = 0; return }
                    if let number = Int(trimmed) { form.thinkingBudget = max(0, number) }
                    return
                }
                if form.accountModels[form.modelConnection] == nil { return }
                if trimmed.isEmpty { form.selectedThinkingBudget = 0; return }
                if let number = Int(trimmed) { form.selectedThinkingBudget = max(0, number) }
            }
        )
    }

    private var compactorEffectiveModel: String {
        let draft = compactorDraft
        if draft.connection == AccountConnectionOptions.customID { return draft.model }
        if draft.connection.isEmpty {
            if form.modelConnection == AccountConnectionOptions.customID {
                if !draft.inheritModel.isEmpty { return draft.inheritModel }
                return form.model
            }
            if let choice = draft.accountModels[form.modelConnection] { return choice.model }
            return form.selectedModel
        }
        if let choice = draft.accountModels[draft.connection] { return choice.model }
        return ""
    }

    private var compactorModelLabel: String {
        if compactorDraft.connection.isEmpty { return "Model override" }
        return "Model"
    }

    private var compactorShowsCustomFields: Bool {
        return compactorDraft.connection == AccountConnectionOptions.customID
    }

    private var compactorConnection: Binding<String> {
        Binding(get: { compactorDraft.connection },
                set: { value in updateCompactor { $0.connection = value } })
    }

    private var compactorModel: Binding<String> {
        Binding(
            get: { compactorDraft.selectedModel(inheriting: form.modelConnection) },
            set: { value in
                updateCompactor { draft in
                    draft.setSelectedModel(value, inheriting: form.modelConnection)
                }
            }
        )
    }

    private var compactorEndpoint: Binding<String> {
        Binding(get: { compactorDraft.endpoint },
                set: { value in updateCompactor { $0.endpoint = value } })
    }

    private var compactorEndpointAccount: String {
        return KeychainStore.modelAccount(endpoint: compactorDraft.endpoint)
    }

    private var compactorAPIKind: Binding<String> {
        Binding(get: { compactorDraft.apiKind },
                set: { value in updateCompactor { $0.apiKind = value } })
    }

    private func updateCompactor(_ change: (inout CompactorDraft) -> Void) {
        var draft = compactorDraft
        change(&draft)
        do {
            form.advancedText = try SettingsCompactorDraft.applying(draft, to: form.advancedText)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func verifiedModels(for provider: String) -> [AccountModel] {
        guard let check = accountChecks[provider] else { return [] }
        return check.models
    }

    private func modelChoices(for provider: String, saved: String) -> ModelChoices {
        ModelSelection.rows(provider: provider, saved: saved, fetched: verifiedModels(for: provider))
    }

    private func modelError(for provider: String) -> String {
        guard let check = accountChecks[provider], !check.ok else { return "" }
        return check.summary
    }

    /// The account check is the bridge call that returns `models`, so the picker
    /// fills without a manual click.
    private func autoCheck(_ provider: String) async {
        guard provider != AccountConnectionOptions.customID, !provider.isEmpty else { return }
        guard !autoCheckedProviders.contains(provider), !accountChecking.contains(provider) else { return }
        guard verifiedModels(for: provider).isEmpty else { return }
        autoCheckedProviders.insert(provider)
        await checkAccount(provider)
    }

    private func accountReport(for provider: String) -> AccountReport? {
        for report in accountReports {
            if report.provider == provider { return report }
        }
        return nil
    }

    private func refreshAccounts(quiet: Bool) async -> Bool {
        accountListRequest += 1
        let request = accountListRequest
        let attempt = accountAttempts.current
        do {
            let result = try await store.engine.call("account/list")
            if Task.isCancelled { return true }
            guard accountAttempts.isCurrent(attempt) else { return true }
            guard request == accountListRequest else { return true }
            applyAccountReports(result)
            if !quiet { accountNotice = "" }
            return true
        } catch {
            if Task.isCancelled { return true }
            guard accountAttempts.isCurrent(attempt) else { return true }
            guard request == accountListRequest else { return true }
            if !quiet { accountNotice = error.localizedDescription }
            return false
        }
    }

    private func pollAccounts() async {
        while !accountPollKey.isEmpty && !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            if Task.isCancelled { return }
            let refreshed = await refreshAccounts(quiet: true)
            if Task.isCancelled { return }
            if refreshed {
                accountPollFailures = 0
            } else {
                accountPollFailures += 1
                if accountPollFailures >= 3 {
                    accountNotice = "Account status stopped refreshing. Use Refresh accounts to try again."
                    return
                }
            }
        }
    }

    private func applyAccountReports(_ result: JSONValue) {
        if accountActionsInFlight > 0 { return }
        var reports: [AccountReport] = []
        var seen: Set<String> = []
        for item in result["accounts"].arrayValue {
            var report = AccountReport(item)
            if report.provider.isEmpty { continue }
            if report.provider == AccountConnectionOptions.customID { continue }
            if seen.contains(report.provider) { continue }
            if report.name.isEmpty { report.name = report.provider }
            reports.append(report)
            seen.insert(report.provider)
        }
        accountReports = reports
    }

    private func applyAccountReport(_ value: JSONValue, provider: String) {
        var report = AccountReport(value)
        if report.provider.isEmpty { report.provider = provider }
        if report.name.isEmpty { report.name = provider }
        if report.provider == AccountConnectionOptions.customID { return }
        var reports: [AccountReport] = []
        var replaced = false
        for existing in accountReports {
            if existing.provider == report.provider {
                reports.append(report)
                replaced = true
            } else {
                reports.append(existing)
            }
        }
        if !replaced { reports.append(report) }
        accountReports = reports
    }

    private func markAccount(_ provider: String, status: String, message: String, clearSignIn: Bool) {
        var reports: [AccountReport] = []
        for existing in accountReports {
            if existing.provider != provider {
                reports.append(existing)
                continue
            }
            var report = existing
            report.status = status
            report.message = message
            if clearSignIn {
                report.verificationURL = ""
                report.userCode = ""
            }
            reports.append(report)
        }
        accountReports = reports
    }

    private func startAccount(_ provider: String) async {
        guard !credentialAuthorizing else { return }
        let attempt = accountAttempts.beginAction()
        accountActionsInFlight += 1
        defer {
            accountActionsInFlight -= 1
            accountListRequest += 1
        }
        accountPollFailures = 0
        accountNotice = ""
        accountChecks[provider] = nil
        markAccount(provider, status: "starting", message: "Starting sign-in…", clearSignIn: true)
        do {
            let result = try await store.engine.call("account/start", ["provider": .string(provider)])
            guard accountAttempts.isCurrent(attempt) else { return }
            applyAccountReport(result, provider: provider)
        } catch {
            guard accountAttempts.isCurrent(attempt) else { return }
            markAccount(provider, status: "error", message: error.localizedDescription, clearSignIn: true)
        }
    }

    private func cancelAccount(_ provider: String) async {
        let attempt = accountAttempts.beginAction()
        accountActionsInFlight += 1
        defer {
            accountActionsInFlight -= 1
            accountListRequest += 1
        }
        accountPollFailures = 0
        accountNotice = ""
        accountChecks[provider] = nil
        markAccount(provider, status: "cancelling", message: "Cancelling sign-in…", clearSignIn: true)
        do {
            let result = try await store.engine.call("account/cancel", ["provider": .string(provider)])
            guard accountAttempts.isCurrent(attempt) else { return }
            applyAccountReport(result, provider: provider)
        } catch {
            guard accountAttempts.isCurrent(attempt) else { return }
            markAccount(provider, status: "error", message: error.localizedDescription, clearSignIn: true)
        }
    }

    private func checkAccount(_ provider: String) async {
        guard !credentialAuthorizing else { return }
        let attempt = accountAttempts.current
        accountChecking.insert(provider)
        accountChecks[provider] = nil
        defer { accountChecking.remove(provider) }
        do {
            let result = try await store.engine.call("account/check", ["provider": .string(provider)])
            guard accountAttempts.isCurrent(attempt) else { return }
            accountChecks[provider] = AccountCheck(result)
            accountNotice = ""
        } catch {
            guard accountAttempts.isCurrent(attempt) else { return }
            var check = AccountCheck()
            check.provider = provider
            check.ok = false
            check.message = error.localizedDescription
            accountChecks[provider] = check
        }
    }

    private func openAccountPage(_ provider: String) {
        guard let report = accountReport(for: provider) else { return }
        guard report.canOpenPage else {
            accountNotice = "No sign-in page is available. Start a connection first."
            return
        }
        guard let url = URL(string: report.verificationURL) else { return }
        NSWorkspace.shared.open(url)
        accountNotice = ""
    }

    private func checkVoiceAuth() async {
        voiceAuthChecking = true
        voiceAuthMessage = ""
        defer { voiceAuthChecking = false }
        do {
            let result = try await store.engine.call("voice/check")
            voiceAuthMessage = result["message"].stringValue
        } catch {
            voiceAuthMessage = "Voice auth check could not run. Try again."
        }
    }

    private func authorizeCredential(role: String, provider: String = "", endpoint: String = "") async {
        guard !credentialAuthorizing else { return }
        credentialAuthorizing = true
        defer { credentialAuthorizing = false }
        do {
            let result = try await store.engine.call("credentials/authorize", [
                "role": .string(role), "provider": .string(provider), "endpoint": .string(endpoint)
            ])
            _ = await refreshAccounts(quiet: true)
            let message = result["message"].stringValue
            accountNotice = message
            notice = message
            if role == "model" {
                await refreshModelKeyState()
                await refreshCompactorKeyState()
            }
        } catch {
            accountNotice = error.localizedDescription
            notice = error.localizedDescription
        }
    }

    /// Saves one typed draft. Returns true only after the helper acknowledged the
    /// write, so the caller can clear the draft it sent.
    private func saveKey(_ value: String, role: String, endpoint: String) async -> Bool {
        guard let service = store.product.keychainServices[role] else {
            notice = "Missing Keychain service."
            return false
        }
        do {
            if role == "model" {
                try await KeychainStore.saveModelKey(value, service: service, endpoint: endpoint)
            } else {
                try await KeychainStore.save(value, service: service)
            }
            notice = "Saved to Keychain"
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    /// Saves the model key for the endpoint shown when the save started. The
    /// draft is cleared only while it still holds the value that was saved.
    private func commitModelKey() async {
        guard !modelKeySaving else { return }
        let typed = modelKey
        guard !typed.isEmpty else { return }
        let endpoint = form.endpoint
        modelKeySaving = true
        defer { modelKeySaving = false }
        let saved = await saveKey(typed, role: "model", endpoint: endpoint)
        guard saved else { return }
        if modelKey == typed && form.endpoint == endpoint {
            modelKey = ""
        }
        await refreshModelKeyState()
        if compactorDraft.endpoint == endpoint {
            await refreshCompactorKeyState()
        }
    }

    private func commitCompactorKey() async {
        guard !compactorKeySaving else { return }
        let typed = compactorKey
        guard !typed.isEmpty else { return }
        let endpoint = compactorDraft.endpoint
        guard !KeychainStore.modelAccount(endpoint: endpoint).isEmpty else { return }
        compactorKeySaving = true
        defer { compactorKeySaving = false }
        let saved = await saveKey(typed, role: "model", endpoint: endpoint)
        guard saved else { return }
        if compactorKey == typed && compactorDraft.endpoint == endpoint {
            compactorKey = ""
        }
        if compactorDraft.endpoint == endpoint {
            await refreshCompactorKeyState()
        }
    }

    private func commitVoiceKey() async {
        guard !voiceKeySaving else { return }
        let typed = voiceKey
        guard !typed.isEmpty else { return }
        voiceKeySaving = true
        defer { voiceKeySaving = false }
        let saved = await saveKey(typed, role: "voice", endpoint: "")
        guard saved else { return }
        if voiceKey == typed {
            voiceKey = ""
        }
    }

    /// Checks the key for the endpoint currently shown. A slower check for an
    /// older endpoint or an older request never overwrites the current notice.
    private func refreshModelKeyState() async {
        modelKeyCheck += 1
        let check = modelKeyCheck
        let endpoint = form.endpoint
        modelKeyPresent = false
        guard !KeychainStore.modelAccount(endpoint: endpoint).isEmpty else {
            modelKeyNotice = "Enter an API base URL to manage its key."
            return
        }
        guard let service = store.product.keychainServices["model"] else {
            modelKeyNotice = "Missing Keychain service."
            return
        }
        do {
            let state = try await KeychainStore.modelKeyState(service: service, endpoint: endpoint)
            if Task.isCancelled { return }
            if check != modelKeyCheck { return }
            if endpoint != form.endpoint { return }
            modelKeyPresent = state == .present
            modelKeyNotice = modelKeyPresent ? "Key saved for this endpoint" : "No key saved for this endpoint"
        } catch {
            if Task.isCancelled { return }
            if check != modelKeyCheck { return }
            if endpoint != form.endpoint { return }
            modelKeyNotice = "Keychain status unavailable. Unlock Keychain and check again."
        }
    }

    private func refreshCompactorKeyState() async {
        compactorKeyCheck += 1
        let check = compactorKeyCheck
        let endpoint = compactorDraft.endpoint
        guard !KeychainStore.modelAccount(endpoint: endpoint).isEmpty else {
            compactorKeyNotice = "Empty inherits the chat endpoint. Enter a compactor API base URL to manage a separate key."
            return
        }
        guard let service = store.product.keychainServices["model"] else {
            compactorKeyNotice = "Missing Keychain service."
            return
        }
        do {
            let state = try await KeychainStore.modelKeyState(service: service, endpoint: endpoint)
            if Task.isCancelled { return }
            if check != compactorKeyCheck { return }
            if endpoint != compactorDraft.endpoint { return }
            if state == .present {
                compactorKeyNotice = "Key saved for this compactor endpoint"
            } else {
                compactorKeyNotice = "No key saved for this compactor endpoint"
            }
        } catch {
            if Task.isCancelled { return }
            if check != compactorKeyCheck { return }
            if endpoint != compactorDraft.endpoint { return }
            compactorKeyNotice = "Keychain status unavailable. Unlock Keychain and check again."
        }
    }

    private func removeModelKey() async {
        guard !modelKeySaving else { return }
        let endpoint = form.endpoint
        modelKeySaving = true
        defer { modelKeySaving = false }
        do {
            guard let service = store.product.keychainServices["model"] else {
                throw GoblinError(message: "Missing Keychain service.")
            }
            try await KeychainStore.deleteModelKey(service: service, endpoint: endpoint)
            notice = "Model key removed for this endpoint"
        } catch {
            notice = error.localizedDescription
            return
        }
        await refreshModelKeyState()
    }

    private func readFloor() async {
        let revision = store.settingsRevision
        let generation = store.connectionGeneration
        do {
            let result = try await store.engine.call("floor/read")
            guard revision == store.settingsRevision && generation == store.connectionGeneration else { return }
            floorDefinition = result["definition"].stringValue
            loadedFloorDefinition = floorDefinition
            notice = ""
        } catch {
            if revision == store.settingsRevision && generation == store.connectionGeneration {
                notice = error.localizedDescription
            }
        }
    }

    private func saveFloor() async {
        do {
            let result = try await store.engine.call("floor/save", ["definition": .string(floorDefinition),
                                                                    "expected_revision": .number(Double(form.revision))])
            floorDefinition = result["definition"].stringValue
            loadedFloorDefinition = floorDefinition
            let definition = try SettingsAdvancedDraft.parseObject(floorDefinition)
            let worldView = (definition["compose"] ?? .null)["world_view"].stringValue
            form.worldView = worldView
            var advanced = try SettingsAdvancedDraft.parseObject(form.advancedText)
            var autonomy = try SettingsAdvancedDraft.autonomyObject(in: advanced)
            if autonomy["world_view"] != nil {
                autonomy["world_view"] = .string(worldView)
                advanced["autonomy"] = .object(autonomy)
                form.advancedText = JSONValue.object(advanced).formatted
            }
            notice = "Floor saved"
        }
        catch { notice = error.localizedDescription }
    }
}
