import AppKit
import SwiftUI

enum AccountProvider {
    /// Voice is an xAI consumer, not a login owner. The account itself comes
    /// from the manifest-backed account/list rows.
    static let xai = "xai"
}

struct AccountConnectionOption: Equatable, Identifiable {
    let id: String
    let label: String
}

enum AccountConnectionOptions {
    static let customID = "custom"

    /// Account rows come from account/list, in manifest order. A saved account
    /// selection is kept even before the first report arrives, so opening
    /// Settings never silently changes the configured route.
    static func accountOptions(reports: [AccountReport], selected: String) -> [AccountConnectionOption] {
        var options: [AccountConnectionOption] = []
        var seen: Set<String> = []
        for report in reports {
            if report.provider.isEmpty { continue }
            if report.provider == customID { continue }
            if seen.contains(report.provider) { continue }
            var label = report.name
            if label.isEmpty { label = report.provider }
            options.append(AccountConnectionOption(id: report.provider, label: label))
            seen.insert(report.provider)
        }
        if selected.isEmpty { return options }
        if selected == customID { return options }
        if seen.contains(selected) { return options }
        options.append(AccountConnectionOption(id: selected, label: selected))
        return options
    }

    static func label(for provider: String, in options: [AccountConnectionOption]) -> String {
        for option in options {
            if option.id == provider { return option.label }
        }
        return provider
    }
}

struct AccountModel: Equatable, Identifiable {
    var id = ""
    var name = ""

    init(_ value: JSONValue) {
        id = value["id"].stringValue
        name = value["name"].stringValue
    }

    var displayName: String {
        if name.isEmpty { return id }
        return name
    }
}

struct AccountReport: Equatable, Identifiable {
    var provider = ""
    var name = ""
    var status = "unknown"
    var message = ""
    var verificationURL = ""
    var userCode = ""

    init() {}

    init(_ value: JSONValue) {
        provider = value["provider"].stringValue
        name = value["name"].stringValue
        status = value["status"].stringValue
        message = value["message"].stringValue
        verificationURL = value["verification_url"].stringValue
        userCode = value["user_code"].stringValue
        if status.isEmpty { status = "unknown" }
    }

    var id: String { provider }

    var isWaiting: Bool {
        return status == "starting" || status == "waiting"
    }

    var isActive: Bool {
        if isWaiting { return true }
        return status == "cancelling"
    }

    var canCancel: Bool { isWaiting }

    var isSignedIn: Bool { status == "signed_in" }
    var requiresKeychainAccess: Bool { status == "keychain_required" }

    var actionTitle: String {
        if isSignedIn { return "Reconnect" }
        return "Connect"
    }

    var statusLabel: String {
        switch status {
        case "signed_in": return "Signed in"
        case "starting": return "Starting"
        case "waiting": return "Waiting for approval"
        case "cancelling": return "Cancelling"
        case "cancelled": return "Cancelled"
        case "interrupted": return "Sign-in interrupted"
        case "unavailable": return "Account unavailable"
        case "keychain_required": return "Keychain access required"
        case "sign_in_required": return "Sign in required"
        case "missing": return "Not connected"
        case "error": return "Sign-in failed"
        default: return "Not checked"
        }
    }

    var canOpenPage: Bool {
        guard let url = URL(string: verificationURL) else { return false }
        guard url.scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }
}

struct AccountCheck: Equatable {
    var provider = ""
    var ok = false
    var message = ""
    var models: [AccountModel] = []

    init() {}

    init(_ value: JSONValue) {
        provider = value["provider"].stringValue
        ok = value["ok"].boolValue
        message = value["message"].stringValue
        var loaded: [AccountModel] = []
        for item in value["models"].arrayValue {
            let model = AccountModel(item)
            if model.id.isEmpty { continue }
            loaded.append(model)
        }
        models = loaded
    }

    var summary: String {
        if !message.isEmpty { return message }
        if ok { return "Connection OK" }
        return "Connection check failed"
    }
}

/// Every start or cancel begins a new account attempt. A completion from an
/// older attempt must not apply over the newer one.
struct AccountAttemptGate: Equatable {
    private(set) var revision = 0
    var current: Int { revision }

    mutating func beginAction() -> Int {
        revision += 1
        return revision
    }

    func isCurrent(_ attempt: Int) -> Bool {
        return attempt == revision
    }
}

