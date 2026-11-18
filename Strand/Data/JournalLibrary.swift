import Foundation

/// One behaviour in Band's journal library. `canonical` is the stable id and the stored
/// question string (never localised); `shortTitle` is display-only.
struct JournalLibraryEntry: Equatable {
    var canonical: String
    var shortTitle: String
    var group: JournalGroup
    var kind: JournalKind
}

extension JournalCatalogStore {

    /// Band's own behaviour library. Starter questions keep their historical canonical strings
    /// so logged and imported rows still join. New entries use Band wording.
    nonisolated static let libraryEntries: [JournalLibraryEntry] = [
        // Nutrition
        .init("Did you drink any alcohol?", "Alcohol", .nutrition, .numeric(unitLabel: "drinks")),
        .init("Did you have caffeine?", "Caffeine", .nutrition, .numeric(unitLabel: "servings")),
        .init("Did you eat close to bedtime?", "Late meal", .nutrition),
        .init("Did you eat a high-protein meal?", "High protein", .nutrition),
        .init("Did you eat a high-carb meal?", "High carb", .nutrition),
        .init("Did you eat a high-fat meal?", "High fat", .nutrition),
        .init("Did you skip a meal?", "Skipped meal", .nutrition),
        .init("Did you fast?", "Fasting", .nutrition),
        .init("Did you drink enough water?", "Hydration", .nutrition),
        .init("Did you eat a lot of sugar?", "Sugar", .nutrition),
        .init("Did you eat spicy food?", "Spicy food", .nutrition),
        .init("Did you eat dairy?", "Dairy", .nutrition),
        .init("Did you eat gluten?", "Gluten", .nutrition),
        .init("Did you eat highly processed food?", "Processed food", .nutrition),

        // Sleep
        .init("Did you view a screen in bed?", "Screen in bed", .sleep),
        .init("Did you share your bed?", "Shared bed", .sleep),
        .init("Did you read before bed?", "Read in bed", .sleep),
        .init("Did you nap?", "Nap", .sleep),
        .init("Did you keep a steady bedtime?", "Steady bedtime", .sleep),
        .init("Did you keep a steady wake time?", "Steady wake", .sleep),
        .init("Did you sleep somewhere new?", "New place", .sleep),
        .init("Did you sleep with a pet?", "Pet in bed", .sleep),
        .init("Did you use a sleep mask?", "Sleep mask", .sleep),
        .init("Did you use earplugs?", "Earplugs", .sleep),
        .init("Did you use a sound machine?", "Sound machine", .sleep),
        .init("Did you sleep in a cool room?", "Cool room", .sleep),

        // Recovery
        .init("Did you use a sauna?", "Sauna", .recovery),
        .init("Did you take a cold plunge?", "Cold plunge", .recovery),
        .init("Did you do contrast heat and cold?", "Contrast", .recovery),
        .init("Did you get a massage?", "Massage", .recovery),
        .init("Did you stretch?", "Stretch", .recovery),
        .init("Did you foam roll?", "Foam roll", .recovery),
        .init("Did you do breathwork?", "Breathwork", .recovery),
        .init("Did you do yoga?", "Yoga", .recovery),
        .init("Did you take a rest day?", "Rest day", .recovery),
        .init("Did you use compression?", "Compression", .recovery),
        .init("Did you use red light?", "Red light", .recovery),
        .init("Did you do mobility work?", "Mobility", .recovery),

        // Lifestyle
        .init("Did you have sex?", "Sex", .lifestyle),
        .init("Did you masturbate?", "Masturbation", .lifestyle),
        .init("Did you go out socially?", "Social", .lifestyle),
        .init("Did you travel?", "Travel", .lifestyle),
        .init("Did you work late?", "Worked late", .lifestyle),
        .init("Did you spend a long time on screens?", "Screen time", .lifestyle),
        .init("Did you spend time outdoors?", "Outdoors", .lifestyle),
        .init("Did you get morning sunlight?", "Morning sun", .lifestyle),
        .init("Did you use nicotine?", "Nicotine", .lifestyle),
        .init("Did you use cannabis?", "Cannabis", .lifestyle),
        .init("Did you play video games?", "Video games", .lifestyle),
        .init("Did you spend a long time on social media?", "Social media", .lifestyle),

        // Health & medication
        .init("Did you feel sick or ill?", "Felt sick", .health),
        .init("Did you take magnesium?", "Magnesium", .health),
        .init("Did you feel pain?", "Pain", .health),
        .init("Did you have a headache?", "Headache", .health),
        .init("Did you have allergy symptoms?", "Allergies", .health),
        .init("Did you take a painkiller?", "Painkiller", .health),
        .init("Did you take an antihistamine?", "Antihistamine", .health),
        .init("Did you take an antibiotic?", "Antibiotic", .health),
        .init("Did you take a prescription?", "Prescription", .health),
        .init("Did you feel injured?", "Injury", .health),
        .init("Did you take omega-3?", "Omega-3", .health),
        .init("Did you take a probiotic?", "Probiotic", .health),

        // Mental & emotional
        .init("Did you feel stressed?", "Stress", .mental),
        .init("Did you feel anxious?", "Anxiety", .mental),
        .init("Did you feel low?", "Low mood", .mental),
        .init("Did you practice gratitude?", "Gratitude", .mental),
        .init("Did you feel socially connected?", "Connected", .mental),
        .init("Did you have a conflict?", "Conflict", .mental),
        .init("Did you go to therapy?", "Therapy", .mental),
        .init("Did you write in a journal?", "Wrote notes", .mental),
        .init("Did you have a high-pressure day?", "High pressure", .mental),
        .init("Did you meditate?", "Meditation", .mental),

        // Training
        .init("Did you train early?", "Early training", .training),
        .init("Did you train late?", "Late training", .training),
        .init("Did you lift weights?", "Strength", .training),
        .init("Did you do cardio?", "Cardio", .training),
        .init("Did you do high-intensity intervals?", "HIIT", .training),
        .init("Did you do a long endurance session?", "Endurance", .training),
        .init("Did you play a sport?", "Sport", .training),
        .init("Did you feel overreached?", "Overreached", .training),
        .init("Did you take a deload?", "Deload", .training),
        .init("Did you do zone 2 work?", "Zone 2", .training),
        .init("Did you sprint?", "Sprints", .training),
        .init("Did you walk a lot?", "Lots of walking", .training),

        // Environment
        .init("Did you fly?", "Flight", .environment),
        .init("Did you go to high altitude?", "Altitude", .environment),
        .init("Did you spend time in heat?", "Heat", .environment),
        .init("Did you spend time in cold?", "Cold", .environment),
        .init("Did you deal with poor air?", "Poor air", .environment),
        .init("Did you sleep in a noisy place?", "Noise", .environment),
        .init("Did you change time zones?", "Time zone", .environment),
        .init("Did you stay in a hotel?", "Hotel", .environment),

        // Women's health
        .init("Did you have your period?", "Period", .womensHealth),
        .init("Are you in your follicular phase?", "Follicular", .womensHealth),
        .init("Are you around ovulation?", "Ovulation", .womensHealth),
        .init("Are you in your luteal phase?", "Luteal", .womensHealth),
        .init("Did you have PMS symptoms?", "PMS", .womensHealth),
        .init("Are you pregnant?", "Pregnant", .womensHealth),
        .init("Are you breastfeeding?", "Breastfeeding", .womensHealth),
        .init("Did you have menopause symptoms?", "Menopause", .womensHealth),
    ]

