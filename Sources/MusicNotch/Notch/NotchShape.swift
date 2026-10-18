import SwiftUI

/// Flush with the top of the screen, with outward-curving top corners like the
/// hardware notch and rounded bottom corners.
///
/// With `bandInset`, the top `bandHeight` (the strip beside the camera housing, where an open
/// panel's app icons sit) reaches that much further out on each side than the body below
/// it, which hangs from the strip's middle with curved corners where the two meet. At 0 it's
/// the plain shape, and it grows out of it smoothly as the inset animates.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var bandInset: CGFloat = 0
    var bandHeight: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), bandInset) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            bandInset = newValue.second
        }
    }

    /// The strip's outer bottom corners, and the curves where the body meets the strip.
    private static let bandCornerRadius: CGFloat = 10
    private static let innerCornerRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        // The strip's sides, and the body's.
        let outerLeft = rect.minX + top, outerRight = rect.maxX - top
        let inset = min(max(bandInset, 0), max(0, (outerRight - outerLeft) / 2 - 1))
        let left = outerLeft + inset, right = outerRight - inset
        let bandBottom = min(rect.minY + max(bandHeight, top), rect.maxY)
        // Both kinds of corner shrink to nothing with the inset, giving the plain shape.
        let outer = min(Self.bandCornerRadius, inset / 2, max(0, bandBottom - rect.minY - top))
        let inner = min(Self.innerCornerRadius, inset / 2, max(0, rect.maxY - bandBottom) / 2)
        let bodyTop = inset > 0 ? bandBottom + inner : rect.minY + top
        let bottom = min(bottomRadius, max(0, rect.maxY - bodyTop), (right - left) / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: outerLeft, y: rect.minY + top),
                          control: CGPoint(x: outerLeft, y: rect.minY))
        if inset > 0 {
            path.addLine(to: CGPoint(x: outerLeft, y: bandBottom - outer))
            path.addQuadCurve(to: CGPoint(x: outerLeft + outer, y: bandBottom),
                              control: CGPoint(x: outerLeft, y: bandBottom))
            path.addLine(to: CGPoint(x: left - inner, y: bandBottom))
            path.addQuadCurve(to: CGPoint(x: left, y: bandBottom + inner),
                              control: CGPoint(x: left, y: bandBottom))
        }
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom),
                          control: CGPoint(x: right, y: rect.maxY))
        if inset > 0 {
            path.addLine(to: CGPoint(x: right, y: bandBottom + inner))
            path.addQuadCurve(to: CGPoint(x: right + inner, y: bandBottom),
                              control: CGPoint(x: right, y: bandBottom))
            path.addLine(to: CGPoint(x: outerRight - outer, y: bandBottom))
            path.addQuadCurve(to: CGPoint(x: outerRight, y: bandBottom - outer),
                              control: CGPoint(x: outerRight, y: bandBottom))
        }
        path.addLine(to: CGPoint(x: outerRight, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: outerRight, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
