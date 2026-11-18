import XCTest
import WhoopStore
@testable import Strand

final class NativeJournalDetailTests: XCTestCase {

    func testEncodeDecodeRoundTripTimeAndNote() {
        let notes = NativeJournalNotes.encode(timeMinutes: 21 * 60 + 30, note: "After dinner")
        XCTAssertNotNil(notes)
        let decoded = NativeJournalNotes.decode(notes)
        XCTAssertEqual(decoded.timeMinutes, 21 * 60 + 30)
        XCTAssertEqual(decoded.note, "After dinner")
    }

    func testEncodeTimeOnlyOmitsEmptyNote() {
        let notes = NativeJournalNotes.encode(timeMinutes: 9 * 60 + 5, note: "  ")
        let decoded = NativeJournalNotes.decode(notes)
        XCTAssertEqual(decoded.timeMinutes, 9 * 60 + 5)
        XCTAssertNil(decoded.note)
        XCTAssertEqual(NativeJournalNotes.hhmm(9 * 60 + 5), "09:05")
    }

    func testLegacyPlainNotesStillDecodeAsNote() {
        let decoded = NativeJournalNotes.decode("Late dinner after the run.")
        XCTAssertNil(decoded.timeMinutes)
        XCTAssertEqual(decoded.note, "Late dinner after the run.")
    }

    func testNilAndEmptyNotesDecodeEmpty() {
        XCTAssertEqual(NativeJournalNotes.decode(nil), NativeJournalNotes.Decoded(timeMinutes: nil, note: nil))
        XCTAssertEqual(NativeJournalNotes.decode(""), NativeJournalNotes.Decoded(timeMinutes: nil, note: nil))
    }

    func testUnrelatedJSONStaysAPlainNote() {
        let raw = "{\"foo\":1}"
        let decoded = NativeJournalNotes.decode(raw)
        XCTAssertNil(decoded.timeMinutes)
        XCTAssertEqual(decoded.note, raw)
    }

    func testOldJournalEntryWithoutNotesStillReadsYesNo() {
        let entry = JournalEntry(
            day: "2026-11-12",
            question: "Did you feel stressed?",
            answeredYes: true,
            notes: nil
        )
        let answers = HomeJournalAnswer.make(entries: [entry], day: "2026-11-12")
        XCTAssertEqual(answers, [HomeJournalAnswer(question: "Stress", value: "Yes")])
    }

    func testOldNumericEntryKeepsQuantityAndIgnoresLegacyNote() {
        let entry = JournalEntry(
            day: "2026-11-12",
            question: "Did you drink any alcohol?",
            answeredYes: true,
            notes: "two pints",
            numericValue: 2
        )
        let answers = HomeJournalAnswer.make(entries: [entry], day: "2026-11-12")
        XCTAssertEqual(answers.first?.value, "2")
        XCTAssertEqual(NativeJournalNotes.decode(entry.notes).note, "two pints")
        XCTAssertNil(NativeJournalNotes.decode(entry.notes).timeMinutes)
    }

    func testAnswerValueAppendsDecodedTime() throws {
        let notes = NativeJournalNotes.encode(timeMinutes: 21 * 60 + 30, note: nil)
        let entry = JournalEntry(
            day: "2026-11-12",
            question: "Did you have caffeine?",
            answeredYes: true,
            notes: notes,
            numericValue: 2
        )
        let answers = HomeJournalAnswer.make(entries: [entry], day: "2026-11-12")
        let value = try XCTUnwrap(answers.first?.value)
        XCTAssertEqual(value, "2 · \(NativeJournalNotes.formatTime(21 * 60 + 30))")
    }

