import AppKit
import SwiftUI

/// The notch's fill. Black, or for the glass theme, glass with black around the camera
/// housing that fades out along its sides and rounded bottom, so the panel still grows out of
/// the housing without an edge.
struct NotchBackground: View {
    let shape: NotchShape
    /// Glass is only drawn while the notch is open; closed, it's black like the housing.
    let isGlass: Bool
    /// The camera housing, centred at the top, for the glass theme's black fade; nil without
    /// a notch or with the black theme.
    let housing: CGSize?
    /// Below 1 only for the invisible target that catches the pointer.
    let opacity: Double

    /// A light dimming over the whole glass keeps white text readable on a bright desktop.
    private static let dimming = 0.22

    var body: some View {
        shape.fill(.black.opacity(isGlass ? 0 : opacity))
            .overlay(alignment: .top) {
                if isGlass {
                    GlassFill(shape: shape)
                        .overlay(Color.black.opacity(Self.dimming))
                        .transition(.opacity)
                }
            }
            // Always there with the glass theme, so it grows and shrinks with the notch
            // rather than fading in and out.
            .overlay(alignment: .top) {
                if let housing { HousingFade(housing: housing, isGrown: isGlass) }
            }
    }
}

/// Black around the camera housing, fading out to the sides and below it: a solid black
/// copy of the housing, so it's the same black as the housing itself, then gradients down
/// each side and along the bottom, joined by elliptical ones at the bottom corners. All of
/// them use one falloff, so the blend is even all the way round. Below the housing the
/// panel's contents start soon after, so the fade there is shorter than at the sides.
/// While the notch is closed the gradients shrink to nothing, out of sight under the
/// housing, and they grow out of it as the notch opens.
private struct HousingFade: View {
    let housing: CGSize
    let isGrown: Bool

    /// How far out the fade reaches glass, beside and below the housing.
    private static let sideFade: CGFloat = 56
    private static let bottomFade: CGFloat = 24
    /// Falls quickly at first and then trails off, so there's no visible edge.
    private static let stops: [Gradient.Stop] = stride(from: 0.0, through: 1.0, by: 0.0625).map { t in
        .init(color: .black.opacity((1 - t) * (1 - t)), location: t)
    }

    var body: some View {
        let side = isGrown ? Self.sideFade : 0
        let bottom = isGrown ? Self.bottomFade : 0
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LinearGradient(stops: Self.stops, startPoint: .trailing, endPoint: .leading)
                    .frame(width: side)
                Color.black.frame(width: housing.width)
                LinearGradient(stops: Self.stops, startPoint: .leading, endPoint: .trailing)
                    .frame(width: side)
            }
            .frame(height: housing.height)
            HStack(spacing: 0) {
                Self.corner(at: .topTrailing, width: side, height: bottom)
                LinearGradient(stops: Self.stops, startPoint: .top, endPoint: .bottom)
                    .frame(width: housing.width)
                Self.corner(at: .topLeading, width: side, height: bottom)
            }
            .frame(height: bottom)
        }
        .frame(width: housing.width, height: housing.height, alignment: .top)
    }

    /// A quarter of an ellipse, fading out from the housing's corner at `center`.
    private static func corner(at center: UnitPoint, width: CGFloat, height: CGFloat) -> some View {
        RadialGradient(stops: stops, center: center, startRadius: 0, endRadius: max(width, 1))
            .frame(width: width, height: width)
            .scaleEffect(x: 1, y: width > 0 ? height / width : 0, anchor: .top)
            .frame(width: width, height: height, alignment: .top)
    }
}

/// Blurs whatever is behind the notch: Liquid Glass from macOS 26, a dark frosted material
/// before it.
private struct GlassFill: View {
    let shape: NotchShape

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            FrostedMaterial()
        }
    }
}

private struct FrostedMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
