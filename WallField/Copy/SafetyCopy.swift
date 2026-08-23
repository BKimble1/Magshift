import Foundation

/// Every safety and limitation string the app can display.
///
/// Centralising this copy is a product requirement, not a convenience: the same
/// wording has to appear in onboarding, on the scan screen, on every saved
/// result, in exports and in App Review notes, and it must be reviewable in one
/// place before release.
///
/// Rules this file enforces by construction (see `Docs/SAFETY_AND_LIMITATIONS.md`):
///
/// * No string describes a measurement as a wire, live wire, screw, stud, pipe
///   or cable. A measured feature is always a *magnetic anomaly*.
/// * No string presents any state as safe, clear or cleared to drill.
/// * The absence of an anomaly is always paired with an explicit statement that
///   absence is not evidence of safety.
enum SafetyCopy {

    // MARK: - The canonical statement

    /// The single paragraph that must appear prominently in onboarding, on the
    /// scan screen (via the safety sheet), on saved results, in exports and in
    /// App Review notes.
    static let canonicalStatement = """
        \(Branding.productName) measures local magnetic-field changes using the iPhone's sensors. \
        It cannot identify every hidden object, determine whether wiring is present or energized, \
        measure object depth, or confirm that a location is safe to drill. Use certified detection \
        equipment and appropriate professional guidance before drilling.
        """

    /// Short form used where vertical space is tight, such as the scan HUD.
    static let compactStatement =
        "Experimental measurement aid. It cannot confirm that any location is safe to drill."

    /// The acknowledgement the user must actively accept before first use.
    static let acknowledgementStatement = """
        I understand that \(Branding.productName) only visualizes magnetic-field changes. \
        It cannot identify every hidden object or confirm that any location is safe to drill.
        """

    /// Version of the acknowledgement text. Increment whenever
    /// `acknowledgementStatement` changes materially so that existing users are
    /// asked to read and accept the revised wording again.
    static let acknowledgementVersion = 1

    // MARK: - Neutral / low reading

    /// Shown instead of any "clear" or "safe" state. Never render a green
    /// success treatment for this.
    static let noAnomalyHeadline = "No strong anomaly measured"

    /// Always displayed immediately beneath `noAnomalyHeadline`.
    static let noAnomalySubtitle = "This does not mean the area is safe to drill."

    // MARK: - What the app measures

    static let whatItMeasures = """
        Your iPhone contains a magnetometer that measures the magnetic field at the phone itself. \
        \(Branding.productName) records that field while you move the phone across a wall, and marks \
        places where the field changes more than the surrounding noise can explain.
        """

    static let whatItCannotDo = """
        \(Branding.productName) does not image through drywall. It has no way to see an object, \
        measure how deep something is, or tell you what caused a reading. A magnetic change can come \
        from screws, nails, ferrous framing, pipes, appliances, speakers, chargers, a magnetic case, \
        a MagSafe accessory, the phone itself, or unrelated interference nearby.
        """

    static let whyReadingsGetDistorted = """
        Magnets near the phone overwhelm the sensor. A MagSafe wallet, a magnetic mount, a magnetic \
        case, a nearby speaker, a charger or a metal tool can all produce large readings that have \
        nothing to do with the wall. Remove magnetic accessories and move loose metal away before \
        you scan.
        """

    static let whyMaterialsMatter = """
        Many wall materials are not magnetic and produce no useful signal at all. A quiet reading \
        across a whole wall may simply mean there is nothing magnetic close enough to the surface \
        for the sensor to register.
        """

    static let aboutWiring = """
        A wire may produce little or no detectable field, depending on how much current flows, how \
        the conductors are arranged, how far away it is, how it is oriented, and whether it is \
        shielded. A wire that is not carrying current produces no current-related magnetic field at \
        all. \(Branding.productName) never identifies a reading as wiring and never reports whether \
        a circuit is energized.
        """

    static let absenceIsNotEvidence = """
        A missing anomaly is never evidence that a location is clear. \(Branding.productName) can \
        only report what it measured at the phone, and there are many objects it cannot measure.
        """

    static let howARMappingWorks = """
        The camera and ARKit build a model of the room and recognise the flat vertical surface in \
        front of you. You pick one wall and lock it, so readings stay attached to that surface \
        instead of drifting between walls. Each accepted reading is stored as a position on that \
        locked wall.
        """

    static let howToScan = """
        Hold the phone flat against the direction you are scanning, keep it a consistent distance \
        from the wall, and move slowly and steadily -- roughly a hand's width per second. Cover the \
        area in overlapping passes. A second pass over the same region is what turns an unconfirmed \
        reading into a repeated one.
        """

    // MARK: - Persistent safety guidance

    static let beforeYouDrillTitle = "Before you drill"

    static let beforeYouDrillPoints: [String] = [
        "Use a certified wall scanner rated for the job.",
        "De-energize the relevant circuits at the panel and verify they are de-energized with appropriate equipment.",
        "Check building plans and follow local codes.",
        "Consult a qualified professional -- an electrician, plumber or contractor -- when you are unsure.",
        "Never treat a \(Branding.productName) result as clearance to drill, cut or fasten.",
    ]

    /// Rendered on the "what this app will never ask you to do" section.
    static let neverDoThis = """
        \(Branding.productName) will never ask you to open electrical equipment, expose conductors, \
        or test the app against energized wiring. Do not attempt to validate readings that way.
        """

    // MARK: - Preparation checklist

    static let preparationChecklist: [String] = [
        "Remove MagSafe wallets, magnetic mounts, magnetic cases and any accessory with a magnet in it.",
        "Move chargers, speakers, power tools and loose metal away from the area when you can.",
        "Keep the phone in one consistent orientation for the whole scan.",
        "Make sure the wall is well lit so the camera can track it.",
        "Do not use this scan to decide where it is acceptable to drill.",
    ]

    // MARK: - Terminology

    /// The only label the app ever applies to a detected feature.
    static let anomalyLabel = "Magnetic anomaly"

    /// Legend heading for the AR heat map. Deliberately describes the
    /// measurement, never an object type.
    static let legendTitle = "Measured magnetic change"

    static let unconfirmedExplanation =
        "Seen on a single pass. A large reading on one pass is still unconfirmed."

    static let repeatedExplanation =
        "Measured again in the same place on a later pass, with acceptable data quality both times."

    static let confidenceMeaning = """
        Confidence describes how sure \(Branding.productName) is that a repeatable magnetic anomaly \
        was measured at approximately that spot on the wall. It says nothing about what caused the \
        anomaly, how deep it is, or whether the area is safe to work on.
        """

    // MARK: - Export headers

    /// Prepended to every exported file so the limitation travels with the data.
    static let exportHeader = """
        \(Branding.productName) \(Branding.appVersion) -- experimental magnetic-field measurements.
        \(canonicalStatement)
        """
}
