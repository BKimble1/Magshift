import SwiftUI

/// A flat, top-down-free 2D map of the wall in wall coordinates.
///
/// Used by the review screen, by saved scan detail, and by the simulated canvas.
/// One implementation so the mark a user saw during the scan looks the same in
/// the saved summary.
///
/// Wall space has +x to the right and +y up, which is what a person facing the
/// wall expects. SwiftUI's y axis points down, so the projection flips it.
struct WallMapView: View {
    var bounds: WallBounds
    var clusters: [AnomalyCluster]
    /// Optional live crosshair position, drawn only during a simulated scan.
    var crosshair: WallPoint? = nil
    /// Draws a scale bar and axis labels. Off for the compact HUD-sized map.
    var showsScale = true
    var onSelect: ((AnomalyCluster) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let layout = WallMapLayout(bounds: bounds, size: proxy.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemBackground))

                gridLines(layout: layout)

                ForEach(clusters) { cluster in
                    marker(for: cluster, layout: layout)
                }

                if let crosshair {
                    let point = layout.point(for: crosshair)
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.8), lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .position(point)
                        .accessibilityHidden(true)
                }

                if showsScale {
                    scaleBar(layout: layout)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of the wall. \(clusters.count) magnetic "
            + "\(clusters.count == 1 ? "anomaly" : "anomalies").")
    }

    private func gridLines(layout: WallMapLayout) -> some View {
        // A 10 cm grid, so a reader can judge distance without a ruler.
        Path { path in
            let step = 0.1
            var x = (bounds.minX / step).rounded(.up) * step
            while x <= bounds.maxX {
                let position = layout.point(for: WallPoint(x: x, y: bounds.minY))
                path.move(to: CGPoint(x: position.x, y: 0))
                path.addLine(to: CGPoint(x: position.x, y: layout.size.height))
                x += step
            }
            var y = (bounds.minY / step).rounded(.up) * step
            while y <= bounds.maxY {
                let position = layout.point(for: WallPoint(x: bounds.minX, y: y))
                path.move(to: CGPoint(x: 0, y: position.y))
                path.addLine(to: CGPoint(x: layout.size.width, y: position.y))
                y += step
            }
        }
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        .accessibilityHidden(true)
    }

    private func marker(for cluster: AnomalyCluster, layout: WallMapLayout) -> some View {
        let center = layout.point(for: cluster.wallPoint)
        let diameter = max(14, min(44, layout.length(
            metres: Double(MarkerEntityFactory.radius(forScore: cluster.peakScore)) * 2
        )))
        let colour = Palette.color(forBand: cluster.strengthBand)

        return ZStack {
            Circle()
                .fill(colour.opacity(cluster.confidence == .repeated ? 0.55 : 0.22))
            Circle()
                .strokeBorder(
                    colour,
                    style: StrokeStyle(
                        lineWidth: 2,
                        dash: cluster.confidence == .repeated ? [] : [3, 3]
                    )
                )
            if cluster.confidence == .repeated {
                // The same bright centre the AR marker uses, so a repeated
                // cluster reads identically in both views.
                Circle()
                    .fill(Palette.confirmedCore)
                    .frame(width: diameter * 0.4, height: diameter * 0.4)
                Image(systemName: "plus")
                    .font(.system(size: diameter * 0.3, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
        }
        .frame(width: diameter, height: diameter)
        .position(center)
        .contentShape(Circle())
        .onTapGesture { onSelect?(cluster) }
        .accessibilityElement()
        .accessibilityLabel(cluster.accessibilityDescription)
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
    }

    private func scaleBar(layout: WallMapLayout) -> some View {
        let width = layout.length(metres: 0.1)
        return VStack(alignment: .leading, spacing: 2) {
            Rectangle()
                .fill(Color.primary.opacity(0.6))
                .frame(width: max(width, 8), height: 2)
            Text("10 cm")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.tight)
        .accessibilityHidden(true)
    }
}

/// Maps wall coordinates to view coordinates, preserving aspect ratio so a
/// circle on the wall is a circle on screen and distances are not distorted.
struct WallMapLayout {
    let bounds: WallBounds
    let size: CGSize
    let scale: Double
    private let originX: Double
    private let originY: Double

    init(bounds: WallBounds, size: CGSize) {
        self.bounds = bounds
        self.size = size
        let width = max(bounds.width, 0.01)
        let height = max(bounds.height, 0.01)
        let scale = min(Double(size.width) / width, Double(size.height) / height)
        self.scale = scale
        // Centre the mapped region inside the available space.
        self.originX = (Double(size.width) - width * scale) / 2
        self.originY = (Double(size.height) - height * scale) / 2
    }

    func point(for wallPoint: WallPoint) -> CGPoint {
        CGPoint(
            x: originX + (wallPoint.x - bounds.minX) * scale,
            // Wall +y is up; SwiftUI +y is down.
            y: originY + (bounds.maxY - wallPoint.y) * scale
        )
    }

    func wallPoint(for point: CGPoint) -> WallPoint {
        // `scale` is zero before the first layout pass gives the view a size.
        // Dividing by it would hand the caller an infinite wall coordinate,
        // which the simulated canvas would then feed straight into the
        // environment and the stored geometry.
        guard scale > 0 else { return bounds.center }
        return WallPoint(
            x: bounds.minX + (Double(point.x) - originX) / scale,
            y: bounds.maxY - (Double(point.y) - originY) / scale
        )
    }

    func length(metres: Double) -> Double {
        metres * scale
    }
}

#Preview {
    WallMapView(
        bounds: WallBounds(minX: -0.6, minY: -0.5, maxX: 0.6, maxY: 0.5),
        clusters: [],
        crosshair: WallPoint(x: 0, y: 0)
    )
    .frame(height: 260)
    .padding()
}
