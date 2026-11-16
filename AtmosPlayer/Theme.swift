import SwiftUI
import UIKit

/// App-wide look, taken from the icon: violet → indigo → cyan on near-black.
enum Brand {
    /// Switches, selections, links.
    static let accent = Color(red: 0.42, green: 0.40, blue: 1.0)
    static let violet = Color(red: 0.78, green: 0.42, blue: 1.0)
    static let cyan = Color(red: 0.18, green: 0.88, blue: 1.0)
    /// The icon's sweep, for progress bars and highlights.
    static let gradient = LinearGradient(colors: [violet, accent, cyan], startPoint: .leading, endPoint: .trailing)
}

/// Switches in the brand colour. The app's tint is white (Apple TV style buttons), which made
/// a switch that's on look white-on-white.
struct BrandToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandSwitch(configuration: configuration)
    }
}

/// The iPhone's green switch, drawn by hand: on Liquid Glass the system one picks up the
/// player's white tint and reads white-on-white whether it is on or off.
private struct BrandSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { configuration.isOn.toggle() }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Color(uiColor: .systemGreen) : Color.white.opacity(0.22))
                    Circle()
                        .fill(.white)
                        .padding(2.5)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
                .frame(width: 51, height: 31)
                .opacity(isEnabled ? 1 : 0.45)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later, a blurred material before that.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// A "Done" button above the keyboard, for fields where Return doesn't close it.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { dismissKeyboard() }
                    .fontWeight(.semibold)
            }
        }
    }
}

@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Buttons that shrink slightly while pressed, like the system's media controls.
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - iPad

/// Sizes that differ between iPhone and iPad.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    /// Posters, cards and stills are this much larger on iPad's bigger screen.
    static let scale: CGFloat = isPad ? 1.32 : 1
    static func size(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
    /// The page's side margin.
    static let margin: CGFloat = isPad ? 32 : 20
}

/// Keeps lists and forms to a comfortable reading width on iPad instead of stretching every
/// row across the whole screen. The list still scrolls from anywhere.
private struct ReadableWidth: ViewModifier {
    let width: CGFloat
    @State private var available: CGFloat = 0

    func body(content: Content) -> some View {
        if Device.isPad {
            content
                .contentMargins(.horizontal, max(0, (available - width) / 2), for: .scrollContent)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        } else {
            content
        }
    }
}

extension View {
    func readableWidth(_ width: CGFloat = 760) -> some View { modifier(ReadableWidth(width: width)) }
}
