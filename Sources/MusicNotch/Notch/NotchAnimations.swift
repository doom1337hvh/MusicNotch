import SwiftUI

/// How the notch opens and closes (Settings → Notch → Open animation).
/// (Raw values 1, 2, 3 and 5 belonged to removed styles; they fall back to Bouncy.)
enum OpenAnimation: Int, CaseIterable, Identifiable {
    case bouncy = 0
    case pop = 4
    case blur = 6
    case instant = 7

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .bouncy: "Bouncy"
        case .pop: "Pop"
        case .blur: "Blur"
        case .instant: "Instant"
        }
    }

    /// The notch growing open; nil for no animation.
    var opening: Animation? {
        switch self {
        case .bouncy: .spring(response: 0.4, dampingFraction: 0.78)
        case .pop: .spring(response: 0.34, dampingFraction: 0.62)
        case .blur: .smooth(duration: 0.35)
        case .instant: nil
        }
    }

    /// The notch shrinking closed; nil for no animation.
    var closing: Animation? {
        switch self {
        case .bouncy: .spring(response: 0.3, dampingFraction: 1)
        case .pop: .snappy(duration: 0.2)
        case .blur: .smooth(duration: 0.25)
        case .instant: nil
        }
    }

    /// How the open panel's contents appear as the notch grows.
    var contentArrival: AnyTransition {
        switch self {
        case .bouncy: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
        case .instant: .opacity
        case .pop: .opacity.combined(with: .scale(scale: 0.4, anchor: .top))
        case .blur: .opacity.combined(with: .modifier(active: BlurEffect(radius: 10), identity: BlurEffect(radius: 0)))
        }
    }
}

/// Where the notch starts from when it appears on a new desktop; the animation brings
/// each value back to rest (no offset, scale 1, no blur).
struct AppearStart {
    var contentOffset: CGFloat = 0
    var scale: CGFloat = 1
    /// Blurs the artwork and bars only; the black shape stays sharp and flush with the top
    /// of the screen, like the hardware notch.
    var contentBlur: CGFloat = 0
}

extension SpaceSwitchAnimation {
    /// The start and curve for animations that move, scale or blur the notch; nil for the
    /// plain fade (and for None), which only fade the window in.
    func motion(direction: SpaceObserver.Direction?, geometry: NotchGeometry) -> (start: AppearStart, curve: Animation)? {
        switch self {
        case .slide:
            guard let direction else { return nil }
            // Moving forward, the new desktop comes in from the right.
            let distance = geometry.wingWidth + 12
            return (AppearStart(contentOffset: direction == .forward ? distance : -distance), .snappy(duration: 0.45))
        case .zoom:
            return (AppearStart(scale: 0.5), .smooth(duration: 0.35))
        case .bounce:
            return (AppearStart(scale: 0.7), .spring(response: 0.42, dampingFraction: 0.6))
        case .blur:
            return (AppearStart(contentBlur: 12), .smooth(duration: 0.4))
        case .fade, .none:
            return nil
        }
    }
}

struct BlurEffect: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}
