import AppKit
import SwiftUI

struct CompanionOptions: View {
    @Bindable var preferences: CompanionPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Always on top", isOn: $preferences.alwaysOnTop).accessibilityIdentifier("always-on-top")
            Toggle("Animate companion", isOn: $preferences.animations).accessibilityIdentifier("animate-companion")
            Toggle("Hold character to talk", isOn: $preferences.pushToTalk).accessibilityIdentifier("push-to-talk")
            Picker("Return while working", selection: $preferences.commandReturn) {
                Text("Steer").tag("steer")
                Text("Queue").tag("queue")
            }.pickerStyle(.segmented).accessibilityIdentifier("command-return")
        }
    }
}

struct GoblinSprite: View {
    var store: GoblinStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LivingCharacter(store: store, reduceMotion: reduceMotion)
            .frame(width: CompanionLayout.figureWidth, height: CompanionLayout.figureHeight)
            .accessibilityHidden(true)
        .overlay { AvatarInteraction(store: store) }
        .overlay(alignment: .bottomTrailing) {
            if store.preferences.pushToTalk {
                Image(systemName: store.pushToTalk.isHeld ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(store.pushToTalk.isHeld ? Color.green : Color.secondary)
                    .padding(7).background(.regularMaterial, in: Circle())
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

struct QuickChatView: View {
    @Bindable var store: GoblinStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.error.isEmpty {
                Text(store.error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(3)
            }
            if let approval = store.approval {
                Text("Approval needed: " + approval["name"].stringValue).font(.caption)
                AccessibleButton(title: "Review request", identifier: "review-approval", enabled: true) {
                    store.showChat?()
                }.frame(height: 28)
            }
            if store.busy {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(store.livePhase).font(.caption2)
                        Text(store.elapsedLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(store.updateLabel).font(.caption2).foregroundStyle(store.isStalled ? Color.orange : Color.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            HStack(spacing: 6) {
                NativeComposer(text: $store.draft, label: "Quick message",
                               commandReturn: { Task { await store.commandReturn() } },
                               identifier: "quick-composer",
                               attachFiles: { urls in store.addAttachments(urls) },
                               pasteDirectory: store.pasteDirectory) {
                    submitQuick()
                }.frame(height: 32)
                AccessibleButton(title: quickActionTitle, identifier: "quick-send", enabled: store.canSend, symbol: "arrow.up") {
                    submitQuick()
                }.frame(width: 30, height: 28)
                AccessibleButton(title: "Open chat", identifier: "open-chat", enabled: true, symbol: "arrow.up.left.and.arrow.down.right") {
                    store.showChat?()
                }.frame(width: 30, height: 28)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.15)))
    }

    private var quickActionTitle: String {
        if !store.busy { return "Send quick message" }
        if store.preferences.commandReturn == "queue" { return "Queue quick message" }
        return "Steer quick message"
    }

    private func submitQuick() {
        if store.busy {
            Task { await store.commandReturn() }
            return
        }
        if store.canSend {
            Task { await store.send() }
        }
    }
}
