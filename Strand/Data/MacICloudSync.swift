import Foundation
#if os(macOS)
import AppKit
#endif

/// macOS one-way auto-sync from a user-picked iCloud Drive (or shared) folder where the
/// iPhone writes `Band-backup-YYYY-MM-DD.zip` (or `.noopbak`) full backups.
///
/// No CloudKit or server required: macOS stores a security-scoped bookmark to the folder,
/// checks for a newer backup on launch and foreground activation, materializes any iCloud
/// placeholder via `NSFileCoordinator`, restores through `DataBackup.restore`, and reopens
/// `Repository` live so every screen updates without a restart.
enum MacICloudSync {
    static let enabledKey = "band.macICloudSync.enabled"
    static let bookmarkKey = "band.macICloudSync.folderBookmark"
    static let lastSignatureKey = "band.macICloudSync.lastSignature"
    static let lastFileNameKey = "band.macICloudSync.lastFileName"
    static let lastSyncedAtKey = "band.macICloudSync.lastSyncedAt"
    static let lastErrorKey = "band.macICloudSync.lastError"

    struct Entry: Equatable, Sendable {
        var name: String
        var modifiedAt: TimeInterval
        var size: Int64
        var isPlaceholder: Bool

        var signature: String {
            "\(name)|\(Int(modifiedAt.rounded()))|\(size)"
        }
    }

    enum SyncOutcome: Equatable, Sendable {
        case disabled
        case needsFolder
        case upToDate(String)
        case noBackupFound
        case downloading(String)
        case synced(String)
        case failure(String)
    }

    // MARK: - Pure candidate selection (unit-tested)

    /// True for files produced by Band's iPhone auto-backup (`Band-backup-YYYY-MM-DD.zip`)
    /// or manual / folder backups (`.noopbak`, `Band-backup*.zip`).
    static func isSupportedBackupName(_ rawName: String) -> Bool {
        let name = BackupSync.iCloudPlaceholderRealName(rawName) ?? rawName
        if AutoICloudBackup.isBackupFile(name) { return true }
        let lower = name.lowercased()
        if lower.hasSuffix(".noopbak") { return true }
        if lower.hasPrefix("band-backup") && lower.hasSuffix(".zip") { return true }
        return false
    }

    /// Pick the newest backup entry: prefers the highest canonical `YYYY-MM-DD` stamp when both
    /// carry one, then latest modification timestamp, then lexicographic filename.
    static func newestCandidate(in entries: [Entry]) -> Entry? {
        let matching = entries.filter { isSupportedBackupName($0.name) }
        return matching.max { lhs, rhs in
            let lDay = backupDayStamp(lhs.name) ?? ""
            let rDay = backupDayStamp(rhs.name) ?? ""
            if lDay != rDay { return lDay < rDay }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.name < rhs.name
        }
    }

    static func shouldSync(candidate: Entry, lastSignature: String?, force: Bool = false) -> Bool {
        if force { return true }
        guard let lastSignature, !lastSignature.isEmpty else { return true }
        return candidate.signature != lastSignature
    }

    private static func backupDayStamp(_ name: String) -> String? {
        guard AutoICloudBackup.isBackupFile(name) else { return nil }
        return String(name.dropFirst(AutoICloudBackup.filePrefix.count).dropLast(AutoICloudBackup.fileSuffix.count))
    }

