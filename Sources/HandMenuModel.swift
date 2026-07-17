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

    /// Claude Code session orbs shown in collapsed mode.
    @Published var claudeOrbs: [ClaudeOrbDisplay] = []
    /// 0...1 fill of the fist-hold ring that raises/lowers the Claude orbs.
    @Published var claudeFistProgress: CGFloat = 0
    /// Live Claude Code sessions (hook-fed).
    let claudeSessions = ClaudeSessionStore()

    let session = AVCaptureSession()
    /// The buddy assistant (chat) engine, shared with the chat window.
    let assistant = AssistantEngine()
    /// Focus timer shown on the dashboard.
    let focus = FocusTimer()
    /// Toast for fired air commands ("✌️ Screenshot").
    @Published var commandToast: String?
    /// 0...1 progress ring while an air gesture is being held.
    @Published var commandHoldProgress: CGFloat = 0
    @Published var commandHoldLabel: String?

    private let pipeline = HandVisionPipeline()
    private let engine = OrbMenuEngine()
    private let mouseEngine = MouseControlEngine()
    private let commands = GestureCommandEngine()
    private let claudeEngine = ClaudeOrbEngine()
    private let voice = VoiceReactor()
    private var commandToastTask: Task<Void, Never>?
    private var lastFrameAt: CFTimeInterval = 0
    private var fpsCounter = 0
    private var fpsTimer: Timer?
    private var launchClearTask: Task<Void, Never>?
    private var settingsSub: AnyCancellable?

    /// Buddy face state derived from tracking + assistant activity.
    var buddyMood: BuddyMood {
        if assistant.isThinking { return .thinking }
        if hands.contains(where: { $0.isPinching }) { return .happy }
        if !hands.isEmpty { return .watching }
        return .idle
    }

    /// Normalized -1...1 gaze target pointing at the primary hand.
    var buddyGaze: CGPoint {
        guard let palm = hands.first?.palmCenter else { return .zero }
        return CGPoint(x: (palm.x - 0.5) * 2, y: (palm.y - 0.5) * 2)
    }

    private func applySettings() {
        let s = AppSettings.shared
        mouseEngine.sensitivity = s.cursorSensitivity
        mouseEngine.pinchClickEnabled = s.pinchClickEnabled
        mouseEngine.scrollGestureEnabled = s.scrollGestureEnabled
        mouseEngine.scrollSpeed = s.scrollSpeed
        engine.actions = MenuAction.ring(bundleIDs: s.orbBundleIDs)
    }

    func start() async {
        applySettings()
        // `mirrored`'s didSet does not fire at init, so push the current value
        // into the pipeline explicitly or the coordinate flip runs on its own
        // default until the user first toggles the control.
        pipeline.mirrored = mirrored
        mouseEngine.onClick = { StatsStore.shared.countClick() }
        commands.onFired = { [weak self] cmd, label in
            guard let self else { return }
            if cmd == .screenshot { StatsStore.shared.countScreenshot() }
            self.commandToast = label
            self.voice.say(cmd.label)
            self.commandToastTask?.cancel()
            self.commandToastTask = Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if !Task.isCancelled { self.commandToast = nil }
            }
        }
        settingsSub = AppSettings.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
        pipeline.onFrame = { [weak self] hands, frameSize in
            Task { @MainActor in self?.publish(hands, frameSize: frameSize) }
        }
        claudeSessions.start()
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
        // Kill switch: drop everything instantly.
        if AppSettings.shared.trackingPaused {
            if !self.hands.isEmpty { self.hands = []; orbs = []; mouseOrb = nil }
            statusText = "Tracking paused — flip the switch to wake me up"
            return
        }
        self.hands = hands
        if frameSize != videoSize { videoSize = frameSize }
        fpsCounter += 1

        // Stats: hands-free control time + air commands.
        let now0 = CACurrentMediaTime()
        if !hands.isEmpty, lastFrameAt > 0 {
            StatsStore.shared.addHandTime(min(now0 - lastFrameAt, 0.2))
        }
        lastFrameAt = now0
        commands.update(hand: hands.first(where: { $0.isPeaceSign || $0.isThumbsUp })
                              ?? hands.first, now: now0)
        commandHoldProgress = commands.holdProgress
        commandHoldLabel = commands.holdingLabel

        // Drive the menu with the best hand: prefer one with a palm center,
        // then the open one.
        let hand = hands.first(where: { $0.isOpenPalmUp })
            ?? hands.first(where: { $0.palmCenter != nil })
            ?? hands.first
        let now = CACurrentMediaTime()

        // Claude session orbs live in collapsed mode; the fist gesture is
        // theirs there (mouse mode keeps the fist for scrolling).
        if collapsed && !mouseModeEnabled {
            claudeEngine.update(sessions: claudeSessions.sessions, hand: hand,
                                videoSize: frameSize, now: now)
            claudeOrbs = claudeEngine.orbs
            claudeFistProgress = claudeEngine.fistProgress
            if let sid = claudeEngine.selectedSessionID,
               let session = claudeSessions.sessions.first(where: { $0.id == sid }) {
                claudeSessions.acknowledge(sid)
                commandToast = "🤖 \(session.name) checked"
                voice.say("\(session.name) done")
                commandToastTask?.cancel()
                commandToastTask = Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    if !Task.isCancelled { self.commandToast = nil }
                }
            }
            statusText = claudeStatus()
            orbs = []
            dismissProgress = 0
            mouseOrb = nil
            return
        }
        if !claudeOrbs.isEmpty || claudeFistProgress > 0 {
            claudeEngine.reset()
            claudeOrbs = []
            claudeFistProgress = 0
        }

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
            StatsStore.shared.countLaunch()
            voice.say("Opening \(fired.name)")
            launchClearTask?.cancel()
            launchClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if !Task.isCancelled { self?.launchedName = nil }
            }
        }
        statusText = status(for: engine.state, hand: hand)
    }

    private func claudeStatus() -> String {
        let sessions = claudeSessions.sessions
        if sessions.isEmpty { return "No Claude sessions" }
        let done = sessions.filter(\.isDone).count
        if claudeOrbs.contains(where: { $0.selectProgress > 0.02 }) {
            return "Hold your finger on an orb to select it"
        }
        if claudeOrbs.first.map({ $0.center.y < 0.5 }) == true {
            return "Point at a session orb to check it off"
        }
        return done > 0
            ? "\(done) Claude session\(done == 1 ? "" : "s") done — hold a fist to review"
            : "\(sessions.count) Claude session\(sessions.count == 1 ? "" : "s") working"
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
