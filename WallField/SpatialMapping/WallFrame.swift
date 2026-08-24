import Foundation
import simd

/// Convenience accessors for the columns of a 4x4 transform.
///
/// ARKit expresses an anchor's orientation as the basis vectors in columns 0-2
/// and its position in column 3. Naming them here keeps the geometry below
/// readable, and keeps the convention documented in one place rather than
/// re-derived at each use.
extension simd_float4x4 {
    /// Translation component.
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    /// Local Y axis in world space.
    ///
    /// For a vertical `ARPlaneAnchor` this is the plane normal, which is the only
    /// axis this app needs from an anchor transform.
    var yAxis: SIMD3<Float> { SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z) }
}

/// A fixed, right-handed 2D coordinate frame lying in the locked wall.
///
/// # Why this exists
///
/// ARKit gives a vertical `ARPlaneAnchor` whose local **+Y axis is the plane
/// normal**, with an arbitrary rotation about that normal. Using the anchor's
/// raw local X/Z as "wall coordinates" would therefore produce a 2D summary map
/// with an arbitrary, unpredictable orientation, and the orientation would shift
/// every time ARKit re-centred the anchor.
///
/// Instead a frame is captured **once**, when the user locks the wall:
///
/// * `normal` is the plane normal;
/// * `up` is world up projected into the plane, so "up" on the map is up on the
///   wall;
/// * `right` is `up x normal`, giving a right-handed basis in which
///   `right x up == normal`.
///
/// Because the frame is captured once and expressed in world space, wall
/// coordinates stay stable for the whole scan even as ARKit refines the anchor.
/// The trade-off is that a large ARKit relocalisation or world-origin change
/// invalidates the frame; the scan flow treats that as a scan-ending condition
/// rather than silently remapping old data. See `Docs/ARCHITECTURE.md`.
///
/// Units are metres throughout.
struct WallFrame: Codable, Sendable, Hashable {
    /// Frame origin in world space -- the anchor's position at lock time.
    var origin: Vector3
    /// Unit vector: +X of wall space, pointing right as seen by a viewer facing
    /// the wall.
    var right: Vector3
    /// Unit vector: +Y of wall space, pointing up.
    var up: Vector3
    /// Unit vector: the wall's outward normal, pointing away from the wall
    /// towards the viewer.
    var normal: Vector3

    /// World up. ARKit's world coordinate system is gravity-aligned with +Y up.
    static var worldUp: SIMD3<Float> { SIMD3<Float>(0, 1, 0) }

    /// Builds a frame from a vertical plane anchor's world transform.
    ///
    /// Returns `nil` when the plane is too close to horizontal for "up on the
    /// wall" to be meaningful; the caller must then refuse to lock that plane
    /// rather than inventing an orientation.
    static func make(anchorTransform: simd_float4x4, cameraPosition: SIMD3<Float>?) -> WallFrame? {
        let rawNormal = anchorTransform.yAxis
        let normalLength = simd_length(rawNormal)
        guard normalLength > 1e-5 else { return nil }
        var normal = rawNormal / normalLength

        // Orient the normal towards the camera so "right" is right from the
        // user's point of view rather than from behind the wall.
        if let cameraPosition {
            let toCamera = cameraPosition - anchorTransform.translation
            if simd_dot(normal, toCamera) < 0 {
                normal = -normal
            }
        }

        // Project world up into the plane.
        let projected = worldUp - simd_dot(worldUp, normal) * normal
        let projectedLength = simd_length(projected)
        // `projectedLength` is the sine of the angle between world up and the
        // plane normal, so this rejects a plane whose normal is within about 8.6
        // degrees of vertical -- that is, a surface lying close to horizontal,
        // where "up on the wall" has no meaningful direction. It is deliberately
        // permissive about tilt otherwise: a leaning wall is still a wall.
        guard projectedLength > 0.15 else { return nil }
        let up = projected / projectedLength

        let right = simd_normalize(simd_cross(up, normal))

        return WallFrame(
            origin: Vector3(anchorTransform.translation),
            right: Vector3(right),
            up: Vector3(up),
            normal: Vector3(normal)
        )
    }

    /// Projects a world position onto the wall's 2D coordinate system.
    func wallPoint(forWorldPosition position: SIMD3<Float>) -> WallPoint {
        let delta = position - origin.simd
        return WallPoint(
            x: Double(simd_dot(delta, right.simd)),
            y: Double(simd_dot(delta, up.simd))
        )
    }

    /// Signed distance of a world position from the wall plane, along the
    /// outward normal. Positive means in front of the wall.
    func normalDistance(forWorldPosition position: SIMD3<Float>) -> Double {
        Double(simd_dot(position - origin.simd, normal.simd))
    }

    /// Inverse of `wallPoint(forWorldPosition:)`.
    func worldPosition(forWallPoint point: WallPoint, normalOffset: Double = 0) -> SIMD3<Float> {
        origin.simd
            + right.simd * Float(point.x)
            + up.simd * Float(point.y)
            + normal.simd * Float(normalOffset)
    }

    /// True when the basis is orthonormal to within `tolerance`. Used by tests
    /// and by a debug assertion when a frame is decoded from disk.
    func isOrthonormal(tolerance: Float = 1e-3) -> Bool {
        let r = right.simd, u = up.simd, n = normal.simd
        let lengths = [simd_length(r), simd_length(u), simd_length(n)]
        guard lengths.allSatisfy({ abs($0 - 1) <= tolerance }) else { return false }
        let dots = [simd_dot(r, u), simd_dot(r, n), simd_dot(u, n)]
        guard dots.allSatisfy({ abs($0) <= tolerance }) else { return false }
        return simd_length(simd_cross(r, u) - n) <= tolerance * 4
    }
}

/// Metadata describing the wall a scan was performed against.
struct WallMetadata: Codable, Sendable, Hashable {
    /// The ARKit plane anchor identifier this scan was locked to. Meaningful
    /// only within the session that produced it.
    var anchorIdentifier: UUID
    /// The frame captured at lock time.
    var frame: WallFrame
    /// The plane's extent at lock time, metres.
    var extentWidth: Double
    var extentHeight: Double
    /// Bounds of the region actually covered by accepted measurements.
    var coveredBounds: WallBounds?

    /// Bounds used to frame the 2D summary: the covered region when there is
    /// one, otherwise the plane extent centred on the origin.
    var displayBounds: WallBounds {
        if let coveredBounds, !coveredBounds.isEmpty {
            return coveredBounds
        }
        return WallBounds(
            minX: -extentWidth / 2,
            minY: -extentHeight / 2,
            maxX: extentWidth / 2,
            maxY: extentHeight / 2
        )
    }
}
