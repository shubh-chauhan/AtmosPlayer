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
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(Brand.accent)
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
