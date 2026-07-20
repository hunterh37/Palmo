import AppKit
import CoreGraphics
import QuartzCore

/// Notification posted when the "Ask" orb is pinched, so the app can open
/// the assistant chat window.
extension Notification.Name {
    static let openAssistant = Notification.Name("brand.openAssistant")
}

/// One action on the orb menu: launch an app, toggle media, or summon the
/// assistant.
struct MenuAction: Identifiable {
    enum Kind {
        case app(bundleID: String)
        case playPause
        case assistant
    }

    let id: String
    let name: String
    let kind: Kind
    /// Orb tint, 0...1 RGB.
    let color: (r: CGFloat, g: CGFloat, b: CGFloat)

    var appURL: URL? {
        guard case .app(let bundleID) = kind else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var icon: NSImage? {
        switch kind {
        case .app:
            guard let url = appURL else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .playPause:
            return NSImage(systemSymbolName: "playpause.circle.fill",
                           accessibilityDescription: "Play/Pause")?
                .tinted(.white)
        case .assistant:
            return NSImage(systemSymbolName: "sparkles",
                           accessibilityDescription: "Assistant")?
                .tinted(.white)
        }
    }

    func launch() {
        switch kind {
        case .app:
            guard let url = appURL else { return }
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        case .playPause:
            MediaKey.postPlayPause()
        case .assistant:
            NotificationCenter.default.post(name: .openAssistant, object: nil)
        }
    }

    /// Bundle IDs of the default ring of apps.
    static let defaultBundleIDs = [
        "com.apple.Safari", "com.apple.mail", "com.apple.MobileSMS",
        "com.apple.Notes", "com.apple.iCal", "com.apple.Music",
    ]

    private static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.20, 0.55, 1.00), (0.35, 0.70, 1.00), (0.25, 0.85, 0.40),
        (1.00, 0.80, 0.25), (1.00, 0.35, 0.30), (0.95, 0.30, 0.55),
        (0.55, 0.45, 1.00), (0.30, 0.85, 0.85),
    ]

    /// Ring built from the user's chosen bundle IDs (missing apps dropped),
    /// always followed by the play/pause and assistant orbs.
    static func ring(bundleIDs: [String]) -> [MenuAction] {
        var out: [MenuAction] = []
        for (i, bid) in bundleIDs.prefix(8).enumerated() {
            let c = palette[i % palette.count]
            let action = MenuAction(id: bid,
                                    name: appName(for: bid),
                                    kind: .app(bundleID: bid),
                                    color: c)
            if action.appURL != nil { out.append(action) }
        }
        out.append(MenuAction(id: "playpause", name: "Play/Pause",
                              kind: .playPause, color: (0.55, 0.95, 0.75)))
        out.append(MenuAction(id: "assistant", name: "Ask \(Brand.name)",
                              kind: .assistant, color: (0.75, 0.55, 1.00)))
        return out
    }

    private static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// Posts hardware media-key events (play/pause) the same way the keyboard does.
enum MediaKey {
    static func postPlayPause() {
        post(key: 16 /* NX_KEYTYPE_PLAY */)
    }

    private static func post(key: Int32) {
        func event(down: Bool) -> NSEvent? {
            let flags: UInt = down ? 0xA00 : 0xB00
            let data1 = Int((Int32(key) << 16) | Int32(flags))
            return NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      subtype: 8, data1: data1, data2: -1)
        }
        event(down: true)?.cgEvent?.post(tap: .cghidEventTap)
        event(down: false)?.cgEvent?.post(tap: .cghidEventTap)
    }
}

extension NSImage {
    /// A template-symbol image re-rendered in a solid color.
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return img
    }
}

/// One orb projected into normalized (0...1, top-left origin) video space.
struct OrbDisplay: Identifiable {
    let id: String
    /// Normalized center in the video frame, top-left origin.
    var center: CGPoint
    /// Orb radius as a fraction of the frame height.
    var radiusNorm: CGFloat
    /// Pop-in scale (0 hidden, 1 settled; may overshoot slightly).
    var scale: CGFloat
    /// Depth offset toward the viewer, 0...1, for the 3D pop.
    var pop: CGFloat
    var highlighted: Bool
    var isCommand: Bool
    /// 0...1 fill toward point-and-dwell selection for this orb.
    var dwellProgress: CGFloat = 0
    var action: MenuAction?
}

