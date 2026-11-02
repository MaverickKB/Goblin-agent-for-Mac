import AppKit
import SwiftUI

struct ChatView: View {
    @Bindable var store: GoblinStore
    @State private var scrollState = ConversationScrollState()
    @State private var visibleTurns = 40

    private var turnsToShow: [ConversationTurn] {
        if store.turns.count <= visibleTurns {
            return store.turns
        }
        return Array(store.turns.suffix(visibleTurns))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Menu {
                        if !store.profileChoicesError.isEmpty {
                            Text(store.profileChoicesError)
                        }
                        Section("Recall here") {
                            ForEach(store.profileChoices) { profile in
                                Button {
                                    store.selectProfile?(profile.id, false)
                                } label: {
                                    if profile.id == store.profileID { Label(profile.name, systemImage: "checkmark") }
                                    else { Text(profile.name) }
                                }
                            }
                        }
                        Menu("Open in new window") {
                            ForEach(store.profileChoices) { profile in
                                Button(profile.name) { store.selectProfile?(profile.id, true) }
                            }
                        }
                        Divider()
                        Button("Create new Goblin…") { store.showProfiles?() }
                    } label: {
                        HStack(spacing: 5) {
                            Text(store.name).font(.headline).lineLimit(1).truncationMode(.tail)
                            Image(systemName: "chevron.down").font(.caption)
                        }
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .fixedSize(horizontal: false, vertical: true).help(store.name)
                        .accessibilityIdentifier("chat-profile-selector")
                    if !store.model.isEmpty {
                        Text(store.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("\(store.turns.count) turns, showing \(turnsToShow.count)").font(.caption2).foregroundStyle(.secondary)
                }
                WindowDragRegion().frame(minWidth: 20, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                Button(store.autonomous ? "Autonomy on" : "Autonomy off", systemImage: store.autonomous ? "sparkle" : "moon") {
                    Task { await store.setAutonomy(!store.autonomous) }
                }.disabled(!store.isConnected).accessibilityIdentifier("autonomy-toggle")
                Button("Settings", systemImage: "gearshape") { store.showSettings?() }.labelStyle(.iconOnly).help("Settings")
                AccessibleButton(title: "Collapse chat", identifier: "collapse-chat", enabled: true,
                                 symbol: "arrow.down.right.and.arrow.up.left") { store.collapseChat?() }
                    .frame(width: 32, height: 26)
            }.padding(16)
            Divider()
            if !store.isConnected {
                HStack {
                    Text(store.connectionState == .starting ? "Connecting to the local engine…" : "The local engine is disconnected.")
                        .font(.caption)
                    Spacer()
                    Button(store.connectionState == .starting ? "Connecting…" : "Reconnect") {
                        Task { await store.start() }
                    }.disabled(store.connectionState == .starting).accessibilityIdentifier("reconnect-engine")
                }.padding(12)
            } else if store.settingsLoaded && !store.ready {
                HStack {
                    Text(store.setupIssue.isEmpty ? "Configure a chat model." : store.setupIssue).font(.caption)
                    Spacer()
                    Button("Open Settings") { store.showSettings?() }.accessibilityIdentifier("open-setup")
                }.padding(12)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if store.hasEarlierHistory {
                            Button(store.loadingHistory ? "Loading history…" : "Load earlier history") {
                                Task { await store.loadEarlierHistory(); visibleTurns += 80 }
                            }.disabled(store.loadingHistory).accessibilityIdentifier("load-earlier-history")
                        }
                        if store.turns.count > turnsToShow.count {
                            Button("Load earlier turns") {
                                visibleTurns += 40
                            }
                            .font(.caption)
                            .accessibilityIdentifier("load-earlier-turns")
                        }
                        ForEach(turnsToShow) { turn in
                            ConversationTurnRow(turn: turn, agent: store.name,
                                isLive: store.busy && turn.id == store.liveTurnID, store: store,
                                onExplore: { scrollState.explore() })
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }.padding(16)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 70
                } action: { _, value in
                    if scrollState.geometryChanged(atBottom: value) { reader.scrollTo("tail", anchor: .bottom) }
                }
                .onScrollPhaseChange { _, phase in
                    let userDriven = phase == .tracking || phase == .interacting || phase == .decelerating
                    scrollState.phaseChanged(userDriven: userDriven)
                }
                .onChange(of: store.submittedMessageID) {
                    scrollState.submitted()
                    reader.scrollTo("tail", anchor: .bottom)
                }
                .onChange(of: store.turns.last?.id) { if scrollState.followsLatest { reader.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: store.busy) { if scrollState.followsLatest { reader.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: store.stream) { if scrollState.followsLatest { reader.scrollTo("tail", anchor: .bottom) } }
            }
            if let approval = store.approval { ApprovalCard(store: store, approval: approval) }
            if !store.error.isEmpty {
                HStack {
                    Text(store.error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { store.error = "" }.labelStyle(.iconOnly)
                }.padding(12).background(.red.opacity(0.12))
            }
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: Binding(get: { store.recordDetail != nil }, set: { if !$0 { store.recordDetail = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Saved record").font(.headline); Spacer(); Button("Done") { store.recordDetail = nil } }
                ScrollView { Text(store.recordDetail ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20).frame(width: 650, height: 550)
        }
        .onChange(of: store.voice.error) {
            if !store.voice.error.isEmpty { store.error = store.voice.error }
        }
    }

    private var voiceActive: Bool {
        return store.voice.isConnected || store.voice.phase == "starting" || store.voice.phase == "connecting"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.attachedFiles.isEmpty {
                ForEach(store.attachedFiles, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent).font(.caption)
                        Button("Remove attachment", systemImage: "xmark.circle") { store.attachedFiles.removeAll { $0 == url } }.labelStyle(.iconOnly)
                    }
                }
            }
            if store.busy { LiveStatusStrip(store: store) }
            NativeComposer(text: $store.draft, label: "Message " + store.name,
                           commandReturn: { Task { await store.commandReturn() } },
                           attachFiles: { urls in store.addAttachments(urls) },
                           pasteDirectory: store.pasteDirectory) {
                submitComposer()
            }.frame(height: CompanionLayout.composerHeight)
            HStack {
                Button("Attach file", systemImage: "paperclip") { store.attach() }.labelStyle(.iconOnly)
                Button(voiceActive ? "End voice" : "Voice", systemImage: voiceActive ? "phone.down.fill" : "waveform") {
                    Task { await store.toggleVoice() }
                }.disabled(!store.isConnected && !voiceActive).accessibilityIdentifier("voice-toggle")
                if store.voice.isConnected {
                    Button(store.voice.isMuted ? "Unmute mic" : "Mute mic", systemImage: store.voice.isMuted ? "mic.slash.fill" : "mic") {
                        store.voice.setMuted(!store.voice.isMuted)
                    }.accessibilityIdentifier("microphone-mute")
                    Text(store.voice.phase).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.busy {
                    Button("Steer") { Task { await store.steer() } }.disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Stop", systemImage: "stop.fill") { Task { await store.stop() } }.accessibilityIdentifier("stop-turn")
                }
                AccessibleButton(title: "Send", identifier: "send-message", enabled: store.canSend) {
                    Task { await store.send() }
                }.frame(width: 72, height: 28)
            }
            Text(returnHint).font(.caption2).foregroundStyle(.secondary)
        }.padding(16)
    }

    private func submitComposer() {
        if store.busy {
            Task { await store.commandReturn() }
            return
        }
        if store.canSend {
            Task { await store.send() }
        }
    }

    private var returnHint: String {
        if store.busy {
            if store.preferences.commandReturn == "queue" {
                return "Return queues this message behind the running turn."
            }
            return "Return steers the running turn."
        }
        return "Return sends."
    }
}

struct LiveStatusStrip: View {
    @Bindable var store: GoblinStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(store.livePhase).font(.caption.weight(.semibold))
                Text(store.elapsedLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(store.updateLabel).font(.caption).foregroundStyle(store.isStalled ? Color.orange : Color.secondary)
                if store.thoughtStream.isEmpty && !store.activityDetail.isEmpty {
                    Text(store.activityDetail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.isStalled {
                    Text("No engine update").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("live-status")
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let agent: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.kind == "user" || message.kind == "agent" {
                Text(message.kind == "user" ? "You" : agent).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(markdown(message.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(message.kind == "user" ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            } else {
                DisclosureGroup(message.name.isEmpty ? message.kind.capitalized : message.name) {
                    Text(message.text).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain)
    }
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct AvatarImage: View {
    var store: GoblinStore
    var size: CGFloat
    var id: String? = nil
    var standing = false

    var body: some View {
        Group {
            if let image = store.avatarImage(id, standing: standing) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityLabel(store.name + " avatar")
    }
}

struct SpeechTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.75, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct CompanionView: View {
    @Bindable var store: GoblinStore

    var body: some View {
        HStack(alignment: .bottom, spacing: CompanionLayout.gap) {
            StandingGoblinView(store: store)
                .frame(width: CompanionLayout.figureColumnWidth)
            if !store.isCollapsed {
                VStack(spacing: 0) {
                    if store.settingsVisible {
                        HStack {
                            Text("Settings").font(.headline)
                            WindowDragRegion().frame(minWidth: 20, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                            Button("Back to chat", systemImage: "arrow.left") { store.settingsVisible = false }
                        }.padding(16)
                        Divider()
                        if let approval = store.approval { ApprovalCard(store: store, approval: approval) }
                        SettingsView(store: store)
                    } else {
                        ChatView(store: store)
                    }
                }
                .frame(width: CompanionLayout.boardWidth, height: CompanionLayout.boardHeight)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.7), lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-board")
            }
        }
        .padding(CompanionLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(.clear)
        .onChange(of: store.voice.error) {
            if !store.voice.error.isEmpty { store.error = store.voice.error }
        }
    }
}

struct StandingGoblinView: View {
    @Bindable var store: GoblinStore

    private var reply: String {
        let current = ConversationText.preview(store.stream)
        if !current.isEmpty { return current }
        if store.busy {
            let thought = store.liveThoughtLine
            if !thought.isEmpty { return thought }
            return store.livePhase + " " + store.elapsedLabel
        }
        return store.turns.last?.preview ?? ""
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if store.isCollapsed && !reply.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button { store.showChat?() } label: {
                        Text(reply).font(.body).foregroundStyle(.black)
                            .multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black, lineWidth: 2.5))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Reply: " + reply + ". Open chat")
                        .accessibilityIdentifier("reply-bubble")
                    SpeechTail().fill(.white).overlay(SpeechTail().stroke(.black, lineWidth: 2.5))
                        .frame(width: 25, height: 19).padding(.leading, 54).offset(y: -2)
                }.padding(.bottom, 6)
            }
            GoblinSprite(store: store)
            if store.isCollapsed {
                QuickChatView(store: store).padding(.top, 8)
            }
        }
    }
}
