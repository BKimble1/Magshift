import SwiftUI

/// The stand-in for the camera feed when running on simulated data.
///
/// Drags move the crosshair across the synthetic wall, which really does change
/// what the simulated sensor reports, so the whole detection pipeline runs
/// exactly as it would on a device. Left alone, the crosshair sweeps back and
/// forth on its own, which is what lets a UI test drive a scan end to end
/// without gestures.
struct SimulatedWallCanvas: View {
    @Bindable var environment: SimulatedEnvironment
    var clusters: [AnomalyCluster]
    var lockedWall: LockedWall?

    private var bounds: WallBounds {
        WallBounds(
            minX: -SimulatedEnvironment.wallWidth / 2,
            minY: -SimulatedEnvironment.wallHeight / 2,
            maxX: SimulatedEnvironment.wallWidth / 2,
            maxY: SimulatedEnvironment.wallHeight / 2
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = WallMapLayout(bounds: bounds, size: proxy.size)
            ZStack {
                Color(uiColor: .systemGray5)

                Rectangle()
                    .fill(Palette.wallOverlay.opacity(lockedWall == nil ? 0.16 : 0.30))
                    .accessibilityHidden(true)

                WallMapView(
                    bounds: bounds,
                    clusters: clusters,
                    crosshair: environment.crosshair,
                    showsScale: false
                )
                .opacity(0.999)

                VStack {
                    Spacer()
                    Text(environment.isAutoSweeping
                        ? "Sweeping automatically. Drag to steer."
                        : "Drag to move the crosshair.")
                        .font(.caption2)
                        .padding(Theme.Spacing.tight)
                        .background(Theme.hudMaterial, in: Capsule())
                        .padding(.bottom, 190)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        environment.moveCrosshair(
                            to: layout.wallPoint(for: value.location),
                            elapsed: 1.0 / 60.0
                        )
                    }
            )
            .accessibilityIdentifier(A11y.scannerSimulatedCanvas)
            .accessibilityLabel("Simulated wall. Drag to move the crosshair.")
        }
    }
}
