import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

/// Which side of the screen a vertical swipe adjusts.
enum SwipeAdjustment: Equatable {
    case brightness, volume

    var symbol: String { self == .brightness ? "sun.max.fill" : "speaker.wave.2.fill" }
}

/// The level shown while swiping.
struct AdjustmentHUD: Equatable {
    let kind: SwipeAdjustment
    let value: Double
}

/// System volume and screen brightness. Volume goes through a hidden `MPVolumeView`, the only
/// way an app may set it; having that view on screen also hides the system's volume overlay, so
/// the player's own level indicator is the only one shown.
@MainActor
final class DeviceLevels {
    static let shared = DeviceLevels()
    fileprivate weak var slider: UISlider?

    var volume: Double {
        get { Double(slider?.value ?? AVAudioSession.sharedInstance().outputVolume) }
        set {
            let value = Float(min(max(newValue, 0), 1))
            slider?.setValue(value, animated: false)
            slider?.sendActions(for: .valueChanged)
        }
    }

    var brightness: Double {
        get { Double(screen?.brightness ?? 0.5) }
        set { screen?.brightness = CGFloat(min(max(newValue, 0), 1)) }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
}

/// A volume view that is in the window (so the system volume overlay stays away) but can never
/// be seen: it sits outside a 1-point container that clips it, and the container itself is
/// placed off screen. On iOS 26 the slider's handle is a glass capsule that ignores a low alpha,
/// so transparency alone isn't enough.
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear
        let volume = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 160, height: 40))
        volume.alpha = 0.01
        volume.isUserInteractionEnabled = false
        container.addSubview(volume)
        DispatchQueue.main.async { Self.capture(volume) }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if DeviceLevels.shared.slider == nil,
           let volume = container.subviews.first as? MPVolumeView {
            Self.capture(volume)
        }
    }

    private static func capture(_ volume: MPVolumeView) {
        guard let slider = volume.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setThumbImage(UIImage(), for: .normal)
        DeviceLevels.shared.slider = slider
    }
}

/// The level pill shown while swiping (brightness on the left, volume on the right).
struct AdjustmentHUDView: View {
    let hud: AdjustmentHUD

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 150, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: 150 * hud.value, height: 6)
                }
            Text("\(Int((hud.value * 100).rounded()))")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glass(Capsule())
    }

    private var symbol: String {
        switch hud.kind {
        case .brightness: return hud.value < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if hud.value == 0 { return "speaker.slash.fill" }
            return hud.value < 0.34 ? "speaker.wave.1.fill" : hud.value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
}

/// "2× ▸▸" while the screen is held.
struct SpeedBoostPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("2×").font(.subheadline.weight(.bold).monospacedDigit())
            Image(systemName: "forward.fill").font(.caption.weight(.bold))
                .symbolEffect(.pulse, options: .repeating)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glass(Capsule())
    }
}