    // MARK: - Persisted state

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var hasFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static var lastSignature: String? {
        get { UserDefaults.standard.string(forKey: lastSignatureKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: lastSignatureKey) }
            else { UserDefaults.standard.removeObject(forKey: lastSignatureKey) }
        }
    }

    static var lastFileName: String? {
        get { UserDefaults.standard.string(forKey: lastFileNameKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: lastFileNameKey) }
            else { UserDefaults.standard.removeObject(forKey: lastFileNameKey) }
        }
    }

    static var lastSyncedAt: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: lastSyncedAtKey)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastSyncedAtKey) }
            else { UserDefaults.standard.removeObject(forKey: lastSyncedAtKey) }
        }
    }

    static var lastError: String? {
        get { UserDefaults.standard.string(forKey: lastErrorKey) }
        set {
            if let newValue, !newValue.isEmpty { UserDefaults.standard.set(newValue, forKey: lastErrorKey) }
            else { UserDefaults.standard.removeObject(forKey: lastErrorKey) }
        }
    }

    static func disable() {
        isEnabled = false
        lastError = nil
    }

    #if os(macOS)
    private static var syncInFlight = false

    static var folderDisplayLabel: String? {
        guard let url = resolveFolder() else { return nil }
        let path = url.path
        let trail = FolderBackup.folderTrail(path: path)
        if FolderBackup.isICloudPath(path) {
            return trail.isEmpty ? String(localized: "iCloud Drive") : String(localized: "iCloud Drive › \(trail)")
        }
        return trail.isEmpty ? url.lastPathComponent : trail
    }

    @MainActor
    static func enablePickingFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose iPhone Backup Folder")
        panel.message = String(localized: "Select the iCloud Drive folder your iPhone backs up Band to.")
        panel.prompt = String(localized: "Select Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let icloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloudDocs.path) {
            panel.directoryURL = icloudDocs
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        saveFolder(url)
        isEnabled = true
        lastError = nil
        return true
    }

    static func saveFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = (try? url.bookmarkData(options: .withSecurityScope,
                                          includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [],
                                      includingResourceValuesForKeys: nil, relativeTo: nil))
        if let data {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            lastError = nil
        } else {
            lastError = String(localized: "Couldn't save the sync folder. Choose it again.")
        }
    }

    static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else {
            lastError = String(localized: "The sync folder is no longer available. Choose it again.")
            return nil
        }
        if stale { saveFolder(url) }
        return url
    }

    /// Check the configured iCloud Drive folder and restore the newest backup if it is newer
    /// than the last synced signature. Reopens `repo` live so screens refresh immediately.
    @MainActor
    @discardableResult
    static func syncIfNeeded(repo: Repository, force: Bool = false) async -> SyncOutcome {
        guard force || isEnabled else { return .disabled }
        guard !syncInFlight else { return .upToDate(lastFileName ?? "") }
        guard let folder = resolveFolder() else { return .needsFolder }

        syncInFlight = true
        defer { syncInFlight = false }

        let priorSig = lastSignature
        let (outcome, newSig, restoredName) = await Task.detached(priority: .utility) {
            performSync(in: folder, lastSignature: priorSig, force: force)
        }.value

        switch outcome {
        case .synced(let name):
            if let newSig { lastSignature = newSig }
            lastFileName = restoredName ?? name
            lastSyncedAt = Date()
            lastError = nil
            await repo.reopenStoreAfterRestore()
        case .upToDate:
            lastError = nil
        case .downloading(let name):
            lastError = String(localized: "Downloading \(name) from iCloud… reopen or tap Sync Now in a moment.")
        case .noBackupFound:
            lastError = force ? String(localized: "No Band backup (.zip or .noopbak) found in this folder yet.") : nil
        case .failure(let msg):
            lastError = msg
        case .disabled, .needsFolder:
            break
        }
        return outcome
    }

    private static func performSync(
        in folder: URL,
        lastSignature: String?,
        force: Bool
    ) -> (outcome: SyncOutcome, signature: String?, fileName: String?) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let rawNames: [String]
        do {
            rawNames = try fm.contentsOfDirectory(atPath: folder.path)
        } catch {
            return (.failure(String(localized: "Couldn't read the sync folder: \(error.localizedDescription)")), nil, nil)
        }

        var entries: [Entry] = []
        var rawByCanonical: [String: String] = [:]
        for rawName in rawNames where isSupportedBackupName(rawName) {
            let placeholder = BackupSync.iCloudPlaceholderRealName(rawName) != nil
            let canonical = BackupSync.iCloudPlaceholderRealName(rawName) ?? rawName
            let itemURL = folder.appendingPathComponent(rawName)
            let vals = try? itemURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = Int64(vals?.fileSize ?? 0)
            // Prefer the real materialized file if both placeholder and real name appear.
            if rawByCanonical[canonical] == nil || !placeholder {
                rawByCanonical[canonical] = rawName
                entries.removeAll { $0.name == canonical }
                entries.append(Entry(name: canonical, modifiedAt: mtime, size: size, isPlaceholder: placeholder))
            }
        }

        guard let newest = newestCandidate(in: entries) else {
            return (.noBackupFound, nil, nil)
        }
        guard shouldSync(candidate: newest, lastSignature: lastSignature, force: force) else {
            return (.upToDate(newest.name), nil, newest.name)
        }

        let targetURL = folder.appendingPathComponent(newest.name)
        if newest.isPlaceholder || !fm.fileExists(atPath: targetURL.path) {
            try? fm.startDownloadingUbiquitousItem(at: targetURL)
            if !fm.fileExists(atPath: targetURL.path) {
                return (.downloading(newest.name), nil, newest.name)
            }
        }

        // Copy through NSFileCoordinator into temp scratch so iCloud Drive finishes downloading
        // and we never unzip while the phone is mid-upload.
        let scratchDir = NoopScratch.subdirectory("mac-icloud-sync-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratchDir) }
        try? fm.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let localCopy = scratchDir.appendingPathComponent(newest.name)

        var coordError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: targetURL, options: .forUploading, error: &coordError) { readableURL in
            do {
                if fm.fileExists(atPath: localCopy.path) { try fm.removeItem(at: localCopy) }
                try fm.copyItem(at: readableURL, to: localCopy)
            } catch {
                copyError = error
            }
        }
        if let err = coordError ?? copyError {
            return (.failure(String(localized: "Couldn't read \(newest.name): \(err.localizedDescription)")), nil, newest.name)
        }

        let refreshedVals = try? targetURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let finalEntry = Entry(
            name: newest.name,
            modifiedAt: refreshedVals?.contentModificationDate?.timeIntervalSince1970 ?? newest.modifiedAt,
            size: Int64(refreshedVals?.fileSize ?? Int(newest.size)),
            isPlaceholder: false
        )

        let dbPath: String
        do {
            dbPath = try StorePaths.defaultDatabasePath()
        } catch {
            return (.failure(String(localized: "Couldn't locate the Band database: \(error.localizedDescription)")), nil, newest.name)
        }

        let result = DataBackup.restore(from: localCopy, toDatabaseAt: dbPath, allowOversize: true)
        switch result {
        case .imported:
            return (.synced(newest.name), finalEntry.signature, newest.name)
        case .failure(let msg):
            return (.failure(msg), nil, newest.name)
        case .restoreTooLarge(let name, _):
            return (.failure(String(localized: "\(name) exceeded the backup size limit.")), nil, newest.name)
        case .cancelled, .exported, .exportedOversize:
            return (.upToDate(newest.name), nil, newest.name)
        }
    }
    #endif
}
