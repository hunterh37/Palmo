import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: HandMenuModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var stats = StatsStore.shared
    @Environment(\.openWindow) private var openWindow
    /// 0→1 dream fade-in progress when entering collapsed mode.
    @State private var dreamReveal: CGFloat = 0

    /// True while any tracked hand shows an open raised palm.
    private var handRaised: Bool {
        model.hands.contains { $0.isOpenPalmUp }
    }

    var body: some View {
        Group {
            if model.collapsed {
                collapsedRoot
            } else {
                dashboard
            }
        }
        .background(WindowAccessor())
        .onChange(of: model.collapsed) { _, collapsed in
            if collapsed {
                dreamReveal = 0
                withAnimation(.easeOut(duration: 1.4)) { dreamReveal = 1 }
            } else {
                dreamReveal = 0
            }
        }
    }

    // MARK: - Dashboard (the useful main window)

    private var dashboard: some View {
        HStack(spacing: 24) {
            leftColumn
                .frame(width: 300)
            rightColumn
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 600)
        .background(LiquidGlassBackground())
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Hero
            HStack(alignment: .center, spacing: 14) {
                PalmoAvatarView(mood: model.buddyMood, gaze: model.buddyGaze,
                                waving: handRaised)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Brand.name)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.gradient)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 6)

            // Tracking kill switch
            HStack(spacing: 12) {
                Image(systemName: settings.trackingPaused ? "eye.slash" : "eye")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(settings.trackingPaused ? .secondary : Brand.accent)
                    .frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
                Text("Tracking").font(.callout)
                Spacer()
                Circle()
                    .fill(settings.trackingPaused ? Color.secondary.opacity(0.4) : .green)
                    .frame(width: 6, height: 6)
                    .shadow(color: settings.trackingPaused ? .clear : .green.opacity(0.8),
                            radius: 4)
                Toggle("", isOn: $settings.trackingPaused.inverted)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Brand.accent)
            }
            .glassCard(padding: 14)

            // Focus timer
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus").microLabel()
                    Text(model.focus.running ? model.focus.display : "25:00")
                        .font(.system(size: 36, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(model.focus.running ? .primary : .secondary)
                }
                Spacer()
                Button {
                    model.focus.running ? model.focus.stop() : model.focus.start()
                } label: {
                    Image(systemName: model.focus.running ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.focus.running ? Color.primary : .white)
                        .frame(width: 36, height: 36)
                        .background {
                            if model.focus.running {
                                Circle().fill(.ultraThinMaterial)
                                    .overlay(Circle().strokeBorder(
                                        .white.opacity(0.15), lineWidth: 1))
                            } else {
                                Circle().fill(Brand.gradient)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(model.focus.running ? "Stop focus session" : "Start focus session")
            }
            .glassCard(padding: 14)
            .animation(.default, value: model.focus.remaining)

            // Chat launcher
            Button {
                openWindow(id: "assistant-chat")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Brand.gradient, in: Circle())
                    Text("Chat").font(.callout)
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("On-device AI — private, offline")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .glassCard(padding: 12)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)

            gestureCheatSheet
            Spacer()
        }
    }

    private var gestureCheatSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gestures").microLabel()
            cheatRow("👉", "Touch Palmo — app orbs")
            cheatRow("🤏", "Click / launch")
            cheatRow("✊", "Scroll")
            cheatRow("✌️", settings.peaceCommand.label)
            cheatRow("👍", settings.thumbsUpCommand.label)
        }
        .glassCard(padding: 14)
    }

    private func cheatRow(_ glyph: String, _ action: String) -> some View {
        HStack(spacing: 12) {
            Text(glyph)
                .font(.system(size: 15))
                .grayscale(0.4)
                .frame(width: 22)
            Text(action)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 14) {
            cameraCard
            statsRow
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard("flame", "\(stats.streakDays)", "streak")
            statCard("arrow.up.forward.app", "\(stats.appLaunches)", "launches")
            statCard("hand.tap", "\(stats.clicks)", "clicks")
            statCard("camera.viewfinder", "\(stats.screenshots)", "shots")
            statCard("clock", handTime, "hands-free")
        }
    }

    private var handTime: String {
        let m = Int(stats.handsSeenSeconds) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    private func statCard(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label).microLabel()
        }
        .frame(maxWidth: .infinity)
        .glassCard(padding: 12)
        .help(label.capitalized)
    }

    private var cameraCard: some View {
        GeometryReader { geo in
            ZStack {
                if settings.trackingPaused {
                    VStack(spacing: 12) {
                        BuddyView(mood: .idle).frame(width: 90, height: 90)
                            .saturation(0)
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.85))
                } else if model.cameraAuthorized {
                    CameraPreview(session: model.session, mirrored: model.mirrored)
                    AvatarSummonOverlay(progress: model.avatarSummonProgress,
                                        center: model.avatarCenter,
                                        touchRadius: model.avatarTouchRadius,
                                        mood: model.buddyMood,
                                        gaze: model.buddyGaze,
                                        menuOpen: !model.orbs.isEmpty,
                                        size: geo.size, videoSize: model.videoSize)
                    OrbSceneView(orbs: model.orbs, size: geo.size,
                                 videoSize: model.videoSize)
                        .allowsHitTesting(false)
                    OrbLabelOverlay(orbs: model.orbs, size: geo.size,
                                    videoSize: model.videoSize)
                    DismissRingOverlay(orbs: model.orbs,
                                       progress: model.dismissProgress,
                                       size: geo.size, videoSize: model.videoSize)
                    if let tip = model.selectionFingertip {
                        FingertipReticleOverlay(tip: tip,
                                                progress: model.selectionDwellProgress,
                                                size: geo.size,
                                                videoSize: model.videoSize)
                    }
                    if let mouseOrb = model.mouseOrb {
                        MouseOrbOverlay(orb: mouseOrb, size: geo.size,
                                        videoSize: model.videoSize)
                    }
                    if model.ticketsActive {
                        TicketOrbOverlay(orbs: model.ticketOrbs,
                                         dropZone: model.ticketDropZone,
                                         sendProgress: model.ticketSendProgress,
                                         fistProgress: model.ticketFistProgress,
                                         loading: model.ticketEngine.isGenerating
                                             && model.ticketOrbs.isEmpty,
                                         projectName: model.ticketProjectName,
                                         size: geo.size, videoSize: model.videoSize)
                    }
                    HandOverlay(hands: model.hands, size: geo.size,
                                videoSize: model.videoSize)
                } else {
                    cameraDeniedNotice.background(Color.black)
                }

                VStack {
                    if let name = model.launchedName {
                        launchToast(name)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let toast = model.commandToast {
                        commandToastView(toast)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer()
                    if model.commandHoldProgress > 0.02, let label = model.commandHoldLabel {
                        holdHUD(label)
                    }
                    quickToggles
                }
                .animation(.spring(duration: 0.35), value: model.launchedName)
                .animation(.spring(duration: 0.3), value: model.commandToast)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    private func commandToastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .foregroundStyle(.white)
            .padding(.top, 14)
    }

    private func holdHUD(_ label: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: model.commandHoldProgress)
                    .stroke(Brand.accent, style: .init(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 10)
    }

    private var quickToggles: some View {
        HStack(spacing: 6) {
            iconToggle("cursorarrow", $model.mouseModeEnabled, "Mouse mode")
            if model.mouseModeEnabled {
                iconToggle("arrow.left.arrow.right", $model.mouseInvertX, "Invert X")
            }
            if settings.ticketSuggestionsEnabled,
               let project = model.projects.mostRecent {
                Button {
                    model.requestTickets(for: project)
                } label: {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.ticketsActive ? .white : .white.opacity(0.45))
                        .frame(width: 28, height: 24)
                        .background(
                            model.ticketsActive ? AnyShapeStyle(Brand.accent.opacity(0.85))
                                                : AnyShapeStyle(Color.white.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Suggest tickets for \(project.name)")
            }
            iconToggle("arrow.trianglehead.2.clockwise.rotate.90", $model.mirrored, "Mirror")
            iconToggle("rectangle.compress.vertical", $model.collapsed, "Collapse")
            Spacer()
            Text("\(model.fps)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .help("Frames per second")
            ForEach(model.hands) { hand in
                Circle()
                    .fill(hand.isPinching ? .yellow : (hand.isLeft ? .blue : .orange))
                    .frame(width: 6, height: 6)
                    .help(hand.isLeft ? "Left hand" : "Right hand")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .animation(.spring(duration: 0.25), value: model.mouseModeEnabled)
    }

    private func iconToggle(_ icon: String, _ binding: Binding<Bool>,
                            _ help: String) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(binding.wrappedValue ? .white : .white.opacity(0.45))
                .frame(width: 28, height: 24)
                .background(
                    binding.wrappedValue ? AnyShapeStyle(Brand.accent.opacity(0.85))
                                         : AnyShapeStyle(Color.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Collapsed overlay mode (unchanged behavior)

    private var collapsedRoot: some View {
        GeometryReader { geo in
            ZStack {
                if model.cameraAuthorized {
                    CameraPreview(session: model.session, mirrored: model.mirrored)
                    HandOverlay(hands: model.hands, size: geo.size,
                                videoSize: model.videoSize)
                    ClaudeOrbOverlay(orbs: model.claudeOrbs,
                                     replyOrbs: model.claudeReplyOrbs,
                                     generating: model.claudeGenerating,
                                     fistProgress: model.claudeFistProgress,
                                     size: geo.size, videoSize: model.videoSize)
                } else {
                    cameraDeniedNotice
                }
                VStack {
                    if let toast = model.commandToast {
                        commandToastView(toast)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer()
                    collapsedBar
                }
                .animation(.spring(duration: 0.3), value: model.commandToast)

                // Palmo peeks in when a hand is raised, even while collapsed.
                PalmoAvatarView(mood: model.buddyMood, gaze: model.buddyGaze,
                                waving: handRaised)
                    .frame(width: 78, height: 78)
                    .opacity(handRaised ? 1 : 0)
                    .scaleEffect(handRaised ? 1 : 0.75, anchor: .bottomLeading)
                    .animation(.spring(duration: 0.55, bounce: 0.35), value: handRaised)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(.leading, 10)
                    .padding(.bottom, 34)
            }
            .overlay { DreamGlow().opacity(Double(dreamReveal)) }
            // Escape hatch: the expand button sits near the feathered edge and
            // the window is movable-by-background, so a double-click anywhere
            // reliably restores the full window even if the button is hard to hit.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.collapsed = false }
        }
        .frame(minWidth: CollapseWindowStyler.collapsedSize.width,
               minHeight: CollapseWindowStyler.collapsedSize.height)
    }

    /// Minimal chrome shown while in collapsed overlay mode.
    private var collapsedBar: some View {
        HStack(spacing: 10) {
            Label(model.statusText, systemImage: "hand.raised")
                .lineLimit(1)
            Spacer()
            Button {
                model.collapsed = false
            } label: {
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.18), in: Circle())
                    // Make the whole circle tappable, not just the glyph.
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Expand")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        // Sit above the ~30pt feathered/blurred edge so the control stays
        // visible and hittable rather than fading into the dream mask.
        .padding(.bottom, 40)
        .padding(.horizontal, 24)
    }

    private func launchToast(_ name: String) -> some View {
        Label(name, systemImage: "sparkles")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 14)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            BuddyView(mood: model.buddyMood, gaze: model.buddyGaze)
                .frame(width: 26, height: 26)
            Text(Brand.name)
                .font(.system(.caption, design: .rounded).weight(.bold))
            Label(model.statusText, systemImage: "hand.raised")
            Spacer()
            Toggle("Mouse", isOn: $model.mouseModeEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
            if model.mouseModeEnabled {
                Toggle("Invert X", isOn: $model.mouseInvertX)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Toggle("Mirror", isOn: $model.mirrored)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Toggle("Collapse", isOn: $model.collapsed)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Divider().frame(height: 14)
            Text("\(model.fps) fps")
            ForEach(model.hands) { hand in
                Text(hand.isLeft ? "L" : "R")
                    .fontWeight(.bold)
                    .foregroundStyle(hand.isPinching ? .yellow : (hand.isLeft ? .blue : .orange))
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var cameraDeniedNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text("Camera access denied")
            Text("Enable it in System Settings, Privacy & Security, Camera.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Palmo living inside the camera view: the touch target that summons the
/// orb menu. Point your index finger at him and hold for 1 second — a
/// circular progress ring fills around him, then the menu pops open beside
/// him.
private struct AvatarSummonOverlay: View {
    let progress: CGFloat
    /// Normalized video-space center of the avatar (top-left origin).
    let center: CGPoint
    /// Touch radius as a fraction of frame height.
    let touchRadius: CGFloat
    let mood: BuddyMood
    let gaze: CGPoint
    let menuOpen: Bool
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        let c = point(center)
        let r = touchRadius * drawnSize().height
        ZStack {
            // Soft halo so Palmo reads against any webcam background.
            Circle()
                .fill(Brand.accent.opacity(progress > 0.02 ? 0.28 : 0.14))
                .frame(width: r * 2.3, height: r * 2.3)
                .blur(radius: r * 0.35)
            // Touch-hold progress ring.
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 4)
                .frame(width: r * 2, height: r * 2)
                .opacity(progress > 0.02 ? 1 : 0)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Brand.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: r * 2, height: r * 2)
            PalmoAvatarView(mood: mood, gaze: gaze, waving: menuOpen)
                .frame(width: r * 1.9, height: r * 1.9)
        }
        .scaleEffect(progress > 0.02 ? 1.08 : 1.0)
        .animation(.spring(duration: 0.3), value: progress > 0.02)
        .position(c)
        .allowsHitTesting(false)
    }

    private func drawnSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        let drawn = drawnSize()
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}

/// Selection reticle pinned to the extended index fingertip while the orb
/// menu is open: an empty circle that fills clockwise over the 1-second
/// dwell when it rests on an orb.
private struct FingertipReticleOverlay: View {
    /// Fingertip in normalized video coordinates (top-left origin).
    let tip: CGPoint
    /// 0...1 dwell fill while resting on an orb.
    let progress: CGFloat
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        let c = point(tip)
        let r: CGFloat = 0.022 * drawnSize().height
        ZStack {
            // Empty ring so the user can see exactly where they're pointing.
            Circle()
                .stroke(.white.opacity(0.85), lineWidth: 2.5)
                .frame(width: r * 2, height: r * 2)
                .shadow(color: .black.opacity(0.6), radius: 3)
            // Circular progress fill while dwelling on an orb.
            if progress > 0.02 {
                Circle()
                    .fill(Brand.accent.opacity(0.25))
                    .frame(width: r * 2, height: r * 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Brand.accent,
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: r * 2, height: r * 2)
            }
        }
        .scaleEffect(progress > 0.02 ? 1.15 : 1.0)
        .animation(.easeOut(duration: 0.15), value: progress > 0.02)
        .position(c)
        .allowsHitTesting(false)
    }

    private func drawnSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        let drawn = drawnSize()
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}

/// Circular countdown drawn around the command orb while a fist is held.
/// Fills clockwise over the 1 second hold; the menu dismisses at full circle.
private struct DismissRingOverlay: View {
    let orbs: [OrbDisplay]
    let progress: CGFloat
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        ZStack {
            if progress > 0.02, let command = orbs.first(where: { $0.isCommand }) {
                let c = point(command.center)
                let r = command.radiusNorm * drawnSize().height * 1.7
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.red,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "xmark")
                        .font(.system(size: max(r * 0.4, 10), weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: r * 2, height: r * 2)
                .position(c)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawnSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        let drawn = drawnSize()
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}

/// App icons and names floating on the orbs, drawn above the 3D layer.
private struct OrbLabelOverlay: View {
    let orbs: [OrbDisplay]
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        ZStack {
            ForEach(orbs) { orb in
                if let action = orb.action, orb.scale > 0.35 {
                    let c = point(orb.center)
                    let r = orb.radiusNorm * drawnSize().height * orb.scale
                    VStack(spacing: 4) {
                        if let icon = action.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: r * 1.05, height: r * 1.05)
                                .shadow(radius: 4)
                        }
                        Text(action.name)
                            .font(.system(size: max(r * 0.30, 9), weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 2)
                    }
                    .position(c)
                    .opacity(Double(min(orb.scale, 1)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawnSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        let drawn = drawnSize()
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}

/// The mouse-control orb: a small gray sphere at the center of the view that
/// the user pinches and drags to drive the real macOS cursor.
private struct MouseOrbOverlay: View {
    let orb: MouseOrbDisplay
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        let c = point(orb.center)
        let r = orb.radiusNorm * drawnSize().height * orb.scale
            * (orb.grabbed ? 1.15 : 1.0)
        ZStack {
            // Soft halo so the orb reads against any webcam background.
            Circle()
                .fill(Color.white.opacity(orb.grabbed ? 0.22 : 0.10))
                .frame(width: r * 3.0, height: r * 3.0)
                .blur(radius: r * 0.5)
            Circle()
                .fill(
                    RadialGradient(
                        colors: orb.grabbed
                            ? [Color(white: 0.95), Color(white: 0.55)]
                            : [Color(white: 0.80), Color(white: 0.42)],
                        center: .init(x: 0.35, y: 0.3),
                        startRadius: 0, endRadius: r * 1.4)
                )
                .frame(width: r * 2, height: r * 2)
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(orb.grabbed ? 0.9 : 0.5),
                        lineWidth: orb.grabbed ? 3 : 2)
                )
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
            Image(systemName: "cursorarrow")
                .font(.system(size: max(r * 0.7, 10), weight: .bold))
                .foregroundStyle(.white.opacity(orb.grabbed ? 1.0 : 0.75))
        }
        .position(c)
        .animation(.easeOut(duration: 0.12), value: orb.grabbed)
        .allowsHitTesting(false)
    }

    private func drawnSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        let drawn = drawnSize()
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}

/// Floating ticket cards the user pinch-grabs and drops on the send ring to
/// hand off to Claude Code. Also renders the loading shimmer while tickets
/// are being generated and the fist-hold dismiss ring.
private struct TicketOrbOverlay: View {
    let orbs: [TicketOrbDisplay]
    let dropZone: CGPoint?
    let sendProgress: CGFloat
    let fistProgress: CGFloat
    let loading: Bool
    let projectName: String?
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        ZStack {
            if let dropZone, !orbs.isEmpty {
                dropRing(at: point(dropZone))
            }
            ForEach(orbs) { cardView($0) }
            if loading { loadingBadge }
            if fistProgress > 0.03 { fistRing }
        }
        .allowsHitTesting(false)
    }

    private func cardView(_ orb: TicketOrbDisplay) -> some View {
        let c = point(orb.center)
        let h = orb.radiusNorm * drawnSize().height * orb.scale
            * (orb.grabbed ? 1.12 : 1.0)
        let w = h * 2.4
        let tint = priorityTint(orb.ticket.priority)
        return VStack(spacing: h * 0.10) {
            HStack(spacing: 5) {
                Circle().fill(tint)
                    .frame(width: max(h * 0.14, 5), height: max(h * 0.14, 5))
                Text(orb.ticket.title)
                    .font(.system(size: max(h * 0.20, 10), weight: .bold,
                                  design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            if !orb.ticket.detail.isEmpty {
                Text(orb.ticket.detail)
                    .font(.system(size: max(h * 0.15, 8)))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(h * 0.22)
        .frame(width: w, height: h * 2, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: h * 0.28, style: .continuous)
                .fill(.black.opacity(orb.grabbed ? 0.72 : 0.55))
                .overlay(RoundedRectangle(cornerRadius: h * 0.28, style: .continuous)
                    .strokeBorder(orb.grabbed ? .white.opacity(0.9) : tint.opacity(0.7),
                                  lineWidth: orb.grabbed ? 2.5 : 1.5)))
        .shadow(color: tint.opacity(orb.grabbed ? 0.6 : 0.3),
                radius: orb.grabbed ? 14 : 8, y: 3)
        .position(c)
        .animation(.easeOut(duration: 0.12), value: orb.grabbed)
    }

    private func dropRing(at c: CGPoint) -> some View {
        let r = 0.11 * drawnSize().height
        return ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [7, 6]))
                .foregroundStyle(.white.opacity(0.45))
            Circle()
                .trim(from: 0, to: sendProgress)
                .stroke(Brand.accent, style: .init(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: max(r * 0.30, 11), weight: .bold))
                Text("Start Claude")
                    .font(.system(size: max(r * 0.14, 8), weight: .semibold,
                                  design: .rounded))
            }
            .foregroundStyle(.white.opacity(sendProgress > 0.02 ? 1 : 0.75))
        }
        .frame(width: r * 2, height: r * 2)
        .position(c)
    }

    private var loadingBadge: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding tickets\(projectName.map { " for \($0)" } ?? "")…")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.55)))
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: 110, height: 56)
                        .shimmering(delay: Double(i) * 0.2)
                }
            }
        }
        .position(x: size.width / 2, y: size.height * 0.24)
    }

    private var fistRing: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: fistProgress)
                .stroke(Color.red, style: .init(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 44, height: 44)
        .position(x: size.width / 2, y: size.height / 2)
    }

    private func priorityTint(_ p: Int) -> Color {
        switch p {
        case 1: return .orange
        case 2: return Brand.accent
        default: return .blue
        }
    }

    private func drawnSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else { return size }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        let drawn = drawnSize()
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}

/// Subtle opacity pulse for loading placeholders.
private struct ShimmerModifier: ViewModifier {
    let delay: Double
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                .delay(delay), value: on)
            .onAppear { on = true }
    }
}

private extension View {
    func shimmering(delay: Double) -> some View {
        modifier(ShimmerModifier(delay: delay))
    }
}

/// Skeleton markers over the live preview.
private struct HandOverlay: View {
    let hands: [DetectedHand]
    let size: CGSize
    let videoSize: CGSize

    private static let chains: [[HandJointID]] = [
        [.wrist, .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
        [.wrist, .indexKnuckle, .indexIntermediateBase, .indexIntermediateTip, .indexTip],
        [.wrist, .middleKnuckle, .middleIntermediateBase, .middleIntermediateTip, .middleTip],
        [.wrist, .ringKnuckle, .ringIntermediateBase, .ringIntermediateTip, .ringTip],
        [.wrist, .littleKnuckle, .littleIntermediateBase, .littleIntermediateTip, .littleTip],
    ]
    private static let tips: Set<HandJointID> = [
        .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip,
    ]

    var body: some View {
        Canvas { ctx, _ in
            for hand in hands {
                let color: Color = hand.isOpenPalmUp ? .cyan
                    : (hand.isLeft ? .blue : .orange)

                for chain in Self.chains {
                    var path = Path()
                    var started = false
                    for id in chain {
                        guard let p = hand.points[id] else { continue }
                        if started { path.addLine(to: point(p)) }
                        else { path.move(to: point(p)); started = true }
                    }
                    ctx.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 2)
                }

                for (id, p) in hand.points {
                    if id == .wrist {
                        marker(ctx, p, color, radius: 8, filled: false)
                    } else {
                        marker(ctx, p, color, radius: Self.tips.contains(id) ? 4.5 : 3,
                               filled: true)
                    }
                }

                if hand.isPinching,
                   let thumb = hand.points[.thumbTip], let index = hand.points[.indexTip] {
                    var path = Path()
                    path.move(to: point(thumb))
                    path.addLine(to: point(index))
                    ctx.stroke(path, with: .color(.yellow), lineWidth: 3)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else {
            return CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        let drawn = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }

    private func marker(_ ctx: GraphicsContext, _ p: CGPoint, _ color: Color,
                        radius: CGFloat, filled: Bool) {
        let c = point(p)
        let rect = CGRect(x: c.x - radius, y: c.y - radius,
                          width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)
        if filled {
            ctx.fill(path, with: .color(color))
        } else {
            ctx.stroke(path, with: .color(color), lineWidth: 3)
        }
    }
}
