import XCTest
@testable import WallField

/// The note the app keeps while it is on a screen that drives hardware the
/// Simulator does not have.
///
/// What cannot be tested here is the case the mechanism exists for: a note
/// surviving an actual crash. A test process that crashes fails the suite rather
/// than reporting anything, so the crash is staged as far as it can be -- a note
/// is left and then read back the way a later launch reads it -- and the rest of
/// these tests pin the property that makes it trustworthy, which is that leaving
/// a screen under the app's own power always erases the note.
@MainActor
final class HardwarePhaseRecorderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HardwarePhaseRecorder.leave()
    }

    override func tearDown() {
        HardwarePhaseRecorder.leave()
        super.tearDown()
    }

    func testANoteSurvivesToBeReadBackLikeALaterLaunchWouldReadIt() {
        HardwarePhaseRecorder.enter(.onDiagnosticsScreen)

        // No `leave`: this is what being killed on that screen looks like.
        XCTAssertEqual(HardwarePhaseRecorder.takeUnfinishedPhase(), .onDiagnosticsScreen)
    }

    func testTheNoteFollowsTheAppFromScreenToHardware() {
        HardwarePhaseRecorder.enter(.onScanScreen)
        HardwarePhaseRecorder.enter(.startingCamera)

        // The narrower phase wins, because it is the more useful thing to be
        // told when that is where the app stopped.
        XCTAssertEqual(HardwarePhaseRecorder.takeUnfinishedPhase(), .startingCamera)
    }

    func testLeavingAScreenErasesTheNote() {
        HardwarePhaseRecorder.enter(.onScanScreen)
        HardwarePhaseRecorder.leave()

        // Closing the app from the app switcher goes through `leave`, so a
        // deliberate exit is never reported at the next launch as a crash.
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testReadingTheNoteConsumesIt() {
        HardwarePhaseRecorder.enter(.startingMagnetometer)

        XCTAssertNotNil(HardwarePhaseRecorder.takeUnfinishedPhase())
        // One crash is reported once. A note that survived being read would put
        // the same card on Home at every launch from then on.
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testDuringRestoresThePhaseItInterrupted() {
        HardwarePhaseRecorder.enter(.onDiagnosticsScreen)

        let result = HardwarePhaseRecorder.during(.startingCamera) { 42 }

        XCTAssertEqual(result, 42)
        // Back on the screen, not back to nothing: the app is still there.
        XCTAssertEqual(HardwarePhaseRecorder.takeUnfinishedPhase(), .onDiagnosticsScreen)
    }

    func testDuringRestoresThePhaseEvenWhenTheWorkThrows() {
        struct Failure: Error {}
        HardwarePhaseRecorder.enter(.onDiagnosticsScreen)

        // The return type is stated because nothing else can supply it: both
        // `during` and `XCTAssertThrowsError` are generic, and a closure body
        // that only throws gives the compiler nothing to infer from.
        XCTAssertThrowsError(
            try HardwarePhaseRecorder.during(.startingCamera) { () -> Int in throw Failure() }
        )

        // A thrown error is a failure the app handles and reports itself, so it
        // must not leave the app looking as though it died in that call.
        XCTAssertEqual(HardwarePhaseRecorder.takeUnfinishedPhase(), .onDiagnosticsScreen)
    }

    func testDuringWithNoScreenBehindItLeavesNothing() {
        HardwarePhaseRecorder.during(.startingMagnetometer) {}

        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testNothingIsReportedWhenNothingWasAttempted() {
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testLeavingIsSafeWhenThereIsNoNote() {
        HardwarePhaseRecorder.leave()
        HardwarePhaseRecorder.leave()
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testEveryPhaseNameFitsTheFixedWidthSlot() {
        for phase in HardwarePhase.allCases {
            // The slot is rewritten in place rather than replaced, so a name that
            // did not fit would be truncated and read back as no phase at all.
            XCTAssertLessThan(
                phase.rawValue.utf8.count,
                HardwarePhaseRecorder.recordSize,
                "\(phase.rawValue) does not fit the record"
            )
        }
    }

    func testEveryPhaseSurvivesTheRoundTripAndSaysSomething() {
        for phase in HardwarePhase.allCases {
            HardwarePhaseRecorder.recordUnfinished(phase)
            XCTAssertEqual(HardwarePhaseRecorder.takeUnfinishedPhase(), phase, phase.rawValue)
            XCTAssertFalse(
                phase.activityDescription.isEmpty,
                "\(phase.rawValue) is shown to the user and needs a description"
            )
        }
    }
}
