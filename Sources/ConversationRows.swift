import SwiftUI

private func renderedReply(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

struct ConversationTurnRow: View {
    let turn: ConversationTurn
    let agent: String
    let isLive: Bool
    var store: GoblinStore
    let onExplore: () -> Void
    @State private var collapsed = false
    @State private var exploring = false
    @State private var branch = "replies"

    private var streamedReply: ChatMessage? {
        if !isLive || ConversationText.preview(store.stream).isEmpty { return nil }
        return ChatMessage(.object([
            "id": .string("stream-" + turn.id), "response_id": .string(store.responseID),
            "kind": .string("agent"), "text": .string(store.stream),
            "turn_id": .string(turn.id), "final": .bool(false), "streaming": .bool(true)
        ]))
    }

    private var savedRecords: [ChatMessage] {
        var result: [ChatMessage] = []
        var seen = Set<Int>()
        for entry in turn.entries {
            if let index = entry.recordIndex, !seen.contains(index) {
                seen.insert(index)
                result.append(entry)
            }
        }
        return result
    }

    var body: some View {
        let segments = turn.segments(stream: streamedReply, active: isLive)
        VStack(alignment: .leading, spacing: 12) {
            if !savedRecords.isEmpty {
                Menu(store.loadingRecord ? "Reading saved record…" : "Saved records") {
                    ForEach(savedRecords) { entry in
                        if let index = entry.recordIndex {
                            Button("Read " + entry.kind + " record " + String(index)) {
                                Task { await store.readRecord(index) }
                            }.accessibilityIdentifier("read-record-" + entry.id)
                        }
                    }
                }.disabled(store.loadingRecord).accessibilityIdentifier("saved-records-" + turn.id)
            }
            if collapsed {
                DisclosureGroup(isExpanded: $exploring) {
                    if exploring {
                        Picker("Explore thread", selection: $branch) {
                            Text("Replies").tag("replies")
                            Text("Tool calls").tag("calls")
                            Text("Diff").tag("diff")
                        }.pickerStyle(.segmented)
                        ForEach(segments) { segment in
                            switch segment {
                            case .message(let message):
                                if branch == "replies" {
                                    ConversationBubble(message: message, agent: agent, onExplore: onExplore) { collapsed = true }
                                }
                            case .work(let work):
                                if branch == "calls" { ConversationCalls(work: work) }
                                if branch == "diff" { ConversationChanges(diffs: work.diffs) }
                            }
                        }
                        Button("Expand thread") { collapsed = false; exploring = false }
                    }
                } label: {
                    Text(ConversationText.preview(turn.prompt?.text ?? turn.preview)).lineLimit(1)
                }
                .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("thread-" + turn.id)
            } else {
                ForEach(segments) { segment in
                    switch segment {
                    case .message(let message):
                        ConversationBubble(message: message, agent: agent, onExplore: onExplore) { collapsed = true }
                    case .work(let work):
                        let active = isLive && segment.id == segments.last?.id
                        let hasReasoning = work.entries.contains { $0.kind == "thought" && !$0.text.isEmpty }
                        if active || !work.calls.isEmpty || !work.diffs.isEmpty || hasReasoning {
                            ConversationWorkRow(work: work, turnID: turn.id, active: active, store: store, onExplore: onExplore)
                        }
                    }
                }
                let hasThoughtSegment = segments.contains { segment in
                    if case .work(let work) = segment {
                        return work.entries.contains { $0.kind == "thought" && !$0.text.isEmpty }
                    }
                    return false
                }
                if !isLive && !hasThoughtSegment && store.finishedThoughtTurnID == turn.id && !store.finishedThought.isEmpty {
                    ReasoningDisclosure(text: store.finishedThought)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: collapsed) { onExplore() }
        .onChange(of: exploring) { onExplore() }
    }
}

struct ConversationBubble: View {
    let message: ChatMessage
    let agent: String
    let onExplore: () -> Void
    let collapseThread: () -> Void
    @State private var collapsed = false

    private var label: String {
        if message.kind == "user" { return "You" }
        return message.status.isEmpty ? agent : "Status"
    }

    var body: some View {
        let user = message.kind == "user"
        HStack {
            if user { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if message.streaming { Text("Replying").font(.caption).foregroundStyle(.secondary) }
                    if user && !message.status.isEmpty { Text(message.status.capitalized).font(.caption).foregroundStyle(.secondary) }
                    Button {
                        collapsed.toggle()
                    } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsed ? "Expand reply" : "Collapse reply")
                    .accessibilityIdentifier("toggle-" + message.displayID)
                    Menu {
                        Button("Collapse thread", action: collapseThread)
                    } label: {
                        Image(systemName: "ellipsis").font(.caption)
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Thread options")
                }
                if collapsed {
                    Text(renderedReply(ConversationText.preview(message.text))).lineLimit(1)
                } else {
                    Text(renderedReply(message.text)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(message.attachmentPaths.indices, id: \.self) { index in
                        let path = message.attachmentPaths[index]
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "paperclip")
                            .font(.caption).foregroundStyle(.secondary).help(path)
                    }
                }
            }
            .padding(12)
            .background(user ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 15))
            .accessibilityIdentifier(message.displayID)
            .onChange(of: collapsed) { onExplore() }
            if !user { Spacer(minLength: 28) }
        }
    }
}

struct ReasoningDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("Reasoning").font(.caption)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("reasoning-toggle")
            if expanded {
                Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ConversationWorkRow: View {
    let work: ConversationWork
    let turnID: String
    let active: Bool
    var store: GoblinStore
    let onExplore: () -> Void
    @State private var expanded = false
    @State private var branch = "calls"

    private var reasoning: String {
        var parts: [String] = []
        for entry in work.entries {
            if entry.kind == "thought" && !entry.text.isEmpty { parts.append(entry.text) }
        }
        if parts.isEmpty && store.finishedThoughtTurnID == turnID { return store.finishedThought }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if active { livePanel }
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    Picker("Explore work", selection: $branch) {
                        Text("Calls").tag("calls")
                        Text("Diff").tag("diff")
                    }.pickerStyle(.segmented).padding(.top, 6)
                    if branch == "calls" { ConversationCalls(work: work) }
                    else { ConversationChanges(diffs: work.diffs) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                    if work.calls.count > 0 { Text("\(work.calls.count) tool \(work.calls.count == 1 ? "call" : "calls")").lineLimit(1) }
                    else { Text(active ? store.livePhase : "Background work").lineLimit(1) }
                    Spacer(minLength: 0)
                    if active {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(store.elapsedLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }.font(.caption)
            }
            if !active && !reasoning.isEmpty {
                ReasoningDisclosure(text: reasoning)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier(work.id)
        .onChange(of: expanded) { if expanded { onExplore() } }
        .contextMenu {
            Button("Show calls") { branch = "calls"; expanded = true }
            Button("Show diff") { branch = "diff"; expanded = true }
        }
    }

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(store.livePhase).font(.caption.weight(.semibold))
                    Text(store.elapsedLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(store.updateLabel).font(.caption).foregroundStyle(store.isStalled ? Color.orange : Color.secondary)
                    Spacer(minLength: 0)
                }
            }
            if !store.thoughtStream.isEmpty {
                ScrollViewReader { reader in
                    ScrollView {
                        Text(store.thoughtStream).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("thought-tail")
                    }
                    .frame(maxHeight: 150)
                    .onChange(of: store.thoughtStream) { reader.scrollTo("thought-tail", anchor: .bottom) }
                }
                .padding(8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("live-reasoning")
            } else if !store.activityDetail.isEmpty {
                Text(store.activityDetail).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("live-activity")
            } else {
                Text("Waiting for the first token. The timer and update age stay live.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConversationCalls: View {
    let work: ConversationWork

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(work.calls) { call in
                DisclosureGroup(call.name) {
                    if let request = call.request {
                        Text(request.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let result = call.result {
                        Text(result.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.accessibilityIdentifier("call-" + call.id)
            }
            DisclosureGroup("Context and full activity") {
                ForEach(work.entries) { entry in
                    if entry.kind != "tool" && entry.kind != "result" {
                        Text(entry.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 6)
    }
}

struct ConversationChanges: View {
    let diffs: [ConversationDiff]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if diffs.isEmpty {
                Text("No file changes recorded for this work.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(diffs) { diff in
                DisclosureGroup(diff.path + " · " + diff.change) {
                    if !diff.detail.isEmpty {
                        Text(diff.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if !diff.movedFrom.isEmpty { Text("From: " + diff.movedFrom).font(.caption) }
                    if !diff.movedTo.isEmpty { Text("To: " + diff.movedTo).font(.caption) }
                    if diff.patch.isEmpty {
                        Text("No inline text patch.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(diff.patch).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.accessibilityIdentifier(diff.id)
            }
        }.padding(.top, 6)
    }
}
