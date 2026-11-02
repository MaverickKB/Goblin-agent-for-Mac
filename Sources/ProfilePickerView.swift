import SwiftUI

struct ProfilePickerView: View {
    let coordinator: ProfileCoordinator
    let current: CompanionWindowController
    let defaultName: String
    let dismiss: () -> Void
    let onRecall: (GoblinProfile, Bool) -> Void
    @State private var profiles: [GoblinProfile] = []
    @State private var selectedID = ""
    @State private var name = ""
    @State private var busy = false
    @State private var notice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Goblin profiles").font(.title2)
            Text("Each Goblin keeps its own settings, avatar, history and live autonomy state. Templates are shared. Choose shared or independent memory using the existing AetherMind settings.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Goblin", selection: $selectedID) {
                ForEach(profiles) { profile in
                    Text(coordinator.name(for: profile, defaultName: defaultName)).tag(profile.id)
                }
            }.accessibilityIdentifier("profile-picker")
            HStack {
                Button("Recall here") { recall(inCurrentWindow: true) }
                    .disabled(busy || selectedID.isEmpty).accessibilityIdentifier("profile-recall-here")
                Button("Open in new window") { recall(inCurrentWindow: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || selectedID.isEmpty).accessibilityIdentifier("profile-open-window")
            }
            Text("Switching keeps outgoing work running. An already presented Goblin is focused in its existing window.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            TextField("New Goblin name", text: $name).accessibilityIdentifier("profile-new-name")
            Button("Create Goblin") { Task { await create() } }
                .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("profile-create")
            if !notice.isEmpty { Text(notice).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button("Done", action: dismiss).disabled(busy) }
        }.padding(22).frame(width: 480)
            .onAppear { reload() }
    }

    private func reload() {
        coordinator.refreshProfileChoices()
        do {
            profiles = try coordinator.catalog.profiles()
            if selectedID.isEmpty { selectedID = current.profile?.id ?? GoblinProfile.defaultProfile.id }
        } catch { notice = error.localizedDescription }
    }

    private func recall(inCurrentWindow: Bool) {
        onRecall(GoblinProfile(id: selectedID), inCurrentWindow)
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let profile = try await coordinator.create(name: name)
            selectedID = profile.id
            name = ""
            reload()
            notice = "Goblin created. Choose Recall here or Open in new window."
        } catch { notice = error.localizedDescription }
    }
}
