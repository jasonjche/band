import Foundation
import WhoopProtocol

/// Where the workout-page HR series came from.
enum WorkoutHeartRateOrigin: Equatable, Sendable {
    case strap
    case appleHealth
    case none
}

/// Strap or Apple Health samples for one workout window, plus which source won.
struct WorkoutHeartRate: Equatable, Sendable {
    var samples: [HRSample]
    var origin: WorkoutHeartRateOrigin
}

/// Pure selection: strap HR when it covers at least half the minutes, else Apple Health, else none.
enum WorkoutHeartRateSelection {
    static let coverageThreshold = 0.5

    /// Distinct workout minutes that carry at least one sample, as a fraction of the window.
    static func minuteCoverage(samples: [HRSample], from: Int, to: Int) -> Double {
        let duration = to - from
        guard duration > 0 else { return 0 }
        let totalMinutes = max(1, (duration + 59) / 60)
        var covered = Set<Int>()
        covered.reserveCapacity(min(samples.count, totalMinutes))
        for sample in samples where sample.ts >= from && sample.ts <= to {
            covered.insert(min((sample.ts - from) / 60, totalMinutes - 1))
        }
        return Double(covered.count) / Double(totalMinutes)
    }

    static func select(strap: [HRSample], apple: [HRSample], from: Int, to: Int) -> WorkoutHeartRate {
        if minuteCoverage(samples: strap, from: from, to: to) >= coverageThreshold {
            return WorkoutHeartRate(samples: strap, origin: .strap)
        }
        if !apple.isEmpty {
            return WorkoutHeartRate(samples: apple, origin: .appleHealth)
        }
        return WorkoutHeartRate(samples: [], origin: .none)
    }
}

/// On-device JSON side-store for Apple Health workout HR, keyed by the workout natural key
/// (`startTs` + sport) the same way `RouteStore` keys GPS routes.
///
/// Kept out of `hrSample`: a write under deviceId `"apple-health"` would move
/// `WhoopStore.analysisFingerprint()` (`MAX(rowid)` / `MAX(ts)` over the whole table) and is not
/// proven unreachable from every scoring read. Never leaves the device.
enum AppleWorkoutHRStore {
    static let maxSamples = 20_000
    static let relativePath = "OpenWhoop/apple-workout-hr"

    static func key(startTs: Int, sport: String) -> String { "\(startTs)|\(sport)" }

    static func fileName(startTs: Int, sport: String) -> String {
        let encoded = sport.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "sport"
        return "\(startTs)-\(encoded).json"
    }

    static func defaultDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent(relativePath, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path)
        #endif
        return dir
    }

    static func contains(startTs: Int, sport: String, in directory: URL? = nil) -> Bool {
        guard let dir = directory ?? (try? defaultDirectory()) else { return false }
        return FileManager.default.fileExists(atPath: url(startTs: startTs, sport: sport, in: dir).path)
    }

    /// nil means not fetched yet. Empty array means fetched and Health had no usable samples.
    static func load(startTs: Int, sport: String, from directory: URL? = nil) -> [HRSample]? {
        guard let dir = directory ?? (try? defaultDirectory()) else { return nil }
        let path = url(startTs: startTs, sport: sport, in: dir)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return decode(data)
    }

    static func store(_ samples: [HRSample], startTs: Int, sport: String, into directory: URL? = nil) {
        guard let dir = directory ?? (try? defaultDirectory()) else { return }
        let capped = samples.count <= maxSamples ? samples : Array(samples.prefix(maxSamples))
        guard let data = encode(capped) else { return }
        let path = url(startTs: startTs, sport: sport, in: dir)
        try? data.write(to: path, options: .atomic)
    }

    static func remove(startTs: Int, sport: String, from directory: URL? = nil) {
        guard let dir = directory ?? (try? defaultDirectory()) else { return }
        try? FileManager.default.removeItem(at: url(startTs: startTs, sport: sport, in: dir))
    }

    static func encode(_ samples: [HRSample]) -> Data? { try? JSONEncoder().encode(samples) }

    static func decode(_ data: Data) -> [HRSample]? {
        try? JSONDecoder().decode([HRSample].self, from: data)
    }

    private static func url(startTs: Int, sport: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(startTs: startTs, sport: sport), isDirectory: false)
    }
}
