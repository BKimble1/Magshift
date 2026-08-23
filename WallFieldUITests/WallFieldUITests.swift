import XCTest

/// UI tests driven entirely by simulated data.
///
/// ARKit and the magnetometer do not exist in the Simulator, so these tests run
/// the app with `-WallFieldDemoMode`, which substitutes the deterministic
/// `SimulatedEnvironment` for both. Everything else -- the state machine,
/// calibration, timestamp matching, quality gating, clustering, persistence and
/// export -- is the shipping code path.
///
/// `-WallFieldResetState` puts each test back at first launch and gives it its
/// own storage container, so tests cannot see or destroy each other's scans.
final class WallFieldUITests: XCTestCase {

    /// The simulated sweep crosses three hidden sources in about four seconds,
    /// so five is a comfortable margin for one pass.
    private let passDuration: TimeInterval = 6

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-WallFieldDemoMode", "-WallFieldResetState"] + extraArguments
        app.launch()
        return app
    }

    // MARK: - Onboarding

    func testFirstLaunchRequiresAnExplicitSafetyAcknowledgement() {
        let app = launch()

        let continueButton = app.buttons[A11yID.onboardingContinue]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10),
                      "onboarding should be presented on first launch")

        advanceToAcknowledgement(app)

        let accept = app.buttons[A11yID.onboardingAccept]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        XCTAssertFalse(accept.isEnabled,
                       "the app must not be enterable without accepting the limitation")

        app.switches[A11yID.acknowledgeToggle].tap()
        XCTAssertTrue(accept.isEnabled)
        accept.tap()

        XCTAssertTrue(app.buttons[A11yID.newScan].waitForExistence(timeout: 10))
    }

    func testOnboardingIsNotShownAgainAfterAcceptance() {
        let app = launch()
        completeOnboarding(app)
        XCTAssertTrue(app.buttons[A11yID.newScan].waitForExistence(timeout: 10))

        // Relaunch without resetting state.
        app.terminate()
        app.launchArguments = ["-WallFieldDemoMode"]
        app.launch()
        XCTAssertTrue(app.buttons[A11yID.newScan].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[A11yID.onboardingContinue].exists)
    }

    func testSimulatedDataIsAlwaysLabelled() {
        let app = launch()
        completeOnboarding(app)
        XCTAssertTrue(app.staticTexts[A11yID.simulatedBanner].waitForExistence(timeout: 5),
                      "a screen driven by simulated data must say so")
    }

    // MARK: - Permissions

    func testCameraDeniedIsExplainedWithARouteToSettings() {
        let app = launch(extraArguments: ["-WallFieldSimulateCameraDenied"])
        completeOnboarding(app)

        XCTAssertTrue(app.staticTexts["Camera access is off"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons[A11yID.newScan].exists,
                       "a scan must not be offered when it cannot run")
    }

    // MARK: - Safety page

    func testSafetyPageIsReachableFromHome() {
        let app = launch()
        completeOnboarding(app)

        // The reminder bar under the primary action opens the safety page.
        let banner = app.buttons[A11yID.safetyBanner]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        XCTAssertTrue(app.staticTexts[SafetyText.noAnomalySubtitle].waitForExistence(timeout: 5),
                      "the safety page must state that a quiet reading is not an all-clear")
        app.buttons[A11yID.safetyClose].tap()
    }

    func testSafetyPageIsReachableFromSettings() {
        let app = launch()
        completeOnboarding(app)
        app.buttons[A11yID.settings].tap()
        let safetyRow = app.buttons["Safety & limitations"]
        XCTAssertTrue(safetyRow.waitForExistence(timeout: 5))
        safetyRow.tap()
        XCTAssertTrue(app.staticTexts[SafetyText.noAnomalySubtitle].waitForExistence(timeout: 5))
    }

    // MARK: - A whole scan

    func testCompleteScanFlowProducesSavesAndDeletesAScan() {
        let app = launch()
        completeOnboarding(app)

        // New scan -> preparation checklist.
        app.buttons[A11yID.newScan].tap()
        let startMapping = app.buttons[A11yID.prepContinue]
        XCTAssertTrue(startMapping.waitForExistence(timeout: 10))
        startMapping.tap()

        // Map and lock the wall.
        let lockWall = app.buttons[A11yID.lockWall]
        XCTAssertTrue(lockWall.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntilEnabled(lockWall, timeout: 15))
        lockWall.tap()

        // Calibrate.
        let calibrate = app.buttons[A11yID.calibrate]
        XCTAssertTrue(calibrate.waitForExistence(timeout: 10))
        calibrate.tap()

        // Scan.
        let startScan = app.buttons[A11yID.startScan]
        XCTAssertTrue(startScan.waitForExistence(timeout: 25),
                      "calibration did not complete")
        startScan.tap()

        // The sweep crosses hidden sources; marks should appear.
        let clusterCount = app.staticTexts[A11yID.clusterCount]
        XCTAssertTrue(clusterCount.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil(timeout: passDuration + 8) { (Int(clusterCount.label) ?? 0) > 0 },
            "the simulated sweep produced no magnetic anomalies"
        )

        // Pause and resume.
        app.buttons[A11yID.pause].tap()
        let resume = app.buttons[A11yID.resume]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.buttons[A11yID.pause].waitForExistence(timeout: 5))

        // A second pass over the same region.
        let firstPassCount = Int(clusterCount.label) ?? 0
        app.buttons[A11yID.newPass].tap()
        _ = waitUntil(timeout: passDuration + 6) { (Int(clusterCount.label) ?? 0) >= firstPassCount }

        // Finish and review.
        app.buttons[A11yID.finish].tap()
        let save = app.buttons[A11yID.save]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[A11yID.export].exists, "export must be offered before saving")

        let nameField = app.textFields[A11yID.reviewName]
        XCTAssertTrue(nameField.exists)
        nameField.tap()
        nameField.typeText(" west")

        save.tap()

        // Back on Home, the saved scan is listed.
        XCTAssertTrue(app.buttons[A11yID.newScan].waitForExistence(timeout: 15))
        let history = app.buttons[A11yID.allScans]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()

        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        // Detail offers export, and deletion asks first.
        XCTAssertTrue(app.buttons[A11yID.export].waitForExistence(timeout: 10))
        app.buttons[A11yID.deleteScan].firstMatch.tap()
        let confirm = app.buttons[A11yID.confirmDelete].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "deleting must ask for confirmation")
        confirm.tap()
    }

    func testUndoAndResetAreOfferedAndResetConfirms() {
        let app = launch()
        completeOnboarding(app)
        startScanning(app)

        let clusterCount = app.staticTexts[A11yID.clusterCount]
        XCTAssertTrue(
            waitUntil(timeout: passDuration + 8) { (Int(clusterCount.label) ?? 0) > 0 },
            "no marks to undo"
        )

        let before = Int(clusterCount.label) ?? 0
        app.buttons[A11yID.undo].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (Int(clusterCount.label) ?? 0) < before })

        app.buttons[A11yID.reset].tap()
        let confirmReset = app.buttons["Remove all marks"]
        XCTAssertTrue(confirmReset.waitForExistence(timeout: 5),
                      "removing every mark must ask first")
        confirmReset.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { clusterCount.label == "0" })
    }

    func testSafetyInformationIsReachableWhileScanning() {
        let app = launch()
        completeOnboarding(app)
        startScanning(app)

        app.buttons[A11yID.scannerSafety].tap()
        XCTAssertTrue(app.staticTexts[SafetyText.noAnomalySubtitle].waitForExistence(timeout: 5))
        app.buttons[A11yID.safetyClose].tap()
        XCTAssertTrue(app.buttons[A11yID.finish].waitForExistence(timeout: 5))
    }

    func testHistoryIsEmptyBeforeAnythingIsSaved() {
        let app = launch()
        completeOnboarding(app)
        XCTAssertTrue(app.staticTexts["Nothing saved yet. Finish a scan and choose Save to keep it here."]
            .waitForExistence(timeout: 10))
    }

    func testDiagnosticsRecordsAndOffersExport() {
        let app = launch()
        completeOnboarding(app)
        app.buttons[A11yID.diagnostics].tap()

        let start = app.buttons[A11yID.diagnosticsStart]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilEnabled(start, timeout: 10))
        start.tap()

        let stop = app.buttons[A11yID.diagnosticsStop]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        pause(3)   // record a few seconds of the simulated stream
        stop.tap()

        XCTAssertTrue(app.buttons[A11yID.diagnosticsExport].waitForExistence(timeout: 10))
    }

    // MARK: - Helpers

    private func advanceToAcknowledgement(_ app: XCUIApplication) {
        let continueButton = app.buttons[A11yID.onboardingContinue]
        var guardCounter = 0
        while continueButton.exists, guardCounter < 12 {
            continueButton.tap()
            guardCounter += 1
        }
    }

    /// Accepts the safety statement and waits for Home.
    ///
    /// Waits for the Settings toolbar button rather than the primary action,
    /// because Home legitimately hides "New wall scan" when the device cannot
    /// run one -- which is exactly what the permission test needs to observe.
    private func completeOnboarding(_ app: XCUIApplication) {
        guard app.buttons[A11yID.onboardingContinue].waitForExistence(timeout: 15) else { return }
        advanceToAcknowledgement(app)
        let accept = app.buttons[A11yID.onboardingAccept]
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        app.switches[A11yID.acknowledgeToggle].tap()
        accept.tap()
        XCTAssertTrue(app.buttons[A11yID.settings].waitForExistence(timeout: 15),
                      "the app did not reach its home screen")
    }

    /// Drives the app to an actively scanning state.
    private func startScanning(_ app: XCUIApplication) {
        app.buttons[A11yID.newScan].tap()
        let startMapping = app.buttons[A11yID.prepContinue]
        XCTAssertTrue(startMapping.waitForExistence(timeout: 10))
        startMapping.tap()

        let lockWall = app.buttons[A11yID.lockWall]
        XCTAssertTrue(lockWall.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntilEnabled(lockWall, timeout: 15))
        lockWall.tap()

        app.buttons[A11yID.calibrate].tap()
        let startScan = app.buttons[A11yID.startScan]
        XCTAssertTrue(startScan.waitForExistence(timeout: 25))
        startScan.tap()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.25)
        }
        return condition()
    }

    /// Blocks the test runner without blocking the app under test.
    private func pause(_ seconds: TimeInterval) {
        let expectation = XCTestExpectation(description: "wait \(seconds) seconds")
        _ = XCTWaiter.wait(for: [expectation], timeout: seconds)
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { element.isEnabled }
    }
}

