import XCTest
import simd
@testable import WallField

final class WallFrameTests: XCTestCase {

    /// A vertical plane anchor whose local +Y (the plane normal) points along
    /// world +Z, rotated about that normal by `rotation` radians.
    private func anchorTransform(rotation: Float, origin: SIMD3<Float> = .zero) -> simd_float4x4 {
        let normal = SIMD3<Float>(0, 0, 1)
        let x = SIMD3<Float>(cos(rotation), sin(rotation), 0)
        let z = simd_cross(x, normal)
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(x.x, x.y, x.z, 0)
        transform.columns.1 = SIMD4<Float>(normal.x, normal.y, normal.z, 0)
        transform.columns.2 = SIMD4<Float>(z.x, z.y, z.z, 0)
        transform.columns.3 = SIMD4<Float>(origin.x, origin.y, origin.z, 1)
        return transform
    }

    func testFrameIsOrthonormal() throws {
        let frame = try XCTUnwrap(WallFrame.make(
            anchorTransform: anchorTransform(rotation: 0),
            cameraPosition: SIMD3<Float>(0, 0, 1)
        ))
        XCTAssertTrue(frame.isOrthonormal())
    }

    func testUpIsWorldUpRegardlessOfTheAnchorsArbitraryRotation() throws {
        // ARKit's vertical plane anchors carry an arbitrary rotation about their
        // normal. The wall frame must not inherit it, or the 2D map would come
        // out at a random angle and would change whenever ARKit re-centred the
        // anchor.
        for rotation in stride(from: Float(0), to: Float.pi * 2, by: 0.7) {
            let frame = try XCTUnwrap(WallFrame.make(
                anchorTransform: anchorTransform(rotation: rotation),
                cameraPosition: SIMD3<Float>(0, 0, 1)
            ))
            XCTAssertEqual(frame.up.x, 0, accuracy: 1e-5)
            XCTAssertEqual(frame.up.y, 1, accuracy: 1e-5)
            XCTAssertEqual(frame.up.z, 0, accuracy: 1e-5)
            XCTAssertTrue(frame.isOrthonormal())
        }
    }

    func testNormalIsOrientedTowardsTheCamera() throws {
        let behind = try XCTUnwrap(WallFrame.make(
            anchorTransform: anchorTransform(rotation: 0),
            cameraPosition: SIMD3<Float>(0, 0, -1)
        ))
        XCTAssertLessThan(behind.normal.z, 0, "the normal should point back towards the camera")

        let inFront = try XCTUnwrap(WallFrame.make(
            anchorTransform: anchorTransform(rotation: 0),
            cameraPosition: SIMD3<Float>(0, 0, 1)
        ))
        XCTAssertGreaterThan(inFront.normal.z, 0)
    }

    func testProjectionRoundTrips() throws {
        let frame = try XCTUnwrap(WallFrame.make(
            anchorTransform: anchorTransform(rotation: 0.9, origin: SIMD3<Float>(1, 2, 3)),
            cameraPosition: SIMD3<Float>(1, 2, 4)
        ))
        for point in [WallPoint(x: 0, y: 0), WallPoint(x: 0.4, y: -0.3), WallPoint(x: -1.2, y: 0.7)] {
            let world = frame.worldPosition(forWallPoint: point)
            let recovered = frame.wallPoint(forWorldPosition: world)
            XCTAssertEqual(recovered.x, point.x, accuracy: 1e-4)
            XCTAssertEqual(recovered.y, point.y, accuracy: 1e-4)
            XCTAssertEqual(frame.normalDistance(forWorldPosition: world), 0, accuracy: 1e-4)
        }
    }

    func testNormalOffsetIsMeasuredAlongTheNormal() throws {
        let frame = try XCTUnwrap(WallFrame.make(
            anchorTransform: anchorTransform(rotation: 0),
            cameraPosition: SIMD3<Float>(0, 0, 1)
        ))
        let offset = frame.worldPosition(forWallPoint: WallPoint(x: 0.2, y: 0.1), normalOffset: 0.05)
        XCTAssertEqual(frame.normalDistance(forWorldPosition: offset), 0.05, accuracy: 1e-4)
        let projected = frame.wallPoint(forWorldPosition: offset)
        XCTAssertEqual(projected.x, 0.2, accuracy: 1e-4)
        XCTAssertEqual(projected.y, 0.1, accuracy: 1e-4)
    }

    func testRightIsToTheRightOfUpAndNormal() throws {
        let frame = try XCTUnwrap(WallFrame.make(
            anchorTransform: anchorTransform(rotation: 0),
            cameraPosition: SIMD3<Float>(0, 0, 1)
        ))
        let cross = simd_cross(frame.right.simd, frame.up.simd)
        XCTAssertEqual(simd_length(cross - frame.normal.simd), 0, accuracy: 1e-4,
                       "right x up must equal the normal for a right-handed frame")
    }

    func testHorizontalSurfaceIsRefused() {
        // A ceiling or a floor has no meaningful "up on the wall", so no frame
        // may be produced and the app must refuse to lock it.
        var transform = matrix_identity_float4x4
        transform.columns.1 = SIMD4<Float>(0, 1, 0, 0)   // normal points straight up
        XCTAssertNil(WallFrame.make(anchorTransform: transform, cameraPosition: SIMD3<Float>(0, 1, 0)))
    }

    func testDegenerateTransformIsRefused() {
        var transform = matrix_identity_float4x4
        transform.columns.1 = SIMD4<Float>(0, 0, 0, 0)
        XCTAssertNil(WallFrame.make(anchorTransform: transform, cameraPosition: nil))
    }
}

