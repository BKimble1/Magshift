import XCTest
@testable import WallField

/// The note the app leaves before touching hardware the Simulator does not have.
///
/// What cannot be tested here is the case the mechanism exists for: a note
/// surviving an actual crash. A test process that crashes fails the suite rather
/// than reporting anything, so the crash is staged as far as it can be -- a note
/// is written and then read back as a later launch would read it -- and the rest
/// of these tests pin the property that makes it trustworthy, which is that
/// *nothing except a crash* leaves one behind.
@MainActor
final class HardwarePhaseRecorderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HardwarePhaseRecorder.erase()
    }

    override func tearDown() {
        HardwarePhaseRecorder.erase()
        super.tearDown()
    }

    func testANoteSurvivesToBeReadBackLikeALaterLaunchWouldReadIt() {
        HardwarePhaseRecorder.recordUnfinished(.startingCamera)

        XCTAssertEqual(HardwarePhaseRecorder.takeUnfinishedPhase(), .startingCamera)
    }

    func testReadingTheNoteConsumesIt() {
        HardwarePhaseRecorder.recordUnfinished(.startingMagnetometer)

        XCTAssertNotNil(HardwarePhaseRecorder.takeUnfinishedPhase())
        // One crash is reported once. A note that survived being read would put
        // the same card on Home at every launch from then on.
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testWorkThatReturnsLeavesNothingBehind() {
        let result = HardwarePhaseRecorder.attempting(.preparingScan) { 42 }

        XCTAssertEqual(result, 42)
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testWorkThatThrowsLeavesNothingBehind() {
        struct Failure: Error {}

        // The return type is stated because nothing else can supply it: both
        // `attempting` and `XCTAssertThrowsError` are generic, and a closure body
        // that only throws gives the compiler nothing to infer from.
        XCTAssertThrowsError(
            try HardwarePhaseRecorder.attempting(.preparingDiagnostics) { () -> Int in
                throw Failure()
            }
        )
        // A thrown error is a failure the app handles and reports itself, so it
        // must not also be reported as a crash at the next launch.
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testNothingIsReportedWhenNothingWasAttempted() {
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
    }

    func testEraseIsSafeWhenThereIsNoNote() {
        HardwarePhaseRecorder.erase()
        HardwarePhaseRecorder.erase()
        XCTAssertNil(HardwarePhaseRecorder.takeUnfinishedPhase())
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
