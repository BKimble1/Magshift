import Foundation
import RealityKit
import UIKit
import simd

/// Builds the wall-aligned discs that visualise clusters.
///
/// # Shape carries meaning, not just colour
///
/// * **Unconfirmed** clusters render as a *ring*: a tinted disc with a dark
///   inner disc punched out of it.
/// * **Repeated** clusters render as a *filled disc with a bright core*.
///
/// A user who cannot distinguish the amber and red tints can still tell a
/// single-pass reading from a repeated one, and the same distinction is repeated
/// in the legend, the 2D map and every accessibility label.
///
/// # Z-fighting
///
/// Discs are pushed a few millimetres off the wall along the wall normal, and the
/// inner disc sits slightly further out than the outer one, so neither fights
/// with the wall overlay or with each other.
enum MarkerEntityFactory {

    /// Radius of the smallest marker, metres.
    static let minimumRadius: Float = 0.030
    /// Additional radius at maximum score, metres.
    static let radiusRange: Float = 0.022
    /// Offset of the outer disc from the wall surface, metres.
    static let outerOffset: Float = 0.004
    /// Offset of the inner disc, metres. Larger than `outerOffset` so the inner
    /// disc always draws in front of the outer one.
    static let innerOffset: Float = 0.006

    /// Fraction of the outer radius used by the inner disc.
    static let unconfirmedCoreScale: Float = 0.62
    static let repeatedCoreScale: Float = 0.40

    /// Replaces `entity`'s children with the geometry for `cluster`.
    ///
    /// The entity itself is reused across updates; only its children are rebuilt,
    /// and only when a cluster actually changes. Nothing here runs per frame.
    static func populate(_ entity: Entity, cluster: AnomalyCluster, normalSign: Float) {
        entity.children.removeAll()

        let radius = radius(forScore: cluster.peakScore)
        let tint = Palette.uiColor(forBand: cluster.strengthBand)

        let outerAlpha: CGFloat = cluster.confidence == .repeated ? 0.72 : 0.42
        let outer = ModelEntity(
            mesh: .generatePlane(width: radius * 2, depth: radius * 2, cornerRadius: radius),
            materials: [UnlitMaterial(color: tint.withAlphaComponent(outerAlpha))]
        )
        outer.name = "outer"
        outer.position = SIMD3<Float>(0, outerOffset, 0)

        let coreScale = cluster.confidence == .repeated ? repeatedCoreScale : unconfirmedCoreScale
        let coreRadius = radius * coreScale
        let coreColor: UIColor = cluster.confidence == .repeated
            ? Palette.confirmedCoreUIColor.withAlphaComponent(0.92)
            : Palette.markerVoidUIColor.withAlphaComponent(0.55)
        let core = ModelEntity(
            mesh: .generatePlane(width: coreRadius * 2, depth: coreRadius * 2, cornerRadius: coreRadius),
            materials: [UnlitMaterial(color: coreColor)]
        )
        core.name = "core"
        core.position = SIMD3<Float>(0, innerOffset, 0)

        entity.addChild(outer)
        entity.addChild(core)

        // `generatePlane` faces the entity's +Y. When the wall normal points
        // along the anchor's -Y, flip the marker so it faces the viewer.
        //
        // The flip is a rotation of the whole entity, so it carries the children
        // with it: the offsets above are expressed in the *rotated* frame, where
        // +Y is outward by construction. Multiplying them by `normalSign` as well
        // would apply the sign twice and push a flipped marker into the wall.
        entity.orientation = normalSign >= 0
            ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            : simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
    }

    static func radius(forScore score: Float) -> Float {
        // A non-finite score would make the radius non-finite, and a mesh
        // generated at a non-finite size is handed to the renderer as garbage.
        // Swift's `min`/`max` propagate NaN rather than clamping it away, so the
        // check has to be explicit.
        guard score.isFinite else { return minimumRadius }
        return minimumRadius + radiusRange * min(max(score, 0), 1)
    }

    static func radius(forScore score: Double) -> Float {
        radius(forScore: Float(score))
    }
}
