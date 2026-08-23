import Foundation
import RealityKit
import simd

/// Builds the translucent geometry drawn over a detected wall.
///
/// ARKit's boundary polygon is preferred because it shows the user the shape the
/// system has actually mapped, which is what the raycast will accept. When no
/// boundary is available the plane's rectangular extent is used instead -- a
/// deliberately conservative fallback that can only ever be a superset of the
/// mapped region in the user's mind, never a claim that more is mapped than is.
enum WallMeshBuilder {

    /// A generous but bounded vertex budget. ARKit boundaries are far smaller
    /// than this; the cap exists so a pathological polygon cannot stall a frame.
    static let maximumBoundaryVertices = 128

    static func mesh(for wall: DetectedWall) -> MeshResource {
        let polygon = boundaryPolygon(for: wall)
        if polygon.count >= 3, let mesh = triangulated(polygon) {
            return mesh
        }
        return fallbackMesh(for: wall)
    }

    /// The polygon to draw, in the anchor's local space (its Y is the normal, so
    /// the polygon lies in the local XZ plane).
    static func boundaryPolygon(for wall: DetectedWall) -> [SIMD3<Float>] {
        if wall.boundary.count >= 3 {
            return Array(wall.boundary.prefix(maximumBoundaryVertices))
        }
        let halfX = wall.extentX / 2
        let halfZ = wall.extentZ / 2
        let c = wall.center
        return [
            SIMD3<Float>(c.x - halfX, 0, c.z - halfZ),
            SIMD3<Float>(c.x + halfX, 0, c.z - halfZ),
            SIMD3<Float>(c.x + halfX, 0, c.z + halfZ),
            SIMD3<Float>(c.x - halfX, 0, c.z + halfZ),
        ]
    }

    /// Triangle fan around the polygon's centroid.
    ///
    /// Every triangle is emitted twice with opposite winding, so the overlay is
    /// visible from either side of the wall without depending on a material
    /// face-culling setting.
    static func triangulated(_ polygon: [SIMD3<Float>]) -> MeshResource? {
        guard polygon.count >= 3 else { return nil }
        var centroid = SIMD3<Float>.zero
        for vertex in polygon { centroid += vertex }
        centroid /= Float(polygon.count)

        var positions: [SIMD3<Float>] = [centroid]
        positions.append(contentsOf: polygon)

        var indices: [UInt32] = []
        indices.reserveCapacity(polygon.count * 6)
        for index in 0..<polygon.count {
            let current = UInt32(index + 1)
            let next = UInt32((index + 1) % polygon.count + 1)
            indices.append(contentsOf: [0, current, next])
            indices.append(contentsOf: [0, next, current])
        }

        var descriptor = MeshDescriptor(name: "wall-overlay")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func fallbackMesh(for wall: DetectedWall) -> MeshResource {
        MeshResource.generatePlane(
            width: max(wall.extentX, 0.05),
            depth: max(wall.extentZ, 0.05)
        )
    }
}

/// Materials for the wall overlay.
enum WallVisualStyle {
    /// Opacity of the overlay drawn over the wall the user is choosing.
    static let unselectedOpacity: CGFloat = 0.16
    /// Opacity once a wall is locked. Higher, so the locked surface reads
    /// clearly, but still low enough to see the wall itself through it.
    static let selectedOpacity: CGFloat = 0.30

    /// `UnlitMaterial` is used rather than a lit material on purpose: the
    /// overlay's job is to communicate a region, and a lit material would change
    /// brightness with room lighting and could be mistaken for a reading.
    static func overlayMaterial(isSelected: Bool) -> UnlitMaterial {
        let opacity = isSelected ? selectedOpacity : unselectedOpacity
        return UnlitMaterial(color: Palette.wallOverlayUIColor.withAlphaComponent(opacity))
    }
}
