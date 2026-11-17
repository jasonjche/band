import XCTest
import WhoopStore
@testable import Strand

/// Pins native journal-entry merging and the production typed catalog. Canonical question strings
/// remain exact-match keys to the effects engines on both platforms.
final class JournalLogicTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let name = "JournalLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    private func makeCatalog(custom: [String] = [], hidden: [String] = []) -> JournalCatalogStore {
        let defaults = isolatedDefaults()
        defaults.set(custom, forKey: JournalCatalogBackupKeys.legacyCustom)
        defaults.set(hidden, forKey: JournalCatalogBackupKeys.legacyHidden)
        return JournalCatalogStore(defaults: defaults)
    }

    private func e(_ day: String, _ q: String, _ yes: Bool) -> JournalEntry {
        JournalEntry(day: day, question: q, answeredYes: yes, notes: nil)
    }

    func testNativeWinsOnCollision() {
        let imported = [e("2026-06-09", "Did you drink any alcohol?", false)]
        let native = [e("2026-06-09", "Did you drink any alcohol?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].answeredYes)
    }

    func testDisjointKeysUnionAndSort() {
        let imported = [e("2026-06-09", "B?", true)]
        let native = [e("2026-06-10", "A?", false), e("2026-06-09", "A?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 3)
        // Sorted day ASC then question ASC, matches the DAO/store read order.
        XCTAssertEqual(merged.map(\.question), ["A?", "B?", "A?"])
        XCTAssertEqual(merged.map(\.day), ["2026-06-09", "2026-06-09", "2026-06-10"])
    }

    @MainActor
    func testCatalogAdoptsImportedCasing() {
        let cat = makeCatalog().resolvedItems(imported: ["DID YOU DRINK ANY ALCOHOL?"]).map(\.canonical)
        XCTAssertEqual(cat.first, "Did you drink any alcohol?")
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testCustomsAppendAndBlanksDrop() {
        let store = makeCatalog(custom: ["  ", "Did you nap?", "did you NAP?"])
        let cat = store.resolvedItems(imported: []).map(\.canonical)
        XCTAssertEqual(Array(cat.prefix(JournalCatalogStore.starterQuestions.count)),
                       JournalCatalogStore.starterQuestions)
        XCTAssertEqual(cat.last, "Did you nap?")
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count + 1)
    }

    @MainActor
    func testImportedMagnesiumWithTrailingWhitespaceDoesNotDoublePrompt() {
        // #224: a WHOOP export leaves a trailing newline / non-breaking space on the cell, so the
        // imported "Did you take magnesium?\n" must fold onto the starter, NOT add a second row.
        let cat = makeCatalog().resolvedItems(
            imported: ["Did you take magnesium?\n", "Did you take  magnesium?", "Did you take magnesium?\u{00a0}"])
            .map(\.canonical)
        let magCount = cat.filter {
            $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .caseInsensitiveCompare("Did you take magnesium?") == .orderedSame
        }.count
        XCTAssertEqual(magCount, 1)
        // No net growth, both imported variants dedupe against the starter.
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testHiddenQuestionsFilteredOutCaseInsensitively() {
        // Hide one starter (different casing) + one custom; both must drop from the merged catalog.
        let store = makeCatalog(custom: ["Did you nap?"],
                                hidden: ["did you drink any alcohol?", "DID YOU NAP?"])
        let cat = store.resolvedItems(imported: []).map(\.canonical)
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you drink any alcohol?") == .orderedSame })
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you nap?") == .orderedSame })
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count - 1)
    }

    @MainActor
    func testSavedMetadataSurvivesNormalizedImportAndReload() throws {
        let defaults = isolatedDefaults()
        let store = JournalCatalogStore(defaults: defaults)
        let canonical = "Did you take magnesium?"
        store.rename(canonical, to: "Magnesium dose")
        store.setKind(canonical, to: .numeric(unitLabel: "mg"))
        store.setGroup(canonical, to: .supplements)
        store.items[0].sortIndex = 7
        let saved = try XCTUnwrap(store.item(for: canonical))
        let imported = [" DID YOU TAKE  MAGNESIUM?\n", canonical]

        let reloaded = JournalCatalogStore(defaults: defaults)
        for catalog in [store, reloaded] {
            let matches = catalog.resolvedItems(imported: imported).filter {
                JournalCatalogStore.norm($0.canonical) == JournalCatalogStore.norm(canonical)
            }
            XCTAssertEqual(matches, [saved], "saved key, display, type, group and order survive imported aliases")
        }
    }

    @MainActor
    func testHiddenImportedAliasCanBeRestoredWithoutDuplicatingItsSavedItem() throws {
        let store = makeCatalog(hidden: ["did you drink any alcohol?"])
        let imported = [" DID YOU DRINK ANY ALCOHOL?\n", "Did you drink any alcohol?"]
        let key = JournalCatalogStore.norm(imported[0])
        XCTAssertFalse(store.resolvedItems(imported: imported).contains {
            JournalCatalogStore.norm($0.canonical) == key
        })
        let hidden = store.resolvedItems(imported: imported, includeHidden: true).filter {
            JournalCatalogStore.norm($0.canonical) == key
        }
        XCTAssertEqual(hidden.count, 1)
        XCTAssertTrue(try XCTUnwrap(hidden.first).hidden)
        store.restore(imported[0])
        let restored = store.resolvedItems(imported: imported).filter {
            JournalCatalogStore.norm($0.canonical) == key
        }
        XCTAssertEqual(restored.count, 1)
        XCTAssertFalse(try XCTUnwrap(restored.first).hidden)
        XCTAssertEqual(restored.first?.canonical, hidden.first?.canonical)
    }

    // MARK: - v2 catalog (#322): legacy migration, rename key-stability, grouping, numeric type

    func testLegacyMigrationFoldsTwoArraysIntoItems() {
        // The one-time fold: customs become .bool/.other custom items; hidden starters become hidden
        // marker items; a hidden custom keeps its hidden flag on the single custom item (no dupe).
        let items = JournalCatalogStore.migrateLegacy(
            custom: ["Did you nap?", "Vitamin D"],
            hidden: ["Did you drink any alcohol?", "Vitamin D"])
        // Two customs materialised, both marked custom.
        let customs = items.filter { $0.custom }
        XCTAssertEqual(Set(customs.map(\.canonical)), ["Did you nap?", "Vitamin D"])
        // The hidden custom kept its flag on the SAME item (deduped by norm, not a second row).
        let vitaminD = items.filter { JournalCatalogStore.norm($0.canonical) == JournalCatalogStore.norm("Vitamin D") }
        XCTAssertEqual(vitaminD.count, 1, "a hidden custom must not duplicate")
        XCTAssertTrue(vitaminD[0].hidden)
        // The hidden starter became a hidden non-custom marker in its default group.
        let alcohol = items.first { JournalCatalogStore.norm($0.canonical) == JournalCatalogStore.norm("Did you drink any alcohol?") }
        XCTAssertNotNil(alcohol)
        XCTAssertTrue(alcohol!.hidden)
        XCTAssertFalse(alcohol!.custom)
        XCTAssertEqual(alcohol!.group, .nutrition)
    }

    @MainActor
    func testRenameKeepsCanonicalStableSoHistorySurvives() {
        // THE key-stability guarantee (#322): renaming an item changes only the display label; the
        // stored canonical (the DB/engine join key) is untouched, so all logged + imported history, 
        // which is keyed on the canonical question string, still lines up after a rename.
        let store = makeCatalog()
        store.items = []   // start from a clean catalog for a deterministic assertion
        let canonical = "Did you have caffeine?"

        // Before: display resolves to the canonical verbatim.
        XCTAssertEqual(store.displayName(for: canonical), canonical)

        store.rename(canonical, to: "Caffeine")

        // After: the DISPLAY changed, the KEY did not.
        XCTAssertEqual(store.displayName(for: canonical), "Caffeine")
        let item = store.item(for: canonical)
        XCTAssertNotNil(item)
        XCTAssertEqual(item!.canonical, canonical,
                       "rename must NEVER change the canonical, history is keyed on it")
        XCTAssertEqual(item!.displayName, "Caffeine")

        // A journal write / effect lookup for this behaviour still keys on the canonical, so a row
        // logged BEFORE the rename (under the canonical) is found AFTER the rename by the same key.
        let resolved = store.resolvedItems(imported: [], includeHidden: false)
        let caffeine = resolved.first { $0.canonical == canonical }
        XCTAssertEqual(caffeine?.display, "Caffeine")
        XCTAssertEqual(caffeine?.canonical, canonical,
                       "the engine key is preserved end to end, logged/imported days still join")

        // Clearing the rename (blank) falls back to the canonical.
        store.rename(canonical, to: "   ")
        XCTAssertEqual(store.displayName(for: canonical), canonical)
        XCTAssertEqual(store.item(for: canonical)?.canonical, canonical)
    }

    @MainActor
    func testSetGroupAndKindPreserveCanonical() {
        let store = makeCatalog()
        store.items = []
        let canonical = "Did you take magnesium?"
        store.setGroup(canonical, to: .supplements)
        store.setKind(canonical, to: .numeric(unitLabel: "mg"))
        let item = store.item(for: canonical)
        XCTAssertEqual(item?.canonical, canonical, "regroup/retype never touch the key")
        XCTAssertEqual(item?.group, .supplements)
        XCTAssertTrue(item?.kind.isNumeric ?? false)
        XCTAssertEqual(item?.kind.unitLabel, "mg")
    }

    @MainActor
    func testResolvedItemsGroupStartersByDefaultAndDropHidden() {
        let store = makeCatalog()
        store.items = []
        let resolved = store.resolvedItems(imported: [], includeHidden: false)
        // Every starter is present with a default group and .bool kind.
        XCTAssertEqual(resolved.count, JournalCatalogStore.starterQuestions.count)
        let alcohol = resolved.first { $0.canonical == "Did you drink any alcohol?" }
        XCTAssertEqual(alcohol?.group, .nutrition)
        XCTAssertTrue(alcohol?.kind.isNumeric ?? false)
        XCTAssertEqual(alcohol?.kind.unitLabel, "drinks")
        // Hidden items are dropped unless includeHidden.
        store.remove("Did you drink any alcohol?")
        let afterHide = store.resolvedItems(imported: [], includeHidden: false)
        XCTAssertFalse(afterHide.contains { $0.canonical == "Did you drink any alcohol?" })
        let withHidden = store.resolvedItems(imported: [], includeHidden: true)
        XCTAssertTrue(withHidden.contains { $0.canonical == "Did you drink any alcohol?" && $0.hidden })
    }

    @MainActor
    func testAddCustomNumericItem() {
        let store = makeCatalog()
        store.items = []
        store.addCustom("Water (L)", kind: .numeric(unitLabel: "L"), group: .nutrition)
        XCTAssertTrue(store.isCustom("Water (L)"))
        let item = store.item(for: "Water (L)")
        XCTAssertEqual(item?.group, .nutrition)
        XCTAssertEqual(item?.kind.unitLabel, "L")
    }

    func testNumericJournalKeyIsNamespaced() {
        // The InsightsView folds a numeric journal series under a namespaced key that can never
        // collide with a fixed metric outcome ("recovery" / "hrv" / …).
        let key = InsightsView.numericJournalKey("Caffeine (mg)")
        XCTAssertTrue(key.hasPrefix("journal.numeric:"))
        XCTAssertNotEqual(key, "recovery")
        XCTAssertNotEqual(key, "hrv")
    }

    // MARK: - WHOOP import aliases fold onto catalogue ids

    func testTitleKeyIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            JournalCatalogStore.titleKey("Consumed caffeine?"),
            JournalCatalogStore.titleKey("consumed caffeine")
        )
        XCTAssertEqual(
            JournalCatalogStore.titleKey("Shared your bed?"),
            JournalCatalogStore.titleKey("shared your bed")
        )
    }

    func testWhoopImportTitlesMapOntoCatalogueIds() {
        let pairs: [(String, String)] = [
            ("Consumed caffeine?", "Did you have caffeine?"),
            ("Have any alcoholic drinks?", "Did you drink any alcohol?"),
            ("Ate food close to bedtime?", "Did you eat close to bedtime?"),
            ("Shared your bed?", "Did you share your bed?"),
            ("Read (non-screened device) while in bed?", "Did you read before bed?"),
            ("e-close", "Did you eat close to bedtime?"),
            ("DID YOU DRINK ANY ALCOHOL?", "Did you drink any alcohol?"),
            ("Engaged in sexual activity?", "Did you have sex?"),
            ("Masturbated?", "Did you masturbate?"),
        ]
        for (imported, canonical) in pairs {
            XCTAssertEqual(JournalCatalogStore.canonicalId(for: imported), canonical, imported)
        }
    }

    func testAnswerIdsIncludeImportedAlias() {
        let ids = JournalCatalogStore.answerIds(for: "Did you have caffeine?")
        XCTAssertTrue(ids.contains("Did you have caffeine?"))
        XCTAssertTrue(ids.contains("Consumed caffeine?"))
    }

    @MainActor
    func testResolvedItemsFoldWhoopDuplicatesAndKeepCaffeineInNutrition() {
        let imported = [
            "Consumed caffeine?",
            "Have any alcoholic drinks?",
            "Ate food close to bedtime?",
            "Shared your bed?",
            "Engaged in sexual activity?",
            "Masturbated?",
        ]
        let items = makeCatalog().resolvedItems(imported: imported)
        let titles = items.map(\.canonical)
        XCTAssertEqual(titles.filter { JournalCatalogStore.canonicalId(for: $0) == "Did you have caffeine?" }.count, 1)
        XCTAssertEqual(titles.filter { JournalCatalogStore.canonicalId(for: $0) == "Did you drink any alcohol?" }.count, 1)
        XCTAssertEqual(titles.filter { JournalCatalogStore.canonicalId(for: $0) == "Did you eat close to bedtime?" }.count, 1)
        XCTAssertEqual(titles.filter { JournalCatalogStore.canonicalId(for: $0) == "Did you share your bed?" }.count, 1)
        XCTAssertFalse(titles.contains("Consumed caffeine?"))
        XCTAssertTrue(titles.contains("Did you have caffeine?"))
        XCTAssertFalse(titles.contains("Engaged in sexual activity?"))
        XCTAssertFalse(titles.contains("Masturbated?"))
        XCTAssertTrue(titles.contains("Did you have sex?"))
        XCTAssertTrue(titles.contains("Did you masturbate?"))
        let caffeine = items.first { $0.canonical == "Did you have caffeine?" }
        XCTAssertEqual(caffeine?.group, .nutrition)
        XCTAssertEqual(caffeine?.display, "Caffeine")
        XCTAssertEqual(items.first { $0.canonical == "Did you have sex?" }?.group, .lifestyle)
        XCTAssertEqual(items.first { $0.canonical == "Did you masturbate?" }?.group, .lifestyle)
        XCTAssertEqual(items.first { $0.canonical == "Did you view a screen in bed?" }?.group, .sleep)
        XCTAssertEqual(items.first { $0.canonical == "Did you feel stressed?" }?.group, .mental)
        XCTAssertEqual(
            items.count,
            JournalCatalogStore.starterQuestions.count + 2
        )
    }

    func testDefaultGroupPutsCaffeineInNutrition() {
        XCTAssertEqual(JournalCatalogStore.defaultGroup(for: "Consumed caffeine?"), .nutrition)
        XCTAssertEqual(JournalCatalogStore.defaultGroup(for: "Did you have caffeine?"), .nutrition)
    }

    // MARK: - Behaviour library

    func testLibraryHasAboutOneHundredUniqueBehaviours() {
        let entries = JournalCatalogStore.libraryEntries
        XCTAssertEqual(entries.count, 100)
        let ids = entries.map { JournalCatalogStore.norm($0.canonical) }
        XCTAssertEqual(ids.count, Set(ids).count)
        let titleKeys = entries.map { JournalCatalogStore.titleKey($0.canonical) }
        XCTAssertEqual(titleKeys.count, Set(titleKeys).count)
        let shorts = entries.map { JournalCatalogStore.norm($0.shortTitle) }
        XCTAssertEqual(shorts.count, Set(shorts).count)
    }

    func testLibraryFillsEveryNamedCategory() {
        let expected: [JournalGroup] = [
            .nutrition, .sleep, .recovery, .lifestyle, .health,
            .mental, .training, .environment, .womensHealth
        ]
        for group in expected {
            XCTAssertGreaterThan(
                JournalCatalogStore.libraryCount(in: group), 0,
                group.rawValue
            )
        }
    }

    func testEveryStarterIsInTheLibrary() {
        for question in JournalCatalogStore.starterQuestions {
            let entry = JournalCatalogStore.libraryEntry(for: question)
            XCTAssertEqual(entry?.canonical, question)
            XCTAssertEqual(JournalCatalogStore.starterGroups[question], entry?.group)
        }
    }

    func testAliasTitlesPointAtLibraryEntries() {
        for pair in JournalCatalogStore.aliasTitles {
            XCTAssertNotNil(
                JournalCatalogStore.libraryEntry(for: pair.canonical),
                pair.canonical
            )
            XCTAssertEqual(
                JournalCatalogStore.canonicalId(for: pair.imported),
                pair.canonical,
                pair.imported
            )
        }
    }

    func testKnownImportTitlesAllMapOntoTheLibrary() {
        let imported = [
            "Consumed caffeine?",
            "Have any alcoholic drinks?",
            "Ate food close to bedtime?",
            "Shared your bed?",
            "Read (non-screened device) while in bed?",
            "Engaged in sexual activity?",
            "Masturbated?",
        ]
        let stats = JournalCatalogStore.libraryMapping(of: imported)
        XCTAssertEqual(stats.mapped, imported.count)
        XCTAssertEqual(stats.unmapped, 0)
    }

    @MainActor
    func testDailyFormStaysOnStartersUntilALibraryItemIsAdded() {
        let store = makeCatalog()
        let daily = store.resolvedItems(imported: [])
        XCTAssertEqual(daily.count, JournalCatalogStore.starterQuestions.count)
        XCTAssertEqual(store.libraryItems().count, JournalCatalogStore.libraryEntries.count)
        XCTAssertGreaterThan(store.libraryItems().count, daily.count)

        let extra = "Did you take a cold plunge?"
        XCTAssertFalse(daily.contains { $0.canonical == extra })
        store.setOnDailyForm(extra, enabled: true)
        let afterAdd = store.resolvedItems(imported: [])
        XCTAssertEqual(afterAdd.count, JournalCatalogStore.starterQuestions.count + 1)
        XCTAssertTrue(afterAdd.contains { $0.canonical == extra && !$0.hidden })
        XCTAssertTrue(store.isOnDailyForm(extra))

        store.setOnDailyForm(extra, enabled: false)
        let afterRemove = store.resolvedItems(imported: [])
        XCTAssertEqual(afterRemove.count, JournalCatalogStore.starterQuestions.count)
        XCTAssertFalse(store.isOnDailyForm(extra))
    }

    @MainActor
    func testImportedHistorySeedsDailyFormWithoutDumpingTheLibrary() {
        let store = makeCatalog()
        let imported = ["Engaged in sexual activity?", "Consumed caffeine?"]
        let daily = store.resolvedItems(imported: imported)
        XCTAssertTrue(daily.contains { $0.canonical == "Did you have sex?" })
        XCTAssertEqual(daily.filter { $0.canonical == "Did you have caffeine?" }.count, 1)
        XCTAssertEqual(daily.count, JournalCatalogStore.starterQuestions.count + 1)
        XCTAssertFalse(store.isOnDailyForm("Did you train late?", imported: imported))
    }

    func testLibrarySearchMatchesShortTitleAndCategory() {
        let item = JournalCatalogItem(
            canonical: "Did you take a cold plunge?", displayName: nil,
            kind: .bool, group: .recovery, sortIndex: 0, hidden: true, custom: false
        )
        XCTAssertTrue(JournalCatalogStore.libraryMatches(item, query: "cold"))
        XCTAssertTrue(JournalCatalogStore.libraryMatches(item, query: "recovery"))
        XCTAssertTrue(JournalCatalogStore.libraryMatches(item, query: "plunge"))
        XCTAssertFalse(JournalCatalogStore.libraryMatches(item, query: "caffeine"))
        XCTAssertTrue(JournalCatalogStore.libraryMatches(item, query: "  "))
    }

    func testImpactCopyResolvesAnyLibraryId() {
        XCTAssertEqual(JournalCatalogStore.shortTitle(for: "Did you take a cold plunge?"), "Cold plunge")
        XCTAssertEqual(JournalCatalogStore.shortTitle(for: "Did you have sex?"), "Sex")
        XCTAssertEqual(JournalCatalogStore.shortTitle(for: "Engaged in sexual activity?"), "Sex")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Did you train late?"), "Late training")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Have any alcoholic drinks?"), "Alcohol")
    }
}
