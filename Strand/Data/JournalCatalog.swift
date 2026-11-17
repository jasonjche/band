import Foundation

/// The user's custom journal questions plus the starter behaviour catalog. Imported WHOOP titles
/// and ids are mapped onto catalogue ids (punctuation-insensitive title match plus an alias table)
/// so each behaviour shows once. Stored journal rows are never rewritten; reads accept either id.
/// UserDefaults-backed (single user).
///
/// v2 (#322 / task #53): a journal item can now be renamed (display-only, the stored key stays put
/// so imported WHOOP history still lines up), typed as numeric (a value + unit, not just yes/no),
/// grouped (Nutrition / Supplements / Lifestyle / Health / Behaviour / Other), and reordered. The
/// `canonical` string is the verbatim DB/engine key and is NEVER localised or rewritten; only
/// `displayName` changes on a rename. The legacy custom/hidden UserDefaults arrays are folded into
/// the v2 items once, then read-only.
/// The UserDefaults keys `JournalCatalogStore` persists under, exposed so the backup bridge
/// (`DataBackup`, which runs OFF the main actor) can read/write them directly without driving the
/// `@MainActor` store. Kept beside the store so the key strings can never drift (#1361). A restore
/// writes the restored custom names to `legacyCustom` and clears `items`; the store's init then
/// re-migrates them into v2 on the relaunch a restore forces.
enum JournalCatalogBackupKeys {
    static let items = "journal.catalog.v2"
    static let legacyCustom = "journal.customQuestions"
    static let legacyHidden = "journal.hiddenQuestions"
}

@MainActor
final class JournalCatalogStore: ObservableObject {

    /// Mirrors Android STARTER_JOURNAL_QUESTIONS value-for-value (JournalLog.kt). These are DATA,
    /// not UI literals, stored verbatim in the journal table and rendered verbatim, so they must
    /// never be localised (a translated key would start a new, disconnected behaviour).
    nonisolated static let starterQuestions: [String] = [
        "Did you drink any alcohol?",
        "Did you have caffeine?",
        "Did you view a screen in bed?",
        "Did you eat close to bedtime?",
        "Did you feel stressed?",
        "Did you use a sauna?",
        "Did you share your bed?",
        "Did you feel sick or ill?",
        "Did you take magnesium?",
        "Did you read before bed?",
    ]

    /// The default group for each starter question (canonical → group), derived from the library.
    nonisolated static let starterGroups: [String: JournalGroup] = {
        let seeds = Set(starterQuestions)
        var d: [String: JournalGroup] = [:]
        d.reserveCapacity(seeds.count)
        for entry in libraryEntries where seeds.contains(entry.canonical) {
            d[entry.canonical] = entry.group
        }
        return d
    }()

    /// Short labels for the form and the day's answer list. Display only; the stored key stays
    /// the full question string.
    nonisolated static let shortTitles: [String: String] = Dictionary(
        uniqueKeysWithValues: libraryEntries.map { ($0.canonical, $0.shortTitle) }
    )

    /// Imported titles (and a few short ids) that mean the same behaviour as a library id.
    /// Keys are `titleKey` forms; values are library canonicals. Stored rows are never rewritten.
    nonisolated static let aliasTitles: [(imported: String, canonical: String)] = [
        ("Consumed caffeine?", "Did you have caffeine?"),
        // Earlier Band starter wording; same behaviour as a caffeine log.
        ("Did you have caffeine late in the day?", "Did you have caffeine?"),
        ("Have any alcoholic drinks?", "Did you drink any alcohol?"),
        ("Ate food close to bedtime?", "Did you eat close to bedtime?"),
        ("Shared your bed?", "Did you share your bed?"),
        ("Read (non-screened device) while in bed?", "Did you read before bed?"),
        ("e-close", "Did you eat close to bedtime?"),
        ("eat close to bedtime", "Did you eat close to bedtime?"),
        ("Engaged in sexual activity?", "Did you have sex?"),
        ("Masturbated?", "Did you masturbate?"),
    ]

    /// The v2 catalog: one item per journal question the user has customised (renamed, retyped,
    /// regrouped, reordered, or hidden). Starter questions with default settings are NOT stored here:
    /// they are synthesised at merge time, so this only holds the user's deltas plus their customs.
    /// Persisted as a single JSON blob under `journal.catalog.v2`.
    @Published var items: [JournalCatalogItem] { didSet { persistItems() } }