final class WallGeometryTests: XCTestCase {

    func testBoundsContainEveryPointWithPadding() throws {
        let points = [WallPoint(x: -0.2, y: 0.1), WallPoint(x: 0.5, y: -0.4)]
        let bounds = try XCTUnwrap(WallBounds.containing(points, padding: 0.1))
        XCTAssertEqual(bounds.minX, -0.3, accuracy: 1e-9)
        XCTAssertEqual(bounds.maxX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(bounds.minY, -0.5, accuracy: 1e-9)
        XCTAssertEqual(bounds.maxY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(bounds.width, 0.9, accuracy: 1e-9)
        XCTAssertEqual(bounds.height, 0.7, accuracy: 1e-9)
    }

    func testBoundsOfNothingIsNilRatherThanAnInventedRectangle() {
        XCTAssertNil(WallBounds.containing([]))
    }

    func testUnionCoversBoth() {
        let a = WallBounds(minX: 0, minY: 0, maxX: 1, maxY: 1)
        let b = WallBounds(minX: -1, minY: 0.5, maxX: 0.5, maxY: 2)
        let union = a.union(b)
        XCTAssertEqual(union.minX, -1)
        XCTAssertEqual(union.maxX, 1)
        XCTAssertEqual(union.minY, 0)
        XCTAssertEqual(union.maxY, 2)
    }

    func testDisplayBoundsFallBackToThePlaneExtent() {
        let metadata = WallMetadata(
            anchorIdentifier: UUID(),
            frame: Fixture.wallFrame,
            extentWidth: 2,
            extentHeight: 3,
            coveredBounds: nil
        )
        XCTAssertEqual(metadata.displayBounds.width, 2, accuracy: 1e-9)
        XCTAssertEqual(metadata.displayBounds.height, 3, accuracy: 1e-9)
    }

    func testVectorRoundTrip() {
        let simd = SIMD3<Float>(1.5, -2.25, 3)
        XCTAssertEqual(Vector3(simd).simd, simd)
        XCTAssertEqual(Vector3.zero.simd, SIMD3<Float>.zero)
    }

    func testWallPointDistance() {
        XCTAssertEqual(WallPoint(x: 0, y: 0).distance(to: WallPoint(x: 3, y: 4)), 5, accuracy: 1e-9)
    }
}

final class SpatialSampleBufferTests: XCTestCase {

    private func buffer(count: Int, interval: TimeInterval = 0.0166) -> SpatialSampleBuffer {
        var buffer = SpatialSampleBuffer(capacity: 180)
        for index in 0..<count {
            buffer.append(Fixture.spatialSample(at: Double(index) * interval))
        }
        return buffer
    }

    func testMatchesTheNearestPoseInTime() throws {
        let poses = buffer(count: 100)
        let match = try XCTUnwrap(poses.match(timestamp: 0.5, tolerance: 0.1))
        XCTAssertEqual(match.sample.timestamp, 0.4980, accuracy: 0.0166)
        XCTAssertLessThanOrEqual(match.timingError, 0.0166)
    }

    func testExactMatchHasZeroError() throws {
        let poses = buffer(count: 50)
        let target = 10 * 0.0166
        let match = try XCTUnwrap(poses.match(timestamp: target, tolerance: 0.1))
        XCTAssertEqual(match.timingError, 0, accuracy: 1e-9)
    }

    func testRefusesToMatchOutsideTolerance() {
        // A reading with no pose close enough in time must not be anchored at
        // all: attributing it to a stale pose would place a confident-looking
        // marker in the wrong place.
        let poses = buffer(count: 50)
        XCTAssertNil(poses.match(timestamp: 100, tolerance: 0.1))
        XCTAssertNil(poses.match(timestamp: -5, tolerance: 0.1))
    }

    func testToleranceBoundaryIsInclusive() throws {
        // Binary-exact values (1.125 = 9/8, 0.125 = 1/8), so this asserts the
        // comparison is `<=` rather than asserting something about floating
        // point. Written with 1.0 and 1.1 it asserts neither: `1.1 - 1.0` is
        // 0.100000000000000088, which is genuinely outside a 0.1 tolerance.
        var poses = SpatialSampleBuffer(capacity: 10)
        poses.append(Fixture.spatialSample(at: 1.0))
        XCTAssertNotNil(poses.match(timestamp: 1.125, tolerance: 0.125),
                        "a pose exactly at the tolerance must still match")
        XCTAssertNil(poses.match(timestamp: 1.1251, tolerance: 0.125))
        let match = try XCTUnwrap(poses.match(timestamp: 1.0625, tolerance: 0.125))
        XCTAssertEqual(match.timingError, 0.0625, accuracy: 1e-12)
    }

    func testEmptyBufferMatchesNothing() {
        let poses = SpatialSampleBuffer(capacity: 10)
        XCTAssertNil(poses.match(timestamp: 0, tolerance: 1))
        XCTAssertTrue(poses.isEmpty)
    }

    func testBufferIsBounded() {
        let poses = buffer(count: 5_000)
        XCTAssertEqual(poses.count, SpatialSampleBuffer.defaultCapacity)
    }

    func testRemoveAllClearsTheBuffer() {
        var poses = buffer(count: 20)
        poses.removeAll()
        XCTAssertTrue(poses.isEmpty)
        XCTAssertNil(poses.newest)
    }
}
