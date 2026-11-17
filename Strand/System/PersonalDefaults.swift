import Foundation
import StrandDesign
import StrandAnalytics

/// Pins the personal-build (Band) preference set at launch. Stock NOOP never calls through here
/// unless `AppBrand.isPersonalBuild` is true, so a missing `NoopPersonalBuild` key is a no-op.
///
/// Cosmetic / customisation knobs are hidden in the personal Settings UI; this is the one place
/// their values are forced. The WHOOP drawing (`NativeStyle.whoop`) stays reachable from Developer
/// → Style, so an already-chosen style is left alone after the first pin.
enum PersonalDefaults {
    /// Apply the personal-build pins. `isPersonalBuild` is injectable so tests can cover both
    /// branches without a Band Info.plist.
    static func apply(isPersonalBuild: Bool = AppBrand.isPersonalBuild,
                      defaults: UserDefaults = .standard,
                      locale: Locale = .current) {
        guard isPersonalBuild else { return }

        defaults.register(defaults: registeredDefaults)

        defaults.set(true, forKey: NativeRouteResolver.layoutKey)
        defaults.set(EffortScale.whoop.rawValue, forKey: UnitPrefs.effortScaleKey)
        defaults.set(true, forKey: PuffinExperiment.experimentalSleepStressKey)
        defaults.set(unitSystem(for: locale).rawValue, forKey: UnitPrefs.systemKey)
        // Pins, not register(): UnitPrefs live-activity readers and CoachBriefScheduler treat a
        // missing key as ON. Coach, Live HR, sync island, and Lift Log are gone from the Native shell.
        // The owner wants miles regardless of the phone's region.
        if defaults.string(forKey: UnitPrefs.distanceSystemKey) == nil {
            defaults.set(UnitSystem.imperial.rawValue, forKey: UnitPrefs.distanceSystemKey)
        }
        defaults.set(false, forKey: "noop.coachEnabled")
        defaults.set(false, forKey: UnitPrefs.liveActivityKey)
        defaults.set(false, forKey: UnitPrefs.syncLiveActivityKey)
        defaults.set(false, forKey: UnitPrefs.liftLiveActivityKey)

        if defaults.object(forKey: NativeStyle.storageKey) == nil {
            defaults.set(NativeStyle.apple.rawValue, forKey: NativeStyle.storageKey)
        }
    }

    /// Body-measurement units from the device locale. Distance and temperature stay "follow body"
    /// (empty override keys), which is the app's existing default.
    static func unitSystem(for locale: Locale) -> UnitSystem {
        locale.measurementSystem == .metric ? .metric : .imperial
    }

    /// Existing app defaults for knobs the personal Settings UI no longer exposes. `register`
    /// fills them only when the key is unset, so a functional choice the user already made
    /// (hydration on, continuous HRV, …) is not wiped.
    static var registeredDefaults: [String: Any] {
        [
            NativeRouteResolver.layoutKey: true,
            NativeStyle.storageKey: NativeStyle.apple.rawValue,
            "noop.liquidTodayEnabled": true,
            UnitPrefs.effortScaleKey: EffortScale.whoop.rawValue,
            PuffinExperiment.experimentalSleepStressKey: true,
            AppearanceMode.storageKey: AppearanceMode.system.rawValue,
            ChartStyle.storageKey: ChartStyle.titanium.rawValue,
            SleepChartStyle.storageKey: SleepChartStyle.classic.rawValue,
            AccentColor.storageKey: AccentColor.mint.rawValue,
            SceneBackgroundPrefs.enabledKey: true,
            SkyBehindCardsPrefs.enabledKey: false,
            CardAppearancePrefs.opacityKey: CardAppearancePrefs.defaultPercent,
            QuietMotionPrefs.enabledKey: false,
            ClockFormatPreference.defaultsKey: ClockFormatPreference.system.rawValue,
            AppLanguage.storageKey: AppLanguage.system.rawValue,
            DayCycleMode.storageKey: DayCycleMode.sleepOnset.rawValue,
            UnitPrefs.trendChartStyleKey: TrendChartStyle.line.rawValue,
            UnitPrefs.hrvWindowKey: HrvWindow.whole.rawValue,
            PuffinExperiment.banisterEffortKey: false,
            HydrationStore.enabledKey: false,
            PuffinExperiment.autoDetectWorkoutsKey: false,
            PuffinExperiment.journalReminderKey: true,
            "workoutKeepScreenOn": false,
            ScreenIdle.strapSyncKeepAwakeKey: false,
            // Off: the heart-rate banner re-pushes every 10–15 s and the sync banner on every offload
            // slice, which costs battery and reads as constant syncing.
            "noop.coachEnabled": false,
            UnitPrefs.liveActivityKey: false,
            UnitPrefs.syncLiveActivityKey: false,
            UnitPrefs.liftLiveActivityKey: false,
            // Hourly offload batches; the strap keeps recording to its own memory in between.
            PuffinExperiment.lowRefreshKey: true,
            "noop.bottomBarAutoHide": false,
            // On: gate 0x2A37 notify, EVENT offload kicks, slice auto-continue, analysis, widget reloads.
            // Off restores the previous cadence. Stock NOOP never registers this key.
            BandPowerPolicy.defaultsKey: true,
        ]
    }
}
