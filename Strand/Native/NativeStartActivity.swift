import SwiftUI
import MapKit
import CoreLocation
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

/// WHOOP-style start screen: live HR circle, Track Route, Strain Target, Start Activity.
struct NativeStartActivityView: View {
    var sport: String
    var workouts: [WorkoutRow] = []
    var onStart: (_ trackRoute: Bool, _ strainTarget: Bool) -> Void

    @EnvironmentObject private var repo: Repository

    @State private var bpm: Int?
    @State private var samples: [NativeHourPoint] = []
    @State private var trackRoute: Bool
    @State private var strainTargetOn = false
    @State private var strainTarget: BandStrainTarget.Result?

    init(
        sport: String,
        workouts: [WorkoutRow] = [],
        onStart: @escaping (_ trackRoute: Bool, _ strainTarget: Bool) -> Void
    ) {
        self.sport = sport
        self.workouts = workouts
        self.onStart = onStart
        _trackRoute = State(initialValue: NativeLiveActivityLogic.defaultTrackRoute(sport))
    }

    private var showsTrackRoute: Bool { NativeLiveActivityLogic.showsTrackRoute(sport) }

    var body: some View {
        NativeStartActivityScreen(
            sport: sport,
            bpm: bpm,
            showsTrackRoute: showsTrackRoute,
            trackRoute: $trackRoute,
            strainTargetOn: $strainTargetOn,
            strainTarget: strainTarget,
            onStart: { onStart(trackRoute, strainTargetOn) }
        )
        .background { NativeLiveHRArm(bpm: $bpm, samples: $samples) }
        .task { strainTarget = resolveTarget() }
    }

    private func resolveTarget() -> BandStrainTarget.Result? {
        let today = NativeDayLogic.logicalToday()
        return NativeStrainTarget.resolve(
            viewingKey: today,
            todayKey: today,
            days: repo.days,
            sleeps: repo.sleeps,
            workouts: workouts,
            importedSleep: repo.importedSleep
        )
    }
}

struct NativeStartActivityScreen: View {
    var sport: String
    var bpm: Int?
    var showsTrackRoute: Bool
    @Binding var trackRoute: Bool
    @Binding var strainTargetOn: Bool
    var strainTarget: BandStrainTarget.Result?
    var onStart: () -> Void

    @Environment(\.nativeStyle) private var style

    var body: some View {
        ZStack {
            mapBackdrop
            VStack(spacing: 0) {
                if showsTrackRoute {
                    HStack {
                        Spacer()
                        NativeStartToggle(title: "Track Route", isOn: $trackRoute)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                Spacer(minLength: 12)
                NativeLiveHRCircle(bpm: bpm)
                Spacer(minLength: 12)
                VStack(spacing: 16) {
                    NativeStartToggle(
                        title: "Strain Target",
                        subtitle: strainTarget.map {
                            NativeStrainTarget.caption(result: $0, strain21: nil)
                        },
                        isOn: $strainTargetOn
                    )
                    .disabled(strainTarget == nil)
                    .opacity(strainTarget == nil ? 0.55 : 1)
                    Button("Start Activity", action: onStart)
                        .buttonStyle(.borderedProminent)
                        .tint(NativePaint.strain(style))
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .background(.ultraThinMaterial)
            }
        }
        .background(NativePageFill().ignoresSafeArea())
        .navigationTitle(sport)
        .modifier(NativeInlineTitle())
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: sportSymbol(sport))
                        .foregroundStyle(NativePaint.strain(style))
                    Text(sport.uppercased())
                        .font(.subheadline.weight(.semibold))
                        .tracking(0.6)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(sport)
            }
        }
    }

    @ViewBuilder private var mapBackdrop: some View {
        if showsTrackRoute {
            NativeStartMap()
                .ignoresSafeArea(edges: .bottom)
        } else {
            NativePageFill()
        }
    }
}

struct NativeLiveHRCircle: View {
    var bpm: Int?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let tint = NativePaint.strain(style)
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: 196, height: 196)
                .shadow(color: tint.opacity(0.35), radius: 24, y: 8)
            VStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(bpm.map { "\($0)" } ?? "—")
                    .font(NativePaint.number(64, style: style))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .padding(24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bpm.map { "Heart rate \($0) BPM" } ?? "Waiting for heart rate")
    }
}

private struct NativeStartToggle: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .textCase(style == .whoop ? .uppercase : nil)
                    .tracking(style == .whoop ? 0.4 : 0)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(NativePaint.strain(style))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct NativeStartMap: View {
    var body: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            NativeStartSwiftMap()
        } else {
            NativePageFill()
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct NativeStartSwiftMap: View {
    @StateObject private var location = NativeStartLocation()
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            if let coordinate = location.coordinate {
                Annotation("You", coordinate: coordinate) {
                    Circle()
                        .fill(NativeTokens.strain)
                        .frame(width: 10, height: 10)
                }
            }
        }
        .mapStyle(.standard)
        .disabled(true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { location.request() }
        .onDisappear { location.stop() }
        .onChangeCompat(of: coordinateKey) { _ in
            if let coordinate = location.coordinate {
                position = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
                ))
            }
        }
    }

    private var coordinateKey: String {
        guard let coordinate = location.coordinate else { return "" }
        return "\(coordinate.latitude),\(coordinate.longitude)"
    }
}

/// When the start-activity map may ask CoreLocation for a fix. Pure so the
/// one-shot / wanted-flag rule is testable without a location manager.
enum NativeStartLocationPolicy {
    /// The map is a backdrop pin, not a live track. One coarse fix is enough.
    static let stopsAfterFirstFix = true

    static func shouldRequestFix(wanted: Bool, authorized: Bool) -> Bool {
        wanted && authorized
    }
}

@MainActor
final class NativeStartLocation: NSObject, ObservableObject {
    @Published var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()
    /// True only while the start-activity map is on screen. Authorization can land
    /// after the user has left, and `onDisappear` does not run when the app is
    /// backgrounded; without this, `startUpdatingLocation` plus the app's
    /// `location` background mode kept GPS hot behind a map nobody could see.
    private var wanted = false
    #if canImport(UIKit) && os(iOS)
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    #endif

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        #if canImport(UIKit) && os(iOS)
        let nc = NotificationCenter.default
        backgroundObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.manager.stopUpdatingLocation() }
        }
        foregroundObserver = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestOneShotIfWanted() }
        }
        #endif
    }

    deinit {
        #if canImport(UIKit) && os(iOS)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        #endif
    }

    func request() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            requestOneShotIfWanted()
        default:
            break
        }
    }

    func stop() {
        wanted = false
        manager.stopUpdatingLocation()
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        return status == .authorizedAlways
        #endif
    }

    private func requestOneShotIfWanted() {
        guard NativeStartLocationPolicy.shouldRequestFix(
            wanted: wanted,
            authorized: Self.isAuthorized(manager.authorizationStatus)
        ) else { return }
        manager.requestLocation()
    }
}

extension NativeStartLocation: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestOneShotIfWanted()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
        if NativeStartLocationPolicy.stopsAfterFirstFix {
            manager.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
