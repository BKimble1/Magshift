import XCTest
@testable import WallField

@MainActor
final class AppPreferencesTests: XCTestCase {

    private func scratch() -> UserDefaults {
        let name = "wallfield.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testFirstLaunchNeedsOnboarding() {
        let preferences = AppPreferences(defaults: scratch())
        XCTAssertTrue(preferences.needsOnboarding)
        XCTAssertTrue(preferences.needsSafetyAcknowledgement)
        XCTAssertFalse(preferences.isReacknowledging)
        XCTAssertNil(preferences.acknowledgedAt)
    }

    func testAcknowledgementIsRecordedWithItsVersionAndDate() {
        let defaults = scratch()
        let preferences = AppPreferences(defaults: defaults)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        preferences.recordSafetyAcknowledgement(at: when)

        XCTAssertFalse(preferences.needsOnboarding)
        XCTAssertFalse(preferences.needsSafetyAcknowledgement)
        XCTAssertEqual(preferences.acknowledgedVersion, SafetyCopy.acknowledgementVersion)
        XCTAssertEqual(preferences.acknowledgedAt, when)

        // It survives a relaunch.
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.needsOnboarding)
        XCTAssertEqual(reloaded.acknowledgedAt, when)
    }

    func testRevisedSafetyWordingRequiresANewAcknowledgement() {
        // Simulates a future build raising `SafetyCopy.acknowledgementVersion`:
        // a user who accepted version 1 has not accepted version 2.
        let defaults = scratch()
        defaults.set(SafetyCopy.acknowledgementVersion - 1, forKey: "wallfield.acknowledgement.version")
        defaults.set(true, forKey: "wallfield.onboarding.completed")

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.needsSafetyAcknowledgement)
        XCTAssertTrue(preferences.needsOnboarding)
        XCTAssertTrue(preferences.isReacknowledging,
                      "a returning user must be told the wording changed")
    }

    func testDefaults() {
        let preferences = AppPreferences(defaults: scratch())
        XCTAssertEqual(preferences.sensitivity, .medium)
        XCTAssertTrue(preferences.hapticsEnabled)
        XCTAssertFalse(preferences.soundEnabled, "sound must be off by default")
        XCTAssertTrue(preferences.wallOverlayVisible)
        XCTAssertEqual(preferences.detectorConfiguration, .preset(.medium))
    }

    func testPreferencesPersistWithoutAnExplicitSave() {
        let defaults = scratch()
        let preferences = AppPreferences(defaults: defaults)
        preferences.sensitivity = .high
        preferences.soundEnabled = true
        preferences.hapticsEnabled = false
        preferences.wallOverlayVisible = false

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.sensitivity, .high)
        XCTAssertTrue(reloaded.soundEnabled)
        XCTAssertFalse(reloaded.hapticsEnabled)
        XCTAssertFalse(reloaded.wallOverlayVisible)
        XCTAssertEqual(reloaded.detectorConfiguration, .preset(.high))
    }

    func testScanNamesAreNumberedFromTheCounter() {
        let preferences = AppPreferences(defaults: scratch())
        XCTAssertEqual(preferences.nextScanName(), "Wall scan 1")
        preferences.incrementScanCounter()
        XCTAssertEqual(preferences.nextScanName(), "Wall scan 2")
    }

    func testResetReturnsEverythingToFirstLaunch() {
        let defaults = scratch()
        let preferences = AppPreferences(defaults: defaults)
        preferences.recordSafetyAcknowledgement()
        preferences.sensitivity = .low
        preferences.incrementScanCounter()

        preferences.resetAll()
        XCTAssertTrue(preferences.needsOnboarding)
        XCTAssertEqual(preferences.sensitivity, .medium)
        XCTAssertEqual(preferences.scanCounter, 0)
        XCTAssertNil(preferences.acknowledgedAt)
        XCTAssertTrue(AppPreferences(defaults: defaults).needsOnboarding)
    }
}

final class SafetyCopyTests: XCTestCase {

