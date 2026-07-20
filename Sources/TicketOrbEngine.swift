import SwiftUI
import QuartzCore

// MARK: - Display model

/// One floating ticket card in normalized (0...1, top-left origin) video space.
struct TicketOrbDisplay: Identifiable, Equatable {
    let id: UUID
    var ticket: Ticket
    var center: CGPoint
    /// Card half-height as a fraction of frame height (sizing anchor).
    var radiusNorm: CGFloat
    var grabbed: Bool
    /// 0...1 fill while held inside the drop zone.
    var sendProgress: CGFloat
    /// Pop-in scale (0 hidden, 1 settled).
    var scale: CGFloat
}

// MARK: - Engine

/// Windowed-mode ticket interaction: after Palmo announces + loads, ticket
/// cards float across the upper part of the frame. Pinch a card to grab it,
/// carry it to the drop zone near the bottom center and release (or hold
/// briefly) to send it to Claude. Release elsewhere and it springs back.
/// A held fist (or idling out) dismisses the cards.
@MainActor
final class TicketOrbEngine {
    enum State: Equatable {
        case idle
        /// Palmo's little heads-up animation beat before loading.
        case announcing(since: CFTimeInterval)
        /// Waiting on generation; shows loading placeholders.
        case loading
        case presenting
        case grabbed(id: UUID)
        /// A ticket was released/held in the drop zone; toast beat.
        case dispatched(until: CFTimeInterval)
    }

    private(set) var state: State = .idle
    private(set) var orbs: [TicketOrbDisplay] = []
    /// Set for one frame when a ticket is dropped on the zone.
    private(set) var firedTicket: Ticket?
    /// 0...1 fill of the fist-hold dismiss ring.
    private(set) var fistProgress: CGFloat = 0
    /// Drop zone center in normalized video coords (visible while presenting).
    let dropZoneCenter = CGPoint(x: 0.5, y: 0.82)
    /// Drop zone radius as a fraction of frame height.
    let dropZoneRadius: CGFloat = 0.11

    var isActive: Bool { state != .idle }
    var isAnnouncing: Bool { if case .announcing = state { return true }; return false }
    var isLoading: Bool { state == .loading }

    // MARK: Tuning

    private let announceDuration: CFTimeInterval = 0.9
    private let cardRadius: CGFloat = 0.075
    private let grabRadius: CGFloat = 0.11
    private let rowY: CGFloat = 0.24
    private let followAlpha: CGFloat = 0.5
    private let returnAlpha: CGFloat = 0.14
    /// Continued pinch-hold inside the zone fires after this long (release
    /// inside the zone fires immediately).
    private let dropDwell: CFTimeInterval = 0.6
    private let fistHold: CFTimeInterval = 0.8
    private let idleTimeout: CFTimeInterval = 20
    private let handLostGrace: CFTimeInterval = 0.35
    private let popDuration: CFTimeInterval = 0.4
    private let toastDuration: CFTimeInterval = 1.6

    // MARK: State

    private var tickets: [Ticket] = []
    /// Card centers in aspect-corrected space (x in 0...aspect, y in 0...1).
    private var centers: [UUID: CGPoint] = [:]
    private var presentedAt: CFTimeInterval = 0
    private var smoothedPinch: CGPoint = .zero
    private var dropEnteredAt: CFTimeInterval?
    private var fistSince: CFTimeInterval?
    private var lastHandSeen: CFTimeInterval = 0
    private var lastActivity: CFTimeInterval = 0
    private var lastPinch = false
    private var aspect: CGFloat = 16.0 / 9.0

    // MARK: Lifecycle

    /// Kick off the announce → loading beat (call when generation starts).
    func begin(now: CFTimeInterval) {
        guard state == .idle else { return }
        state = .announcing(since: now)
        tickets = []
        orbs = []
        lastActivity = now
        lastHandSeen = now
    }

    func reset() {
        state = .idle
        tickets = []
        orbs = []
        centers = [:]
        firedTicket = nil
        fistProgress = 0
        fistSince = nil
        dropEnteredAt = nil
        lastPinch = false
    }

    // MARK: Per-frame update

    func update(tickets fresh: [Ticket], generating: Bool, hand: DetectedHand?,
                videoSize: CGSize, now: CFTimeInterval) {
        firedTicket = nil
        fistProgress = 0
        guard state != .idle else { orbs = []; return }
        aspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 16.0 / 9.0
        if hand != nil { lastHandSeen = now; lastActivity = now }

        // Fist-hold dismissal works from any live state.
        if hand?.isFist == true {
            if fistSince == nil { fistSince = now }
            fistProgress = min(CGFloat((now - fistSince!) / fistHold), 1)
            if fistProgress >= 1 { reset(); return }
        } else {
            fistSince = nil
        }

        switch state {
        case .idle:
            break
        case .announcing(let since):
            if now - since >= announceDuration {
                state = .loading
            }
        case .loading:
            adoptTickets(fresh, now: now)
            if !generating && fresh.isEmpty {
                // Generation ended with nothing to show.
                reset()
            }
        case .presenting:
            adoptTickets(fresh, now: now)
            updatePresenting(hand: hand, now: now)
            if now - lastActivity > idleTimeout { reset(); return }
        case .grabbed(let id):
            updateGrabbed(id: id, hand: hand, now: now)
        case .dispatched(let until):
            if now >= until { reset(); return }
        }

        // Only a real pinch counts, so a hand blipping out doesn't grab.
        if hand != nil { lastPinch = hand?.isPinching ?? false }
        orbs = layout(now: now)
    }

