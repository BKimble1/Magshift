import XCTest
@testable import WallField

/// Lifecycle rules for the magnetic-field services.
///
/// These are about *sequencing*, not arithmetic: the detector tests already
/// cover what happens to a sample once it arrives. What is checked here is the
/// contract `MagneticFieldProviding.start` states -- that starting while already
/// running replaces the stream rather than leaving two, or none.
@MainActor
final class SensorLifecycleTests: XCTestCase {

    func testRestartingLeavesTheReplacementStreamDelivering() async {
        let clock = ManualClock()
        let environment = SimulatedEnvironment(clock: clock)
        let service = SimulatedMagneticFieldService(environment: environment, clock: clock)
        defer {
            service.stop()
            environment.stop()
        }

        let first = service.start(preferredSampleRate: 50)
        let second = service.start(preferredSampleRate: 50)

        // The second `start` finishes the first stream, and that stream's
        // termination handler has to hop back to the main actor before it can
        // touch the service -- so it runs *after* the replacement is already in
        // place. A handler that stopped unconditionally would tear down the
        // stream that had just been started.
        var iterator = second.makeAsyncIterator()
        let sample = await iterator.next()

        XCTAssertNotNil(sample, "the stream returned by the second start was stopped by the first")
        XCTAssertTrue(service.isRunning)
        withExtendedLifetime(first) {}
    }

    func testStoppingFinishesTheStream() async {
        let clock = ManualClock()
        let environment = SimulatedEnvironment(clock: clock)
        let service = SimulatedMagneticFieldService(environment: environment, clock: clock)
        defer { environment.stop() }

        let stream = service.start(preferredSampleRate: 50)
        service.stop()

        XCTAssertFalse(service.isRunning)
        // The emit task is main-actor isolated and this test never suspended
        // between the start and the stop, so it cannot have produced anything.
        // The point of the loop is that it ends: a stream nobody finished would
        // hang here forever.
        var received = 0
        for await _ in stream { received += 1 }
        XCTAssertEqual(received, 0)
    }

    func testStopIsSafeWhenNothingWasStarted() {
        let clock = ManualClock()
        let environment = SimulatedEnvironment(clock: clock)
        let service = SimulatedMagneticFieldService(environment: environment, clock: clock)
        service.stop()
        service.stop()
        XCTAssertFalse(service.isRunning)
    }
}
