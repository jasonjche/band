import XCTest
@testable import Strand
import StrandAnalytics

/// Personal-build pins must land when the flag is on, and must leave stock defaults alone when it is off.
final class PersonalDefaultsTests: XCTestCase {

    private let suite = "PersonalDefaultsTests"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDoesNotApplyWhenFlagIsOff() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: NativeRouteResolver.layoutKey)
        defaults.set(NativeStyle.whoop.rawValue, forKey: NativeStyle.storageKey)
        defaults.set(EffortScale.hundred.rawValue, forKey: UnitPrefs.effortScaleKey)
        defaults.set(false, forKey: PuffinExperiment.experimentalSleepStressKey)
        defaults.set(UnitSystem.imperial.rawValue, forKey: UnitPrefs.systemKey)

        PersonalDefaults.apply(isPersonalBuild: false,
                               defaults: defaults,
                               locale: Locale(identifier: "fr_FR"))

        XCTAssertEqual(defaults.object(forKey: NativeRouteResolver.layoutKey) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: NativeStyle.storageKey), NativeStyle.whoop.rawValue)
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.effortScaleKey), EffortScale.hundred.rawValue)
        XCTAssertEqual(defaults.object(forKey: PuffinExperiment.experimentalSleepStressKey) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.systemKey), UnitSystem.imperial.rawValue)
        // Read the suite's own domain: `object(forKey:)` also sees defaults the host app registered.
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[BandPowerPolicy.defaultsKey])
    }

    func testPinsLayoutStyleEffortSleepStressAndLocaleUnitsWhenFlagIsOn() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: NativeRouteResolver.layoutKey)
        defaults.set(EffortScale.hundred.rawValue, forKey: UnitPrefs.effortScaleKey)
        defaults.set(false, forKey: PuffinExperiment.experimentalSleepStressKey)
        defaults.set(UnitSystem.metric.rawValue, forKey: UnitPrefs.systemKey)

        PersonalDefaults.apply(isPersonalBuild: true,
                               defaults: defaults,
                               locale: Locale(identifier: "en_US"))

        XCTAssertEqual(defaults.object(forKey: NativeRouteResolver.layoutKey) as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: NativeStyle.storageKey), NativeStyle.apple.rawValue)
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.effortScaleKey), EffortScale.whoop.rawValue)
        XCTAssertTrue(defaults.bool(forKey: PuffinExperiment.experimentalSleepStressKey))
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.systemKey), UnitSystem.imperial.rawValue)
        XCTAssertTrue(defaults.bool(forKey: BandPowerPolicy.defaultsKey))
        XCTAssertEqual(defaults.object(forKey: "noop.coachEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: UnitPrefs.liveActivityKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: UnitPrefs.syncLiveActivityKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: UnitPrefs.liftLiveActivityKey) as? Bool, false)
    }

    func testMetricLocalePinsMetricUnits() {
        let defaults = freshDefaults()
        PersonalDefaults.apply(isPersonalBuild: true,
                               defaults: defaults,
                               locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.systemKey), UnitSystem.metric.rawValue)
    }

    func testDeveloperStyleChoiceSurvivesALaterPin() {
        let defaults = freshDefaults()
        defaults.set(NativeStyle.whoop.rawValue, forKey: NativeStyle.storageKey)

        PersonalDefaults.apply(isPersonalBuild: true,
                               defaults: defaults,
                               locale: Locale(identifier: "en_US"))

        XCTAssertEqual(defaults.string(forKey: NativeStyle.storageKey), NativeStyle.whoop.rawValue)
        XCTAssertEqual(defaults.object(forKey: NativeRouteResolver.layoutKey) as? Bool, true)
    }

    func testUnitSystemFollowsLocaleMeasurementSystem() {
        XCTAssertEqual(PersonalDefaults.unitSystem(for: Locale(identifier: "en_US")), .imperial)
        XCTAssertEqual(PersonalDefaults.unitSystem(for: Locale(identifier: "fr_FR")), .metric)
    }
}
