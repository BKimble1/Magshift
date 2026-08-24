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

    /// Triangle fan around the polygon's centroid, built as two facing sheets.
    ///
    /// The overlay has to be visible from either side of the wall. It used to get
    /// that by emitting every triangle twice over the *same* vertices with
    /// opposite winding, and supplying no normals.
    ///
    /// That is a mesh RealityKit cannot survive. With no normals in the
    /// descriptor it generates them, and a vertex normal is the average of the
    /// faces touching that vertex -- so every vertex here averaged a face and its
    /// exact opposite, which cancels to the zero vector, and normalising zero
    /// gives NaN. The whole normal buffer came out NaN. Nothing in the Simulator
    /// ever built this mesh, because there are no ARKit planes there, so it only
    /// ran on a real device once a wall had actually been detected.
    ///
    /// Front and back now get their own vertices and their own explicit normals.
    /// No two triangles are coincident, and nothing has to be generated.
    ///
    /// The polygon lies in the anchor's local XZ plane, so its normal is the
    /// local Y axis.
    static func triangulated(_ polygon: [SIMD3<Float>]) -> MeshResource? {
        guard let geometry = geometry(for: polygon) else { return nil }
        var descriptor = MeshDescriptor(name: "wall-overlay")
        descriptor.positions = MeshBuffers.Positions(geometry.positions)
        descriptor.normals = MeshBuffers.Normals(geometry.normals)
        descriptor.primitives = .triangles(geometry.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// The vertex data, separated from RealityKit so it can be checked directly.
    ///
    /// The bug this replaced produced a `MeshResource` perfectly happily; what
    /// was wrong was the geometry inside it. A test that only asserted a mesh
    /// came back would have passed throughout.
    struct Geometry {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
    }

    static func geometry(for polygon: [SIMD3<Float>]) -> Geometry? {
        guard polygon.count >= 3 else { return nil }
        var centroid = SIMD3<Float>.zero
        for vertex in polygon { centroid += vertex }
        centroid /= Float(polygon.count)

        // A polygon carrying a non-finite vertex would put NaN straight into the
        // vertex buffer. ARKit should never report one; refusing here costs one
        // comparison per vertex and means it cannot matter if it ever does.
        let sheet = [centroid] + polygon
        guard sheet.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return nil
        }

        let sheetCount = UInt32(sheet.count)
        var indices: [UInt32] = []
        indices.reserveCapacity(polygon.count * 6)
        for index in 0..<polygon.count {
            let current = UInt32(index + 1)
            let next = UInt32((index + 1) % polygon.count + 1)
            indices.append(contentsOf: [0, current, next])
            // The back sheet is wound the other way, so it faces away.
            indices.append(contentsOf: [sheetCount, sheetCount + next, sheetCount + current])
        }

        return Geometry(
            positions: sheet + sheet,
            normals: Array(repeating: SIMD3<Float>(0, 1, 0), count: sheet.count)
                + Array(repeating: SIMD3<Float>(0, -1, 0), count: sheet.count),
            indices: indices
        )
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
