import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let kind: String
    let text: String
    let name: String
    let turnID: String
    let automatic: Bool
    let isFinal: Bool
    let status: String
    let callID: String
    let responseID: String
    let streaming: Bool
    let diffs: [ConversationDiff]
    let attachmentPaths: [String]
    let recordIndex: Int?
    let truncated: Bool

    init(_ value: JSONValue) {
        recordIndex = value["record_i"] == .null ? nil : Int(value["record_i"].numberValue)
        truncated = value["truncated"].boolValue
        id = value["id"].stringValue
        kind = value["kind"].stringValue
        text = value["text"].stringValue
        name = value["name"].stringValue
        turnID = value["turn_id"].stringValue
        automatic = value["automatic"].boolValue
        isFinal = value["final"] == .null || value["final"].boolValue
        status = value["status"].stringValue
        callID = value["call_id"].stringValue
        responseID = value["response_id"].stringValue
        streaming = value["streaming"].boolValue
        var changes: [ConversationDiff] = []
        for (index, change) in value["diffs"].arrayValue.enumerated() {
            changes.append(ConversationDiff(id: value["id"].stringValue + "-diff-" + String(index),
                path: change["path"].stringValue, patch: change["patch"].stringValue,
                change: change["change"].stringValue, detail: change["detail"].stringValue,
                movedFrom: change["moved_from"].stringValue, movedTo: change["moved_to"].stringValue))
        }
        diffs = changes
        var paths: [String] = []
        for item in value["attachments"].arrayValue {
            let path = item.stringValue
            if !path.isEmpty { paths.append(path) }
        }
        attachmentPaths = paths
    }
}

struct SettingsMutationOutcome: Equatable {
    let revision: Int
    let ready: Bool
    let settingsIssue: String
    let setupIssue: String
    let autonomyEnabled: Bool?

    init(_ value: JSONValue) {
        revision = Int(value["settings_revision"].numberValue)
        ready = value["ready"].boolValue
        settingsIssue = value["settings_issue"].stringValue
        setupIssue = value["setup_issue"].stringValue
        if value["autonomy"]["enabled"] != .null {
            autonomyEnabled = value["autonomy"]["enabled"].boolValue
        } else {
            autonomyEnabled = nil
        }
    }

    var saveNotice: String {
        if !settingsIssue.isEmpty {
            return "Saved; not applied: " + settingsIssue
        }
        if !setupIssue.isEmpty {
            return "Saved. " + setupIssue
        }
        return "Saved"
    }
}

enum GoblinConnectionState {
    case notStarted
    case starting
    case connected
    case disconnected
}

@MainActor
@Observable
final class GoblinStore {
    let product: Product
    let resources: URL
    let home: URL
    let applicationHome: URL
    let profileID: String
    @ObservationIgnored let defaults: UserDefaults
    let engine: EngineConnection
    @ObservationIgnored var rpc: @MainActor (String, [String: JSONValue]) async throws -> JSONValue
    var voice: GoblinVoice
    private(set) var avatars: [Avatar]
    let preferences: CompanionPreferences
    let pushToTalk: PushToTalkController
    let avatarLibrary: AvatarLibrary
    private let bundledAvatarIDs: Set<String>
    private(set) var connectionState: GoblinConnectionState = .notStarted
    @ObservationIgnored private(set) var connectionGeneration = 0
    private(set) var historyID = ""
    @ObservationIgnored private var localIntakeByHistory: [String: [ChatMessage]] = [:]
    @ObservationIgnored private var localPartialsByHistory: [String: [ChatMessage]] = [:]
    private(set) var localPartialRows: [ChatMessage] = []
    private(set) var snapshot: JSONValue = .object([:])
    private(set) var compactionStatus: JSONValue = .null
    private(set) var messages: [ChatMessage] = []
    private(set) var historyBefore: Int?
    private(set) var hasEarlierHistory = false
    private(set) var loadingHistory = false
    private(set) var gistPreview = ""
    private(set) var loadingGist = false
    var recordDetail: String?
    private(set) var loadingRecord = false
    private(set) var turns: [ConversationTurn] = []
    private(set) var pendingMessages: [ChatMessage] = []
    private(set) var localIntakeRows: [ChatMessage] = []
    private(set) var localSubmissions = 0
    private(set) var turnActive = false
    private(set) var activityStarted: Date?
    private(set) var lastEventAt: Date?
    private(set) var livePhase = "Idle"
    private(set) var finishedThought = ""
    private(set) var finishedThoughtTurnID = ""
    private(set) var submittedMessageID = ""
    var thoughtStream = ""
    private(set) var responseID = ""
    private(set) var activeTurnID = ""
    @ObservationIgnored private var timerTurnID = ""
    @ObservationIgnored private var latestRevision = -1
    @ObservationIgnored private var stopGeneration = 0
    var draft = ""
    var attachedFiles: [URL] = []
    var stream = ""
    var activity = "Starting"
    var activityDetail = ""
    var error = ""
    var isCollapsed = false
    var settingsVisible = false
    var selectedAvatar: String
    var bubble = ""
    var approval: JSONValue?
    private(set) var toolActive = false
    private(set) var activityToolKind = ""
    private(set) var activityToken = 0
    private(set) var completionPulse = false
    var showChat: (() -> Void)?
    var collapseChat: (() -> Void)?
    var showSettings: (() -> Void)?
    var showProfiles: (() -> Void)?
    var profileChoices: [ProfileChoice] = []
    var profileChoicesError = ""
    var selectProfile: ((String, Bool) -> Void)?
    @ObservationIgnored var profileNameChanged: (() -> Void)?
    @ObservationIgnored weak var presentationWindow: NSWindow?