/// Menu state machine. Fed one hand per frame; publishes the orb layout in
/// normalized video coordinates. All timing uses the caller's clock.
final class OrbMenuEngine {
    enum State {
        case hidden
        case summoning(start: CFTimeInterval)
        case open(start: CFTimeInterval)
        case launching(action: MenuAction, at: CGPoint, start: CFTimeInterval)
        case closing(start: CFTimeInterval)
    }

    private(set) var state: State = .hidden
    private(set) var orbs: [OrbDisplay] = []
    /// Set for one frame when an action fires.
    private(set) var firedAction: MenuAction?
    /// 0...1 progress toward the fist-hold dismissal while the menu is open.
    private(set) var dismissProgress: CGFloat = 0
    /// 0...1 progress of the avatar-touch hold that summons the menu.
    private(set) var summonProgress: CGFloat = 0

    /// Where the Palmo avatar sits, in normalized (0...1, top-left origin)
    /// video coordinates. The menu summons from — and opens next to — it.
    let avatarCenter = CGPoint(x: 0.30, y: 0.72)
    /// Touch radius around the avatar, as a fraction of frame height
    /// (aspect-corrected space).
    let avatarTouchRadius: CGFloat = 0.11

    /// Current orb ring; rebuilt when the user edits their apps in settings.
    var actions: [MenuAction] = MenuAction.ring(bundleIDs: MenuAction.defaultBundleIDs)

    /// Immediately hide the menu and clear transient gesture state (used when
    /// another interaction mode takes over the hand).
    func reset() {
        state = .hidden
        orbs = []
        firedAction = nil
        dismissProgress = 0
        summonProgress = 0
        avatarTouchSince = nil
        fistSince = nil
        lastPinch = false
        dwellOrbID = nil
        dwellSince = nil
        dwellProgress = 0
        fingertip = nil
    }

    // Layout tuning (aspect-corrected units: fractions of frame height).
    private let commandRadius: CGFloat = 0.036
    private let orbRadius: CGFloat = 0.042
    private let fanRadius: CGFloat = 0.28
    private let hoverAbovePalm: CGFloat = 0.20
    private let summonDuration: CFTimeInterval = 0.75
    private let fanStagger: CFTimeInterval = 0.06
    private let fanDuration: CFTimeInterval = 0.35
    /// How long a fist must be held to dismiss the open menu.
    private let fistHold: CFTimeInterval = 1.0
    /// How long the index fingertip must rest on an orb to select it.
    private let dwellHold: CFTimeInterval = 1.0
    /// Grace period after the menu opens before selection can begin, so the
    /// finger that just summoned the menu can't instantly fire an orb while
    /// the fan is still animating out.
    private let selectionGrace: CFTimeInterval = 0.5
    /// How long the fingertip must rest on the avatar to summon the menu.
    private let avatarTouchHold: CFTimeInterval = 1.0

    // Gesture stability.
    private var avatarTouchSince: CFTimeInterval?
    private var fistSince: CFTimeInterval?
    private var lastHandSeen: CFTimeInterval = 0
    private var lastPinch = false
    /// Point-and-dwell selection: the orb the fingertip currently rests on,
    /// when the dwell began, and the accumulated 0...1 fill.
    private var dwellOrbID: String?
    private var dwellSince: CFTimeInterval?
    private(set) var dwellProgress: CGFloat = 0
    /// Index fingertip in normalized video coordinates while the menu is open
    /// and the finger is extended — drives the on-screen selection reticle.
    private(set) var fingertip: CGPoint?

    /// Smoothed anchor (palm center) in aspect-corrected space.
    private var anchor: CGPoint = .zero
    private var aspect: CGFloat = 16.0 / 9.0

