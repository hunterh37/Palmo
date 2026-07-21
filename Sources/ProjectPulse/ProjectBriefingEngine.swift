import CoreGraphics
import QuartzCore

// MARK: - Actions

/// What the user can trigger from an expanded project bubble. Routed by
/// `HandMenuModel` into the existing session / ticket / terminal machinery.
enum PulseAction: Equatable {
    case reply(cwd: String)
    case tickets(cwd: String)
    case openTerminal(cwd: String)
    case acknowledge(cwd: String)

    var cwd: String {
        switch self {
        case .reply(let c), .tickets(let c), .openTerminal(let c), .acknowledge(let c):
            return c
        }
    }

    var label: String {
        switch self {
        case .reply:       return "Reply"
        case .tickets:     return "Tickets"
        case .openTerminal: return "Open"
        case .acknowledge: return "Dismiss"
        }
    }

    var systemImage: String {
        switch self {
        case .reply:       return "paperplane.fill"
        case .tickets:     return "ticket.fill"
        case .openTerminal: return "terminal.fill"
        case .acknowledge: return "checkmark"
        }
    }

    /// Actions offered for a pulse, most useful first, capped at four.
    static func actions(for p: ProjectPulse) -> [PulseAction] {
        var out: [PulseAction] = []
        if p.canSend { out.append(.reply(cwd: p.cwd)) }
        out.append(.tickets(cwd: p.cwd))
        out.append(.openTerminal(cwd: p.cwd))
        if p.hasLiveSession { out.append(.acknowledge(cwd: p.cwd)) }
        return Array(out.prefix(4))
    }
}

// MARK: - Display models

/// One project status bubble in normalized (0...1, top-left origin) video space.
struct PulseBubbleDisplay: Identifiable, Equatable {
    let id: String            // == cwd
    var center: CGPoint
    var widthNorm: CGFloat    // fraction of frame width
    var heightNorm: CGFloat   // fraction of frame height
    var highlighted: Bool
    var dwellProgress: CGFloat
    var expanded: Bool
    var pulse: ProjectPulse
}

/// A tappable action chip shown beneath an expanded bubble.
struct PulseActionChip: Identifiable, Equatable {
    let id: String
    var center: CGPoint
    var radiusNorm: CGFloat
    var action: PulseAction
    var highlighted: Bool
    var dwellProgress: CGFloat
}

// MARK: - Engine

/// Frame-driven state machine for the project briefing: Palmo "speaks" a
/// vertical stack of status bubbles to its right; the user points to highlight,
/// dwells to expand a bubble, dwells on an action chip to fire it, and holds a
/// fist to dismiss. Fed one frame at a time, exactly like `ClaudeOrbEngine`.
///
/// Not `ObservableObject` — `HandMenuModel` calls `update(...)` per frame and
/// copies the read-only display arrays into its own published state.
@MainActor
final class ProjectBriefingEngine {
    enum State: Equatable { case hidden, briefing }

    private(set) var state: State = .hidden
    private(set) var bubbles: [PulseBubbleDisplay] = []
    private(set) var actionChips: [PulseActionChip] = []
    /// 0...1 fill of the summon-dwell ring on the Palmo anchor.
    private(set) var summonProgress: CGFloat = 0
    /// 0...1 fill of the fist-hold dismiss ring.
    private(set) var dismissProgress: CGFloat = 0
    /// cwd of the currently expanded bubble, if any.
    private(set) var expandedID: String?
    /// Set for exactly one frame when an action chip is selected.
    private(set) var firedAction: PulseAction?

    var isActive: Bool { state == .briefing }

    /// Where Palmo sits (lower-left, nudged in off the edge); the summon
    /// target and the bubbles' anchor point.
    let anchor = CGPoint(x: 0.24, y: 0.78)

    // Tuning.
    private let summonHold: CFTimeInterval = 1.0
    private let pointHold: CFTimeInterval = 1.0
    private let fistHold: CFTimeInterval = 1.0
    private let idleTimeout: CFTimeInterval = 12.0
    private let anchorRadius: CGFloat = 0.10
    private let maxVisible = 6

