import Foundation

/// When `analyzeRecent` should walk the full window, today only, or skip.
///
/// Live 0x2A37 ticks must not force a 21-day restage. The full window runs after an offload
/// that stored new records, or a manual workout save / import. Idle ticks are today-only
/// while the policy is on.
enum AnalysisGating {
    enum Kind: Equatable {
        case idleTick
        case offload
        case manual
    }

    enum Pass: Equatable {
        case skip
        case todayOnly
        case fullWindow
    }

    static func pass(policyEnabled: Bool, kind: Kind, storedNewRecords: Bool) -> Pass {
        switch kind {
        case .manual:
            return .fullWindow
        case .offload:
            return storedNewRecords ? .fullWindow : .skip
        case .idleTick:
            return policyEnabled ? .todayOnly : .fullWindow
        }
    }

    /// O(1) change token from indexed frontiers (max ts / max rowid). Replaces a whole-table
    /// `COUNT(*)` as the thing a caller compares across ticks.
    static func fingerprint(maxHrTs: Int, maxHrRowid: Int, maxRrRowid: Int = 0) -> String {
        "o1|ts\(maxHrTs)|hid\(maxHrRowid)|rid\(maxRrRowid)"
    }
}
