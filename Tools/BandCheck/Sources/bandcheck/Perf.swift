import Foundation

/// Wall-clock stage timers for BandCheck. Printed in a TIMING section that is not a gate.
/// Per-day rows print only when BAND_PERF=1.
enum Perf {
    static let perDay = ProcessInfo.processInfo.environment["BAND_PERF"] == "1"
    static let analysisReplay = ProcessInfo.processInfo.environment["BAND_PERF"] == "1"

    private static var order: [String] = []
    private static var ms: [String: Double] = [:]
    private static var calls: [String: Int] = [:]
    private static var days: [String: Int] = [:]
    private static var dayLines: [String] = []
    private static var t0: UInt64 = DispatchTime.now().uptimeNanoseconds
    private static var started = false

    private static func markStart() {
        if started { return }
        started = true
        t0 = DispatchTime.now().uptimeNanoseconds
    }

    @discardableResult
    static func measure<T>(_ name: String, days nDays: Int = 0, _ body: () throws -> T) rethrows -> T {
        markStart()
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        add(name, ms: Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000, days: nDays)
        return value
    }

    static func measureDay(_ name: String, day: String, _ body: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        add(name, ms: elapsed, days: 1)
        if perDay {
            dayLines.append("    \(day)  \(name)  \(String(format: "%.1f", elapsed)) ms")
        }
    }

    static func add(_ name: String, ms elapsed: Double, days nDays: Int = 0) {
        if ms[name] == nil { order.append(name) }
        ms[name, default: 0] += elapsed
        calls[name, default: 0] += 1
        days[name, default: 0] += nDays
    }

    static func report() -> String {
        let total = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
        func pad(_ s: String, _ n: Int) -> String {
            if s.count >= n { return s }
            return s + String(repeating: " ", count: n - s.count)
        }
        var lines: [String] = [
            "",
            "F. TIMING  (not a gate; ms wall-clock)",
            "--------------------------------------------------------------------------------",
            "  \(pad("stage", 28)) \(pad("ms", 10)) \(pad("calls", 7)) days",
        ]
        for name in order {
            let d = days[name] ?? 0
            let dayField = d > 0 ? String(d) : "—"
            let msField = String(format: "%10.1f", ms[name] ?? 0)
            let callField = String(format: "%7d", calls[name] ?? 0)
            lines.append("  \(pad(name, 28)) \(msField) \(callField) \(dayField)")
        }
        lines.append("  \(pad("total_wall", 28)) \(String(format: "%10.1f", total))")
        if !dayLines.isEmpty {
            lines.append("  per-day (BAND_PERF=1):")
            lines.append(contentsOf: dayLines)
        }
        return lines.joined(separator: "\n")
    }
}