    func testFollowUpMapsWhoopBehaviours() {
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Did you drink any alcohol?", kind: .bool),
            .quantityAndTime(unit: "drinks")
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Did you have caffeine?", kind: .bool),
            .quantityAndTime(unit: "servings")
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Did you view a screen in bed?", kind: .bool),
            .time
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Did you eat close to bedtime?", kind: .bool),
            .time
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Did you feel stressed?", kind: .bool),
            .none
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Did you take magnesium?", kind: .numeric(unitLabel: "mg")),
            .quantity(unit: "mg")
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Consumed caffeine?", kind: .bool),
            .quantityAndTime(unit: "servings")
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Have any alcoholic drinks?", kind: .bool),
            .quantityAndTime(unit: "drinks")
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("Ate food close to bedtime?", kind: .bool),
            .time
        )
        XCTAssertEqual(
            NativeJournalFollowUp.forQuestion("e-close", kind: .bool),
            .time
        )
    }

    func testWinningEntriesPreferCatalogueIdAndKeepImportedReadable() {
        let imported = JournalEntry(
            day: "2026-11-12",
            question: "Consumed caffeine?",
            answeredYes: true,
            notes: nil
        )
        let native = JournalEntry(
            day: "2026-11-12",
            question: "Did you have caffeine?",
            answeredYes: false,
            notes: nil
        )
        let folded = NativeJournalIdentity.winningEntries([imported, native])
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].question, "Did you have caffeine?")
        XCTAssertFalse(folded[0].answeredYes)
        XCTAssertEqual(
            NativeJournalIdentity.lookup(
                ["Consumed caffeine?": true],
                canonical: "Did you have caffeine?"
            ),
            true
        )
    }

    func testDayListMergesDuplicateQuestionsOntoOneRow() {
        let entries = [
            JournalEntry(day: "2026-11-12", question: "Consumed caffeine?", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-11-12", question: "Did you have caffeine?", answeredYes: false, notes: nil),
            JournalEntry(day: "2026-11-12", question: "Shared your bed?", answeredYes: true, notes: nil),
        ]
        let answers = HomeJournalAnswer.make(entries: entries, day: "2026-11-12")
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers.first { $0.question == "Caffeine" }?.value, "No")
        XCTAssertEqual(answers.first { $0.question == "Shared bed" }?.value, "Yes")
    }

    func testSectionsGroupFilterAndSort() {
        let nap = JournalCatalogItem(
            canonical: "Did you nap?", displayName: nil, kind: .bool,
            group: .sleep, sortIndex: 2, hidden: false, custom: false
        )
        let read = JournalCatalogItem(
            canonical: "Did you read before bed?", displayName: nil, kind: .bool,
            group: .sleep, sortIndex: 1, hidden: false, custom: false
        )
        let alcohol = JournalCatalogItem(
            canonical: "Did you drink any alcohol?", displayName: nil, kind: .bool,
            group: .nutrition, sortIndex: 0, hidden: false, custom: false
        )
        let sections = NativeJournalSections.make([nap, read, alcohol])
        XCTAssertEqual(sections.map(\.group), [.nutrition, .sleep])
        XCTAssertEqual(sections[0].items.map(\.canonical), ["Did you drink any alcohol?"])
        XCTAssertEqual(sections[1].items.map(\.canonical), ["Did you read before bed?", "Did you nap?"])

        let filtered = NativeJournalSections.make([nap, read, alcohol], query: "nap")
        XCTAssertEqual(filtered.map(\.group), [.sleep])
        XCTAssertEqual(filtered[0].items.map(\.canonical), ["Did you nap?"])

        XCTAssertTrue(NativeJournalSections.make([nap, read, alcohol], query: "  ").map(\.group) == sections.map(\.group))
    }

    func testDraftCarriesPreviousDayWhenTodayIsEmpty() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let notes = NativeJournalNotes.encode(timeMinutes: 21 * 60 + 30, note: nil)
        let yesterday = JournalEntry(
            day: "2026-11-16",
            question: "Did you drink any alcohol?",
            answeredYes: true,
            notes: notes,
            numericValue: 2
        )
        let seed = NativeJournalDraft.seed(
            entries: [yesterday],
            nativeAnswers: [:],
            nativeNumeric: [:],
            dayKey: "2026-11-17",
            selectedDay: today,
            calendar: calendar
        )
        let key = JournalCatalogStore.canonicalId(for: "Did you drink any alcohol?")
        XCTAssertEqual(seed.yes[key], true)
        XCTAssertEqual(seed.numeric[key] ?? -1, 2, accuracy: 0.01)
        let carriedTime = try XCTUnwrap(seed.times[key])
        XCTAssertEqual(
            NativeJournalNotes.minutes(from: carriedTime, calendar: calendar),
            21 * 60 + 30
        )
        XCTAssertEqual(calendar.component(.year, from: carriedTime), 2026)
        XCTAssertEqual(calendar.component(.month, from: carriedTime), 11)
        XCTAssertEqual(calendar.component(.day, from: carriedTime), 16)
        XCTAssertTrue(seed.persistedYes.isEmpty)
        XCTAssertTrue(NativeJournalDraft.shouldWrite(
            key: key, draftYes: seed.yes, draftNumeric: seed.numeric, draftTimes: seed.times,
            persistedYes: seed.persistedYes, persistedNumeric: seed.persistedNumeric,
            persistedTimes: seed.persistedTimes
        ))
        XCTAssertFalse(NativeJournalDraft.shouldWrite(
            key: key, draftYes: seed.yes, draftNumeric: seed.numeric, draftTimes: seed.times,
            persistedYes: seed.yes, persistedNumeric: seed.numeric, persistedTimes: seed.times
        ))
    }

    func testBehaviorDayIsTheCalendarDayBeforeTheWakeDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let wake = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 8))!
        let behavior = NativeJournalBehaviorDay.date(from: wake, calendar: calendar)
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: behavior),
            DateComponents(year: 2026, month: 11, day: 17)
        )
        let defaultTime = NativeJournalNotes.defaultTime(on: behavior, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: defaultTime), 17)
        XCTAssertEqual(calendar.component(.hour, from: defaultTime), NativeJournalNotes.defaultHour)
        let stamped = NativeJournalNotes.date(minutes: 14 * 60 + 30, on: behavior, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: stamped), 17)
        XCTAssertEqual(calendar.component(.hour, from: stamped), 14)
        XCTAssertEqual(calendar.component(.minute, from: stamped), 30)
    }

    func testFramingShowsYesterdayOnTheLogicalWakeDay() {
        let calendar = Calendar.current
        let now = Date()
        let todayKey = NativeDayLogic.logicalToday(now: now)
        let parts = todayKey.split(separator: "-").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3)
        let selectedDay = calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        ) ?? calendar.startOfDay(for: now)
        XCTAssertEqual(
            NativeJournalBehaviorDay.title(for: selectedDay, now: now, calendar: calendar),
            "Yesterday"
        )
        let caption = NativeJournalBehaviorDay.caption(for: selectedDay, now: now, calendar: calendar)
        XCTAssertTrue(caption.contains("yesterday"))
        XCTAssertTrue(caption.contains("before last night's sleep"))
        let previousWake = calendar.date(byAdding: .day, value: -1, to: selectedDay)!
        let previousTitle = NativeJournalBehaviorDay.title(for: previousWake, now: now, calendar: calendar)
        XCTAssertNotEqual(previousTitle, "Yesterday")
        XCTAssertEqual(
            previousTitle,
            NativeScopeFormat.weekdayDate(
                NativeJournalBehaviorDay.date(from: previousWake, calendar: calendar),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            NativeJournalBehaviorDay.caption(for: previousWake, now: now, calendar: calendar)
                .contains("before that night's sleep")
        )
    }

    func testMorningJournalPromptGatesHourSleepAndTests() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 7))!
        let predawn = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 4, minute: 15))!
        let today = NativeDayLogic.logicalToday(now: morning)
        XCTAssertTrue(NativeMorningJournal.shouldPresent(
            now: morning, selectedKey: today, loaded: true, storeEmpty: false,
            journalFetched: true, hasTodayEntry: false, promptedDay: nil,
            sleepPresent: false, calendar: calendar, isTestProcess: false
        ))
        XCTAssertFalse(NativeMorningJournal.shouldPresent(
            now: predawn, selectedKey: NativeDayLogic.logicalToday(now: predawn),
            loaded: true, storeEmpty: false, journalFetched: true, hasTodayEntry: false,
            promptedDay: nil, sleepPresent: false, calendar: calendar, isTestProcess: false
        ))
        XCTAssertTrue(NativeMorningJournal.shouldPresent(
            now: predawn, selectedKey: NativeDayLogic.logicalToday(now: predawn),
            loaded: true, storeEmpty: false, journalFetched: true, hasTodayEntry: false,
            promptedDay: nil, sleepPresent: true, calendar: calendar, isTestProcess: false
        ))
        XCTAssertFalse(NativeMorningJournal.shouldPresent(
            now: morning, selectedKey: today, loaded: true, storeEmpty: false,
            journalFetched: true, hasTodayEntry: false, promptedDay: nil,
            sleepPresent: true, calendar: calendar, isTestProcess: true
        ))
    }
}
