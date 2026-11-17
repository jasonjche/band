import SwiftUI
import MapKit
import CoreLocation
import StrandDesign
import StrandAnalytics
import WhoopStore

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
                    .textCase(.uppercase)
                    .tracking(0.4)
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

@MainActor
final class NativeStartLocation: NSObject, ObservableObject {
    @Published var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension NativeStartLocation: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
