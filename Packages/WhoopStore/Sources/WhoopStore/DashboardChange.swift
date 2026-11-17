import Foundation

/// One writer's delta of dashboard-cache tables (`dailyMetric`, `sleepSession`, sleep-figure
/// `metricSeries`, `appleDaily`). `Repository.refresh()` uses this to skip a full-history SQLite
/// reload when nothing those tables care about has moved, and to reload only the touched day
/// range when the set is small.
public struct DashboardChangeSet: Equatable, Sendable {
    public let revision: Int
    public let days: Set<String>
    public let forceFull: Bool

    public var isIncremental: Bool { !forceFull && !days.isEmpty }

    public init(revision: Int, days: Set<String>, forceFull: Bool) {
        self.revision = revision
        self.days = days
        self.forceFull = forceFull
    }
}

/// Process-local watermark of dashboard-cache writes. Same shape as `StepDataRevisionIndex`:
/// monotonic revision plus the UTC/local day keys the writer touched. Size is proportional to
/// distinct days written since the last `take()`, not to history depth.
struct DashboardChangeIndex {
    /// Above this many distinct days (or this many days of span) a delta is cheaper as a full reload.
    static let incrementalDayCap = 60

    private(set) var revision = 0
    private var changedDays = Set<String>()
    private var forceFull = false

    mutating func record(days: some Sequence<String>) {
        let list = days.filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        revision += 1
        if forceFull { return }
        changedDays.formUnion(list)
        if changedDays.count > Self.incrementalDayCap || Self.spanExceedsCap(changedDays) {
            forceFull = true
        }
    }

    mutating func recordFull() {
        revision += 1
        forceFull = true
    }

    func peek() -> DashboardChangeSet {
        DashboardChangeSet(revision: revision, days: changedDays, forceFull: forceFull)
    }

    /// Snapshot then clear the pending day set so the next writer starts a fresh delta.
    /// Revision stays monotonic.
    mutating func take() -> DashboardChangeSet {
        let snap = peek()
        changedDays.removeAll(keepingCapacity: true)
        forceFull = false
        return snap
    }

    private static func spanExceedsCap(_ days: Set<String>) -> Bool {
        guard let first = days.min(), let last = days.max(),
              first.count == 10, last.count == 10,
              let a = ymd(first), let b = ymd(last) else { return false }
        return b - a > incrementalDayCap
    }

    private static func ymd(_ day: String) -> Int? {
        let y = Int(day.prefix(4))
        let m = Int(day.dropFirst(5).prefix(2))
        let d = Int(day.suffix(2))
        guard let y, let m, let d else { return nil }
        return y * 400 + m * 32 + d
    }
}
