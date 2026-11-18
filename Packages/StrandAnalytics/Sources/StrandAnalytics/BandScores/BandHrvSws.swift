import Foundation

/// HRV during SWS — method spec §6, instrumentation only. Not a Recovery input.
///
/// rMSSD on artifact-cleaned RR inside deep-sleep (N3/SWS) 5-minute windows.
/// Two aggregations (all-SWS mean vs last-SWS exponential near-wake weighting)
/// plus a full-sleep fallback when SWS coverage is too thin.
public enum BandHrvSws {

    public static let rrMinMs: Double = 300
    public static let rrMaxMs: Double = 2000
    public static let windowSec: Double = 300
    public static let minSwsMinutes: Double = 10
    public static let lastHours: Double = 2
    public static let defaultTauMin: Double = 90
    public static let artifactFrac: Double = 0.20
    public static let madK: Double = 3
    public static let minCleanFrac: Double = 0.80
    public static let swsEpochFrac: Double = 0.80
    public static let gapSplitSec: Double = 2

    public struct Beat: Sendable, Equatable {
        public var tSec: Double
        public var rrMs: Double
        public init(tSec: Double, rrMs: Double) { self.tSec = tSec; self.rrMs = rrMs }
    }

    public struct Epoch: Sendable, Equatable {
        public var startSec: Double
        public var endSec: Double
        public var isSws: Bool
        public init(startSec: Double, endSec: Double, isSws: Bool) {
            self.startSec = startSec; self.endSec = endSec; self.isSws = isSws
        }
    }

    public struct Result: Sendable, Equatable {
        public var allSwsRmssd: Double?
        public var lastSwsRmssd: Double?
        public var fullSleepRmssd: Double?
        public var fallback: Bool
        public var validSwsMinutes: Double
        public var windowCount: Int
    }

    /// Task Force 1996 rMSSD: sqrt(mean(diff(RR)^2)).
    public static func rmssd(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        var ss = 0.0
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            ss += d * d
        }
        return sqrt(ss / Double(rr.count - 1))
    }

    /// Flag beats in one 5-min window: |RR − median| > max(0.20 × median, 3 × MAD).
    public static func cleanWindow(_ rr: [Double]) -> [Double]? {
        let ranged = rr.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
        guard !ranged.isEmpty else { return nil }
        let m = BandScores.median(ranged)
        let mad = 1.4826 * BandScores.median(ranged.map { abs($0 - m) })
        let thresh = max(artifactFrac * m, madK * mad)
        var kept: [Double] = []
        kept.reserveCapacity(ranged.count)
        for v in ranged {
            if abs(v - m) <= thresh { kept.append(v) }
        }
        guard Double(kept.count) / Double(ranged.count) >= minCleanFrac else { return nil }
        return kept
    }

    public static func compute(beats: [Beat], epochs: [Epoch], sleepStartSec: Double, sleepEndSec: Double,
                               tauMin: Double = defaultTauMin) -> Result {
        let inSleep = beats.filter { $0.tSec >= sleepStartSec && $0.tSec < sleepEndSec }
            .sorted { $0.tSec < $1.tSec }
        let full = windowedRmssd(beats: inSleep, from: sleepStartSec, to: sleepEndSec, epochs: nil)
        let sws = windowedRmssd(beats: inSleep, from: sleepStartSec, to: sleepEndSec, epochs: epochs)

        let allMean: Double?
        if sws.rmssd.isEmpty {
            allMean = nil
        } else {
            allMean = sws.rmssd.reduce(0, +) / Double(sws.rmssd.count)
        }

        var last: Double?
        if !sws.rmssd.isEmpty {
            var num = 0.0, den = 0.0
            let tauSec = tauMin * 60
            for i in sws.rmssd.indices {
                let w = exp((sws.centers[i] - sleepEndSec) / tauSec)
                num += w * sws.rmssd[i]
                den += w
            }
            if den > 0 { last = num / den }
        }

        let lastTwoStart = sleepEndSec - lastHours * 3600
        let hasLateSws = zip(sws.centers, sws.durations).contains { c, d in c >= lastTwoStart && d > 0 }
        let fallback = sws.minutes < minSwsMinutes || !hasLateSws
        return Result(
            allSwsRmssd: allMean,
            lastSwsRmssd: last,
            fullSleepRmssd: full.rmssd.isEmpty
                ? nil
                : full.rmssd.reduce(0, +) / Double(full.rmssd.count),
            fallback: fallback,
            validSwsMinutes: sws.minutes,
            windowCount: sws.rmssd.count
        )
    }

    private struct Windows {
        var rmssd: [Double]
        var centers: [Double]
        var durations: [Double]
        var minutes: Double
    }

    private static func windowedRmssd(beats: [Beat], from: Double, to: Double,
                                      epochs: [Epoch]?) -> Windows {
        var rm: [Double] = []
        var centers: [Double] = []
        var durs: [Double] = []
        var minutes = 0.0
        var t0 = from
        while t0 + windowSec <= to + 1e-9 {
            let t1 = t0 + windowSec
            if let epochs {
                let overlap = swsOverlap(epochs: epochs, start: t0, end: t1)
                if overlap < swsEpochFrac {
                    t0 += windowSec
                    continue
                }
            }
            let slice = splitOnGaps(beats.filter { $0.tSec >= t0 && $0.tSec < t1 })
            var windowKept: [Double] = []
            var ok = false
            for group in slice {
                if let cleaned = cleanWindow(group.map(\.rrMs)) {
                    windowKept.append(contentsOf: cleaned)
                    ok = true
                }
            }
            if ok, let v = rmssd(windowKept) {
                rm.append(v)
                centers.append(0.5 * (t0 + t1))
                durs.append(windowSec)
                minutes += windowSec / 60
            }
            t0 += windowSec
        }
        return Windows(rmssd: rm, centers: centers, durations: durs, minutes: minutes)
    }

    private static func swsOverlap(epochs: [Epoch], start: Double, end: Double) -> Double {
        let span = end - start
        guard span > 0 else { return 0 }
        var sws = 0.0
        for e in epochs where e.isSws {
            let lo = max(e.startSec, start)
            let hi = min(e.endSec, end)
            if hi > lo { sws += hi - lo }
        }
        return sws / span
    }

    /// Split a window's beats wherever successive timestamps jump by more than 2 s.
    public static func splitOnGaps(_ beats: [Beat]) -> [[Beat]] {
        guard !beats.isEmpty else { return [] }
        var groups: [[Beat]] = [[beats[0]]]
        for i in 1..<beats.count {
            if beats[i].tSec - beats[i - 1].tSec > gapSplitSec {
                groups.append([beats[i]])
            } else {
                groups[groups.count - 1].append(beats[i])
            }
        }
        return groups
    }
}
