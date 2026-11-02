import Foundation
import SwiftUI

struct HelpDocument: Decodable, Identifiable {
    let id: String
    let title: String
    let audience: String
    let file: String
}

struct HelpCatalog: Decodable {
    let documents: [HelpDocument]

    static func load(from root: URL) throws -> HelpCatalog {
        let catalog = try JSONDecoder().decode(HelpCatalog.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
        for document in catalog.documents {
            guard !document.file.isEmpty, document.file != ".", document.file != "..",
                  (document.file as NSString).lastPathComponent == document.file else {
                throw GoblinError(message: "Help catalog contains an invalid document filename.")
            }
        }
        return catalog
    }

    func read(_ id: String, from root: URL) throws -> String {
        guard let document = documents.first(where: { $0.id == id }) else {
            throw GoblinError(message: "Choose a help document.")
        }
        let path = root.appendingPathComponent(document.file).resolvingSymlinksInPath()
        guard path.deletingLastPathComponent().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw GoblinError(message: "Help document is outside its catalog directory.")
        }
        return try String(contentsOf: path, encoding: .utf8)
    }
}

enum HelpMarkdown {
    static func blocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var lines: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if !inFence && !lines.isEmpty {
                    blocks.append(lines.joined(separator: "\n"))
                    lines = []
                }
                lines.append(line)
                inFence.toggle()
                if !inFence {
                    blocks.append(lines.joined(separator: "\n"))
                    lines = []
                }
            } else if line.isEmpty && !inFence {
                if !lines.isEmpty {
                    blocks.append(lines.joined(separator: "\n"))
                    lines = []
                }
            } else {
                lines.append(line)
            }
        }
        if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
        return blocks
    }

    static func codeText(_ block: String) -> String {
        var lines = block.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

enum HelpLinkDestination: Equatable {
    case document(String)
    case external
    case unavailable

    static func resolve(_ url: URL, documents: [HelpDocument]) -> HelpLinkDestination {
        if url.scheme == "https" || url.scheme == "http" {
            return url.host == nil ? .unavailable : .external
        }
        guard url.scheme == nil, url.host == nil else { return .unavailable }
        for document in documents {
            if url.path == document.file { return .document(document.id) }
        }
        return .unavailable
    }
}

struct HelpView: View {
    let root: URL
    @State private var documents: [HelpDocument] = []
    @State private var selected = ""
    @State private var bodyText = ""
    @State private var query = ""
    @State private var issue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Manual", selection: $selected) {
                ForEach(documents) { document in Text(document.title).tag(document.id) }
            }.accessibilityIdentifier("help-document")
            TextField("Find in this manual", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("help-search")
            if !issue.isEmpty { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("help-error") }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if query.isEmpty {
                        ForEach(Array(HelpMarkdown.blocks(bodyText).enumerated()), id: \.offset) { _, block in
                            helpBlock(block)
                        }
                    } else {
                        if searchMatches.isEmpty { Text("No matching text in this manual.") }
                        ForEach(searchMatches, id: \.number) { match in
                            Text("\(match.number): \(match.text)").font(.callout).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.accessibilityIdentifier("help-content")
        }.padding(20).frame(minWidth: 540, minHeight: 500)
            .onAppear { load() }.onChange(of: selected) { read() }
            .environment(\.openURL, OpenURLAction { url in
                switch HelpLinkDestination.resolve(url, documents: documents) {
                case .document(let id):
                    selected = id
                    query = ""
                    read()
                    return .handled
                case .external:
                    return .systemAction
                case .unavailable:
                    issue = "This link is not available in the Help catalog."
                    return .discarded
                }
            })
    }

    private struct SearchMatch {
        let number: Int
        let text: String
    }

    private var searchMatches: [SearchMatch] {
        var matches: [SearchMatch] = []
        for (index, line) in bodyText.components(separatedBy: "\n").enumerated() {
            if line.localizedCaseInsensitiveContains(query) {
                matches.append(SearchMatch(number: index + 1, text: line))
            }
        }
        return matches
    }

    @ViewBuilder private func helpBlock(_ block: String) -> some View {
        if block.hasPrefix("# ") {
            Text(String(block.dropFirst(2))).font(.title).textSelection(.enabled)
        } else if block.hasPrefix("## ") {
            Text(String(block.dropFirst(3))).font(.title2).textSelection(.enabled)
        } else if block.hasPrefix("### ") {
            Text(String(block.dropFirst(4))).font(.headline).textSelection(.enabled)
        } else if block.hasPrefix("```") {
            Text(HelpMarkdown.codeText(block)).font(.callout.monospaced()).textSelection(.enabled)
        } else {
            Text(.init(block)).textSelection(.enabled)
        }
    }

    private func load() {
        do {
            documents = try HelpCatalog.load(from: root).documents
            selected = documents.first?.id ?? ""
            read()
        } catch { issue = error.localizedDescription }
    }

    private func read() {
        do {
            bodyText = try HelpCatalog(documents: documents).read(selected, from: root)
            issue = ""
        } catch { issue = error.localizedDescription; bodyText = "" }
    }
}