    /// Every string the product can show a user, gathered in one place so the
    /// rules below cover all of it.
    private var allCopy: [String] {
        var strings = [
            SafetyCopy.canonicalStatement,
            SafetyCopy.compactStatement,
            SafetyCopy.acknowledgementStatement,
            SafetyCopy.noAnomalyHeadline,
            SafetyCopy.noAnomalySubtitle,
            SafetyCopy.whatItMeasures,
            SafetyCopy.whatItCannotDo,
            SafetyCopy.whyReadingsGetDistorted,
            SafetyCopy.whyMaterialsMatter,
            SafetyCopy.aboutWiring,
            SafetyCopy.absenceIsNotEvidence,
            SafetyCopy.howARMappingWorks,
            SafetyCopy.howToScan,
            SafetyCopy.neverDoThis,
            SafetyCopy.anomalyLabel,
            SafetyCopy.legendTitle,
            SafetyCopy.unconfirmedExplanation,
            SafetyCopy.repeatedExplanation,
            SafetyCopy.confidenceMeaning,
            SafetyCopy.exportHeader,
            Branding.productCategory,
            Branding.tagline,
        ]
        strings.append(contentsOf: SafetyCopy.beforeYouDrillPoints)
        strings.append(contentsOf: SafetyCopy.preparationChecklist)
        return strings
    }

    /// The same ban list `Tools/lint_claims.py` enforces over the whole
    /// repository, checked here too so it also runs wherever the tests run.
    ///
    // lint-allow-banned-phrase: begin -- this array *is* the ban list.
    private let bannedPhrases = [
        "x-ray", "xray", "see through the wall", "see through walls",
        "stud finder", "metal detector", "wire detector", "electrical detector",
        "professional-grade", "professional grade",
        "find hidden wires", "find live wires", "detects every", "detect every",
        "guaranteed", "know where it is safe",
    ]
    // lint-allow-banned-phrase: end

    func testNoCopyMakesABannedClaim() {
        for text in allCopy {
            let lower = text.lowercased()
            for phrase in bannedPhrases {
                XCTAssertFalse(lower.contains(phrase),
                               "copy contains the banned phrase \(phrase): \(text.prefix(80))")
            }
        }
    }

    // lint-allow-banned-phrase: begin -- this test asserts the rule, so it must
    // name the guarded phrase it is checking for.
    func testEveryMentionOfDrillingSafetyIsNegated() {
        let negations = ["not", "never", "cannot", "no ", "does not", "without"]
        let guardedPhrase = "safe to drill"
        for text in allCopy {
            let lower = text.lowercased()
            guard lower.contains(guardedPhrase) else { continue }
            for sentence in lower.split(whereSeparator: { ".!?".contains($0) })
            where sentence.contains(guardedPhrase) {
                XCTAssertTrue(
                    negations.contains { sentence.contains($0) },
                    "an unnegated claim about drilling safety: \(sentence)"
                )
            }
        }
    }

    func testTheCanonicalStatementSaysAllFourThings() {
        let statement = SafetyCopy.canonicalStatement.lowercased()
        XCTAssertTrue(statement.contains("cannot identify every hidden object"))
        XCTAssertTrue(statement.contains("energized"))
        XCTAssertTrue(statement.contains("depth"))
        XCTAssertTrue(statement.contains(guardedDrillingPhrase))
        XCTAssertTrue(statement.contains("certified"))
    }

    private let guardedDrillingPhrase = "safe to drill"
    // lint-allow-banned-phrase: end

    func testTheNoAnomalyStateIsNeverPresentedAsSafe() {
        XCTAssertEqual(SafetyCopy.noAnomalyHeadline, "No strong anomaly measured")
        XCTAssertTrue(SafetyCopy.noAnomalySubtitle.lowercased().contains("does not mean"))
        XCTAssertFalse(SafetyCopy.noAnomalyHeadline.lowercased().contains("clear"))
        XCTAssertFalse(SafetyCopy.noAnomalyHeadline.lowercased().contains("safe"))
    }

    func testTheOnlyLabelForAMeasurementIsMagneticAnomaly() {
        XCTAssertEqual(SafetyCopy.anomalyLabel, "Magnetic anomaly")
        XCTAssertEqual(Fixture.cluster().label, SafetyCopy.anomalyLabel)
        XCTAssertFalse(SafetyCopy.legendTitle.lowercased().contains("object"))
    }