    init(product: Product, resources: URL, home: URL, applicationHome: URL? = nil,
         profileID: String = "default", defaults: UserDefaults = .standard) throws {
        self.product = product
        self.resources = resources
        self.home = home
        self.applicationHome = applicationHome ?? home
        self.profileID = profileID
        self.defaults = defaults
        let connection = EngineConnection()
        self.engine = connection
        self.rpc = { method, params in try await connection.call(method, params) }
        let voiceSession = GoblinVoice(engine: connection)
        let preferences = CompanionPreferences(defaults: defaults)
        let talk = PushToTalkController(voice: voiceSession)
        let library = AvatarLibrary(directory: home.appendingPathComponent("avatars"))
        let data = try Data(contentsOf: resources.appendingPathComponent("avatars.json"))
        let bundled = try JSONDecoder().decode([Avatar].self, from: data)
        var bundledIDs = Set<String>()
        for avatar in bundled { bundledIDs.insert(avatar.id) }
        let imported = try library.avatars()
        var loaded = bundled
        loaded.append(contentsOf: imported)
        let savedAvatar = defaults.string(forKey: "avatar") ?? product.defaultAvatar
        var chosen = product.defaultAvatar
        for avatar in loaded {
            if avatar.id == savedAvatar { chosen = savedAvatar }
        }
        self.voice = voiceSession
        self.preferences = preferences
        self.pushToTalk = talk
        self.avatarLibrary = library
        self.bundledAvatarIDs = bundledIDs
        self.avatars = loaded
        self.selectedAvatar = chosen
        voice.allowSpeakers = defaults.bool(forKey: "allowSpeakers")
        engine.onEvent = { [weak self] name, data in self?.receive(name, data) }
        pushToTalk.onError = { [weak self] message in self?.error = message }
        preferences.pushToTalkChanged = { [weak self] in self?.pushToTalk.release() }
    }

