import SwiftUI
import StrandDesign

/// More → Backup. WHOOP-format export, full Band backup / restore, optional iCloud Drive auto-backup.
struct BandBackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var work: BackupWork?
    @State private var actionsReady = false
    @State private var backupAlertTitle = ""
    @State private var backupAlertMessage = ""
    @State private var showBackupAlert = false
    @State private var showOversizeRestoreConfirm = false
    @State private var oversizeRestoreMessage = ""
    #if os(iOS)
    @State private var autoBackupEnabled = AutoICloudBackup.isEnabled
    @State private var autoBackupLastDay = AutoICloudBackup.lastBackupDay
    @State private var autoBackupError = AutoICloudBackup.lastError
    #endif

    private enum BackupWork {
        case whoopExport
        case fullBackup
        case restore
    }

    var body: some View {
        List {
            Section {
                Button {
                    runWhoopExport()
                } label: {
                    HStack {
                        Text("Export (WHOOP format)")
                        Spacer()
                        if work == .whoopExport {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(work != nil)
            } footer: {
                Text("A zip of the same four CSVs WHOOP exports, so you can continue there or re-import into Band.")
            }

            Section {
                Button {
                    runExport()
                } label: {
                    HStack {
                        Text("Full backup (.zip)")
                        Spacer()
                        if work == .fullBackup {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(work != nil)
                Button {
                    runImport()
                } label: {
                    HStack {
                        Text("Restore from backup…")
                        Spacer()
                        if work == .restore {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(work != nil)
            } footer: {
                Text("Importing replaces all data on this device. Backups are unencrypted ZIP files.")
            }

            #if os(iOS)
            Section {
                Toggle("Automatic backup to iCloud Drive", isOn: $autoBackupEnabled)
                    .disabled(work != nil)
                    .onChangeCompat(of: autoBackupEnabled) { on in
                        Task { await setAutoBackup(on) }
                    }
                if autoBackupEnabled {
                    Button("Choose folder…") {
                        Task { await pickAutoBackupFolder() }
                    }
                    .disabled(work != nil)
                }
                if let last = formattedLastBackup {
                    Text("Last backup: \(last)")
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let err = autoBackupError, !err.isEmpty {
                    Text(err)
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            } footer: {
                Text("Writes a dated full backup to a folder you pick in Files or iCloud Drive, at most once a day when Band is opened. Keeps the newest 7 Band-backup files and leaves everything else in the folder alone.")
            }
            #endif
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .appleSettingsChrome("Backup")
        .task {
            // The NavigationLink tap that pushed this page can land on Export. Wait one
            // turn so appear does not start a checkpoint / zip / integrity check.
            await Task.yield()
            actionsReady = true
            #if os(iOS)
            refreshAutoBackupState()
            #endif
        }
        .alert(backupAlertTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupAlertMessage)
        }
        .alert("Backup problem", isPresented: $showOversizeRestoreConfirm) {
            Button("Restore") { runImport(allowOversize: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(oversizeRestoreMessage)
        }
    }

    #if os(iOS)
    private var formattedLastBackup: String? {
        guard let day = autoBackupLastDay else { return nil }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: day) else { return day }
        let show = DateFormatter()
        show.dateStyle = .medium
        return show.string(from: date)
    }

    private func refreshAutoBackupState() {
        autoBackupEnabled = AutoICloudBackup.isEnabled
        autoBackupLastDay = AutoICloudBackup.lastBackupDay
        autoBackupError = AutoICloudBackup.lastError
    }

    private func setAutoBackup(_ on: Bool) async {
        if on {
            if AutoICloudBackup.hasFolder, AutoICloudBackup.resolveFolder() != nil {
                AutoICloudBackup.isEnabled = true
                AutoICloudBackup.lastError = nil
                await AutoICloudBackup.catchUpIfDue(checkpoint: { await model.repo.checkpointForBackup() })
            } else {
                let picked = await AutoICloudBackup.enablePickingFolder()
                if picked {
                    await AutoICloudBackup.catchUpIfDue(checkpoint: { await model.repo.checkpointForBackup() })
                } else {
                    AutoICloudBackup.isEnabled = false
                }
            }
        } else {
            AutoICloudBackup.disable()
        }
        refreshAutoBackupState()
    }

    private func pickAutoBackupFolder() async {
        _ = await AutoICloudBackup.enablePickingFolder()
        refreshAutoBackupState()
    }
    #endif

    private func runWhoopExport() {
        guard actionsReady, work == nil else { return }
        work = .whoopExport
        Task {
            let result = await CsvExport.run(repo: model.repo)
            work = nil
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                backupAlertTitle = String(localized: "WHOOP export saved")
                backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent). The zip has WHOOP's four CSVs and re-imports into Band or WHOOP.")
                showBackupAlert = true
            case .failure(let message):
                backupAlertTitle = String(localized: "Export problem")
                backupAlertMessage = message
                showBackupAlert = true
            }
        }
    }

    private func runExport() {
        guard actionsReady, work == nil else { return }
        work = .fullBackup
        Task {
            handleBackup(await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() }))
        }
    }

    private func runImport(allowOversize: Bool = false) {
        guard actionsReady, work == nil else { return }
        work = .restore
        Task {
            handleBackup(await DataBackup.runImport(allowOversize: allowOversize))
        }
    }

    @MainActor
    private func handleBackup(_ result: DataBackup.BackupResult) {
        work = nil
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupAlertTitle = String(localized: "Backup exported")
            backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent).")
            showBackupAlert = true
        case .exportedOversize(let url, _, _):
            backupAlertTitle = String(localized: "Backup exported")
            backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent). Restoring it will ask you to confirm once.")
            showBackupAlert = true
        case .restoreTooLarge(let name, _):
            oversizeRestoreMessage = String(localized: "\(name) is larger than Band restores without asking. You'll be asked to choose the file again.")
            showOversizeRestoreConfirm = true
        case .imported:
            backupAlertTitle = String(localized: "Backup imported")
            backupAlertMessage = String(localized: "Your data has been restored. Quit and reopen for it to take effect.")
            showBackupAlert = true
        case .failure(let message):
            backupAlertTitle = String(localized: "Backup problem")
            backupAlertMessage = message
            showBackupAlert = true
        }
    }
}