    func testNothingIsEmpty() {
        for text in allCopy {
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertFalse(SafetyCopy.beforeYouDrillPoints.isEmpty)
        XCTAssertFalse(SafetyCopy.preparationChecklist.isEmpty)
    }

    func testSupportAndPrivacyLinksAreAbsentRatherThanPlaceholders() {
        // A dead link is worse than no link. Settings hides these rows until
        // real URLs exist; see Docs/APP_STORE_PREP.md.
        XCTAssertNil(Branding.supportURL)
        XCTAssertNil(Branding.privacyPolicyURL)
    }

    func testAlgorithmVersionAdvertisesItsProvisionalStatus() {
        XCTAssertTrue(AlgorithmVersion.isProvisional,
                      "remove the provisional flag only once thresholds are validated on hardware")
    }
}

@MainActor
final class SimulatedEnvironmentTests: XCTestCase {

    func testTheGeneratorIsReproducible() {
        var first = DeterministicRandom(seed: 99)
        var second = DeterministicRandom(seed: 99)
        let a = (0..<200).map { _ in first.gaussian() }
        let b = (0..<200).map { _ in second.gaussian() }
        XCTAssertEqual(a, b)
    }

    func testNoiseIsZeroMean() {
        var random = DeterministicRandom(seed: 5)
        let values = (0..<20_000).map { _ in random.gaussian() }
        let mean = values.reduce(0, +) / Double(values.count)
        XCTAssertEqual(mean, 0, accuracy: 0.05)
    }

    func testTheFieldRisesOverAHiddenSource() {
        let environment = SimulatedEnvironment()
        guard let source = SimulatedEnvironment.sources.first else {
            return XCTFail("the synthetic wall has no sources")
        }
        environment.moveCrosshair(to: WallPoint(x: 0.9, y: -0.7), elapsed: 1)
        let away = (0..<40).map { _ in environment.sampleMagnitude() }
        environment.moveCrosshair(to: source.point, elapsed: 1)
        let over = (0..<40).map { _ in environment.sampleMagnitude() }

        let awayMedian = RobustStatistics.median(away) ?? 0
        let overMedian = RobustStatistics.median(over) ?? 0
        XCTAssertGreaterThan(abs(overMedian - awayMedian), 5,
                             "the synthetic wall must produce a detectable change")
    }

    func testMovingOffTheWallRemovesTheSources() {
        let environment = SimulatedEnvironment()
        guard let source = SimulatedEnvironment.sources.first else {
            return XCTFail("the synthetic wall has no sources")
        }
        environment.moveCrosshair(to: source.point, elapsed: 1)
        let onWall = RobustStatistics.median((0..<40).map { _ in environment.sampleMagnitude() }) ?? 0
        environment.isOnWall = false
        let offWall = RobustStatistics.median((0..<40).map { _ in environment.sampleMagnitude() }) ?? 0
        XCTAssertEqual(offWall, SimulatedEnvironment.baselineMagnitude, accuracy: 1.5)
        XCTAssertNotEqual(onWall, offWall, accuracy: 0.001)
    }

    func testHoldingStillReportsSteadyMotion() {
        let environment = SimulatedEnvironment()
        environment.holdStill()
        XCTAssertTrue(environment.motionEnergy.isSteady)
        XCTAssertEqual(environment.speed, 0)
        environment.beginSweeping()
        XCTAssertFalse(environment.motionEnergy.isSteady)
    }

    func testTheVectorAlwaysHasTheRequestedMagnitude() {
        let environment = SimulatedEnvironment()
        for magnitude in [10.0, 48.0, 92.5] {
            let vector = environment.vector(forMagnitude: magnitude)
            let length = (vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
                .squareRoot()
            XCTAssertEqual(length, magnitude, accuracy: 1e-9)
        }
    }

    func testSimulatedModeIsOffUnlessExplicitlyRequested() {
        let defaults = UserDefaults(suiteName: "wallfield.tests.runtime") ?? .standard
        defaults.removePersistentDomain(forName: "wallfield.tests.runtime")
        XCTAssertEqual(RuntimeMode.resolve(arguments: [], defaults: defaults), .live)
        XCTAssertEqual(
            RuntimeMode.resolve(arguments: [RuntimeMode.demoLaunchArgument], defaults: defaults),
            .simulated
        )
    }
}

final class CapabilityBlockTests: XCTestCase {

