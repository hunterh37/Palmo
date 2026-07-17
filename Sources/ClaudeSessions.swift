import SwiftUI
import AppKit
import QuartzCore

// MARK: - Session model

/// One live Claude Code session, as reported by the installed hooks.
struct ClaudeSession: Identifiable, Equatable {
    let id: String
    /// Working directory of the session (used as the display name).
    var cwd: String
    /// "working" while Claude is running, "done" once a Stop hook fires.
    var isDone: Bool
    var updatedAt: Date

    var name: String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? "Claude" : last
    }
}

// MARK: - Store (hook files -> sessions)

/// Watches the state directory that the Claude Code hooks write into and
/// publishes the set of live sessions. Also knows how to install the hooks
/// into ~/.claude/settings.json.
@MainActor
final class ClaudeSessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var hooksInstalled: Bool = false

    static let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("HandOrbMenu")
    static let sessionsDir = supportDir.appendingPathComponent("claude-sessions")
    static let hookScript = supportDir.appendingPathComponent("claude-orb-hook.py")

    private var timer: Timer?
    /// Sessions untouched for this long are considered dead and swept.
    private let staleAfter: TimeInterval = 12 * 60 * 60

    func start() {
        try? FileManager.default.createDirectory(at: Self.sessionsDir,
                                                 withIntermediateDirectories: true)
        hooksInstalled = Self.checkHooksInstalled()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The user selected this session's orb: clear its "done" state.
    func acknowledge(_ id: String) {
        let url = Self.sessionsDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        sessions.removeAll { $0.id == id }
    }

    private func refresh() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.sessionsDir,
                                                      includingPropertiesForKeys: nil)
        else { return }
        var out: [ClaudeSession] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["session_id"] as? String else { continue }
            let updated = Date(timeIntervalSince1970: obj["updated_at"] as? Double ?? 0)
            if Date().timeIntervalSince(updated) > staleAfter {
                try? fm.removeItem(at: url)
                continue
            }
            out.append(ClaudeSession(id: sid,
                                     cwd: obj["cwd"] as? String ?? "",
                                     isDone: (obj["status"] as? String) == "done",
                                     updatedAt: updated))
        }
        out.sort { $0.updatedAt > $1.updatedAt }
        if out != sessions { sessions = out }
    }

    // MARK: Hook installation

    private static let hookMarker = "claude-orb-hook.py"

    /// Shell command Claude Code runs for each hook event.
    private static func hookCommand(_ event: String) -> String {
        "/usr/bin/python3 \"$HOME/Library/Application Support/HandOrbMenu/claude-orb-hook.py\" \(event)"
    }

    private static let hookEvents: [(hook: String, arg: String)] = [
        ("SessionStart", "start"),
        ("UserPromptSubmit", "prompt"),
        ("Stop", "stop"),
        ("SessionEnd", "end"),
    ]

    static func checkHooksInstalled() -> Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard FileManager.default.fileExists(atPath: hookScript.path),
              let data = try? Data(contentsOf: settings),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(hookMarker)
    }

    /// Writes the hook script and merges the four hook entries into
    /// ~/.claude/settings.json (idempotent). Throws on I/O failure.
    func installHooks() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.sessionsDir, withIntermediateDirectories: true)
        try Self.hookScriptSource.write(to: Self.hookScript, atomically: true,
                                        encoding: .utf8)

        let claudeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, arg) in Self.hookEvents {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            let command = Self.hookCommand(arg)
            let already = matchers.contains { matcher in
                ((matcher["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(Self.hookMarker) == true
                }
            }
            if !already {
                matchers.append(["hooks": [["type": "command", "command": command]]])
                hooks[event] = matchers
            }
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
        hooksInstalled = true
    }

    /// The hook: reads the event payload on stdin, mirrors session state into
    /// the app's watched directory. Kept dependency-free (system python3).
    private static let hookScriptSource = """
    #!/usr/bin/env python3
    # Installed by Palmo (Hand Orb Menu). Mirrors Claude Code session state
    # so the app can show an orb per session. Safe to delete.
    import json, os, sys, time

    event = sys.argv[1] if len(sys.argv) > 1 else "start"
    d = os.path.expanduser(
        "~/Library/Application Support/HandOrbMenu/claude-sessions")
    os.makedirs(d, exist_ok=True)
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    sid = data.get("session_id") or "unknown"
    path = os.path.join(d, sid + ".json")
    if event == "end":
        try:
            os.remove(path)
        except OSError:
            pass
    else:
        status = "done" if event == "stop" else "working"
        with open(path, "w") as f:
            json.dump({"session_id": sid,
                       "cwd": data.get("cwd", ""),
                       "status": status,
                       "updated_at": time.time()}, f)
    sys.exit(0)
    """
}

// MARK: - Orb engine (collapsed-mode gestures)

/// One Claude session orb in normalized (0...1, top-left origin) video space.
struct ClaudeOrbDisplay: Identifiable, Equatable {
    let id: String
    var center: CGPoint
    /// Radius as a fraction of frame height.
    var radiusNorm: CGFloat
    var name: String
    var isDone: Bool
    /// 0...1 fill of the point-to-select ring on this orb.
    var selectProgress: CGFloat
    var highlighted: Bool
}

/// Collapsed-mode state machine: session orbs sit docked at the bottom of
/// the camera view; a 1s fist hold floats them near the top; pointing the
/// index finger at one for 1s selects it.
@MainActor
final class ClaudeOrbEngine {
    enum State {
        case docked
        case raising(start: CFTimeInterval)
        case raised
        case lowering(start: CFTimeInterval)
    }

    private(set) var state: State = .docked
    private(set) var orbs: [ClaudeOrbDisplay] = []
    /// 0...1 fill of the fist-hold ring while docked (or raised, to lower).
    private(set) var fistProgress: CGFloat = 0
    /// Set for one frame when an orb is selected.
    private(set) var selectedSessionID: String?

    // Tuning.
    private let fistHold: CFTimeInterval = 1.0
    private let pointHold: CFTimeInterval = 1.0
    private let raiseDuration: CFTimeInterval = 0.5
    private let dockedY: CGFloat = 0.90
    private let raisedY: CGFloat = 0.16
    private let dockedRadius: CGFloat = 0.045
    private let raisedRadius: CGFloat = 0.075
    /// Auto-dock after this long with no hand while raised.
    private let idleTimeout: CFTimeInterval = 8.0

    private var fistSince: CFTimeInterval?
    private var pointTargetID: String?
    private var pointSince: CFTimeInterval?
    private var lastHandSeen: CFTimeInterval = 0
    private var aspect: CGFloat = 16.0 / 9.0

    func reset() {
        state = .docked
        orbs = []
        fistProgress = 0
        selectedSessionID = nil
        fistSince = nil
        pointTargetID = nil
        pointSince = nil
    }

    func update(sessions: [ClaudeSession], hand: DetectedHand?,
                videoSize: CGSize, now: CFTimeInterval) {
        selectedSessionID = nil
        fistProgress = 0
        aspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 16.0 / 9.0

        guard !sessions.isEmpty else { reset(); return }
        if hand != nil { lastHandSeen = now }

        // Fist tracking (shared by raise & lower).
        if hand?.isFist == true {
            if fistSince == nil { fistSince = now }
        } else {
            fistSince = nil
        }

        switch state {
        case .docked:
            if let since = fistSince {
                fistProgress = min(CGFloat((now - since) / fistHold), 1)
                if fistProgress >= 1 {
                    fistProgress = 0
                    fistSince = nil
                    state = .raising(start: now)
                }
            }
        case .raising(let start):
            if now - start >= raiseDuration { state = .raised }
        case .raised:
            trackPointing(sessions: sessions, hand: hand, now: now)
            if let since = fistSince {
                fistProgress = min(CGFloat((now - since) / fistHold), 1)
                if fistProgress >= 1 {
                    fistProgress = 0
                    fistSince = nil
                    state = .lowering(start: now)
                }
            }
            if now - lastHandSeen > idleTimeout { state = .lowering(start: now) }
        case .lowering(let start):
            if now - start >= raiseDuration { state = .docked }
        }

        orbs = layout(sessions: sessions, now: now)
    }

    // MARK: Pointing

    private func trackPointing(sessions: [ClaudeSession], hand: DetectedHand?,
                               now: CFTimeInterval) {
        guard let tip = hand?.indexTip else {
            pointTargetID = nil; pointSince = nil
            return
        }
        let p = corrected(tip)
        var hit: String?
        for (i, session) in sessions.enumerated() {
            let c = corrected(orbCenter(index: i, count: sessions.count, progress: 1))
            if hypot(p.x - c.x, p.y - c.y) < raisedRadius * 1.5 {
                hit = session.id
                break
            }
        }
        if hit != pointTargetID {
            pointTargetID = hit
            pointSince = hit == nil ? nil : now
        }
        if let id = pointTargetID, let since = pointSince,
           now - since >= pointHold {
            selectedSessionID = id
            pointTargetID = nil
            pointSince = nil
            state = .lowering(start: now)
        }
    }

    // MARK: Layout

    private func corrected(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }

    /// Center of orb `index` at raise `progress` (0 docked, 1 raised).
    private func orbCenter(index: Int, count: Int, progress: CGFloat) -> CGPoint {
        // Evenly spaced row, centered. Spacing in aspect-corrected units,
        // converted back to normalized x.
        let spacing: CGFloat = (raisedRadius * 3.2) / aspect
        let x = 0.5 + (CGFloat(index) - CGFloat(count - 1) / 2) * spacing
        let y = dockedY + (raisedY - dockedY) * progress
        return CGPoint(x: x, y: y)
    }

    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let x = 1 - t
        return 1 - x * x * x
    }

    private func raiseProgress(now: CFTimeInterval) -> CGFloat {
        switch state {
        case .docked: return 0
        case .raising(let start):
            return easeOutCubic(min(CGFloat((now - start) / raiseDuration), 1))
        case .raised: return 1
        case .lowering(let start):
            return 1 - easeOutCubic(min(CGFloat((now - start) / raiseDuration), 1))
        }
    }

    private func layout(sessions: [ClaudeSession], now: CFTimeInterval) -> [ClaudeOrbDisplay] {
        let p = raiseProgress(now: now)
        let radius = dockedRadius + (raisedRadius - dockedRadius) * p
        var out: [ClaudeOrbDisplay] = []
        for (i, session) in sessions.enumerated() {
            var selectP: CGFloat = 0
            if case .raised = state, session.id == pointTargetID,
               let since = pointSince {
                selectP = min(CGFloat((now - since) / pointHold), 1)
            }
            out.append(ClaudeOrbDisplay(id: session.id,
                                        center: orbCenter(index: i,
                                                          count: sessions.count,
                                                          progress: p),
                                        radiusNorm: radius,
                                        name: session.name,
                                        isDone: session.isDone,
                                        selectProgress: selectP,
                                        highlighted: session.id == pointTargetID))
        }
        return out
    }
}

