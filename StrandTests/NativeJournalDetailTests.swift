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
        XCTAssertEqual(answers, [HomeJournalAnswer(question: "Did you feel stressed?", value: "Yes")])
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
            question: "Did you have caffeine late in the day?",
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
            NativeJournalFollowUp.forQuestion("Did you have caffeine late in the day?", kind: .bool),
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
    }
}
