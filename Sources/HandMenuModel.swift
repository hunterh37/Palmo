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
    /// 0...1 progress of the avatar-touch hold, drawn as a ring around Palmo.
    @Published var avatarSummonProgress: CGFloat = 0
    @Published var statusText: String = "Point at Palmo to open the menu"
    /// Index fingertip (normalized video coords) while the menu is open and
    /// the finger is extended — drives the selection reticle.
    @Published var selectionFingertip: CGPoint?
    /// 0...1 fill of the 1-second dwell on the orb under the fingertip.
    @Published var selectionDwellProgress: CGFloat = 0
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
    /// Reply-preset orbs shown while composing a response to a session.
    @Published var claudeReplyOrbs: [ReplyOrbDisplay] = []
    /// True while a session is selected and replies are being drafted/chosen.
    @Published var claudeComposing: Bool = false
    /// True while the on-device model is still drafting replies.
    @Published var claudeGenerating: Bool = false
    /// 0...1 fill of the fist-hold ring that raises/lowers the Claude orbs.
    @Published var claudeFistProgress: CGFloat = 0
    /// Live Claude Code sessions (hook-fed).
    let claudeSessions = ClaudeSessionStore()
    /// On-device reply drafting for the selected session.
    let replyEngine = ReplyPresetEngine()
    private let replySender = ClaudeReplySender()

    /// Known projects (auto-registered from Claude session cwds).
    let projects = ProjectRegistry()
    /// OpenRouter-backed ticket suggestion generation.
    let ticketEngine = TicketEngine()
    private let ticketOrbEngine = TicketOrbEngine()
    private let ticketDispatcher = TicketDispatcher()
    /// Floating ticket cards shown in windowed mode.
    @Published var ticketOrbs: [TicketOrbDisplay] = []
    /// True while the ticket flow (announce/load/present) is on screen.
    @Published var ticketsActive = false
    /// Drop target shown while presenting tickets, in normalized video coords.
    @Published var ticketDropZone: CGPoint?
    /// 0...1 drop-zone fill of the currently grabbed ticket.
    @Published var ticketSendProgress: CGFloat = 0
    /// 0...1 fill of the fist-hold ring that dismisses the tickets.
    @Published var ticketFistProgress: CGFloat = 0
    /// Name of the project the on-screen tickets belong to.
    @Published var ticketProjectName: String?
    private var sessionsSub: AnyCancellable?
    private var headPollTimer: Timer?
    private var previousSessions: [String: Bool] = [:]  // id -> isDone
    private var lastSuggestionAt: [String: Date] = [:]  // cwd -> last generation

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

    /// Where the in-camera Palmo avatar sits, in normalized video coordinates.
    var avatarCenter: CGPoint { engine.avatarCenter }
    /// Avatar touch radius as a fraction of frame height.
    var avatarTouchRadius: CGFloat { engine.avatarTouchRadius }

    /// Buddy face state derived from tracking + assistant activity.
    var buddyMood: BuddyMood {
        if assistant.isThinking { return .thinking }
        if ticketEngine.isGenerating || ticketOrbEngine.isAnnouncing
            || ticketOrbEngine.isLoading { return .thinking }
        if avatarSummonProgress > 0.02 { return .happy }
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
        projects.load()
        sessionsSub = claudeSessions.$sessions.sink { [weak self] sessions in
            Task { @MainActor in self?.sessionsChanged(sessions) }
        }
        startHeadPolling()
        await configureCamera()
        startFPSTimer()
    }

    // MARK: Ticket suggestions

    private var ticketsEnabled: Bool {
        AppSettings.shared.ticketSuggestionsEnabled
            && !AppSettings.shared.openRouterKey.isEmpty
    }

    /// Register every session cwd as a project and trigger suggestions when a
    /// session finishes (working → done).
    private func sessionsChanged(_ sessions: [ClaudeSession]) {
        var current: [String: Bool] = [:]
        for session in sessions {
            current[session.id] = session.isDone
            let project = projects.register(cwd: session.cwd)
            if session.isDone, previousSessions[session.id] == false, let project {
                maybeSuggestTickets(for: project)
            }
        }
        previousSessions = current
    }

    /// Cheap 30s poll: a new commit on a registered project triggers suggestions.
    private func startHeadPolling() {
        headPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ticketsEnabled else { return }
                for project in self.projects.projects {
                    let head = ProjectRegistry.currentHead(cwd: project.cwd)
                    guard let head, head != project.lastSeenHead else { continue }
                    let known = project.lastSeenHead != nil
                    self.projects.updateHead(cwd: project.cwd, head: head)
                    // Only react to changes, not the first observation.
                    if known { self.maybeSuggestTickets(for: project) }
                }
            }
        }
    }

    /// Manual trigger (toolbar button).
    func requestTickets(for project: Project) {
        lastSuggestionAt[project.cwd] = nil
        maybeSuggestTickets(for: project, manual: true)
    }

    private func maybeSuggestTickets(for project: Project, manual: Bool = false) {
        guard ticketsEnabled, !collapsed, !mouseModeEnabled else { return }
        guard ticketOrbEngine.state == .idle || manual else { return }
        // At most one automatic generation per project per 5 minutes.
        if !manual, let last = lastSuggestionAt[project.cwd],
           Date().timeIntervalSince(last) < 300 { return }
        lastSuggestionAt[project.cwd] = Date()

        if manual { ticketOrbEngine.reset() }
        ticketProjectName = project.name
        ticketOrbEngine.begin(now: CACurrentMediaTime())
        voice.say("Looking for tickets in \(project.name)")
        ticketEngine.start(project: project)
    }

    /// Deliver the grabbed ticket into the right project, then toast.
    private func dispatchTicket(_ ticket: Ticket) {
        let sessions = claudeSessions.sessions
        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.ticketDispatcher.dispatch(ticket, sessions: sessions)
                self.commandToast = "🎟️ \(summary)"
                self.voice.say(summary)
            } catch {
                self.commandToast = "🎟️ Couldn't start — \(error.localizedDescription)"
            }
            self.scheduleToastDismiss()
        }
    }

    private func clearTicketUI() {
        if !ticketOrbs.isEmpty { ticketOrbs = [] }
        ticketsActive = false
        ticketDropZone = nil
        ticketSendProgress = 0
        ticketFistProgress = 0
        ticketProjectName = nil
    }

    private func ticketStatus() -> String {
        switch ticketOrbEngine.state {
        case .announcing: return "Palmo spotted something…"
        case .loading: return "Finding tickets for \(ticketProjectName ?? "your project")…"
        case .grabbed: return "Drop the ticket on the ring to start Claude"
        case .dispatched: return "On it — Claude is starting"
        case .presenting:
            return "Pinch a ticket to grab it (fist to dismiss)"
        case .idle: return ""
        }
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
        // Tickets only live in windowed, non-mouse mode.
        if (collapsed || mouseModeEnabled), ticketOrbEngine.isActive {
            ticketOrbEngine.reset()
            ticketEngine.cancel()
            clearTicketUI()
        }

        if collapsed && !mouseModeEnabled {
            claudeEngine.update(sessions: claudeSessions.sessions,
                                presets: replyEngine.presets, hand: hand,
                                videoSize: frameSize, now: now)
            claudeOrbs = claudeEngine.orbs
            claudeReplyOrbs = claudeEngine.replyOrbs
            claudeFistProgress = claudeEngine.fistProgress
            claudeComposing = claudeEngine.composingSessionID != nil
            claudeGenerating = replyEngine.isGenerating

            // Session picked → start drafting replies on-device.
            if let sid = claudeEngine.selectedSessionID,
               let session = claudeSessions.sessions.first(where: { $0.id == sid }) {
                beginComposing(for: session)
            }

            // A reply orb was picked → send it into that session's channel.
            if let reply = claudeEngine.selectedReply {
                sendReply(reply)
            }

            // Compose ended (dismissed / idled out) without a pick → stop drafting.
            if claudeEngine.composingSessionID == nil,
               (replyEngine.isGenerating || !replyEngine.presets.isEmpty) {
                replyEngine.cancel()
            }

            statusText = claudeStatus()
            orbs = []
            dismissProgress = 0
            avatarSummonProgress = 0
            selectionFingertip = nil
            selectionDwellProgress = 0
            mouseOrb = nil
            return
        }
        if !claudeOrbs.isEmpty || !claudeReplyOrbs.isEmpty || claudeFistProgress > 0
            || claudeComposing {
            claudeEngine.reset()
            replyEngine.cancel()
            claudeOrbs = []
            claudeReplyOrbs = []
            claudeFistProgress = 0
            claudeComposing = false
            claudeGenerating = false
        }

        if mouseModeEnabled {
            // Mouse mode replaces the orb menu entirely.
            mouseEngine.update(hand: hand, videoSize: frameSize, now: now)
            mouseOrb = mouseEngine.orb
            mouseControlTrusted = mouseEngine.isTrusted
            orbs = []
            dismissProgress = 0
            avatarSummonProgress = 0
            selectionFingertip = nil
            selectionDwellProgress = 0
            statusText = mouseStatus(hand: hand)
            return
        }
        mouseOrb = nil

        // Windowed-mode ticket flow: while active it owns the pinch, and the
        // orb menu stands down so the two don't fight over gestures.
        if ticketOrbEngine.isActive {
            ticketOrbEngine.update(tickets: ticketEngine.tickets,
                                   generating: ticketEngine.isGenerating,
                                   hand: hand, videoSize: frameSize, now: now)
            if let fired = ticketOrbEngine.firedTicket { dispatchTicket(fired) }
            if ticketOrbEngine.isActive {
                ticketOrbs = ticketOrbEngine.orbs
                ticketsActive = true
                ticketDropZone = ticketOrbEngine.state == .loading
                    || ticketOrbEngine.isAnnouncing ? nil : ticketOrbEngine.dropZoneCenter
                ticketSendProgress = ticketOrbEngine.orbs
                    .first(where: \.grabbed)?.sendProgress ?? 0
                engine.reset()
                orbs = []
                ticketFistProgress = ticketOrbEngine.fistProgress
                dismissProgress = 0
                avatarSummonProgress = 0
                selectionFingertip = nil
                selectionDwellProgress = 0
                statusText = ticketStatus()
                return
            }
            // The flow just ended (dismissed, dispatched, or came up empty).
            ticketEngine.cancel()
            clearTicketUI()
            if let error = ticketEngine.lastError {
                commandToast = "🎟️ \(error)"
                scheduleToastDismiss()
            }
        } else if ticketsActive {
            clearTicketUI()
        }

        engine.setHover(from: hand)
        engine.update(hand: hand, videoSize: frameSize, now: now)
        orbs = engine.orbs
        dismissProgress = engine.dismissProgress
        avatarSummonProgress = engine.summonProgress
        selectionFingertip = engine.fingertip
        selectionDwellProgress = engine.dwellProgress

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
        // Composing a reply.
        if claudeComposing {
            if claudeReplyOrbs.contains(where: { $0.selectProgress > 0.02 }) {
                return "Hold on a reply to send it"
            }
            if claudeReplyOrbs.isEmpty {
                return "Drafting replies…"
            }
            return claudeGenerating
                ? "Point at a reply — more are still coming"
                : "Point at the reply to send (or fist to cancel)"
        }
        let done = sessions.filter(\.isDone).count
        if claudeOrbs.contains(where: { $0.selectProgress > 0.02 }) {
            return "Hold your finger on an orb to reply"
        }
        if claudeOrbs.first.map({ $0.center.y < 0.5 }) == true {
            return "Point at a session to draft a reply"
        }
        return done > 0
            ? "\(done) Claude session\(done == 1 ? "" : "s") done — hold a fist to review"
            : "\(sessions.count) Claude session\(sessions.count == 1 ? "" : "s") working"
    }

    // MARK: Claude reply composing

    /// Begin on-device drafting of replies for a session: gather its diff, then
    /// kick off the progressive generation rounds.
    private func beginComposing(for session: ClaudeSession) {
        guard ReplyPresetEngine.isAvailable else {
            commandToast = "🤖 On-device model unavailable"
            scheduleToastDismiss()
            return
        }
        let name = session.name
        let cwd = session.cwd
        let lastMessage = session.lastMessage
        voice.say("Drafting replies for \(name)")
        Task { [weak self] in
            let diff = await ReplyPresetEngine.gitDiff(cwd: cwd)
            guard let self else { return }
            self.replyEngine.start(context: ComposeContext(
                sessionName: name, cwd: cwd, lastMessage: lastMessage, diff: diff))
        }
    }

    /// Deliver the chosen reply into the session's channel, then wind down.
    private func sendReply(_ reply: (sessionID: String, text: String)) {
        let session = claudeSessions.sessions.first(where: { $0.id == reply.sessionID })
        let name = session?.name ?? "session"
        let port = session?.port
        replyEngine.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.replySender.send(text: reply.text,
                                                sessionID: reply.sessionID, port: port)
                self.commandToast = "🤖 Sent to \(name)"
                self.voice.say("Sent to \(name)")
            } catch {
                self.commandToast = "🤖 Couldn't send — \(error.localizedDescription)"
            }
            self.scheduleToastDismiss()
        }
    }

    private func scheduleToastDismiss() {
        commandToastTask?.cancel()
        commandToastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled { self?.commandToast = nil }
        }
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
            if avatarSummonProgress > 0.02 { return "Keep touching Palmo..." }
            return hand == nil
                ? "Show a hand to the camera"
                : "Touch Palmo for 1 second to summon the menu"
        case .summoning:
            return "Summoning..."
        case .open:
            return "Point your index finger at an orb and hold 1 second to open it. Fist to dismiss."
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