// MARK: - Overlay view

/// Draws the Claude session orbs over the collapsed camera view, plus the
/// centered fist-hold ring while the raise gesture is charging.
struct ClaudeOrbOverlay: View {
    let orbs: [ClaudeOrbDisplay]
    let fistProgress: CGFloat
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        ZStack {
            ForEach(orbs) { orb in
                orbView(orb)
            }
            if fistProgress > 0.03 {
                fistRing
            }
        }
        .allowsHitTesting(false)
    }

    private func orbView(_ orb: ClaudeOrbDisplay) -> some View {
        let c = point(orb.center)
        let r = orb.radiusNorm * drawnSize().height
            * (orb.highlighted ? 1.15 : 1.0)
        let tint: Color = orb.isDone ? .green : .orange
        return ZStack {
            // Glow halo — "done" orbs breathe so they catch the eye.
            Circle()
                .fill(tint.opacity(orb.isDone ? 0.45 : 0.25))
                .frame(width: r * 3.2, height: r * 3.2)
                .blur(radius: r * 0.6)
            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.55)],
                    center: .init(x: 0.35, y: 0.3),
                    startRadius: 0, endRadius: r * 1.5))
                .frame(width: r * 2, height: r * 2)
                .overlay(Circle().strokeBorder(
                    .white.opacity(orb.highlighted ? 0.9 : 0.4),
                    lineWidth: orb.highlighted ? 2.5 : 1.5))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Image(systemName: orb.isDone ? "checkmark" : "hourglass")
                .font(.system(size: max(r * 0.8, 8), weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
            if orb.selectProgress > 0.02 {
                Circle()
                    .trim(from: 0, to: orb.selectProgress)
                    .stroke(Color.white,
                            style: .init(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: r * 2.6, height: r * 2.6)
            }
            Text(orb.name)
                .font(.system(size: max(r * 0.45, 8), weight: .bold,
                              design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 2)
                .offset(y: r * 1.9)
        }
        .position(c)
    }

    /// Centered progress ring while the fist raise/lower gesture charges.
    private var fistRing: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: fistProgress)
                .stroke(Brand.accent, style: .init(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 44, height: 44)
        .position(x: size.width / 2, y: size.height / 2)
    }

    // Aspect-fill mapping, matching the other overlays.
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
