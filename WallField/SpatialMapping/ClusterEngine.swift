import Foundation
import simd

/// Merges accepted candidates into spatial clusters on the locked wall.
///
/// # Why clustering is mandatory
///
/// The sensor delivers ~50 samples a second and the detector can emit a
/// candidate roughly three times a second while passing over one physical
/// feature. Rendering an entity per candidate would leak RealityKit entities,
/// destroy frame rate, and present a smear of markers as though many separate
/// things had been found. One physical region must produce one marker.
///
/// # What a cluster means
///
/// A cluster says: *accepted readings that deviated from baseline were measured
/// within `clusterRadius` of this point on this wall*. Its confidence rises to
/// `repeated` only when a later, separate pass measured the same place again.
/// A single pass stays `unconfirmed` however large its reading was, because one
/// pass cannot distinguish a real feature from a transient.
struct ClusterEngine {
    let configuration: DetectorConfiguration

    private(set) var clusters: [AnomalyCluster] = []
    private(set) var measurements: [StoredMeasurement] = []
    /// Accepted measurements that were not stored because the per-scan cap was
    /// reached. Reported in exports so a truncated file is never mistaken for a
    /// complete one.
    private(set) var droppedMeasurementCount = 0

    private var lastHapticByCluster: [UUID: TimeInterval] = [:]

    /// What happened when a candidate was offered.
    enum Outcome: Sendable, Equatable {
        case created(AnomalyCluster)
        case updated(AnomalyCluster)
        /// The candidate could not be placed. Includes the reason so the caller
        /// can count it in the scan's quality summary.
        case rejected(QualityReason)

        var cluster: AnomalyCluster? {
            switch self {
            case .created(let cluster), .updated(let cluster): return cluster
            case .rejected: return nil
            }
        }

        var isNewCluster: Bool {
            if case .created = self { return true }
            return false
        }
    }

    init(configuration: DetectorConfiguration) {
        self.configuration = configuration.sanitized()
    }

    // MARK: - Ingestion

    /// Adds an accepted candidate.
    ///
    /// The caller must have run `ScanQualityGate` first; this type assumes the
    /// gate passed and concerns itself only with spatial merging.
    mutating func add(
        candidate: AnomalyCandidate,
        match: SpatialMatch,
        passIndex: Int,
        scanStart: TimeInterval,
        date: Date
    ) -> Outcome {
        guard let hit = match.sample.hit else { return .rejected(.noWallIntersection) }

        let score = candidate.score(configuration: configuration)
        let existingIndex = nearestClusterIndex(to: hit.wallPoint)

        let cluster: AnomalyCluster
        let outcome: Outcome

        if let index = existingIndex {
            var updated = clusters[index]
            merge(&updated, candidate: candidate, score: score, hit: hit,
                  match: match, passIndex: passIndex, date: date)
            clusters[index] = updated
            cluster = updated
            outcome = .updated(updated)
        } else {
            guard clusters.count < configuration.maximumClusters else {
                return .rejected(.clusterLimitReached)
            }
            let created = AnomalyCluster.make(
                candidate: candidate,
                score: score,
                wallPoint: hit.wallPoint,
                anchorLocalPosition: Vector3(hit.anchorLocalPosition),
                worldPosition: Vector3(hit.worldPosition),
                raycastQuality: hit.quality,
                timingError: match.timingError,
                passIndex: passIndex,
                date: date
            )
            clusters.append(created)
            cluster = created
            outcome = .created(created)
        }

        recordMeasurement(
            candidate: candidate, score: score, hit: hit, match: match,
            passIndex: passIndex, scanStart: scanStart, clusterID: cluster.id
        )
        return outcome
    }

