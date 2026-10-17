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

/// Black around the camera housing, fading out along its sides and rounded bottom: a solid
/// copy of the housing, so it's the same black as the housing itself, over a blurred one that
/// spreads a little outside it and runs above the top of the screen, so the top isn't
/// blurred. Below the housing the panel's contents start soon after, so there the fade is cut
/// short. While the notch is closed the blurred one shrinks to the housing's size, where
/// it's out of sight, and it grows out of the housing as the notch opens.
private struct HousingFade: View {
    let housing: CGSize
    let isGrown: Bool

    /// The blur's spread; beside the housing the fade reaches glass about 6 × this out.
    private static let softness: CGFloat = 5
    /// How far below the housing the fade reaches glass. The contents start 8 pt below it.
    private static let bottomFade: CGFloat = 6
    /// The real housing's bottom corners.
    private static let cornerRadius: CGFloat = 8
    /// Eased, so the fade below has no visible start or end.
    private static let bottomFadeStops: [Gradient.Stop] = stride(from: 0.0, through: 1.0, by: 0.25).map { t in
        .init(color: .black.opacity(1 - t * t * (3 - 2 * t)), location: t)
    }

    var body: some View {
        let softness = isGrown ? Self.softness : 0
        // Grown by 3 × the spread, the blurred copy is still fully black at the housing's edge.
        let grow = 3 * softness
        // Room for the blur around the blurred copy, so the mask doesn't cut it off.
        let room = 3 * Self.softness
        ZStack(alignment: .top) {
            Self.shape(radius: Self.cornerRadius + grow)
                .frame(width: housing.width + 2 * grow, height: housing.height + 2 * grow)
                .blur(radius: softness)
                .padding(room)
                // In heights rather than fractions, so the cut stays at the housing's bottom
                // while the copy grows.
                .mask {
                    VStack(spacing: 0) {
                        Color.black.frame(height: room + grow + housing.height)
                        LinearGradient(stops: Self.bottomFadeStops, startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.bottomFade)
                        Color.clear
                    }
                }
                .offset(y: -(room + grow))
            Self.shape(radius: Self.cornerRadius)
                .frame(width: housing.width, height: housing.height)
        }
        .frame(width: housing.width, height: housing.height, alignment: .top)
    }

    private static func shape(radius: CGFloat) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
            .fill(.black)
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