    /// Advance the state machine. `hand` is the menu-driving hand (or nil),
    /// `videoSize` the camera frame pixels, `now` the frame clock.
    func update(hand: DetectedHand?, videoSize: CGSize, now: CFTimeInterval) {
        firedAction = nil
        aspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 16.0 / 9.0
        if hand != nil { lastHandSeen = now }

        trackGestures(hand: hand, now: now)

        dismissProgress = 0
        summonProgress = 0
        fingertip = nil
        // Dwell only accumulates while the menu is open; clear it otherwise.
        if case .open = state {} else {
            dwellOrbID = nil
            dwellSince = nil
            dwellProgress = 0
        }
        switch state {
        case .hidden:
            // Summon by resting the index fingertip on the avatar for 1s.
            if let tip = hand?.indexTip ?? hand?.pinchPoint {
                let p = corrected(tip)
                let a = corrected(avatarCenter)
                if hypot(p.x - a.x, p.y - a.y) < avatarTouchRadius {
                    if avatarTouchSince == nil { avatarTouchSince = now }
                    summonProgress = min(CGFloat((now - avatarTouchSince!) / avatarTouchHold), 1)
                    if summonProgress >= 1 {
                        summonProgress = 0
                        avatarTouchSince = nil
                        // The menu opens next to the avatar.
                        anchor = a
                        state = .summoning(start: now)
                    }
                } else {
                    avatarTouchSince = nil
                }
            } else {
                avatarTouchSince = nil
            }
        case .summoning(let start):
            if now - start >= summonDuration { state = .open(start: now) }
        case .open(let start):
            // Show the reticle on the extended index fingertip.
            if let hand, hand.isIndexExtended, let tip = hand.indexTip {
                fingertip = tip
            }
            // Selection waits out a short grace period so the finger that
            // summoned the menu can't instantly fire an orb.
            if now - start >= selectionGrace {
                handleSelection(hand: hand, now: now)
            }
            if let since = fistSince {
                dismissProgress = min(CGFloat((now - since) / fistHold), 1)
                if dismissProgress >= 1 {
                    dismissProgress = 0
                    state = .closing(start: now)
                }
            }
        case .launching(let action, _, let start):
            _ = action
            if now - start > 0.55 { state = .hidden }
        case .closing(let start):
            if now - start > 0.25 { state = .hidden }
        }

        orbs = layout(now: now)
        lastPinch = hand?.isPinching ?? lastPinch
    }

    // MARK: - Gestures

    private func trackGestures(hand: DetectedHand?, now: CFTimeInterval) {
        // Only trust a fist when all fingertips were actually tracked this
        // frame; missing joints read as "curled" and fake a fist, which was
        // dismissing the menu while the user pointed at orbs.
        if let hand, hand.isFist, hand.hasAllFingerTips {
            if fistSince == nil { fistSince = now }
        } else {
            fistSince = nil
        }
    }


    // MARK: - Anchor