    func testNoBlockWhenEverythingIsAvailable() {
        XCTAssertNil(CapabilityBlock.evaluate(.simulated(), runtimeMode: .live))
    }

    func testUnsupportedDeviceIsExplainedWithoutOfferingSettings() throws {
        let capabilities = DeviceCapabilities(
            supportsWorldTracking: false,
            supportsVerticalPlaneDetection: false,
            supportsSceneDepth: false,
            supportsSceneReconstruction: false,
            cameraAuthorization: .authorized
        )
        let block = try XCTUnwrap(CapabilityBlock.evaluate(capabilities, runtimeMode: .live))
        XCTAssertFalse(block.offersSettings)
        XCTAssertTrue(block.message.contains("ARKit"))
    }

    func testDeniedCameraOffersSettings() throws {
        var capabilities = DeviceCapabilities.simulated()
        capabilities.cameraAuthorization = .denied
        let block = try XCTUnwrap(CapabilityBlock.evaluate(capabilities, runtimeMode: .live))
        XCTAssertTrue(block.offersSettings)
    }

    func testRestrictedCameraDoesNotOfferSettings() throws {
        var capabilities = DeviceCapabilities.simulated()
        capabilities.cameraAuthorization = .restricted
        let block = try XCTUnwrap(CapabilityBlock.evaluate(capabilities, runtimeMode: .live))
        XCTAssertFalse(block.offersSettings, "there is nothing the user can change")
    }

    func testUndeterminedCameraIsNotABlock() {
        // The system prompt is presented when the scan starts, which is when the
        // reason for it is obvious.
        var capabilities = DeviceCapabilities.simulated()
        capabilities.cameraAuthorization = .notDetermined
        XCTAssertNil(CapabilityBlock.evaluate(capabilities, runtimeMode: .live))
    }

    func testSimulatedModeBypassesHardwareChecks() {
        let capabilities = DeviceCapabilities(
            supportsWorldTracking: false,
            supportsVerticalPlaneDetection: false,
            supportsSceneDepth: false,
            supportsSceneReconstruction: false,
            cameraAuthorization: .authorized
        )
        XCTAssertNil(CapabilityBlock.evaluate(capabilities, runtimeMode: .simulated))
    }

    /// Simulated mode bypasses hardware, not permission.
    ///
    /// `DeviceCapabilities.simulated()` reports `.authorized`, so a refusal can
    /// only have been set deliberately -- which is what
    /// `-WallFieldSimulateCameraDenied` does. `WallFieldUITests`
    /// `testCameraDeniedIsExplainedWithARouteToSettings` depends on this: it
    /// runs in simulated mode and expects the recovery card.
    func testSimulatedModeStillReportsADeliberatelyDeniedCamera() throws {
        var capabilities = DeviceCapabilities.simulated()
        capabilities.cameraAuthorization = .denied
        let block = try XCTUnwrap(CapabilityBlock.evaluate(capabilities, runtimeMode: .simulated))
        XCTAssertTrue(block.offersSettings)
    }

    func testLiveScanRequiresTrackingAndCamera() {
        XCTAssertTrue(DeviceCapabilities.simulated().canRunLiveScan)
        var denied = DeviceCapabilities.simulated()
        denied.cameraAuthorization = .denied
        XCTAssertFalse(denied.canRunLiveScan)
    }

    func testDeviceMetadataCarriesNoPersistentIdentifier() {
        let metadata = DeviceMetadata.current(capabilities: .simulated())
        XCTAssertFalse(metadata.model.isEmpty)
        XCTAssertEqual(metadata.systemName, "iOS")
        // A hardware model identifier is shared by every unit of that model. It
        // must never look like a per-device identifier.
        XCTAssertLessThan(metadata.model.count, 32)
        XCTAssertFalse(metadata.model.contains("-"))
    }
}