    private let d: UserDefaults
    private enum K {
        static let items = JournalCatalogBackupKeys.items
        // Legacy (v1) keys, read once for the one-time migration, never written again.
        static let custom = JournalCatalogBackupKeys.legacyCustom
        static let hidden = JournalCatalogBackupKeys.legacyHidden
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        if let blob = d.data(forKey: K.items),
           let decoded = try? JSONDecoder().decode([JournalCatalogItem].self, from: blob) {
            items = decoded
        } else {
            // One-time fold of the legacy two-array store into v2 items. Custom questions become
            // `.bool` items in `.other`; hidden ones keep their hidden flag. Idempotent: after this
            // runs it persists the v2 blob, and the legacy keys are never read again.
            items = Self.migrateLegacy(
                custom: d.stringArray(forKey: K.custom) ?? [],
                hidden: d.stringArray(forKey: K.hidden) ?? [])
            persistItems()
        }
    }

    private func persistItems() {
        if let blob = try? JSONEncoder().encode(items) { d.set(blob, forKey: K.items) }
    }

    /// Build the v2 item list from the legacy custom/hidden arrays. Custom questions → `.bool`
    /// items in `.other`, ordered as they were; hidden starter/imported ones → hidden marker items.
    nonisolated static func migrateLegacy(custom: [String], hidden: [String]) -> [JournalCatalogItem] {
        var out: [JournalCatalogItem] = []
        var seen = Set<String>()
        var i = 0
        for q in custom {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            guard !t.isEmpty, seen.insert(key).inserted else { continue }
            out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                          group: .other, sortIndex: i, hidden: false, custom: true))
            i += 1
        }
        for q in hidden {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            guard !t.isEmpty else { continue }
            if let idx = out.firstIndex(where: { norm($0.canonical) == key }) {
                out[idx].hidden = true   // a hidden custom question
            } else if seen.insert(key).inserted {
                out.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                              group: Self.starterGroups[t] ?? .other,
                                              sortIndex: i, hidden: true, custom: false))
                i += 1
            }
        }
        return out
    }

    // MARK: - Legacy-shape accessors (kept so existing call sites keep working)

    /// The user's custom question canonicals (v1 API shape). Derived from the v2 items.
    var customQuestions: [String] {
        get { items.filter { $0.custom }.sorted { $0.sortIndex < $1.sortIndex }.map(\.canonical) }
        set {
            // Append any new customs as `.bool`/`.other` items; drop customs no longer present.
            let keys = Set(newValue.map { Self.norm($0) })
            items.removeAll { $0.custom && !keys.contains(Self.norm($0.canonical)) }
            let existing = Set(items.map { Self.norm($0.canonical) })
            var next = nextSortIndex()
            for q in newValue {
                let key = Self.norm(q)
                let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !existing.contains(key) else { continue }
                items.append(JournalCatalogItem(canonical: t, displayName: nil, kind: .bool,
                                                group: .other, sortIndex: next,
                                                hidden: false, custom: true))
                next += 1
            }
        }
    }

    /// The user's hidden question canonicals (v1 API shape). Derived from the v2 items.
    var hiddenQuestions: [String] {
        items.filter { $0.hidden }.map(\.canonical)
    }

    private func nextSortIndex() -> Int { (items.map(\.sortIndex).max() ?? -1) + 1 }

    /// Dedup/identity key for a question. Normalises ALL whitespace, leading/trailing AND internal
    /// runs collapse to a single space (not just ASCII space/tab), then lowercases. A WHOOP export
    /// commonly leaves a trailing newline or non-breaking space on a journal cell, which a bare
    /// `.whitespaces` trim leaves in place: that's what let "Did you take magnesium?\n" (imported)
    /// sit beside the starter "Did you take magnesium?" as two rows (#224). Collapsing here folds
    /// them onto one key. The DISPLAYED string is still the original verbatim text, only the match
    /// key is normalised, so the stored behaviour key (which the effects engine joins on) is intact.
    /// Kept value-for-value in step with Android `normJournalKey` (JournalLog.kt).
    nonisolated static func norm(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Case- and punctuation-insensitive match key. "Shared your bed?" and "shared your bed"
    /// collapse to the same token; "Did you share your bed?" does not, so that pair needs an alias.
    nonisolated static func titleKey(_ s: String) -> String {
        let folded = norm(s).unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(folded)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Map an imported title or id onto the catalogue canonical, if one exists.
    /// Stored journal rows are never rewritten; this is display and read-side identity only.
    nonisolated static func canonicalId(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let key = titleKey(trimmed)
        if let library = libraryTitleKeys[key] { return library }
        if let mapped = aliasByTitleKey[key] { return mapped }
        return trimmed
    }

    /// Every question string that should be treated as `canonical` when reading answers:
    /// the catalogue id plus every known imported title/id that aliases onto it.
    nonisolated static func answerIds(for canonical: String) -> [String] {
        let id = canonicalId(for: canonical)
        var seen = Set<String>()
        var out: [String] = []
        for candidate in [id, canonical] + aliasTitles.compactMap({ titleKey($0.canonical) == titleKey(id) ? $0.imported : nil }) {
            let t = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(norm(t)).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// Short form used by the journal UI. Falls back to the verbatim question.
    nonisolated static func shortTitle(for raw: String) -> String {
        let id = canonicalId(for: raw)
        if let title = shortTitles[id] { return title }
        if let title = shortTitles[raw] { return title }
        if raw.hasSuffix("?") { return String(raw.dropLast()) }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Group for a question with no saved catalog item. Library and starters win;
    /// leftover imports get a topic bucket so caffeine never lands in Other.
    nonisolated static func defaultGroup(for raw: String) -> JournalGroup {
        let id = canonicalId(for: raw)
        if let group = libraryEntry(for: id)?.group { return group }
        if let group = starterGroups[id] { return group }
        let key = titleKey(id)
        if key.contains("caffeine") || key.contains("alcohol") || key.contains("food")
            || key.contains("eat") || key.contains("meal") {
            return .nutrition
        }
        if key.contains("bed") || key.contains("sleep") || key.contains("screen") || key.contains("read") {
            return .sleep
        }
        if key.contains("sauna") || key.contains("ice") || key.contains("cold plunge")
            || key.contains("massage") {
            return .recovery
        }
        if key.contains("stress") || key.contains("anxi") || key.contains("mood") {
            return .mental
        }
        if key.contains("sick") || key.contains("ill") || key.contains("medic") {
            return .health
        }
        if key.contains("train") || key.contains("workout") || key.contains("lift") {
            return .training
        }
        if key.contains("period") || key.contains("pregnan") || key.contains("ovulat") {
            return .womensHealth
        }
        if key.contains("flight") || key.contains("altitude") || key.contains("time zone") {
            return .environment
        }
        if key.contains("sexual") || key.contains("masturbat") {
            return .lifestyle
        }
        return .other
    }

    private nonisolated static let aliasByTitleKey: [String: String] = {
        Dictionary(uniqueKeysWithValues: aliasTitles.map { (titleKey($0.imported), $0.canonical) })
    }()

    /// The day's form: chosen questions only. Defaults to starters plus imported/recent titles
    /// folded onto library ids, plus any library item the user has added and any custom question.
    /// The full library is `libraryItems(imported:)`. Hidden items are dropped unless `includeHidden`.
    ///
    /// Resolved `canonical` is the catalogue id. Stored journal rows keep their original question
    /// strings; `display` is the rename, else a short title.
    func resolvedItems(imported: [String], includeHidden: Bool = false) -> [JournalCatalogItem] {
        var byCanon: [String: JournalCatalogItem] = [:]
        for it in items {
            let id = Self.canonicalId(for: it.canonical)
            if byCanon[Self.norm(id)] == nil { byCanon[Self.norm(id)] = it }
        }

        var out: [JournalCatalogItem] = []
        var seen = Set<String>()
        var fallbackIndex = (items.map(\.sortIndex).max() ?? -1) + 1
        for q in imported + Self.starterQuestions {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let canon = Self.canonicalId(for: t)
            let seenKey = Self.norm(canon)
            guard seen.insert(seenKey).inserted else { continue }
            if var saved = byCanon[seenKey] {
                saved.canonical = canon
                out.append(saved)
            } else {
                out.append(Self.makeDefaultItem(canonical: canon, sortIndex: &fallbackIndex))
            }
        }
        for it in items.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            let canon = Self.canonicalId(for: it.canonical)
            let seenKey = Self.norm(canon)
            guard seen.insert(seenKey).inserted else { continue }
            var saved = it
            saved.canonical = canon
            out.append(saved)
        }
        if !includeHidden { out.removeAll { $0.hidden } }
        return out
    }

    /// Every library behaviour as a catalog item, with `hidden` reflecting daily-form membership.
    func libraryItems(imported: [String] = []) -> [JournalCatalogItem] {
        Self.libraryEntries.enumerated().map { index, entry in
            if var saved = item(for: entry.canonical) {
                saved.canonical = entry.canonical
                return saved
            }
            return JournalCatalogItem(
                canonical: entry.canonical, displayName: nil, kind: entry.kind, group: entry.group,
                sortIndex: index, hidden: !isOnDailyForm(entry.canonical, imported: imported),
                custom: false)
        }
    }

    /// Whether `canonical` currently sits on the day's form.
    func isOnDailyForm(_ canonical: String, imported: [String] = []) -> Bool {
        let id = Self.canonicalId(for: canonical)
        if let saved = item(for: id) { return !saved.hidden }
        if Self.starterQuestions.contains(id) { return true }
        let importedIds = Set(imported.map { Self.norm(Self.canonicalId(for: $0)) })
        return importedIds.contains(Self.norm(id))
    }

    /// Add or remove a library (or starter) question from the day's form. Customs are deleted
    /// when removed, matching `remove`.
    func setOnDailyForm(_ canonical: String, enabled: Bool) {
        if enabled {
            restore(canonical)
        } else {
            remove(canonical)
        }
    }

    nonisolated static func makeDefaultItem(canonical: String, sortIndex: inout Int) -> JournalCatalogItem {
        let lib = libraryEntry(for: canonical)
        let starterIdx = starterQuestions.firstIndex(of: canonical)
        let libIdx = libraryEntries.firstIndex { norm($0.canonical) == norm(canonical) }
        let index = starterIdx ?? libIdx ?? sortIndex
        if starterIdx == nil && libIdx == nil { sortIndex += 1 }
        return JournalCatalogItem(
            canonical: canonical, displayName: nil,
            kind: lib?.kind ?? .bool,
            group: lib?.group ?? starterGroups[canonical] ?? defaultGroup(for: canonical),
            sortIndex: index, hidden: false, custom: false)
    }

    // MARK: - Item lookup / edits (v2)

    /// The saved item for a canonical key, if the user has customised it.
    func item(for canonical: String) -> JournalCatalogItem? {
        let key = Self.norm(Self.canonicalId(for: canonical))
        return items.first { Self.norm(Self.canonicalId(for: $0.canonical)) == key }
    }

    /// Upsert the saved item for `canonical`, applying `mutate` to a fresh-or-existing item. Used by
    /// rename / retype / regroup / reorder so a starter question the user touches gets materialised
    /// into `items` with its defaults, then edited. NEVER changes `canonical`.
    private func edit(_ canonical: String, mutate: (inout JournalCatalogItem) -> Void) {
        let key = Self.norm(Self.canonicalId(for: canonical))
        if let idx = items.firstIndex(where: { Self.norm(Self.canonicalId(for: $0.canonical)) == key }) {
            mutate(&items[idx])
        } else {
            let t = Self.canonicalId(for: canonical)
            let lib = Self.libraryEntry(for: t)
            var fresh = JournalCatalogItem(
                canonical: t, displayName: nil,
                kind: lib?.kind ?? .bool,
                group: lib?.group ?? Self.starterGroups[t] ?? Self.defaultGroup(for: t),
                sortIndex: nextSortIndex(), hidden: false, custom: false)
            mutate(&fresh)
            items.append(fresh)
        }
    }

    /// Rename an item: sets a display-only label. The stored `canonical` (the DB/engine key) is
    /// untouched, so all history, logged AND imported, stays joined under the original question.
    /// A blank / whitespace-only name clears the rename (falls back to the canonical).
    func rename(_ canonical: String, to displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(canonical) { $0.displayName = trimmed.isEmpty ? nil : trimmed }
    }

    /// Move an item to a different group (display + organisation only, no scoring change).
    func setGroup(_ canonical: String, to group: JournalGroup) {
        edit(canonical) { $0.group = group }
    }

    /// Change an item's type. `.numeric` carries an optional unit label (e.g. "mg", "units").
    func setKind(_ canonical: String, to kind: JournalKind) {
        edit(canonical) { $0.kind = kind }
    }

    // MARK: - Custom add / remove / restore (v1 API preserved)

    /// The display label for a canonical key: the user's rename, or the verbatim canonical.
    func displayName(for canonical: String) -> String {
        item(for: canonical)?.displayName ?? canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `q` is a user-added custom question (not a starter/imported one).
    func isCustom(_ q: String) -> Bool {
        let key = Self.norm(Self.canonicalId(for: q))
        return items.contains { Self.norm(Self.canonicalId(for: $0.canonical)) == key && $0.custom }
    }

    /// Add a custom question of the given type and group (defaults: yes/no, Other).
    func addCustom(_ q: String, kind: JournalKind = .bool, group: JournalGroup = .other) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let key = Self.norm(t)
        guard !items.contains(where: { Self.norm($0.canonical) == key }) else { return }
        items.append(JournalCatalogItem(canonical: t, displayName: nil, kind: kind,
                                        group: group, sortIndex: nextSortIndex(),
                                        hidden: false, custom: true))
    }

    /// Remove `q` from the journal: a custom question is deleted outright; a starter/imported one is
    /// hidden (restorable). Either way it leaves the merged catalog.
    func remove(_ q: String) {
        let key = Self.norm(Self.canonicalId(for: q))
        if isCustom(q) {
            items.removeAll { Self.norm(Self.canonicalId(for: $0.canonical)) == key }
        } else {
            edit(Self.canonicalId(for: q)) { $0.hidden = true }
        }
    }

    /// Un-hide a previously hidden starter/imported/library question. Materialises a library
    /// entry if the user has never saved it, so adding from the browser lands on the day's form.
    func restore(_ q: String) {
        edit(Self.canonicalId(for: q)) { $0.hidden = false }
    }
}

/// A journal item's type: a plain yes/no toggle, or a numeric value with an optional unit label.
enum JournalKind: Equatable, Codable {
    case bool
    case numeric(unitLabel: String?)

    var isNumeric: Bool { if case .numeric = self { return true } else { return false } }
    var unitLabel: String? { if case let .numeric(u) = self { return u } else { return nil } }
}

/// A user-visible grouping for related journal items (display + organisation only, never a scoring
/// change). `rawValue` is the stable persisted key; `title` is the localised display label.
/// Legacy `supplements` / `behaviour` remain so older `journal.catalog.v2` blobs still decode.
enum JournalGroup: String, CaseIterable, Codable {
    case supplements
    case nutrition
    case sleep
    case lifestyle
    case recovery
    case health
    case mental
    case training
    case environment
    case womensHealth
    case behaviour
    case other

    /// Library categories first, then leftover persisted groups, then Other.
    static let displayOrder: [JournalGroup] = [
        .nutrition, .sleep, .recovery, .lifestyle, .health,
        .mental, .training, .environment, .womensHealth,
        .supplements, .behaviour, .other
    ]

    var title: String {
        switch self {
        case .supplements:   return String(localized: "Supplements")
        case .nutrition:     return String(localized: "Nutrition")
        case .sleep:         return String(localized: "Sleep")
        case .lifestyle:     return String(localized: "Lifestyle")
        case .recovery:      return String(localized: "Recovery")
        case .health:        return String(localized: "Health & medication")
        case .mental:        return String(localized: "Mental & emotional")
        case .training:      return String(localized: "Training")
        case .environment:   return String(localized: "Environment")
        case .womensHealth:  return String(localized: "Women's health")
        case .behaviour:     return String(localized: "Behaviour")
        case .other:         return String(localized: "Other")
        }
    }
}

/// One journal catalog item. `canonical` is the verbatim DB/engine key (the exact question string
/// the effects engine and the `journal` table join on), it is NEVER localised or rewritten, so a
/// rename or a re-import always folds onto one behaviour. `displayName` (a rename) and `kind` /
/// `group` / `sortIndex` are display + organisation only. Mirrors Android `JournalCatalogItem`.
struct JournalCatalogItem: Equatable, Codable, Identifiable {
    /// The stable key. Rename NEVER touches this, so history (logged + imported) is preserved.
    var canonical: String
    /// The renamed display label, or nil to render the canonical verbatim.
    var displayName: String?
    var kind: JournalKind
    var group: JournalGroup
    var sortIndex: Int
    var hidden: Bool
    /// True for a user-added question (deletable); false for a starter/imported one (hideable only).
    var custom: Bool

    var id: String { canonical }

    /// What the UI renders: the rename if present, else a short catalogue title, else the key.
    var display: String {
        displayName ?? JournalCatalogStore.shortTitle(for: canonical)
    }

    init(canonical: String, displayName: String?, kind: JournalKind, group: JournalGroup,
         sortIndex: Int, hidden: Bool, custom: Bool) {
        self.canonical = canonical
        self.displayName = displayName
        self.kind = kind
        self.group = group
        self.sortIndex = sortIndex
        self.hidden = hidden
        self.custom = custom
    }
}
