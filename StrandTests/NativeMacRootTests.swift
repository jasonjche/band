import XCTest
@testable import Strand

final class NativeMacRootTests: XCTestCase {

    func testSidebarSectionsAndTitles() {
        XCTAssertEqual(NativeMacSidebarSection.titles, ["Overview", "Health", "Band"])
        XCTAssertEqual(
            NativeMacSidebarSection.overview.items.map(\.title),
            ["Home", "Sleep", "Recovery", "Strain", "Stress Monitor", "Health Monitor", "Journal"]
        )
        XCTAssertEqual(
            NativeMacSidebarSection.health.items.map(\.title),
            ["Healthspan", "Trends", "Reports"]
        )
        XCTAssertEqual(
            NativeMacSidebarSection.band.items.map(\.title),
            ["Strap", "Data & Backup", "Profile", "Settings", "Notifications", "About"]
        )
        XCTAssertEqual(
            NativeMacSidebarSection.allCases.flatMap(\.items),
            NativeMacSidebarItem.allCases
        )
        XCTAssertEqual(NativeMacSidebarItem.titles.count, 16)
    }

    func testSidebarIconsAndRouteMapping() {
        XCTAssertEqual(NativeMacSidebarItem.home.icon, "house")
        XCTAssertEqual(NativeMacSidebarItem.sleep.scoreKind, .sleep)
        XCTAssertEqual(NativeMacSidebarItem.recovery.scoreKind, .recovery)
        XCTAssertEqual(NativeMacSidebarItem.strain.scoreKind, .strain)
        XCTAssertEqual(NativeMacSidebarItem.healthspan.healthItem, .healthspan)
        XCTAssertEqual(NativeMacSidebarItem.trends.healthItem, .trends)
        XCTAssertEqual(NativeMacSidebarItem.reports.healthItem, .reports)
        XCTAssertEqual(NativeMacSidebarItem.strap.moreItem, .strap)
        XCTAssertEqual(NativeMacSidebarItem.dataBackup.moreItem, .dataBackup)
        XCTAssertEqual(NativeMacSidebarItem.settings.moreItem, .settings)
        XCTAssertEqual(NativeMacSidebarItem.notifications.moreItem, .notifications)
        XCTAssertEqual(NativeMacSidebarItem.about.moreItem, .about)
        XCTAssertEqual(NativeMacSidebarItem.item(for: .devices), .strap)
        XCTAssertEqual(NativeMacSidebarItem.item(for: .trends), .trends)
        XCTAssertEqual(NativeMacSidebarItem.item(for: .journal), .journal)
        XCTAssertEqual(NativeMacSidebarItem.item(for: .alarms), .sleep)
        XCTAssertEqual(NativeMacSidebarItem.item(for: .coach), .home)
        XCTAssertEqual(NativeMacSidebarItem.item(for: .activeWorkout), .home)
    }

    func testGoMenuShortcuts() {
        XCTAssertEqual(NativeMacCommand.sidebarShortcuts.map(\.title), [
            "Home", "Health", "Trends", "Reports", "Journal"
        ])
        XCTAssertEqual(NativeMacCommand.sidebarShortcuts.map(\.item), [
            .home, .healthspan, .trends, .reports, .journal
        ])
        XCTAssertEqual(NativeMacCommand.sidebarShortcuts.map { String($0.key) }, [
            "1", "2", "3", "4", "5"
        ])
    }

    func testWindowLayout() {
        XCTAssertEqual(NativeMacLayout.contentWidth, 860, accuracy: 0.5)
        XCTAssertEqual(NativeMacLayout.windowWidth, 1120, accuracy: 0.5)
        XCTAssertEqual(NativeMacLayout.windowHeight, 780, accuracy: 0.5)
        XCTAssertEqual(NativeMacLayout.minWidth, 820, accuracy: 0.5)
        XCTAssertEqual(NativeMacLayout.minHeight, 560, accuracy: 0.5)
    }

    func testXCTestHostGating() {
        XCTAssertTrue(NativeMacHost.isUnitTestProcess)
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
    }

    func testStrandAppKeepsTheLightweightTestHost() throws {
        let src = try String(contentsOfFile: Self.strandAppPath, encoding: .utf8)
        XCTAssertTrue(src.contains("NativeMacHost.isUnitTestProcess"))
        XCTAssertTrue(src.contains("Band test host"))
        XCTAssertTrue(src.contains("NativeMacRootView()"))
        XCTAssertTrue(src.contains("PersonalDefaults.apply()"))
        XCTAssertTrue(src.contains("PuffinExperiment.migrateContinuousHrvOvernightDefault()"))
        XCTAssertTrue(src.contains("NativeMacLayout.windowWidth"))
        XCTAssertTrue(src.contains("NativeMacLayout.windowHeight"))
        XCTAssertTrue(src.contains(".defaultSize("))
        let host = try String(contentsOfFile: Self.rootViewPath, encoding: .utf8)
        XCTAssertTrue(host.contains("NSClassFromString(\"XCTestCase\")"))
    }

    func testDetailStackRegistersNativeDestinations() throws {
        let src = try String(contentsOfFile: Self.rootViewPath, encoding: .utf8)
        XCTAssertTrue(src.contains(".tabRouteDestinations()"))
        XCTAssertTrue(src.contains("NativeHealthItem.self"))
        XCTAssertTrue(src.contains("NativeMoreItem.self"))
        XCTAssertTrue(src.contains("NativeHeartRateRoute.self"))
        XCTAssertTrue(src.contains("NativeJournalImpactRoute.self"))
        XCTAssertTrue(src.contains("nativeStyleBridge()"))
        XCTAssertTrue(src.contains("nativeNavigationPath"))
        XCTAssertTrue(src.contains("nativeContinuityStack()"))
        XCTAssertTrue(src.contains("keyboardShortcut(\"r\", modifiers: .command)"))
        XCTAssertTrue(src.contains("keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertTrue(src.contains("NativeMacCommands"))
    }

    func testMacHomeDateStepperOpensTheCalendar() throws {
        let src = try String(contentsOfFile: Self.homeViewPath, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(
            src.components(separatedBy: "onTitleTap: { showingCalendar = true }").count - 1,
            2
        )
        XCTAssertTrue(src.contains(".sheet(isPresented: $showingCalendar)"))
    }

    private static var strandAppPath: String {
        root.appendingPathComponent("Strand/App/StrandApp.swift").path
    }

    private static var rootViewPath: String {
        root.appendingPathComponent("Strand/Native/NativeMacRootView.swift").path
    }

    private static var homeViewPath: String {
        root.appendingPathComponent("Strand/Native/NativeHomeView.swift").path
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
