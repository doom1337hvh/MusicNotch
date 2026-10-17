import AppKit
import SwiftUI

/// The notch's fill. Black, or for the glass theme, glass that's black over the camera
/// housing and fades out below it, so the open panel grows out of the housing without an edge.
struct NotchBackground: View {
    let shape: NotchShape
    /// Glass is only drawn while the notch is open: closed, the notch is all housing height,
    /// so it would be covered in black anyway.
    let isGlass: Bool
    /// How far down the glass stays black: the housing's height, or 0 without a notch.
    let blackHeight: CGFloat
    /// Below 1 only for the invisible target that catches the pointer.
    let opacity: Double

    /// The fade from black to glass, below `blackHeight`.
    private static let fadeHeight: CGFloat = 30
    /// A light dimming over the whole glass keeps white text readable on a bright desktop.
    private static let dimming = 0.22
    /// Eased, so the fade has no visible start or end.
    private static let fadeStops: [Gradient.Stop] = stride(from: 0.0, through: 1.0, by: 0.125).map { t in
        .init(color: .black.opacity(1 - t * t * (3 - 2 * t)), location: t)
    }

    var body: some View {
        shape.fill(.black.opacity(isGlass ? 0 : opacity))
            .overlay(alignment: .top) {
                if isGlass {
                    GlassFill(shape: shape)
                        .overlay(Color.black.opacity(Self.dimming))
                        // Top-aligned, so while the panel is still shorter than this it runs off
                        // the bottom (and is clipped) instead of being centred.
                        .overlay(alignment: .top) {
                            VStack(spacing: 0) {
                                Color.black.frame(height: blackHeight)
                                LinearGradient(stops: Self.fadeStops, startPoint: .top, endPoint: .bottom)
                                    .frame(height: Self.fadeHeight)
                            }
                        }
                        .transition(.opacity)
                }
            }
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