    private mutating func merge(
        _ cluster: inout AnomalyCluster,
        candidate: AnomalyCandidate,
        score: Double,
        hit: WallHit,
        match: SpatialMatch,
        passIndex: Int,
        date: Date
    ) {
        let weight = max(score, 0.0001)
        let newWeight = cluster.totalWeight + weight

        cluster.wallPoint = WallPoint(
            x: (cluster.wallPoint.x * cluster.totalWeight + hit.wallPoint.x * weight) / newWeight,
            y: (cluster.wallPoint.y * cluster.totalWeight + hit.wallPoint.y * weight) / newWeight
        )
        cluster.anchorLocalPosition = Vector3(
            (cluster.anchorLocalPosition.simd * Float(cluster.totalWeight)
                + hit.anchorLocalPosition * Float(weight)) / Float(newWeight)
        )
        cluster.worldPosition = Vector3(
            (cluster.worldPosition.simd * Float(cluster.totalWeight)
                + hit.worldPosition * Float(weight)) / Float(newWeight)
        )
        cluster.totalWeight = newWeight
        cluster.sampleCount += 1

        if abs(candidate.delta) > abs(cluster.peakDelta) {
            cluster.peakDelta = candidate.delta
            cluster.polarity = candidate.polarity
        }
        cluster.peakZScore = max(cluster.peakZScore, candidate.robustZScore)
        cluster.peakScore = max(cluster.peakScore, score)
        cluster.bestRaycastQuality = max(cluster.bestRaycastQuality, hit.quality)
        cluster.worstTimingError = max(cluster.worstTimingError, match.timingError)

        // A later pass only counts when it is genuinely later. Without this a
        // single continuous sweep, or a user tapping "new pass" mid-sweep, could
        // promote an unconfirmed reading to repeated without new evidence.
        let elapsedSinceLastContribution = candidate.timestamp - cluster.lastSeenMonotonic
        if !cluster.passIndices.contains(passIndex),
           elapsedSinceLastContribution >= configuration.repeatPassMinimumInterval {
            cluster.passIndices.append(passIndex)
        }

        cluster.lastSeen = date
        cluster.lastSeenMonotonic = candidate.timestamp
    }

    private mutating func recordMeasurement(
        candidate: AnomalyCandidate,
        score: Double,
        hit: WallHit,
        match: SpatialMatch,
        passIndex: Int,
        scanStart: TimeInterval,
        clusterID: UUID
    ) {
        guard measurements.count < configuration.maximumMeasurements else {
            droppedMeasurementCount += 1
            return
        }
        let sample = candidate.sample
        measurements.append(
            StoredMeasurement(
                id: candidate.id,
                timestamp: candidate.timestamp,
                elapsed: max(0, candidate.timestamp - scanStart),
                field: Vector3(x: Float(sample.x), y: Float(sample.y), z: Float(sample.z)),
                magnitude: sample.magnitude,
                delta: candidate.delta,
                robustZScore: candidate.robustZScore,
                score: score,
                gradient: candidate.gradient,
                persistence: candidate.persistence,
                accuracy: sample.accuracy,
                source: sample.source,
                timingError: match.timingError,
                trackingQuality: match.sample.tracking,
                raycastQuality: hit.quality,
                wallPoint: hit.wallPoint,
                worldPosition: Vector3(hit.worldPosition),
                wallDistance: hit.distanceFromCamera,
                cameraSpeed: match.sample.cameraSpeed,
                passIndex: passIndex,
                clusterID: clusterID
            )
        )
    }

    /// Index of the cluster within `clusterRadius` of `point`, choosing the
    /// nearest when several qualify.
    private func nearestClusterIndex(to point: WallPoint) -> Int? {
        var bestIndex: Int?
        var bestDistance = configuration.clusterRadius
        for (index, cluster) in clusters.enumerated() {
            let distance = cluster.wallPoint.distance(to: point)
            if distance <= bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: - Editing

    /// Removes the most recently created cluster and every measurement that fed
    /// it. Returns the removed cluster, or `nil` when there is nothing to undo.
    @discardableResult
    mutating func undoLastCluster() -> AnomalyCluster? {
        guard let removed = clusters.popLast() else { return nil }
        measurements.removeAll { $0.clusterID == removed.id }
        lastHapticByCluster[removed.id] = nil
        return removed
    }

    mutating func removeAll() {
        clusters.removeAll()
        measurements.removeAll()
        lastHapticByCluster.removeAll()
        droppedMeasurementCount = 0
    }

    // MARK: - Haptics

    /// Whether a haptic pulse should fire for this cluster now.
    ///
    /// One physical region must not vibrate continuously while the user holds
    /// the phone over it, so each cluster gets at most one pulse per
    /// `hapticRefractoryInterval`.
    mutating func shouldPulseHaptic(for clusterID: UUID, at timestamp: TimeInterval) -> Bool {
        if let last = lastHapticByCluster[clusterID],
           timestamp - last < configuration.hapticRefractoryInterval {
            return false
        }
        lastHapticByCluster[clusterID] = timestamp
        // The per-cluster table is bounded by the cluster cap, but prune removed
        // clusters so a long scan with many undos cannot accumulate entries.
        if lastHapticByCluster.count > configuration.maximumClusters {
            let live = Set(clusters.map(\.id))
            lastHapticByCluster = lastHapticByCluster.filter { live.contains($0.key) }
        }
        return true
    }

    // MARK: - Derived

    /// Bounds of the region covered by clusters, for the 2D summary map.
    var coveredBounds: WallBounds? {
        WallBounds.containing(clusters.map(\.wallPoint), padding: 0.12)
    }
}
