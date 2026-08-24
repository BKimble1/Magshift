import XCTest
import simd
@testable import WallField

/// The geometry of the overlay drawn over a detected wall.
///
/// This mesh is built only from real ARKit plane boundaries, so it had never
/// been built anywhere before it reached a device. The version it replaced
/// emitted every triangle twice over the same vertices with opposite winding and
/// supplied no normals -- so RealityKit generated them, every vertex averaged a
/// face with its exact opposite, and the whole normal buffer came out NaN.
///
/// These tests are written against the vertex data rather than the
/// `MeshResource`, because the broken version produced a `MeshResource` quite
/// happily. What was wrong was inside it.
final class WallMeshBuilderTests: XCTestCase {

    /// A square in the anchor's local XZ plane, as ARKit reports boundaries.
    private let square: [SIMD3<Float>] = [
        SIMD3(-1, 0, -1), SIMD3(1, 0, -1), SIMD3(1, 0, 1), SIMD3(-1, 0, 1),
    ]

    func testNoTriangleIsDrawnTwiceOverTheSameVertices() throws {
        let geometry = try XCTUnwrap(WallMeshBuilder.geometry(for: square))

        var seen = Set<Set<UInt32>>()
        for triangle in stride(from: 0, to: geometry.indices.count, by: 3) {
            let corners = Set(geometry.indices[triangle..<(triangle + 3)])
            XCTAssertEqual(corners.count, 3, "a triangle repeated a vertex, so it has no area")
            XCTAssertTrue(
                seen.insert(corners).inserted,
                "two triangles share all three vertices; their normals cancel to NaN"
            )
        }
    }

    func testEveryVertexCarriesAFiniteNormal() throws {
        let geometry = try XCTUnwrap(WallMeshBuilder.geometry(for: square))

        XCTAssertEqual(geometry.normals.count, geometry.positions.count)
        for normal in geometry.normals {
            XCTAssertTrue(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite)
            // Supplied, not generated: a zero-length normal is what NaN comes from.
            XCTAssertGreaterThan(simd_length(normal), 0.5)
        }
    }

    func testTheTwoSheetsFaceOppositeWays() throws {
        let geometry = try XCTUnwrap(WallMeshBuilder.geometry(for: square))

        // The overlay has to read from either side of the wall, which is what the
        // duplicated winding was for. It still does, from its own vertices.
        XCTAssertTrue(geometry.normals.contains { $0.y > 0 })
        XCTAssertTrue(geometry.normals.contains { $0.y < 0 })
    }

    func testEveryIndexAddressesAVertexThatExists() throws {
        let geometry = try XCTUnwrap(WallMeshBuilder.geometry(for: square))

        XCTAssertEqual(geometry.indices.count % 3, 0)
        XCTAssertFalse(geometry.indices.isEmpty)
        for index in geometry.indices {
            XCTAssertLessThan(Int(index), geometry.positions.count)
        }
    }

    func testEveryPositionIsFinite() throws {
        let geometry = try XCTUnwrap(WallMeshBuilder.geometry(for: square))

        for position in geometry.positions {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }
    }

    func testAPolygonWithANonFiniteVertexIsRefused() {
        let poisoned = square + [SIMD3<Float>(.nan, 0, 0)]

        // Better no overlay than a vertex buffer that takes the renderer down.
        XCTAssertNil(WallMeshBuilder.geometry(for: poisoned))
    }

    func testTooFewPointsToBeASurfaceAreRefused() {
        XCTAssertNil(WallMeshBuilder.geometry(for: []))
        XCTAssertNil(WallMeshBuilder.geometry(for: Array(square.prefix(2))))
    }

    func testABoundaryIsPreferredOverTheRectangularExtent() {
        let wall = DetectedWall(
            id: UUID(),
            transform: matrix_identity_float4x4,
            center: SIMD3<Float>(0, 0, 0),
            extentX: 2,
            extentZ: 2,
            boundary: square
        )

        XCTAssertEqual(WallMeshBuilder.boundaryPolygon(for: wall), square)
    }

    func testAWallWithNoBoundaryFallsBackToItsExtent() {
        let wall = DetectedWall(
            id: UUID(),
            transform: matrix_identity_float4x4,
            center: SIMD3<Float>(0, 0, 0),
            extentX: 2,
            extentZ: 4,
            boundary: []
        )

        let polygon = WallMeshBuilder.boundaryPolygon(for: wall)

        XCTAssertEqual(polygon.count, 4)
        XCTAssertNotNil(WallMeshBuilder.geometry(for: polygon))
    }

    func testAPathologicalBoundaryIsCapped() {
        let many = (0..<500).map { index -> SIMD3<Float> in
            let angle = Float(index) / 500 * 2 * .pi
            return SIMD3<Float>(cos(angle), 0, sin(angle))
        }
        let wall = DetectedWall(
            id: UUID(),
            transform: matrix_identity_float4x4,
            center: .zero,
            extentX: 2,
            extentZ: 2,
            boundary: many
        )

        XCTAssertEqual(
            WallMeshBuilder.boundaryPolygon(for: wall).count,
            WallMeshBuilder.maximumBoundaryVertices
        )
    }
}

/// The marker geometry, which has the same property as the wall mesh: it is
/// built only for real clusters on a real locked wall, so it had never run
/// anywhere either.
final class MarkerGeometryTests: XCTestCase {

    func testANonFiniteScoreCannotProduceANonFiniteRadius() {
        // Swift's `min` and `max` propagate NaN rather than clamping it, so
        // `min(max(nan, 0), 1)` is nan, not 0. A mesh generated at that size is
        // handed to the renderer as garbage.
        XCTAssertTrue(MarkerEntityFactory.radius(forScore: Float.nan).isFinite)
        XCTAssertTrue(MarkerEntityFactory.radius(forScore: Float.infinity).isFinite)
        XCTAssertTrue(MarkerEntityFactory.radius(forScore: -Float.infinity).isFinite)
    }

    func testEveryRadiusIsBigEnoughToDraw() {
        for score in [Float(-5), 0, 0.5, 1, 5, .nan] {
            let radius = MarkerEntityFactory.radius(forScore: score)
            XCTAssertGreaterThan(radius, 0, "score \(score) produced a radius of \(radius)")
        }
    }

    func testTheRadiusGrowsWithTheScoreAndThenStops() {
        XCTAssertEqual(MarkerEntityFactory.radius(forScore: Float(0)), MarkerEntityFactory.minimumRadius)
        XCTAssertGreaterThan(
            MarkerEntityFactory.radius(forScore: Float(0.5)),
            MarkerEntityFactory.radius(forScore: Float(0))
        )
        // Clamped, so an extreme reading cannot draw a marker the size of a wall.
        XCTAssertEqual(
            MarkerEntityFactory.radius(forScore: Float(5)),
            MarkerEntityFactory.radius(forScore: Float(1))
        )
    }
}
