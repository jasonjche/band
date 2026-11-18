import Foundation

/// Optional automatic full backup to a user-picked iCloud Drive (or Files) folder, without
/// iCloud/CloudKit entitlements. The user picks a folder once (`UIDocumentPicker` on `.folder`);
/// Band stores a security-scoped bookmark and writes `Band-backup-YYYY-MM-DD.zip` (the same
/// payload as a manual full backup) at most once per local day. Only those dated Band-backup
/// files are pruned; nothing else in the folder is touched.
///
/// Off by default. Keys: `band.autoBackup.enabled`, `band.autoBackup.folderBookmark`.
enum AutoICloudBackup {
    static let enabledKey = "band.autoBackup.enabled"
    static let bookmarkKey = "band.autoBackup.folderBookmark"
    static let lastDateKey = "band.autoBackup.lastDate"
    static let lastErrorKey = "band.autoBackup.lastError"

    static let filePrefix = "Band-backup-"
    static let fileSuffix = ".zip"
    static let keepCount = 7

    // MARK: - Pure filename / prune (unit-tested)

    static func dayStamp(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func fileName(on date: Date = Date(), timeZone: TimeZone = .current) -> String {
        filePrefix + dayStamp(date, timeZone: timeZone) + fileSuffix
    }

    /// `Band-backup-YYYY-MM-DD.zip` only.
    static func isBackupFile(_ name: String) -> Bool {
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else { return false }
        let stamp = String(name.dropFirst(filePrefix.count).dropLast(fileSuffix.count))
        return stamp.count == 10
            && stamp[stamp.index(stamp.startIndex, offsetBy: 4)] == "-"
            && stamp[stamp.index(stamp.startIndex, offsetBy: 7)] == "-"
            && stamp.filter(\.isNumber).count == 8
    }

    /// Oldest first, only canonical Band-backup files, beyond `keep`. Never returns other names.
    static func filesToPrune(_ names: [String], keep: Int = keepCount) -> [String] {
        let backups = names.filter(isBackupFile).sorted(by: >)
        return backups.count <= keep ? [] : Array(backups.dropFirst(keep))
    }

    // MARK: - Persisted state

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var lastBackupDay: String? {
        get { UserDefaults.standard.string(forKey: lastDateKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: lastDateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastDateKey)
            }
        }
    }

    static var lastError: String? {
        get { UserDefaults.standard.string(forKey: lastErrorKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: lastErrorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastErrorKey)
            }
        }
    }

    static var hasFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static func isDue(now: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        lastBackupDay != dayStamp(now, timeZone: timeZone)
    }

    static func disable() {
        isEnabled = false
        lastError = nil
    }

    // MARK: - iOS folder bookmark + write

    #if os(iOS)
    enum RunResult {
        case skipped
        case wrote(String)
        case needsFolder
        case failure(String)
    }

    @MainActor
    static func enablePickingFolder() async -> Bool {
        guard let url = await DocumentPicker.pickFolder() else { return false }
        saveFolder(url)
        isEnabled = true
        lastError = nil
        return true
    }

    static func saveFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try? url.bookmarkData(options: [],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            lastError = nil
        } else {
            lastError = String(localized: "Couldn't save the backup folder. Pick it again.")
        }
    }

    /// Resolve the bookmarked folder. A stale bookmark is refreshed when possible; otherwise
    /// the caller should ask the user to pick again.
    static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            lastError = String(localized: "The backup folder is no longer available. Pick it again.")
            return nil
        }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(options: [],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            } else {
                lastError = String(localized: "The backup folder is no longer available. Pick it again.")
                return nil
            }
        }
        return url
    }

    /// Foreground / BGAppRefresh catch-up. No-op unless enabled, a folder is set, and nothing
    /// has been written today.
    static func catchUpIfDue(checkpoint: @escaping () async -> Bool) async {
        _ = await runIfDue(checkpoint: checkpoint)
    }

    static func runIfDue(checkpoint: @escaping () async -> Bool) async -> RunResult {
        guard isEnabled else { return .skipped }
        guard hasFolder else { return .needsFolder }
        guard isDue() else { return .skipped }
        return await backupNow(checkpoint: checkpoint)
    }

    static func backupNow(checkpoint: @escaping () async -> Bool) async -> RunResult {
        guard let folder = resolveFolder() else { return .needsFolder }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let name = fileName()
        let dest = folder.appendingPathComponent(name)
        switch await DataBackup.writeBackupCoordinated(checkpoint: checkpoint, to: dest) {
        case .exported, .exportedOversize:
            lastBackupDay = dayStamp()
            lastError = nil
            prune(in: folder)
            return .wrote(name)
        case .failure(let message):
            lastError = message
            return .failure(message)
        default:
            lastError = String(localized: "Backup failed.")
            return .failure(String(localized: "Backup failed."))
        }
    }

    private static func prune(in folder: URL) {
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordError) { url in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in filesToPrune(names) {
                let file = url.appendingPathComponent(name)
                var writeError: NSError?
                NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting,
                                               error: &writeError) { doomed in
                    try? FileManager.default.removeItem(at: doomed)
                }
            }
        }
    }
    #endif
}