    /// Library entry for a raw title or id, after alias folding.
    nonisolated static func libraryEntry(for raw: String) -> JournalLibraryEntry? {
        let id = canonicalId(for: raw)
        if let hit = libraryByCanonical[norm(id)] { return hit }
        return libraryTitleKeys[titleKey(id)].flatMap { libraryByCanonical[norm($0)] }
    }

    /// Distinct titles that fold onto a library id vs those that do not.
    nonisolated static func libraryMapping(of titles: [String]) -> (mapped: Int, unmapped: Int) {
        var seen = Set<String>()
        var mapped = 0
        var unmapped = 0
        for title in titles {
            let key = titleKey(title)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if libraryEntry(for: title) != nil {
                mapped += 1
            } else {
                unmapped += 1
            }
        }
        return (mapped, unmapped)
    }

    /// Search haystack for the add-behaviours browser (title, short title, category).
    nonisolated static func libraryMatches(_ item: JournalCatalogItem, query: String) -> Bool {
        let needle = titleKey(query)
        guard !needle.isEmpty else { return true }
        let hay = titleKey(
            item.display + " " + item.canonical + " " + shortTitle(for: item.canonical) + " " + item.group.title
        )
        return hay.contains(needle)
    }

    nonisolated static func libraryCount(in group: JournalGroup) -> Int {
        libraryEntries.filter { $0.group == group }.count
    }

    nonisolated static let libraryByCanonical: [String: JournalLibraryEntry] = {
        Dictionary(uniqueKeysWithValues: libraryEntries.map { (norm($0.canonical), $0) })
    }()

    nonisolated static let libraryTitleKeys: [String: String] = {
        Dictionary(uniqueKeysWithValues: libraryEntries.map { (titleKey($0.canonical), $0.canonical) })
    }()
}

private extension JournalLibraryEntry {
    init(_ canonical: String, _ shortTitle: String, _ group: JournalGroup, _ kind: JournalKind = .bool) {
        self.canonical = canonical
        self.shortTitle = shortTitle
        self.group = group
        self.kind = kind
    }
}
