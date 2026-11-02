import Foundation

struct ConversationTurn: Identifiable {
    let id: String
    var prompt: ChatMessage?
    var entries: [ChatMessage] = []

    var reply: ChatMessage? {
        for entry in entries.reversed() {
            if entry.kind == "agent" && entry.isFinal && entry.hasConversationText { return entry }
        }
        return nil
    }

    var preview: String {
        for entry in entries.reversed() {
            if entry.kind == "agent" && entry.hasConversationText { return ConversationText.preview(entry.text) }
        }
        if let prompt { return ConversationText.preview(prompt.text) }
        return "Background work"
    }

    func segments(stream: ChatMessage? = nil, active: Bool = false) -> [ConversationSegment] {
        var source = entries
        if let stream { source.append(stream) }
        var result: [ConversationSegment] = []
        var pending: [ChatMessage] = []
        var anchor = id
        for entry in source {
            if entry.isConversation {
                if !pending.isEmpty {
                    result.append(.work(ConversationWork(id: "work-" + anchor, entries: pending)))
                    pending = []
                }
                result.append(.message(entry))
                anchor = entry.displayID
            } else {
                pending.append(entry)
            }
        }
        let awaitingReply = active && reply == nil
        if !pending.isEmpty || awaitingReply {
            result.append(.work(ConversationWork(id: "work-" + anchor, entries: pending)))
        }
        return result
    }

    static func group(_ messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var positions: [String: Int] = [:]
        var current = ""
        for message in messages {
            if !message.turnID.isEmpty { current = message.turnID }
            else if message.kind == "user" || current.isEmpty { current = message.id }
            if positions[current] == nil {
                positions[current] = turns.count
                turns.append(ConversationTurn(id: current))
            }
            guard let index = positions[current] else { continue }
            if message.kind == "user" && !message.automatic { turns[index].prompt = message }
            turns[index].entries.append(message)
        }
        return turns
    }
}

enum ConversationSegment: Identifiable {
    case message(ChatMessage)
    case work(ConversationWork)

    var id: String {
        switch self {
        case .message(let message): return message.displayID
        case .work(let work): return work.id
        }
    }
}

struct ConversationWork: Identifiable {
    let id: String
    let entries: [ChatMessage]

    var calls: [ConversationCall] {
        var result: [ConversationCall] = []
        var positions: [String: Int] = [:]
        var last = ""
        for entry in entries {
            if entry.kind == "tool" {
                let key = entry.callID.isEmpty ? entry.id : entry.callID
                positions[key] = result.count
                result.append(ConversationCall(id: key, request: entry))
                last = key
            } else if entry.kind == "result" {
                let key = entry.callID.isEmpty ? last : entry.callID
                if let index = positions[key] { result[index].result = entry }
                else { result.append(ConversationCall(id: entry.id, result: entry)) }
            }
        }
        return result
    }

    var diffs: [ConversationDiff] {
        var result: [ConversationDiff] = []
        for entry in entries { result.append(contentsOf: entry.diffs) }
        return result
    }
}

struct ConversationCall: Identifiable {
    let id: String
    var request: ChatMessage? = nil
    var result: ChatMessage? = nil

    var name: String {
        if let request, !request.name.isEmpty { return request.name }
        if let result, !result.name.isEmpty { return result.name }
        return "Tool call"
    }
}

struct ConversationDiff: Identifiable, Equatable {
    let id: String
    let path: String
    let patch: String
    let change: String
    var detail = ""
    var movedFrom = ""
    var movedTo = ""
}

extension ChatMessage {
    var hasConversationText: Bool { !ConversationText.preview(text).isEmpty }
    var isConversation: Bool {
        if kind == "user" { return !automatic }
        return kind == "agent" && hasConversationText
    }
    var displayID: String {
        if kind == "agent" && !responseID.isEmpty { return "reply-" + responseID }
        return "message-" + id
    }
}

struct ConversationScrollState {
    private(set) var followsLatest = true
    private var atBottom = true
    private var userScrolling = false

    mutating func geometryChanged(atBottom value: Bool) -> Bool {
        atBottom = value
        if userScrolling { followsLatest = value }
        return followsLatest && !value
    }

    mutating func phaseChanged(userDriven: Bool) {
        if userScrolling && !userDriven { followsLatest = atBottom }
        userScrolling = userDriven
    }

    mutating func submitted() {
        followsLatest = true
        userScrolling = false
    }

    mutating func explore() {
        followsLatest = false
        userScrolling = false
    }
}

enum ConversationText {
    static func preview(_ text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
