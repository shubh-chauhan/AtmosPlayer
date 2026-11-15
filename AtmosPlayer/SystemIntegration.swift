import SwiftUI
import UIKit
import AVKit
import Combine
import AetherEngine

// MARK: - Orientation

/// Lets the player turn the app to landscape and back, the way Infuse does.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Browsing stays upright on iPhone, like the Apple TV app; the player turns to landscape.
    static let defaultMask: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    static var orientationMask: UIInterfaceOrientationMask = defaultMask

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

enum OrientationLock {
    @MainActor
    static func set(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}

// MARK: - Picture in Picture

/// Builds the PiP controller for whichever pipeline the engine picked, and keeps the engine
/// told when PiP is on (it keeps the pipeline alive in the background).
@MainActor
final class PiPController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    private weak var engine: AetherEngine?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    private var nativeLayer: AVPlayerLayer?
    private var softwareSource: ObjectIdentifier?

    func attach(_ engine: AetherEngine) {
        guard self.engine !== engine || cancellables.isEmpty else { return }
        self.engine = engine
        cancellables.removeAll()
        engine.$softwarePiPSource
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        engine.$videoRoute
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        engine.$hasFirstFrameReadyForDisplay
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    private func rebuild() {
        guard let engine, AVPictureInPictureController.isPictureInPictureSupported() else {
            isPossible = false
            return
        }
        if let layer = engine.nativePlayerLayer {
            if nativeLayer === layer, controller != nil { return }
            nativeLayer = layer
            softwareSource = nil
            install(AVPictureInPictureController(playerLayer: layer))
        } else if let source = engine.softwarePiPSource {
            let identity = ObjectIdentifier(source)
            if softwareSource == identity, controller != nil { return }
            softwareSource = identity
            nativeLayer = nil
            install(source.makePictureInPictureController())
        } else {
            nativeLayer = nil
            softwareSource = nil
            install(nil)
        }
    }

    private func install(_ newController: AVPictureInPictureController?) {
        possibleObservation = nil
        controller = newController
        guard let newController else {
            isPossible = false
            return
        }
        newController.delegate = self
        newController.canStartPictureInPictureAutomaticallyFromInline = true
        possibleObservation = newController.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = true
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.engine?.pictureInPictureActive = false
            self.isActive = false
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