/// Accessibility identifiers, mirrored from `A11y` in the app target.
///
/// Duplicated deliberately: a UI test that imported the app's constants could
/// not catch an identifier being renamed out from under it, which is one of the
/// things these tests exist to catch.
private enum A11yID {
    static let onboardingContinue = "onboarding.continue"
    static let acknowledgeToggle = "onboarding.acknowledge.toggle"
    static let onboardingAccept = "onboarding.accept"

    static let newScan = "home.newScan"
    static let allScans = "home.history"
    static let diagnostics = "home.diagnostics"
    static let settings = "home.settings"
    static let simulatedBanner = "home.simulatedBanner"

    static let prepContinue = "prep.continue"
    static let lockWall = "scanner.lockWall"
    static let calibrate = "scanner.calibrate"
    static let startScan = "scanner.start"
    static let pause = "scanner.pause"
    static let resume = "scanner.resume"
    static let newPass = "scanner.newPass"
    static let undo = "scanner.undo"
    static let reset = "scanner.reset"
    static let finish = "scanner.finish"
    static let scannerSafety = "scanner.safety"
    static let clusterCount = "scanner.clusterCount"

    static let save = "review.save"
    static let export = "review.export"
    static let reviewName = "review.name"

    static let historyList = "history.list"
    static let deleteScan = "history.delete"
    static let confirmDelete = "history.confirmDelete"

    static let safetyPage = "safety.page"
    static let safetyBanner = "safety.banner"
    static let safetyClose = "safety.close"

    static let diagnosticsStart = "diagnostics.start"
    static let diagnosticsStop = "diagnostics.stop"
    static let diagnosticsExport = "diagnostics.export"
}

/// Copy the tests look for on screen, mirrored from `SafetyCopy`.
private enum SafetyText {
    static let noAnomalySubtitle = "This does not mean the area is safe to drill."
}
