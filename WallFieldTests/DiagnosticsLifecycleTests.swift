import XCTest
@testable import WallField

/// When the diagnostics screen is allowed to power hardware up.
///
/// The screen's job is the magnetometer. AR is an optional extra behind a switch
/// that most diagnostic runs never touch, and building it costs an `ARView`, a
/// RealityKit renderer and an `ARSession`. These tests pin the rule that opening
/// the screen builds none of that, because the failure mode is invisible in the
/// Simulator: there is no AR there, so an eager provider costs nothing until the
/// build reaches a real device.
@MainActor
final class DiagnosticsLifecycleTests: XCTestCase {

    /// Counts how many times the spatial provider was asked for.
    ///
    /// A class rather than a captured `var` so the count survives being read from
    /// an escaping closure without the capture semantics being part of the test.
    private final class BuildCounter {
        var count = 0
    }

    private func makeModel(
        supportsAR: Bool,
        counter: BuildCounter,
        environment: SimulatedEnvironment,
        clock: any MonotonicClock
    ) -> DiagnosticsModel {
        DiagnosticsModel(
            fieldService: SimulatedMagneticFieldService(environment: environment, clock: clock),
            supportsAR: supportsAR,
            spatialProviderFactory: {
                counter.count += 1
                return SimulatedSpatialProvider(environment: environment, clock: clock)
            },
            capabilities: .simulated(),
            configuration: .default,
            isSimulated: true,
            clock: clock
        )
    }

    func testOpeningDiagnosticsBuildsNoSpatialProvider() {
        let clock = ManualClock()
        let environment = SimulatedEnvironment(clock: clock)
        let counter = BuildCounter()
        let model = makeModel(
            supportsAR: true, counter: counter, environment: environment, clock: clock
        )
        defer {
            model.stop()
            environment.stop()
        }

        model.start()

        XCTAssertTrue(model.isStreaming)
        XCTAssertEqual(counter.count, 0, "the AR stack was built merely by opening the screen")
        XCTAssertFalse(model.isARActive)
    }

    func testTheProviderIsBuiltOnceWhenARIsSwitchedOn() {
        let clock = ManualClock()
        let environment = SimulatedEnvironment(clock: clock)
        let counter = BuildCounter()
        let model = makeModel(
            supportsAR: true, counter: counter, environment: environment, clock: clock
        )
        defer {
            model.stop()
            environment.stop()
        }

        model.start()
        model.setARActive(true)
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(model.isARActive)

        // Off and on again reuses the provider: rebuilding it would throw away the
        // session, and with it any wall the user had already locked.
        model.setARActive(false)
        XCTAssertFalse(model.isARActive)
        model.setARActive(true)
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(model.isARActive)
    }

    func testARIsNeverStartedOnADeviceThatCannotRunIt() {
        let clock = ManualClock()
        let environment = SimulatedEnvironment(clock: clock)
        let counter = BuildCounter()
        let model = makeModel(
            supportsAR: false, counter: counter, environment: environment, clock: clock
        )
        defer {
            model.stop()
            environment.stop()
        }

        model.start()
        model.setARActive(true)

        XCTAssertFalse(model.supportsAR)
        XCTAssertFalse(model.isARActive)
        XCTAssertEqual(counter.count, 0)
    }
}