    // MARK: Steps

    private func adoptTickets(_ fresh: [Ticket], now: CFTimeInterval) {
        guard !fresh.isEmpty else { return }
        guard fresh != tickets else { return }
        tickets = fresh
        var newCenters: [UUID: CGPoint] = [:]
        for (i, t) in tickets.enumerated() {
            newCenters[t.id] = centers[t.id] ?? corrected(restCenter(index: i, count: tickets.count))
        }
        centers = newCenters
        if state == .loading {
            state = .presenting
            presentedAt = now
            lastActivity = now
        }
    }

    private func updatePresenting(hand: DetectedHand?, now: CFTimeInterval) {
        // Spring cards back toward their resting slots.
        for (i, t) in tickets.enumerated() {
            let rest = corrected(restCenter(index: i, count: tickets.count))
            var c = centers[t.id] ?? rest
            c.x += (rest.x - c.x) * returnAlpha
            c.y += (rest.y - c.y) * returnAlpha
            centers[t.id] = c
        }
        // Pinch onset near a card grabs it.
        let pinching = hand?.isPinching ?? false
        guard pinching, !lastPinch, let raw = hand?.pinchPoint else { return }
        let p = corrected(raw)
        var best: (id: UUID, dist: CGFloat)?
        for t in tickets {
            guard let c = centers[t.id] else { continue }
            let d = hypot(p.x - c.x, p.y - c.y)
            if d < grabRadius, d < (best?.dist ?? .infinity) { best = (t.id, d) }
        }
        if let best {
            smoothedPinch = p
            dropEnteredAt = nil
            state = .grabbed(id: best.id)
            lastActivity = now
        }
    }

    private func updateGrabbed(id: UUID, hand: DetectedHand?, now: CFTimeInterval) {
        guard let ticket = tickets.first(where: { $0.id == id }) else {
            state = .presenting
            return
        }
        let pinching = hand?.isPinching ?? false
        let zone = corrected(dropZoneCenter)

        if pinching, let raw = hand?.pinchPoint {
            let p = corrected(raw)
            smoothedPinch.x += (p.x - smoothedPinch.x) * followAlpha
            smoothedPinch.y += (p.y - smoothedPinch.y) * followAlpha
            centers[id] = CGPoint(
                x: min(max(smoothedPinch.x, cardRadius), aspect - cardRadius),
                y: min(max(smoothedPinch.y, cardRadius), 1 - cardRadius))
            lastActivity = now

            // Dwell-in-zone: keep holding inside the drop zone to fire.
            if inDropZone(centers[id] ?? .zero, zone: zone) {
                if dropEnteredAt == nil { dropEnteredAt = now }
                if now - dropEnteredAt! >= dropDwell { fire(ticket, now: now) }
            } else {
                dropEnteredAt = nil
            }
        } else if !pinching || now - lastHandSeen > handLostGrace {
            // Released: inside the zone sends immediately, otherwise the card
            // just springs back (handled by presenting-state easing).
            if let c = centers[id], inDropZone(c, zone: zone),
               hand != nil || now - lastHandSeen <= handLostGrace {
                fire(ticket, now: now)
            } else {
                dropEnteredAt = nil
                state = .presenting
            }
        }
    }

    private func fire(_ ticket: Ticket, now: CFTimeInterval) {
        firedTicket = ticket
        tickets.removeAll { $0.id == ticket.id }
        centers[ticket.id] = nil
        dropEnteredAt = nil
        state = .dispatched(until: now + toastDuration)
    }

    private func inDropZone(_ p: CGPoint, zone: CGPoint) -> Bool {
        hypot(p.x - zone.x, p.y - zone.y) < dropZoneRadius
    }

    // MARK: Layout

    private func restCenter(index: Int, count: Int) -> CGPoint {
        let spacing: CGFloat = (cardRadius * 3.4) / aspect
        let x = 0.5 + (CGFloat(index) - CGFloat(count - 1) / 2) * spacing
        return CGPoint(x: x, y: rowY)
    }

    private func layout(now: CFTimeInterval) -> [TicketOrbDisplay] {
        guard state != .loading, isActive, !tickets.isEmpty else { return [] }
        let pop = min(CGFloat((now - presentedAt) / popDuration), 1)
        var grabbedID: UUID?
        if case .grabbed(let id) = state { grabbedID = id }
        var dropP: CGFloat = 0
        if let entered = dropEnteredAt {
            dropP = min(CGFloat((now - entered) / dropDwell), 1)
        }
        // Gentle idle bob so the cards feel alive.
        return tickets.enumerated().map { i, t in
            var c = normalized(centers[t.id] ?? corrected(restCenter(index: i, count: tickets.count)))
            let grabbed = t.id == grabbedID
            if !grabbed {
                c.y += 0.008 * sin(CGFloat(now) * 1.6 + CGFloat(i) * 1.3)
            }
            return TicketOrbDisplay(id: t.id, ticket: t, center: c,
                                    radiusNorm: cardRadius,
                                    grabbed: grabbed,
                                    sendProgress: grabbed ? dropP : 0,
                                    scale: 0.6 + 0.4 * pop)
        }
    }

    // MARK: Coordinate helpers (match MouseControlEngine conventions)

    private func corrected(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }
    private func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / aspect, y: p.y) }
}