struct ConnectionAccountsSection: View {
    let reports: [AccountReport]
    let checks: [String: AccountCheck]
    let checking: Set<String>
    let notice: String
    let authorizing: Bool
    let authorize: (String) -> Void
    let connect: (String) -> Void
    let cancel: (String) -> Void
    let openPage: (String) -> Void
    let checkConnection: (String) -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if reports.isEmpty {
                Text("Loading accounts…").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("accounts-loading")
            }
            ForEach(reports) { report in
                AccountRow(report: report,
                           check: checks[report.provider],
                           checking: checking.contains(report.provider),
                           authorizing: authorizing,
                           authorize: authorize,
                           connect: connect,
                           cancel: cancel,
                           openPage: openPage,
                           checkConnection: checkConnection)
            }
            AccessibleButton(title: "Refresh accounts",
                             identifier: "refresh-accounts",
                             enabled: true) {
                refresh()
            }.frame(height: 28)
            if !notice.isEmpty {
                Text(notice).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("account-notice")
            }
        }.padding(.vertical, 4)
    }
}

struct AccountRow: View {
    let report: AccountReport
    let check: AccountCheck?
    let checking: Bool
    let authorizing: Bool
    let authorize: (String) -> Void
    let connect: (String) -> Void
    let cancel: (String) -> Void
    let openPage: (String) -> Void
    let checkConnection: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(report.name).font(.headline)
                Text(report.statusLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("account-status-" + report.provider)
                Spacer()
            }
            if !report.message.isEmpty {
                Text(report.message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("account-message-" + report.provider)
            }
            if !report.userCode.isEmpty {
                HStack(spacing: 8) {
                    Text("Code").font(.caption).foregroundStyle(.secondary)
                    Text(report.userCode).font(.headline.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("account-code-" + report.provider)
                }
            }
            HStack(spacing: 8) {
                if report.requiresKeychainAccess {
                    AccessibleButton(title: "Allow Keychain access",
                                     identifier: "account-authorize-" + report.provider,
                                     enabled: !authorizing && !report.isActive) {
                        authorize(report.provider)
                    }.frame(height: 28)
                }
                AccessibleButton(title: report.actionTitle,
                                 identifier: "account-connect-" + report.provider,
                                 enabled: !report.isActive && !authorizing && !report.requiresKeychainAccess) {
                    connect(report.provider)
                }.frame(height: 28)
                AccessibleButton(title: "Cancel",
                                 identifier: "account-cancel-" + report.provider,
                                 enabled: report.canCancel) {
                    cancel(report.provider)
                }.frame(height: 28)
                AccessibleButton(title: "Open sign-in page",
                                 identifier: "account-open-page-" + report.provider,
                                 enabled: report.canOpenPage) {
                    openPage(report.provider)
                }.frame(height: 28)
                AccessibleButton(title: "Check connection",
                                 identifier: "account-check-" + report.provider,
                                 enabled: !checking && !report.isActive && !authorizing && !report.requiresKeychainAccess) {
                    checkConnection(report.provider)
                }.frame(height: 28)
            }
            if report.requiresKeychainAccess {
                Text("Choose Always Allow to keep access.").font(.caption).foregroundStyle(.secondary)
            }
            if let check {
                Text(check.summary).font(.caption)
                    .foregroundStyle(check.ok ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("account-check-result-" + report.provider)
                if !check.models.isEmpty {
                    Text(modelCountLabel(check.models.count)).font(.caption).foregroundStyle(.secondary)
                    Text(modelNames(check.models)).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("account-models-" + report.provider)
                }
            }
        }.accessibilityElement(children: .contain)
    }

    private func modelCountLabel(_ count: Int) -> String {
        if count == 1 { return "1 verified model" }
        return "\(count) verified models"
    }

    private func modelNames(_ models: [AccountModel]) -> String {
        var names: [String] = []
        var index = 0
        for model in models {
            if index >= 8 { break }
            names.append(model.displayName)
            index += 1
        }
        var text = names.joined(separator: ", ")
        if models.count > names.count {
            text += " and \(models.count - names.count) more"
        }
        return text
    }
}

struct AccountModelField: View {
    @Binding var model: String
    let models: [AccountModel]
    let identifier: String

    var body: some View {
        SettingsTextField("Model", text: $model, identifier: identifier)
        AccountModelMenu(model: $model, models: models, identifier: identifier)
    }
}

struct AccountModelMenu: View {
    @Binding var model: String
    let models: [AccountModel]
    let identifier: String

    var body: some View {
        if models.isEmpty {
            Text("Check the account above to list its models.").font(.caption).foregroundStyle(.secondary)
        } else {
            Menu("Verified models") {
                ForEach(models) { item in
                    Button(item.displayName) { model = item.id }
                }
            }.accessibilityIdentifier(identifier + "-verified-models")
        }
    }
}
