import AVFoundation
import SwiftUI
import Combine
import QuartzCore

/// Owns the camera + Vision pipeline and the orb menu engine, and publishes
/// UI state. Vision runs on a background queue; published mutations hop to
/// the main actor.
@MainActor
final class HandMenuModel: ObservableObject {
    @Published var cameraAuthorized: Bool = true
    @Published var fps: Int = 0
    @Published var hands: [DetectedHand] = []
    @Published var orbs: [OrbDisplay] = []
    /// 0...1 progress of the fist-hold dismissal, drawn as a ring on the command orb.
    @Published var dismissProgress: CGFloat = 0
    @Published var statusText: String = "Hold your palm up to the camera"
    @Published var launchedName: String?
    /// Pixel size of the camera frames, for aspect-fill-correct overlay mapping.
    @Published var videoSize: CGSize = CGSize(width: 16, height: 9)

    @Published var mirrored: Bool = true {
        didSet { pipeline.mirrored = mirrored }
    }

    /// Mouse-control mode: replaces the orb menu with a draggable gray orb
    /// that drives the real macOS cursor.
    @Published var mouseModeEnabled: Bool = false {
        didSet {
            mouseEngine.setEnabled(mouseModeEnabled, now: CACurrentMediaTime())
            if mouseModeEnabled { engine.reset() } else { mouseOrb = nil }
        }
    }
    @Published var mouseOrb: MouseOrbDisplay?

    /// Flip horizontal cursor movement in mouse mode.
    @Published var mouseInvertX: Bool = false {
        didSet { mouseEngine.invertHorizontal = mouseInvertX }
    }

    /// Collapse mode: shrinks the main window into a small always-on-top
    /// overlay pinned to the top-right corner of the screen.
    @Published var collapsed: Bool = false {
        didSet { CollapseWindowStyler.shared.setCollapsed(collapsed) }
    }

    @Published var mouseControlTrusted: Bool = true

    let session = AVCaptureSession()
    private let pipeline = HandVisionPipeline()
    private let engine = OrbMenuEngine()
    private let mouseEngine = MouseControlEngine()
    private var fpsCounter = 0
    private var fpsTimer: Timer?
    private var launchClearTask: Task<Void, Never>?

    func start() async {
        pipeline.onFrame = { [weak self] hands, frameSize in
            Task { @MainActor in self?.publish(hands, frameSize: frameSize) }
        }
        await configureCamera()
        startFPSTimer()
    }

    private func configureCamera() async {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        cameraAuthorized = granted
        guard granted else { return }

        session.beginConfiguration()
        session.sessionPreset = .high
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        if let device, let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(pipeline, queue: pipeline.queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        Task.detached { [session] in session.startRunning() }
    }

    private func publish(_ hands: [DetectedHand], frameSize: CGSize) {
        self.hands = hands
        if frameSize != videoSize { videoSize = frameSize }
        fpsCounter += 1

        // Drive the menu with the best hand: prefer one with a palm center,
        // then the open one.
        let hand = hands.first(where: { $0.isOpenPalmUp })
            ?? hands.first(where: { $0.palmCenter != nil })
            ?? hands.first
        let now = CACurrentMediaTime()
        if mouseModeEnabled {
            // Mouse mode replaces the orb menu entirely.
            mouseEngine.update(hand: hand, videoSize: frameSize, now: now)
            mouseOrb = mouseEngine.orb
            mouseControlTrusted = mouseEngine.isTrusted
            orbs = []
            dismissProgress = 0
            statusText = mouseStatus(hand: hand)
            return
        }
        mouseOrb = nil
        engine.setHover(from: hand)
        engine.update(hand: hand, videoSize: frameSize, now: now)
        orbs = engine.orbs
        dismissProgress = engine.dismissProgress

        if let fired = engine.firedAction {
            launchedName = fired.name
            launchClearTask?.cancel()
            launchClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if !Task.isCancelled { self?.launchedName = nil }
            }
        }
        statusText = status(for: engine.state, hand: hand)
    }

    private func mouseStatus(hand: DetectedHand?) -> String {
        if !mouseControlTrusted {
            return "Grant Accessibility access in System Settings to control the mouse"
        }
        if mouseOrb?.grabbed == true { return "Dragging: release the pinch to drop the orb" }
        return hand == nil
            ? "Show a hand to the camera"
            : "Pinch the gray orb and drag to move the mouse"
    }

    private func status(for state: OrbMenuEngine.State, hand: DetectedHand?) -> String {
        switch state {
        case .hidden:
            return hand == nil
                ? "Show a hand to the camera"
                : "Hold your palm up, fingers spread, to summon the menu"
        case .summoning:
            return "Summoning..."
        case .open:
            return "Pinch an orb to open the app. Hold a fist for 1 second to dismiss."
        case .launching(let action, _, _):
            return "Opening \(action.name)"
        case .closing:
            return ""
        }
    }

    private func startFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = self.fpsCounter
                self.fpsCounter = 0
            }
        }
    }
}
