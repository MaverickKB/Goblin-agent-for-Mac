import Foundation

/// A model a provider is known to serve. `reasoning` marks models that spend
/// tokens thinking before answering; compaction wants a fast non-reasoning one.
struct CatalogModel: Equatable, Identifiable {
    let id: String
    let name: String
    let reasoning: Bool

    var displayName: String {
        if name.isEmpty { return id }
        return name
    }
}

/// Seed catalogs keyed by provider id. They exist so the picker is populated
/// before the network catalog arrives, and so a provider with no reachable
/// catalog still offers its documented ids instead of free text.
enum ModelCatalog {
    static func models(for provider: String) -> [CatalogModel] {
        switch provider {
        case AccountProvider.xai: return xai
        default: return []
        }
    }

    /// Ids verified against https://docs.x.ai/developers/models.md.
    static let xai: [CatalogModel] = [
        CatalogModel(id: "grok-4.7", name: "Grok 4.7", reasoning: true),
        CatalogModel(id: "grok-4.6", name: "Grok 4.6", reasoning: true),
        CatalogModel(id: "grok-4.5", name: "Grok 4.5", reasoning: true),
        CatalogModel(id: "grok-4.3", name: "Grok 4.3", reasoning: true),
        CatalogModel(id: "grok-4.20-0309-reasoning", name: "Grok 4.20 Reasoning", reasoning: true),
        CatalogModel(id: "grok-4.20-0309-non-reasoning", name: "Grok 4.20 Non-reasoning", reasoning: false),
        CatalogModel(id: "grok-4.20-multi-agent-0309", name: "Grok 4.20 Multi-agent", reasoning: true),
        CatalogModel(id: "grok-build-0.1", name: "Grok Build 0.1", reasoning: true)
    ]

    /// Compaction rewrites history, it does not need to think.
    static func defaultCompactionModel(for provider: String) -> String? {
        models(for: provider).first { !$0.reasoning }?.id
    }

    /// Closest catalog id to an unrecognized saved id, for a non-blocking
    /// warning. Prefix or substring overlap is enough; the provider may simply
    /// have shipped a model the catalog has not learned yet.
    static func suggestion(for id: String, in models: [CatalogModel]) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if models.contains(where: { $0.id == trimmed }) { return nil }
        let saved = normalize(trimmed)
        guard !saved.isEmpty else { return nil }
        // Same letters and digits, different separators: the published id is a
        // correction, not a different model.
        if let exact = models.first(where: { normalize($0.id) == saved }) { return exact.id }
        var best: (score: Int, id: String)?
        for model in models {
            let candidate = normalize(model.id)
            var score = 0
            if candidate.hasPrefix(saved) || saved.hasPrefix(candidate) {
                score = max(saved.count, candidate.count) + 100
            } else if candidate.contains(saved) || saved.contains(candidate) {
                score = min(saved.count, candidate.count)
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (score, model.id)
            }
        }
        return best?.id
    }

    /// Separators vary between a guessed id and the published one, as in
    /// `grok-4-7` against `grok-4.7`, so compare without them.
    private static func normalize(_ id: String) -> String {
        id.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// The rows a model picker shows for one provider: the catalog, plus the saved
/// id when it is not in that catalog so a mismatch stays visible instead of
/// being silently dropped.
struct ModelChoices: Equatable {
    let rows: [CatalogModel]
    let savedNotInCatalog: String?
    let usedSeed: Bool

    var isEmpty: Bool { rows.isEmpty && savedNotInCatalog == nil }
}

enum ModelSelection {
    /// A saved id absent from the chosen list becomes its own row, tagged so the
    /// operator can see it is not catalog-backed.
    static func rows(provider: String, saved: String, fetched: [AccountModel]) -> ModelChoices {
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog: [CatalogModel]
        var usedSeed = false
        if fetched.isEmpty {
            catalog = ModelCatalog.models(for: provider)
            usedSeed = !catalog.isEmpty
        } else {
            catalog = fetched.map { CatalogModel(id: $0.id, name: $0.displayName, reasoning: false) }
        }
        let present = catalog.contains { $0.id == trimmed }
        let savedRow = (!trimmed.isEmpty && !present) ? trimmed : nil
        return ModelChoices(rows: catalog, savedNotInCatalog: savedRow, usedSeed: usedSeed)
    }
}