    private var aspect: CGFloat = 16.0 / 9.0
    private var summonSince: CFTimeInterval?
    private var fistSince: CFTimeInterval?
    private var pointTargetID: String?
    private var pointSince: CFTimeInterval?
    private var lastHandSeen: CFTimeInterval = 0

    func reset() {
        state = .hidden
        bubbles = []
        actionChips = []
        summonProgress = 0
        dismissProgress = 0
        expandedID = nil
        firedAction = nil
        summonSince = nil
        fistSince = nil
        pointTargetID = nil
        pointSince = nil
    }

    /// Force the briefing open (e.g. from an orb tap or a collapsed-mode hand
    /// raise) without the summon dwell.
    func begin(now: CFTimeInterval) {
        state = .briefing
        expandedID = nil
        pointTargetID = nil
        pointSince = nil
        lastHandSeen = now
    }

    func update(pulses: [ProjectPulse], hand: DetectedHand?,
                videoSize: CGSize, now: CFTimeInterval) {
        firedAction = nil
        summonProgress = 0
        dismissProgress = 0
        aspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 16.0 / 9.0

        guard !pulses.isEmpty else { reset(); return }
        if hand != nil { lastHandSeen = now }

        // Fist tracking (dismiss).
        if hand?.isFist == true {
            if fistSince == nil { fistSince = now }
        } else {
            fistSince = nil
        }

        switch state {
        case .hidden:
            trackSummon(hand: hand, now: now)
        case .briefing:
            if let since = fistSince {
                dismissProgress = min(CGFloat((now - since) / fistHold), 1)
                if dismissProgress >= 1 { reset(); return }
            }
            if now - lastHandSeen > idleTimeout { reset(); return }
            trackPointing(pulses: pulses, hand: hand, now: now)
        }

        layout(pulses: pulses, now: now)
    }

    // MARK: - Summon

    private func trackSummon(hand: DetectedHand?, now: CFTimeInterval) {
        guard let tip = hand?.indexTip else { summonSince = nil; return }
        let p = corrected(tip)
        let a = corrected(anchor)
        if hypot(p.x - a.x, p.y - a.y) < anchorRadius {
            if summonSince == nil { summonSince = now }
            summonProgress = min(CGFloat((now - (summonSince ?? now)) / summonHold), 1)
            if summonProgress >= 1 {
                summonSince = nil
                summonProgress = 0
                begin(now: now)
            }
        } else {
            summonSince = nil
        }
    }

    // MARK: - Pointing

    private func trackPointing(pulses: [ProjectPulse], hand: DetectedHand?,
                               now: CFTimeInterval) {
        guard let tip = hand?.indexTip else {
            pointTargetID = nil; pointSince = nil; return
        }
        let p = corrected(tip)

        if let expanded = expandedID,
           let pulse = pulses.first(where: { $0.cwd == expanded }) {
            let chips = PulseAction.actions(for: pulse)
            // Dwell on a chip → fire.
            var hit: String?
            for (i, action) in chips.enumerated() {
                let c = corrected(chipCenter(index: i, count: chips.count))
                if hypot(p.x - c.x, p.y - c.y) < chipRadius * 1.6 {
                    hit = chipID(action); break
                }
            }
            // Dwell on the big bubble itself → collapse.
            if hit == nil {
                let c = corrected(expandedBubbleCenter)
                if abs(p.y - c.y) < expandedBubbleSize.height * 0.5,
                   abs(p.x - c.x) < expandedBubbleSize.width * aspect * 0.5 {
                    hit = "collapse"
                }
            }
            advanceDwell(to: hit, now: now) { [weak self] id in
                guard let self else { return }
                if id == "collapse" {
                    self.expandedID = nil
                } else if let action = chips.first(where: { self.chipID($0) == id }) {
                    self.firedAction = action
                }
            }
            return
        }

        // Not expanded: dwell on a bubble → expand it.
        let visible = Array(pulses.prefix(maxVisible))
        var hit: String?
        for (i, pulse) in visible.enumerated() {
            let c = corrected(bubbleCenter(index: i, count: visible.count))
            let size = bubbleSize(count: visible.count)
            if abs(p.y - c.y) < size.height * 0.55,
               abs(p.x - c.x) < size.width * aspect * 0.5 {
                hit = pulse.cwd; break
            }
        }
        advanceDwell(to: hit, now: now) { [weak self] id in
            self?.expandedID = id
            self?.pointTargetID = nil
            self?.pointSince = nil
        }
    }

