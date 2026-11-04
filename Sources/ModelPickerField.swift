import SwiftUI

struct ModelPickerField: View {
    @Binding var model: String
    let provider: String
    let choices: ModelChoices
    let loading: Bool
    let error: String
    let identifier: String

    var body: some View {
        if provider == AccountConnectionOptions.customID {
            SettingsTextField("Model", text: $model, identifier: identifier)
        } else {
            LabeledContent("Model") {
                if choices.isEmpty && loading {
                    Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                } else if choices.isEmpty {
                    Text("No models available for this account.").font(.caption).foregroundStyle(.orange)
                } else {
                    Picker("Model", selection: $model) {
                        if model.isEmpty {
                            Text("Choose a model").tag("")
                        }
                        if let saved = choices.savedNotInCatalog {
                            Text("Saved, not in catalog: " + saved).tag(saved)
                        }
                        ForEach(choices.rows) { item in
                            Text(item.displayName + (item.reasoning ? " (reasoning)" : "")).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier(identifier)
                }
            }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier(identifier + "-error")
            } else if choices.usedSeed {
                Text("Showing the provider's documented models. Checking the account refreshes this list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