    var name: String {
        let value = snapshot["settings"]["agent_name"].stringValue
        return value.isEmpty ? product.name : value
    }
    var settingsLoaded: Bool { !snapshot["settings"].objectValue.isEmpty }
    var isConnected: Bool { connectionState == .connected }
    var ready: Bool { isConnected && snapshot["ready"].boolValue }
    var setupIssue: String {
        let appliedIssue = snapshot["settings_issue"].stringValue
        if !appliedIssue.isEmpty { return appliedIssue }
        return snapshot["setup_issue"].stringValue
    }
    var settingsIssue: String { snapshot["settings_issue"].stringValue }
    var liveTurnID: String {
        if !activeTurnID.isEmpty { return activeTurnID }
        if localSubmissions > 0 { return pendingMessages.first?.turnID ?? "" }
        return ""
    }
    var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return ready && (!text.isEmpty || !attachedFiles.isEmpty)
    }
    var busy: Bool { isConnected && (localSubmissions > 0 || turnActive || snapshot["busy"].boolValue) }
    var autonomous: Bool { snapshot["autonomy"]["enabled"].boolValue }

    var standDownNote: String {
        let record = snapshot["autonomy"]["last_stand_down"]
        let text = record["text"].stringValue
        if text.isEmpty {
            return ""
        }
        let rule = record["rule"].stringValue
        if rule.isEmpty {
            return "Autonomy stood down: " + text
        }
        return "Autonomy stood down (" + rule + "): " + text
    }
    var model: String { snapshot["model"].stringValue }
    var gist: String { gistPreview }
    var tools: [JSONValue] { snapshot["tools"].arrayValue }
    var settingsRevision: Int { Int(snapshot["settings_revision"].numberValue) }

    var elapsedSeconds: Int {
        guard let started = activityStarted else { return 0 }
        return max(0, Int(Date().timeIntervalSince(started)))
    }

    var elapsedLabel: String {
        let total = elapsedSeconds
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 { return String(minutes) + "m " + String(seconds) + "s" }
        return String(seconds) + "s"
    }

    var secondsSinceLastEvent: Int? {
        guard let last = lastEventAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(last)))
    }

    var isStalled: Bool {
        if !busy { return false }
        guard let age = secondsSinceLastEvent else { return false }
        return age >= 20
    }

    var updateLabel: String {
        guard let age = secondsSinceLastEvent else { return "starting" }
        if age >= 20 { return "no update " + String(age) + "s" }
        return "updated " + String(age) + "s ago"
    }

    var liveSummary: String {
        if !busy { return "" }
        return livePhase + " | " + elapsedLabel + " | " + updateLabel
    }

    var liveThoughtLine: String {
        let lines = thoughtStream.components(separatedBy: .newlines)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    var characterSignals: CharacterSignals {
        var signals = CharacterSignals()
        signals.listening = voice.isConnected && !voice.isMuted && voice.userIsSpeaking
        signals.thinking = busy && !toolActive
        signals.working = busy && toolActive
        signals.speaking = voice.isSpeaking
        signals.attention = busy || !draft.isEmpty || approval != nil
        signals.speechLevel = voice.characterSpeechLevel
        signals.error = !error.isEmpty
        signals.approval = approval != nil
        signals.autonomy = autonomous
        signals.typing = !draft.isEmpty
        signals.toolKind = activityToolKind
        signals.activityToken = activityToken
        signals.completed = completionPulse
        return signals
    }

    func beginConnection() -> Int {
        connectionGeneration += 1
        connectionState = .starting
        latestRevision = -1
        historyBefore = nil
        hasEarlierHistory = false
        loadingHistory = false
        activity = "Connecting"
        livePhase = activity
        error = ""
        return connectionGeneration
    }

    @discardableResult
    func finishConnection(_ value: JSONValue, generation: Int) -> Bool {
        guard generation == connectionGeneration, connectionState == .starting else { return false }
        connectionState = .connected
        apply(value)
        if !busy { activity = ready ? "Ready" : "Setup needed"; livePhase = activity }
        return true
    }

    func start() async {
        if connectionState == .starting || isConnected { return }
        let generation = beginConnection()
        do {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("cache"), withIntermediateDirectories: true)
            try await engine.start(resources: resources, home: home, applicationHome: applicationHome)
            let value = try await rpc("bootstrap", [:])
            if !finishConnection(value, generation: generation) { return }
            await loadEarlierHistory()
        } catch {
            if generation != connectionGeneration { return }
            receive("disconnected", .string(error.localizedDescription))
        }
    }

    private func preserveDisconnectedOutput() {
        let turnID = activeTurnID.isEmpty ? timerTurnID : activeTurnID
        let identity = responseID.isEmpty ? UUID().uuidString : responseID
        for (kind, text) in [("thought", thoughtStream), ("agent", stream)] {
            if text.isEmpty { continue }
            localPartialRows.append(ChatMessage(.object([
                "id": .string("local-partial-" + identity + "-" + kind),
                "turn_id": .string(turnID), "response_id": .string(identity),
                "kind": .string(kind), "text": .string(text),
                "final": .bool(false), "status": .string("interrupted")
            ])))
        }
    }

    func receive(_ event: String, _ data: JSONValue) {
        if event == "disconnected" {
            preserveDisconnectedOutput()
            connectionGeneration += 1
            connectionState = .disconnected
            localSubmissions = 0
            turnActive = false
            toolActive = false
            activeTurnID = ""
            approval = nil
            activityStarted = nil
            lastEventAt = nil
            timerTurnID = ""
            responseID = ""
            stream = ""
            thoughtStream = ""
            loadingHistory = false
            loadingGist = false
            loadingRecord = false
            livePhase = "Engine stopped"
            activity = livePhase
            error = data.stringValue.isEmpty ? "The local engine exited." : data.stringValue
            rebuildTurns()
            return
        }
        if connectionState == .disconnected || connectionState == .notStarted { return }
        let eventHistory = data["history_id"].stringValue
        if event != "snapshot" && !eventHistory.isEmpty && !historyID.isEmpty && eventHistory != historyID {
            return
        }
        let revision = Int(data["revision"].numberValue)
        if event == "snapshot" || event == "compaction" || event == "approval" {
            if revision > 0 && revision < latestRevision { return }
            latestRevision = max(latestRevision, revision)
        } else if event == "activity" || event == "stream" || event == "message" {
            if revision > 0 { latestRevision = max(latestRevision, revision) }
        }
        if event == "stream" || event == "activity" {
            let active = data["active_turn_id"].stringValue
            if !active.isEmpty { activeTurnID = active }
        }
        switch event {
        case "snapshot": apply(data)
        case "compaction":
            let becameReady = data["ready"].boolValue && !compactionStatus["ready"].boolValue
            compactionStatus = data
            if becameReady {
                let generation = connectionGeneration
                Task {
                    if generation != self.connectionGeneration { return }
                    await self.refresh()
                }
            }
        case "message":
            lastEventAt = Date()
            let message = ChatMessage(data)
            var found = false
            for entry in messages { if entry.id == message.id { found = true; break } }
            if !found {
                messages.append(message)
                if message.kind == "agent" && !message.text.isEmpty { bubble = message.text }
                if message.kind == "agent" && (message.responseID == responseID || responseID.isEmpty) {
                    var turnID = message.turnID
                    if turnID.isEmpty { turnID = activeTurnID }
                    archiveThought(turnID: turnID)
                    stream = ""
                    thoughtStream = ""
                }
                if message.kind == "thought" && finishedThought.isEmpty && !message.text.isEmpty {
                    finishedThought = message.text
                    finishedThoughtTurnID = message.turnID
                }
            }
            rebuildTurns()
        case "stream":
            lastEventAt = Date()
            turnActive = true
            toolActive = false
            if data["kind"].stringValue == "agent" {
                stream += data["text"].stringValue
                livePhase = "Replying"
            } else {
                thoughtStream += data["text"].stringValue
                livePhase = "Thinking"
            }
            activity = livePhase
        case "activity":
            let phase = data["phase"].stringValue
            let text = data["text"].stringValue
            lastEventAt = Date()
            switch phase {
            case "queued":
                turnActive = true
                beginTurn(turnID: data["turn_id"].stringValue)
                livePhase = "Message received"
                activity = livePhase
            case "turn_start":
                let turnID = data["turn_id"].stringValue
                activeTurnID = turnID
                turnActive = true
                toolActive = false
                stream = ""
                thoughtStream = ""
                beginTurn(turnID: turnID)
                livePhase = "Preparing the response"
                activity = livePhase
            case "compacting":
                compactionStatus = data["compaction"]
            case "model_start":
                if !data["turn_id"].stringValue.isEmpty { activeTurnID = data["turn_id"].stringValue }
                responseID = data["response_id"].stringValue
                turnActive = true
                toolActive = false
                stream = ""
                thoughtStream = ""
                if activityStarted == nil { activityStarted = Date() }
                livePhase = "Thinking"
                activity = livePhase
            case "tool":
                turnActive = true
                toolActive = true
                livePhase = "Working"
                activity = livePhase
                if !text.isEmpty { activityToolKind = text }
                activityToken += 1
            case "turn_end", "stopped":
                archiveThought(turnID: data["turn_id"].stringValue)
                if data["turn_id"].stringValue == activeTurnID { activeTurnID = "" }
                turnActive = false
                toolActive = false
                activityStarted = nil
                timerTurnID = ""
                livePhase = phase == "stopped" ? "Stopped" : "Ready"
                activity = livePhase
                if phase == "turn_end" && data["success"].boolValue {
                    completionPulse = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        self.completionPulse = false
                    }
                }
            case "approval_resolved":
                livePhase = "Continuing"
                activity = livePhase
            case "ready":
                if isConnected && !busy { livePhase = "Ready"; activity = livePhase }
            case "status", "heartbeat":
                if !text.isEmpty { activityDetail = text }
                livePhase = toolActive ? "Working" : "Thinking"
                activity = livePhase
            default:
                if !text.isEmpty { activity = text; livePhase = text }
            }
        case "approval":
            approval = data
            livePhase = "Approval needed"
            activity = livePhase
            bubble = "Approval needed: " + data["name"].stringValue
        default: break
        }
    }

    private func beginTurn(turnID: String) {
        let now = Date()
        if turnID.isEmpty || timerTurnID != turnID {
            timerTurnID = turnID
            activityStarted = now
            lastEventAt = now
        }
        if activityStarted == nil { activityStarted = now }
    }

    private func archiveThought(turnID: String) {
        if thoughtStream.isEmpty { return }
        finishedThought = thoughtStream
        finishedThoughtTurnID = turnID
        thoughtStream = ""
    }

    func mergeHistoryPage(_ page: JSONValue) {
        let pageHistory = page["history_id"].stringValue
        if !pageHistory.isEmpty && !historyID.isEmpty && pageHistory != historyID { return }
        var byID: [String: ChatMessage] = [:]
        for message in messages { byID[message.id] = message }
        for value in page["messages"].arrayValue {
            let message = ChatMessage(value)
            byID[message.id] = message
            if message.kind == "agent" && !responseID.isEmpty && message.responseID == responseID {
                archiveThought(turnID: message.turnID)
                stream = ""
                thoughtStream = ""
            }
        }
        messages = byID.values.sorted { first, second in
            let firstIndex = first.recordIndex ?? Int(first.id.split(separator: "-")[0]) ?? 0
            let secondIndex = second.recordIndex ?? Int(second.id.split(separator: "-")[0]) ?? 0
            if firstIndex != secondIndex { return firstIndex < secondIndex }
            return first.kind == "thought" && second.kind != "thought"
        }
        historyBefore = Int(page["before"].numberValue)
        hasEarlierHistory = page["has_more"].boolValue
        rebuildTurns()
        if stream.isEmpty {
            for message in messages.reversed() {
                if message.kind == "agent" && !message.text.isEmpty {
                    bubble = message.text
                    break
                }
            }
        }
    }

    func loadEarlierHistory() async {
        if loadingHistory || !isConnected { return }
        let generation = connectionGeneration
        let history = historyID
        loadingHistory = true
        defer { if generation == connectionGeneration && history == historyID { loadingHistory = false } }
        var params: [String: JSONValue] = [:]
        if let historyBefore { params["before"] = .number(Double(historyBefore)) }
        do {
            let page = try await rpc("history/page", params)
            if generation == connectionGeneration && history == historyID && isConnected { mergeHistoryPage(page) }
        } catch {
            if generation == connectionGeneration && history == historyID { self.error = error.localizedDescription }
        }
    }

    func loadGistPreview() async {
        if loadingGist || !isConnected { return }
        let generation = connectionGeneration
        let history = historyID
        loadingGist = true
        defer { if generation == connectionGeneration && history == historyID { loadingGist = false } }
        do {
            var data = Data()
            var params: [String: JSONValue] = [:]
            var offset = 0
            while true {
                let result = try await rpc("history/gist", params)
                if generation != connectionGeneration || history != historyID || !isConnected { return }
                if result["history_id"].stringValue != "" && result["history_id"].stringValue != history { return }
                guard let bytes = Data(base64Encoded: result["data"].stringValue) else {
                    throw GoblinError(message: "The summaries could not be read.")
                }
                data.append(bytes)
                let next = Int(result["next_offset"].numberValue)
                if next >= Int(result["total"].numberValue) { break }
                if next <= offset { throw GoblinError(message: "The summary read made no progress.") }
                offset = next
                params = ["token": result["token"], "offset": .number(Double(offset))]
            }
            gistPreview = String(decoding: data, as: UTF8.self)
        } catch {
            if generation == connectionGeneration && history == historyID { self.error = error.localizedDescription }
        }
    }

    func readRecord(_ index: Int) async {
        if loadingRecord || !isConnected { return }
        let generation = connectionGeneration
        let history = historyID
        loadingRecord = true
        defer { if generation == connectionGeneration && history == historyID { loadingRecord = false } }
        do {
            var data = Data()
            var offset = 0
            while true {
                let chunk = try await rpc("history/record", ["i": .number(Double(index)), "offset": .number(Double(offset))])
                if generation != connectionGeneration || history != historyID || !isConnected { return }
                if chunk["history_id"].stringValue != "" && chunk["history_id"].stringValue != history { return }
                guard let bytes = Data(base64Encoded: chunk["data"].stringValue) else {
                    throw GoblinError(message: "The saved record could not be read.")
                }
                data.append(bytes)
                let next = Int(chunk["next_offset"].numberValue)
                let total = Int(chunk["total"].numberValue)
                if next >= total { break }
                if next <= offset { throw GoblinError(message: "The saved record made no progress.") }
                offset = next
            }
            let text = try await Task.detached {
                let record = try JSONDecoder().decode(JSONValue.self, from: data)
                var display = record["text"].stringValue
                var details = record.objectValue
                details.removeValue(forKey: "text")
                if !details.isEmpty {
                    display += "\n\nSaved details\n" + JSONValue.object(details).formatted
                }
                return display
            }.value
            if generation == connectionGeneration && history == historyID && isConnected { recordDetail = text }
        } catch {
            if generation == connectionGeneration && history == historyID { self.error = error.localizedDescription }
        }
    }

    private func resetHistoryPresentation() {
        messages = []
        localPartialRows = []
        historyBefore = nil
        hasEarlierHistory = false
        loadingHistory = false
        loadingGist = false
        loadingRecord = false
        gistPreview = ""
        recordDetail = ""
        stream = ""
        thoughtStream = ""
        finishedThought = ""
        finishedThoughtTurnID = ""
        activeTurnID = ""
        responseID = ""
        timerTurnID = ""
        bubble = ""
    }

    func apply(_ value: JSONValue) {
        if !isConnected { return }
        let revision = Int(value["revision"].numberValue)
        if revision < latestRevision { return }
        let incomingHistory = value["history_id"].stringValue
        let historyChanged = !incomingHistory.isEmpty && !historyID.isEmpty && incomingHistory != historyID
        if historyChanged {
            localIntakeByHistory[historyID] = localIntakeRows
            localPartialsByHistory[historyID] = localPartialRows
            resetHistoryPresentation()
            localIntakeRows = localIntakeByHistory[incomingHistory] ?? []
            localPartialRows = localPartialsByHistory[incomingHistory] ?? []
        }
        if !incomingHistory.isEmpty { historyID = incomingHistory }
        latestRevision = revision
        let previousName = name
        snapshot = value
        if name != previousName { profileNameChanged?() }
        if let window = presentationWindow, window.title != name { window.title = name }
        compactionStatus = value["compaction"]
        activeTurnID = value["active_turn_id"].stringValue
        turnActive = value["busy"].boolValue
        rebuildTurns()
        settleIfIdle()
        if !value["error"].stringValue.isEmpty { error = value["error"].stringValue }
        let pending = value["pending_approvals"].arrayValue
        approval = pending.first
        if historyChanged {
            let connection = connectionGeneration
            let history = historyID
            Task {
                if connection == self.connectionGeneration && history == self.historyID {
                    await self.loadEarlierHistory()
                }
            }
        }
    }

    private func settleIfIdle() {
        if !isConnected || busy { return }
        stream = ""
        thoughtStream = ""
        toolActive = false
        activity = "Ready"
        livePhase = "Ready"
        activityStarted = nil
        lastEventAt = nil
        timerTurnID = ""
        responseID = ""
    }

    private func rebuildTurns() {
        var partials: [ChatMessage] = []
        for partial in localPartialRows {
            var committed = false
            for message in messages {
                if message.responseID == partial.responseID && message.kind == partial.kind {
                    committed = true
                    break
                }
            }
            if !committed { partials.append(partial) }
        }
        localPartialRows = partials
        reconcilePendingIntake()
        var keptLocalRows: [ChatMessage] = []
        for row in localIntakeRows {
            if hasServerUserRow(turnID: row.turnID) { continue }
            keptLocalRows.append(row)
        }
        localIntakeRows = keptLocalRows
        var remainingPending: [ChatMessage] = []
        for pending in pendingMessages {
            if hasServerUserRow(turnID: pending.turnID) { continue }
            if hasLocalIntakeRow(turnID: pending.turnID) { continue }
            remainingPending.append(pending)
        }
        pendingMessages = remainingPending
        var visible = messages
        visible.append(contentsOf: localIntakeRows)
        visible.append(contentsOf: pendingMessages)
        visible.append(contentsOf: localPartialRows)
        turns = ConversationTurn.group(visible)
    }

    private func reconcilePendingIntake() {
        if pendingMessages.isEmpty { return }
        var remaining: [ChatMessage] = []
        for pending in pendingMessages {
            if hasServerUserRow(turnID: pending.turnID) { continue }
            let state = terminalTurnState(turnID: pending.turnID)
            if state.isEmpty {
                remaining.append(pending)
                continue
            }
            let status = intakeStatus(forTurnState: state)
            let files = pendingAttachments(pending)
            appendLocalIntakeRow(text: pending.text, files: files, requestID: pending.turnID, status: status)
            restoreAttachments(files)
        }
        pendingMessages = remaining
    }

    private func terminalTurnState(turnID: String) -> String {
        for turn in snapshot["turns"].arrayValue {
            if turn["id"].stringValue != turnID { continue }
            let state = turn["state"].stringValue
            if state == "done" || state == "error" || state == "cancelled" { return state }
            return ""
        }
        return ""
    }

    private func intakeStatus(forTurnState state: String) -> String {
        if state == "cancelled" { return "cancelled" }
        if state == "done" { return "not saved" }
        return "failed"
    }

    private func hasServerUserRow(turnID: String) -> Bool {
        if turnID.isEmpty { return false }
        for message in messages {
            if message.kind == "user" && message.turnID == turnID { return true }
        }
        return false
    }

    private func hasLocalIntakeRow(turnID: String) -> Bool {
        for row in localIntakeRows {
            if row.turnID == turnID { return true }
        }
        return false
    }

    private func pendingAttachments(_ message: ChatMessage) -> [URL] {
        var files: [URL] = []
        for path in message.attachmentPaths {
            files.append(URL(fileURLWithPath: path))
        }
        return files
    }

    private func appendLocalIntakeRow(text: String, files: [URL], requestID: String, status: String) {
        if hasLocalIntakeRow(turnID: requestID) { return }
        var attachmentValues: [JSONValue] = []
        for file in files { attachmentValues.append(.string(file.path)) }
        let row = ChatMessage(.object([
            "id": .string("local-intake-" + requestID),
            "turn_id": .string(requestID),
            "kind": .string("user"),
            "text": .string(text),
            "status": .string(status),
            "attachments": .array(attachmentValues)
        ]))
        localIntakeRows.append(row)
    }

    private func restoreAttachments(_ files: [URL]) {
        for file in files {
            if attachedFiles.contains(file) { continue }
            attachedFiles.append(file)
        }
    }

    private func addPendingIntake(text: String, files: [URL], requestID: String) {
        var attachmentValues: [JSONValue] = []
        for file in files { attachmentValues.append(.string(file.path)) }
        pendingMessages.append(ChatMessage(.object([
            "id": .string("pending-" + requestID),
            "turn_id": .string(requestID),
            "kind": .string("user"),
            "text": .string(text),
            "attachments": .array(attachmentValues)
        ])))
    }

    func refresh() async {
        if !isConnected { return }
        let generation = connectionGeneration
        do {
            let value = try await rpc("snapshot", [:])
            if generation == connectionGeneration && isConnected { apply(value) }
        } catch {
            if generation == connectionGeneration { self.error = error.localizedDescription }
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachedFiles
        await submit("chat/send", text: text, files: files, fromComposer: true)
    }

    func queue() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachedFiles
        await submit("chat/queue", text: text, files: files, fromComposer: true)
    }

    private func submit(_ method: String, text: String, files: [URL], fromComposer: Bool) async {
        guard ready else {
            let issue = !isConnected ? "Reconnect to send this message." : (setupIssue.isEmpty ? "Configure a chat model in Settings." : setupIssue)
            error = issue
            recoverFailedIntake(text: text, files: files, requestID: UUID().uuidString, fromComposer: fromComposer)
            rebuildTurns()
            return
        }
        if text.isEmpty && files.isEmpty { return }
        let requestID = UUID().uuidString
        addPendingIntake(text: text, files: files, requestID: requestID)
        if fromComposer {
            draft = ""
            attachedFiles = []
        }
        localSubmissions += 1
        let now = Date()
        activityStarted = now
        lastEventAt = now
        timerTurnID = ""
        livePhase = "Sending your message"
        activity = livePhase
        error = ""
        rebuildTurns()
        submittedMessageID = requestID
        var attachments: [JSONValue] = []
        for file in files { attachments.append(.string(file.path)) }
        let generation = stopGeneration
        let connection = connectionGeneration
        defer {
            if connection == connectionGeneration {
                localSubmissions -= 1
                settleIfIdle()
            }
        }
        do {
            _ = try await rpc(method, ["text": .string(text), "attachments": .array(attachments),
                                        "request_id": .string(requestID), "expected_history_id": .string(historyID)])
            if connection != connectionGeneration || !isConnected { return }
            if stopGeneration == generation && activity == "Sending your message" {
                livePhase = "Message received"
                activity = livePhase
            }
            await refresh()
        } catch {
            if connection != connectionGeneration { return }
            pendingMessages.removeAll { $0.turnID == requestID }
            recoverFailedIntake(text: text, files: files, requestID: requestID, fromComposer: fromComposer)
            rebuildTurns()
            self.error = error.localizedDescription
        }
    }

    private func recoverFailedIntake(text: String, files: [URL], requestID: String, fromComposer: Bool) {
        if hasServerUserRow(turnID: requestID) { return }
        if hasLocalIntakeRow(turnID: requestID) {
            restoreAttachments(files)
            return
        }
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDraft == text {
            restoreAttachments(files)
            return
        }
        if fromComposer && trimmedDraft.isEmpty && attachedFiles.isEmpty {
            draft = text
            attachedFiles = files
            return
        }
        appendLocalIntakeRow(text: text, files: files, requestID: requestID, status: "failed")
        restoreAttachments(files)
    }

    func commandReturn() async {
        if preferences.commandReturn == "queue" {
            await queue()
            return
        }
        await steer()
    }

    func steer() async {
        if !isConnected { return }
        let connection = connectionGeneration
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        let generation = stopGeneration
        lastEventAt = Date()
        livePhase = "Steering"
        activity = livePhase
        do {
            let result = try await rpc("chat/steer", ["text": .string(text)])
            if connection != connectionGeneration || !isConnected { return }
            if result["accepted"].boolValue {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                if stopGeneration == generation {
                    lastEventAt = Date()
                    livePhase = "Direction received"
                    activity = livePhase
                }
            } else if stopGeneration == generation {
                await submit("chat/send", text: text, files: [], fromComposer: false)
            }
        }
        catch { if connection == connectionGeneration { self.error = error.localizedDescription } }
    }

    func stop() async {
        if !isConnected { return }
        let connection = connectionGeneration
        stopGeneration += 1
        lastEventAt = Date()
        livePhase = "Stopping"
        activity = livePhase
        do {
            _ = try await rpc("chat/stop", [:])
            if connection != connectionGeneration || !isConnected { return }
            await voice.interrupt()
            if connection != connectionGeneration || !isConnected { return }
            await refresh()
            settleIfIdle()
        }
        catch { if connection == connectionGeneration { self.error = error.localizedDescription } }
    }

    func setAutonomy(_ enabled: Bool) async {
        let generation = connectionGeneration
        do { _ = try await setAutonomy(enabled, expectedRevision: nil) }
        catch { if generation == connectionGeneration { self.error = error.localizedDescription } }
    }

    @discardableResult
    func setAutonomy(_ enabled: Bool, expectedRevision: Int?) async throws -> SettingsMutationOutcome {
        guard isConnected else { throw GoblinError(message: "Reconnect before changing autonomy.") }
        let generation = connectionGeneration
        var params: [String: JSONValue] = ["enabled": .bool(enabled)]
        if let expectedRevision {
            params["expected_revision"] = .number(Double(expectedRevision))
        }
        let result = try await rpc("autonomy/set", params)
        guard generation == connectionGeneration && isConnected else { throw GoblinError(message: "The engine disconnected while saving.") }
        return adoptSettingsMutation(result)
    }

    @discardableResult
    func saveSettings(_ settings: [String: JSONValue], expectedRevision: Int) async throws -> SettingsMutationOutcome {
        guard isConnected else { throw GoblinError(message: "Reconnect before saving settings.") }
        let generation = connectionGeneration
        let result = try await rpc("settings/save", [
            "settings": .object(settings),
            "expected_revision": .number(Double(expectedRevision))
        ])
        guard generation == connectionGeneration && isConnected else { throw GoblinError(message: "The engine disconnected while saving.") }
        return adoptSettingsMutation(result)
    }

    @discardableResult
    func adoptSettingsMutation(_ value: JSONValue) -> SettingsMutationOutcome {
        let outcome = SettingsMutationOutcome(value)
        apply(value)
        return outcome
    }

    func resolveApproval(_ accepted: Bool) async {
        guard isConnected, let approval else { return }
        let generation = connectionGeneration
        let requestedID = approval["id"]
        do {
            _ = try await rpc("approval/resolve", ["id": requestedID, "accepted": .bool(accepted)])
            if generation == connectionGeneration && self.approval?["id"] == requestedID {
                self.approval = nil
            }
        } catch {
            if generation == connectionGeneration && self.approval?["id"] == requestedID {
                self.error = error.localizedDescription
            }
        }
    }

    func chooseAvatar(_ id: String) {
        selectedAvatar = id
        defaults.set(id, forKey: "avatar")
    }

    func toggleChat() {
        if isCollapsed { showChat?() }
        else { collapseChat?() }
    }

    func toggleVoice() async {
        if voice.isActive {
            pushToTalk.release()
            await voice.stop()
            return
        }
        do {
            try await voice.start(initiallyMuted: preferences.pushToTalk)
        } catch let thrown {
            if thrown is CancellationError { return }
            error = thrown.localizedDescription
        }
    }

    func importAvatar() {
        guard let window = presentationWindow else {
            error = "The companion window is not available."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import avatar"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.importAvatar(at: url)
        }
    }

    func importAvatar(at url: URL) {
        do {
            let avatar = try avatarLibrary.importImage(at: url)
            avatars.append(avatar)
            chooseAvatar(avatar.id)
        } catch { self.error = error.localizedDescription }
    }

    func avatarImage(_ id: String? = nil, standing: Bool = false) -> NSImage? {
        let selected = id ?? selectedAvatar
        for avatar in avatars {
            if avatar.id == selected {
                if bundledAvatarIDs.contains(avatar.id) {
                    let file = standing ? avatar.standingFile : avatar.file
                    return NSImage(contentsOf: resources.appendingPathComponent(file))
                }
                do { return NSImage(contentsOf: try avatarLibrary.imageURL(for: avatar)) }
                catch { return nil }
            }
        }
        return nil
    }

    func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addAttachments(panel.urls) }
    }

    var pasteDirectory: URL {
        return home.appendingPathComponent("cache/pasted", isDirectory: true)
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls where !attachedFiles.contains(url) {
            attachedFiles.append(url)
        }
    }
}
