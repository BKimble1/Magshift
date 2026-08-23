import Foundation
import simd

/// A `Codable` three-component vector.
///
/// `SIMD3<Float>` is used for all in-memory maths; this type exists purely so
/// persisted records have an explicit, stable, human-readable encoding that will
/// not change if the standard library's SIMD `Codable` representation ever does.
struct Vector3: Codable, Sendable, Hashable {
    var x: Float
    var y: Float
    var z: Float

    init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ simd: SIMD3<Float>) {
        self.init(x: simd.x, y: simd.y, z: simd.z)
    }

    var simd: SIMD3<Float> { SIMD3<Float>(x, y, z) }

    static let zero = Vector3(x: 0, y: 0, z: 0)
}

/// A position on the locked wall, in metres, in the wall's own 2D frame.
///
/// `x` increases to the right along the wall as seen by a viewer facing it;
/// `y` increases upwards. The origin is the wall frame's origin, captured when
/// the wall was locked. See `WallFrame`.
struct WallPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    static let zero = WallPoint(x: 0, y: 0)

    func distance(to other: WallPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    static func + (lhs: WallPoint, rhs: WallPoint) -> WallPoint {
        WallPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func * (lhs: WallPoint, rhs: Double) -> WallPoint {
        WallPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

/// An axis-aligned rectangle in wall space, used to frame the 2D summary map.
struct WallBounds: Codable, Sendable, Hashable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var width: Double { max(0, maxX - minX) }
    var height: Double { max(0, maxY - minY) }
    var center: WallPoint { WallPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    var isEmpty: Bool { width <= 0 && height <= 0 }

    static let empty = WallBounds(minX: 0, minY: 0, maxX: 0, maxY: 0)

    /// Bounds that contain every supplied point, expanded by `padding` metres.
    /// Returns `nil` for an empty input rather than inventing a rectangle.
    static func containing(_ points: [WallPoint], padding: Double = 0.1) -> WallBounds? {
        guard let first = points.first else { return nil }
        var bounds = WallBounds(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for point in points.dropFirst() {
            bounds.minX = min(bounds.minX, point.x)
            bounds.minY = min(bounds.minY, point.y)
            bounds.maxX = max(bounds.maxX, point.x)
            bounds.maxY = max(bounds.maxY, point.y)
        }
        bounds.minX -= padding
        bounds.minY -= padding
        bounds.maxX += padding
        bounds.maxY += padding
        return bounds
    }

    /// Union with another rectangle.
    func union(_ other: WallBounds) -> WallBounds {
        WallBounds(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )
    }
}
