import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// The mouse-control orb projected into normalized (0...1, top-left origin)
/// video space, mirroring the conventions of `OrbDisplay`.
struct MouseOrbDisplay {
    /// Normalized center in the video frame, top-left origin.
    var center: CGPoint
    /// Orb radius as a fraction of the frame height.
    var radiusNorm: CGFloat
    /// True while the user is pinching and dragging the orb.
    var grabbed: Bool
    /// Pop-in scale (0 hidden, 1 settled).
    var scale: CGFloat
}

/// Trackpad-style mouse control driven by hand tracking.
///
/// A small gray orb rests at the center of the webcam view. Pinching on (or
/// near) the orb grabs it; while grabbed, the orb follows the pinch point and
/// the *movement* of the orb is applied to the real macOS cursor as relative
/// deltas (like a trackpad). Releasing the pinch lets the orb spring back to
/// center, ready for the next stroke — so large cursor travel is done with
/// repeated grab-drag-release strokes, exactly like swiping a trackpad.
///
/// Cursor events are posted with `CGEvent`, which requires the app to be
/// trusted for Accessibility. `requestTrustIfNeeded()` triggers the system
/// prompt; `isTrusted` is re-checked so the UI can guide the user.
///
/// All methods must be called from the main actor (the model already hops
/// camera frames onto it).
@MainActor
final class MouseControlEngine {
    private(set) var orb: MouseOrbDisplay?
    /// True when the app may post mouse events (Accessibility trust).
    private(set) var isTrusted: Bool = AXIsProcessTrusted()

    /// Flip horizontal cursor movement (for setups where camera mirroring
    /// makes left-hand motion read as rightward cursor motion).
    var invertHorizontal = false

    // MARK: Tuning (aspect-corrected units: fractions of frame height)

    /// Resting orb radius.
    private let orbRadius: CGFloat = 0.045
    /// A pinch that starts within this distance of the orb grabs it.
    private let grabRadius: CGFloat = 0.045 * 2.0
    /// Cursor speed: dragging across one full frame height moves the cursor
    /// roughly this many screen heights. User-tunable in settings.
    var sensitivity: CGFloat = 2.4
    /// Quick pinch-and-release on the orb posts a real left click.
    var pinchClickEnabled = true
    /// Holding a fist and moving it vertically scrolls the frontmost window.
    var scrollGestureEnabled = true
    /// Scroll speed multiplier.
    var scrollSpeed: CGFloat = 1.0
    /// Fired after a pinch-tap click is posted (for stats/reactions).
    var onClick: (() -> Void)?
    /// Low-pass factor for the pinch point (higher = snappier, noisier).
    private let followAlpha: CGFloat = 0.55
    /// Return-to-center easing when released.
    private let returnAlpha: CGFloat = 0.16
    /// Losing the hand for longer than this releases the grab.
    private let handLostGrace: CFTimeInterval = 0.25
    /// Pop-in animation length when the mode is enabled.
    private let popDuration: CFTimeInterval = 0.35

    // MARK: State

    private var enabled = false
    private var enabledAt: CFTimeInterval = 0
    private var aspect: CGFloat = 16.0 / 9.0
    /// Orb center in aspect-corrected space (x in 0...aspect, y in 0...1).
    private var center = CGPoint(x: 8.0 / 9.0, y: 0.5)
    private var grabbed = false
    /// Smoothed pinch point while grabbed (aspect-corrected).
    private var smoothedPinch: CGPoint = .zero
    private var lastHandSeen: CFTimeInterval = 0
    private var lastPinch = false
    /// When the current grab began and how far it has travelled, used to
    /// classify a quick low-travel grab as a click.
    private var grabStart: CFTimeInterval = 0
    private var grabTravel: CGFloat = 0
    /// Smoothed fist palm-y while air-scrolling (aspect-corrected units).
    private var scrollAnchorY: CGFloat?
    /// Virtual cursor position in global display (Quartz, top-left origin)
    /// coordinates; kept locally so sub-pixel deltas accumulate smoothly.
    private var cursor: CGPoint?
    private let eventSource = CGEventSource(stateID: .combinedSessionState)

    // MARK: Lifecycle

    /// Turn the mode on/off. Turning on re-checks Accessibility trust and
    /// (once) shows the system prompt if the app is not yet trusted.
    func setEnabled(_ on: Bool, now: CFTimeInterval) {
        guard on != enabled else { return }
        enabled = on
        if on {
            enabledAt = now
            center = restCenter
            grabbed = false
            cursor = nil
            requestTrustIfNeeded()
        } else {
            release()
            orb = nil
        }
    }

    /// Shows the macOS Accessibility prompt if the app is not trusted yet.
    func requestTrustIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Per-frame update

