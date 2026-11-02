import SwiftUI

struct ApprovalCard: View {
    var store: GoblinStore
    let approval: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve " + approval["name"].stringValue + "?").font(.headline)
            Text(approval["arguments"].formatted).font(.caption.monospaced()).lineLimit(3)
            DisclosureGroup("Full arguments") {
                ScrollView {
                    Text(approval["arguments"].formatted).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
            }
            HStack {
                AccessibleButton(title: "Deny", identifier: "deny-approval", enabled: true) {
                    Task { await store.resolveApproval(false) }
                }.frame(width: 80, height: 28)
                AccessibleButton(title: "Allow once", identifier: "allow-approval", enabled: true) {
                    Task { await store.resolveApproval(true) }
                }.frame(width: 110, height: 28)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pending-approval")
    }
}