    /// Convert a normalized point into aspect-corrected space where distances
    /// are isotropic (x scaled by the frame aspect).
    private func corrected(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }
    private func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / aspect, y: p.y) }

    // MARK: - Selection

    /// Point-and-dwell selection: rest the index fingertip on an orb and hold
    /// it there briefly to launch. Sliding off an orb cancels the dwell. Hit
    /// tests run in aspect-corrected space so the fingertip and orb centers
    /// share coordinates.
    private func handleSelection(hand: DetectedHand?, now: CFTimeInterval) {
        // Index finger only: the finger must be extended and its tip tracked.
        guard let hand, hand.isIndexExtended, let point = hand.indexTip else {
            dwellOrbID = nil
            dwellSince = nil
            dwellProgress = 0
            return
        }
        let p = corrected(point)
        var hit: (action: MenuAction, center: CGPoint)?
        for orb in fanCenters(progress: 1) {
            guard let action = orb.action else { continue }
            let oc = corrected(orb.center)
            if hypot(p.x - oc.x, p.y - oc.y) < orbRadius * 1.35 {
                hit = (action, orb.center)
                break
            }
        }
        guard let hit else {
            // Fingertip is off every orb; reset the dwell.
            dwellOrbID = nil
            dwellSince = nil
            dwellProgress = 0
            return
        }
        // Restart the timer whenever the fingertip moves to a different orb.
        if dwellOrbID != hit.action.id {
            dwellOrbID = hit.action.id
            dwellSince = now
        }
        let since = dwellSince ?? now
        dwellProgress = min(CGFloat((now - since) / dwellHold), 1)
        if dwellProgress >= 1 {
            dwellOrbID = nil
            dwellSince = nil
            dwellProgress = 0
            firedAction = hit.action
            hit.action.launch()
            state = .launching(action: hit.action, at: hit.center, start: now)
        }
    }

    /// Hover target for highlight rings while the menu is open.
    private func hoverPoint(hand: DetectedHand?) -> CGPoint? {
        guard let p = hand?.indexTip else { return nil }
        return corrected(p)
    }

    // MARK: - Layout

    private struct FanOrb {
        var center: CGPoint // aspect-corrected
        var action: MenuAction?
    }

    private var commandCenterTarget: CGPoint {
        CGPoint(x: anchor.x, y: anchor.y - hoverAbovePalm)
    }

    private func fanCenters(progress: CGFloat) -> [OrbDisplay] {
        let cc = commandCenterTarget
        let n = actions.count
        guard n > 0 else { return [] }
        let startAngle = -160.0 * CGFloat.pi / 180
        let endAngle = -20.0 * CGFloat.pi / 180
        var out: [OrbDisplay] = []
        for (i, action) in actions.enumerated() {
            let t = n == 1 ? 0.5 : CGFloat(i) / CGFloat(n - 1)
            let angle = startAngle + (endAngle - startAngle) * t
            let r = fanRadius * progress
            let center = CGPoint(x: cc.x + cos(angle) * r, y: cc.y + sin(angle) * r)
            out.append(OrbDisplay(id: action.id,
                                  center: normalized(center),
                                  radiusNorm: orbRadius,
                                  scale: 1, pop: 1,
                                  highlighted: false,
                                  isCommand: false,
                                  action: action))
        }
        return out
    }

    private func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c: CGFloat = 1.70158
        let x = t - 1
        return 1 + (c + 1) * x * x * x + c * x * x
    }

    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let x = 1 - t
        return 1 - x * x * x
    }

    private func layout(now: CFTimeInterval) -> [OrbDisplay] {
        switch state {
        case .hidden:
            return []
        case .summoning(let start):
            let t = min(CGFloat((now - start) / summonDuration), 1)
            let p = easeOutCubic(t)
            let cc = commandCenterTarget
            // Descend from above the top edge of the frame.
            let y = (-0.12) + (cc.y + 0.12) * p
            return [OrbDisplay(id: "command",
                               center: normalized(CGPoint(x: cc.x, y: y)),
                               radiusNorm: commandRadius,
                               scale: 0.6 + 0.4 * p,
                               pop: p,
                               highlighted: false,
                               isCommand: true,
                               action: nil)]
        case .open(let start):
            var out = [OrbDisplay(id: "command",
                                  center: normalized(commandCenterTarget),
                                  radiusNorm: commandRadius,
                                  scale: 1, pop: 1,
                                  highlighted: false,
                                  isCommand: true,
                                  action: nil)]
            let hover = pendingHover
            for (i, var orb) in fanCenters(progress: 1).enumerated() {
                let delay = fanStagger * CFTimeInterval(i)
                let t = min(max(CGFloat((now - start - delay) / fanDuration), 0), 1)
                let s = easeOutBack(t)
                // Fan the orb out along its own ray.
                let target = corrected(orb.center)
                let cc = commandCenterTarget
                let c = CGPoint(x: cc.x + (target.x - cc.x) * min(s, 1.0),
                                y: cc.y + (target.y - cc.y) * min(s, 1.0))
                orb.center = normalized(c)
                orb.scale = s
                orb.pop = t
                if let h = hover {
                    let d = hypot(h.x - target.x, h.y - target.y)
                    orb.highlighted = d < orbRadius * 1.35
                }
                // Fill the orb the fingertip is dwelling on.
                if orb.action?.id == dwellOrbID { orb.dwellProgress = dwellProgress }
                out.append(orb)
            }
            return out
        case .launching(let action, let at, let start):
            let t = min(CGFloat((now - start) / 0.55), 1)
            return [OrbDisplay(id: action.id,
                               center: normalized(at),
                               radiusNorm: orbRadius,
                               scale: 1 + 0.7 * t,
                               pop: 1,
                               highlighted: true,
                               isCommand: false,
                               action: action)]
        case .closing(let start):
            let t = min(CGFloat((now - start) / 0.25), 1)
            var out = fanCenters(progress: 1 - easeOutCubic(t))
            for i in out.indices { out[i].scale = 1 - t; out[i].pop = 1 - t }
            out.append(OrbDisplay(id: "command",
                                  center: normalized(commandCenterTarget),
                                  radiusNorm: commandRadius,
                                  scale: 1 - t, pop: 1 - t,
                                  highlighted: false,
                                  isCommand: true,
                                  action: nil))
            return out
        }
    }

    /// Hover point captured before layout, set from update()'s hand.
    private var pendingHover: CGPoint?
    func setHover(from hand: DetectedHand?) { pendingHover = hoverPoint(hand: hand) }
}