    func update(hand: DetectedHand?, videoSize: CGSize, now: CFTimeInterval) {
        guard enabled else { return }
        aspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 16.0 / 9.0
        if hand != nil { lastHandSeen = now }

        let pinching = hand?.isPinching ?? false
        let pinchPoint = (hand?.pinchPoint).map(corrected)

        if grabbed {
            if pinching, let p = pinchPoint {
                drag(to: p)
            } else if !pinching || now - lastHandSeen > handLostGrace {
                let wasQuickTap = pinchClickEnabled
                    && now - grabStart < 0.30 && grabTravel < 0.025
                release()
                if wasQuickTap { postClick() }
            }
        } else if pinching && !lastPinch, let p = pinchPoint,
                  hypot(p.x - center.x, p.y - center.y) < grabRadius {
            beginGrab(at: p, now: now)
        }

        // Air scroll: hold a fist and move it up/down.
        if scrollGestureEnabled, !grabbed, let hand, hand.isFist,
           let palm = hand.palmCenter {
            let y = corrected(palm).y
            if let anchor = scrollAnchorY {
                let dy = y - anchor
                if abs(dy) > 0.0015 { postScroll(deltaNorm: dy) }
            }
            scrollAnchorY = y
        } else {
            scrollAnchorY = nil
        }

        if !grabbed {
            // Spring back to the resting center.
            let rest = restCenter
            center.x += (rest.x - center.x) * returnAlpha
            center.y += (rest.y - center.y) * returnAlpha
        }

        // Only a real pinch (not a lost hand) counts as "was pinching" so a
        // hand that blips out and back doesn't grab spuriously mid-pinch.
        if hand != nil { lastPinch = pinching }

        let pop = min(CGFloat((now - enabledAt) / popDuration), 1)
        orb = MouseOrbDisplay(center: normalized(center),
                              radiusNorm: orbRadius,
                              grabbed: grabbed,
                              scale: 0.6 + 0.4 * pop)
    }

    // MARK: Grab / drag / release

    private func beginGrab(at p: CGPoint, now: CFTimeInterval) {
        // Re-check trust cheaply at grab time; the user may have granted it
        // in System Settings since the mode was enabled.
        if !isTrusted { isTrusted = AXIsProcessTrusted() }
        grabbed = true
        smoothedPinch = p
        grabStart = now
        grabTravel = 0
        cursor = currentCursorLocation()
    }

    /// Posts a left mouse down+up at the current cursor position.
    private func postClick() {
        guard isTrusted, let pos = currentCursorLocation() else { return }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: eventSource, mouseType: type,
                    mouseCursorPosition: pos, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        onClick?()
    }

    /// Posts a smooth scroll-wheel event from a normalized vertical delta.
    private func postScroll(deltaNorm: CGFloat) {
        guard isTrusted else { return }
        let pixels = Int32((deltaNorm * 900 * scrollSpeed).rounded())
        guard pixels != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource,
                                  units: .pixel, wheelCount: 1,
                                  wheel1: -pixels, wheel2: 0, wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    private func drag(to raw: CGPoint) {
        let previous = smoothedPinch
        smoothedPinch.x += (raw.x - smoothedPinch.x) * followAlpha
        smoothedPinch.y += (raw.y - smoothedPinch.y) * followAlpha

        // The orb follows the (smoothed) pinch, clamped inside the frame.
        center = CGPoint(x: min(max(smoothedPinch.x, orbRadius), aspect - orbRadius),
                         y: min(max(smoothedPinch.y, orbRadius), 1 - orbRadius))

        let dx = smoothedPinch.x - previous.x
        let dy = smoothedPinch.y - previous.y
        grabTravel += hypot(dx, dy)
        guard dx != 0 || dy != 0 else { return }
        moveCursor(byNormalized: CGSize(width: dx, height: dy))
    }

    private func release() {
        grabbed = false
        cursor = nil
    }

    // MARK: Cursor posting

    /// Applies an aspect-corrected normalized delta to the real cursor.
    private func moveCursor(byNormalized d: CGSize) {
        guard isTrusted else { return }
        guard var pos = cursor ?? currentCursorLocation() else { return }

        // Scale: one full frame height of hand travel = `sensitivity` screen
        // heights of cursor travel, uniform in x and y.
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let gain = sensitivity * screenHeight
        let dxSign: CGFloat = invertHorizontal ? -1 : 1
        pos.x += d.width * gain * dxSign
        pos.y += d.height * gain
        pos = clampToDisplays(pos)
        cursor = pos

        guard let event = CGEvent(mouseEventSource: eventSource,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: pos,
                                  mouseButton: .left) else { return }
        // Integer deltas keep delta-based consumers (games, pointer lock) working.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((d.width * gain * dxSign).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((d.height * gain).rounded()))
        event.post(tap: .cghidEventTap)
    }

    /// Current cursor position in Quartz global coordinates (top-left origin).
    private func currentCursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Clamp a Quartz-coordinate point to the nearest active display so the
    /// virtual cursor never drifts into dead space between monitors.
    private func clampToDisplays(_ p: CGPoint) -> CGPoint {
        var displayCount: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &displayCount)
        guard displayCount > 0 else { return p }

        var best = p
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<Int(displayCount) {
            let b = CGDisplayBounds(ids[i])
            let clamped = CGPoint(x: min(max(p.x, b.minX), b.maxX - 1),
                                  y: min(max(p.y, b.minY), b.maxY - 1))
            let d = hypot(clamped.x - p.x, clamped.y - p.y)
            if d < bestDist { bestDist = d; best = clamped }
            if d == 0 { return p }
        }
        return best
    }

    // MARK: Coordinate helpers (match OrbMenuEngine conventions)

    private var restCenter: CGPoint { CGPoint(x: aspect / 2, y: 0.5) }
    private func corrected(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }
    private func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / aspect, y: p.y) }
}