    /// Shared dwell bookkeeping: tracks the pointed-at id and fires `commit`
    /// once the dwell completes.
    private func advanceDwell(to hit: String?, now: CFTimeInterval,
                              commit: (String) -> Void) {
        if hit != pointTargetID {
            pointTargetID = hit
            pointSince = hit == nil ? nil : now
        }
        if let id = pointTargetID, let since = pointSince, now - since >= pointHold {
            pointTargetID = nil
            pointSince = nil
            commit(id)
        }
    }

    // MARK: - Layout geometry

    private func corrected(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }

    private let stackCenterX: CGFloat = 0.60
    private let stackTop: CGFloat = 0.16
    private let stackBottom: CGFloat = 0.88
    private let maxSpacing: CGFloat = 0.16

    private func spacing(count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return min((stackBottom - stackTop) / CGFloat(count - 1), maxSpacing)
    }

    private func bubbleCenter(index: Int, count: Int) -> CGPoint {
        let s = spacing(count: count)
        let totalH = s * CGFloat(count - 1)
        let startY = 0.52 - totalH / 2
        return CGPoint(x: stackCenterX, y: startY + CGFloat(index) * s)
    }

    private func bubbleSize(count: Int) -> CGSize {
        let s = spacing(count: count)
        let h = count <= 1 ? 0.14 : min(s * 0.82, 0.13)
        return CGSize(width: 0.62, height: h)
    }

    private let expandedBubbleCenter = CGPoint(x: 0.58, y: 0.30)
    private let expandedBubbleSize = CGSize(width: 0.66, height: 0.22)
    private let chipRadius: CGFloat = 0.055

    private func chipCenter(index: Int, count: Int) -> CGPoint {
        let chipSpacing: CGFloat = 0.20
        let x = 0.58 + (CGFloat(index) - CGFloat(count - 1) / 2) * chipSpacing
        return CGPoint(x: x, y: 0.64)
    }

    private func chipID(_ action: PulseAction) -> String { "\(action)" }

    // MARK: - Build display models

    private func layout(pulses: [ProjectPulse], now: CFTimeInterval) {
        guard state == .briefing else { bubbles = []; actionChips = []; return }

        if let expanded = expandedID,
           let pulse = pulses.first(where: { $0.cwd == expanded }) {
            bubbles = [PulseBubbleDisplay(
                id: pulse.cwd, center: expandedBubbleCenter,
                widthNorm: expandedBubbleSize.width, heightNorm: expandedBubbleSize.height,
                highlighted: pointTargetID == "collapse",
                dwellProgress: dwell(for: "collapse", now: now),
                expanded: true, pulse: pulse)]
            let actions = PulseAction.actions(for: pulse)
            actionChips = actions.enumerated().map { i, action in
                let id = chipID(action)
                return PulseActionChip(
                    id: id, center: chipCenter(index: i, count: actions.count),
                    radiusNorm: chipRadius, action: action,
                    highlighted: pointTargetID == id,
                    dwellProgress: dwell(for: id, now: now))
            }
            return
        }

        actionChips = []
        let visible = Array(pulses.prefix(maxVisible))
        let size = bubbleSize(count: visible.count)
        bubbles = visible.enumerated().map { i, pulse in
            PulseBubbleDisplay(
                id: pulse.cwd, center: bubbleCenter(index: i, count: visible.count),
                widthNorm: size.width, heightNorm: size.height,
                highlighted: pointTargetID == pulse.cwd,
                dwellProgress: dwell(for: pulse.cwd, now: now),
                expanded: false, pulse: pulse)
        }
    }

    private func dwell(for id: String, now: CFTimeInterval) -> CGFloat {
        guard id == pointTargetID, let since = pointSince else { return 0 }
        return min(CGFloat((now - since) / pointHold), 1)
    }
}
