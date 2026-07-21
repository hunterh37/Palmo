import AppKit
import Combine
import QuartzCore

/// Draws thin, stacked progress lines that hug the MacBook notch (or a floating
/// pill on Macs without a notch) — one line per detected account, each in its
/// own color, filling with that account's 5-hour usage. Toggled from settings.
final class NotchController: ObservableObject {
    static let shared = NotchController()

    private static let defaultsKey = "claudeUsageShowNotchGauge"
    private let gap: CGFloat = 4          // spacing between stacked lines
    private let maxLines = 6              // cap so the overlay stays compact

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            render(animated: false)
        }
    }

    private weak var engine: UsageEngine?
    private var panel: NSPanel?
    private var view: NotchView?
    private var bag = Set<AnyCancellable>()

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    /// Wire up to the shared engine. Call once on launch (main thread).
    func attach(engine: UsageEngine) {
        self.engine = engine
        engine.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render(animated: true) }
            .store(in: &bag)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        render(animated: false)
    }

    @objc private func screensChanged() { render(animated: false) }

    // MARK: - Render

    private func render(animated: Bool) {
        guard enabled else { panel?.orderOut(nil); return }
        let entries = buildEntries()
        guard !entries.isEmpty,
              let g = computeGeometry(lineCount: entries.count) else {
            panel?.orderOut(nil); return
        }
        ensurePanel()
        guard let panel, let view else { return }
        panel.setFrame(g.rect, display: true)
        view.frame = CGRect(origin: .zero, size: g.rect.size)
        view.setEntries(entries, wing: g.wing, notchWidth: g.notchWidth,
                        notchHeight: g.notchHeight, gap: gap, animated: animated)
        panel.orderFrontRegardless()
    }

    private func buildEntries() -> [NotchView.Entry] {
        guard let engine else { return [] }
        return engine.snapshots.prefix(maxLines).enumerated().map { i, s in
            let hex = s.info.colorHex ?? AccountPalette.defaultHex(i)
            let color = NSColor(hex: hex) ?? .systemTeal
            let limit = s.info.effectiveFiveHourLimit
            var frac: CGFloat = 0
            if limit > 0, let w = s.fiveHour {
                let used = s.info.useBillableMetric ? w.counts.weighted : w.counts.total
                frac = CGFloat(min(1.0, Double(used) / Double(limit)))
            }
            return NotchView.Entry(color: color.cgColor, fraction: frac)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let v = NotchView()
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = v
        panel = p
        view = v
    }

    // MARK: - Geometry

    private func computeGeometry(lineCount: Int) -> (rect: NSRect, notchWidth: CGFloat,
                                                     notchHeight: CGFloat, wing: CGFloat)? {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        guard let screen else { return nil }
        let f = screen.frame
        var notchH = screen.safeAreaInsets.top
        let notchW: CGFloat
        let notchLeft: CGFloat

        if notchH > 0,
           let l = screen.auxiliaryTopLeftArea,
           let r = screen.auxiliaryTopRightArea {
            notchLeft = l.maxX
            notchW = max(120, r.minX - l.maxX)
        } else {
            notchH = 32
            notchW = 200
            notchLeft = f.midX - notchW / 2
        }

        let extra = CGFloat(max(0, lineCount - 1)) * gap
        let wing = 34 + extra
        let winH = notchH + 8 + extra
        let winW = notchW + wing * 2
        let rect = NSRect(x: notchLeft - wing, y: f.maxY - winH, width: winW, height: winH)
        return (rect, notchW, notchH, wing)
    }
}

/// Layer-backed view that strokes one subtle track + colored progress line per
/// account, each nested a little further out from the notch than the last.
final class NotchView: NSView {
    struct Entry { let color: CGColor; let fraction: CGFloat }

    private var trackLayers: [CAShapeLayer] = []
    private var progLayers: [CAShapeLayer] = []
    private let lineWidth: CGFloat = 2.5

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    func setEntries(_ entries: [Entry], wing: CGFloat, notchWidth: CGFloat,
                    notchHeight: CGFloat, gap: CGFloat, animated: Bool) {
        if trackLayers.count != entries.count { rebuild(count: entries.count) }
        let size = bounds.size

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.5)
        for (i, e) in entries.enumerated() {
            let offset = CGFloat(i) * gap
            let path = Self.notchPath(size: size, wing: wing, notchWidth: notchWidth,
                                      notchHeight: notchHeight, offset: offset,
                                      lineWidth: lineWidth)
            let track = trackLayers[i]
            track.frame = bounds
            track.path = path
            track.strokeColor = e.color.copy(alpha: 0.12) ?? e.color

            let prog = progLayers[i]
            prog.frame = bounds
            prog.path = path
            prog.strokeColor = e.color
            prog.shadowColor = e.color
            prog.strokeEnd = e.fraction
        }
        CATransaction.commit()
    }

    private func rebuild(count: Int) {
        (trackLayers + progLayers).forEach { $0.removeFromSuperlayer() }
        trackLayers.removeAll(); progLayers.removeAll()
        for _ in 0..<count {
            let track = CAShapeLayer()
            track.fillColor = NSColor.clear.cgColor
            track.lineWidth = lineWidth
            track.lineCap = .round

            let prog = CAShapeLayer()
            prog.fillColor = NSColor.clear.cgColor
            prog.lineWidth = lineWidth
            prog.lineCap = .round
            prog.strokeEnd = 0
            prog.shadowRadius = 4
            prog.shadowOpacity = 0.6
            prog.shadowOffset = .zero

            layer?.addSublayer(track)
            layer?.addSublayer(prog)
            trackLayers.append(track)
            progLayers.append(prog)
        }
    }

    /// Trace the notch outline (bottom-left origin), nudged `offset` points
    /// outward so multiple lines nest around each other.
    static func notchPath(size: CGSize, wing: CGFloat, notchWidth: CGFloat,
                          notchHeight: CGFloat, offset: CGFloat,
                          lineWidth: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let m = lineWidth / 2 + 0.5
        let r: CGFloat = 7
        let W = size.width
        let topY = size.height - m
        let botY = size.height - notchHeight - offset
        let x0 = wing - offset                 // notch left edge (nudged out)
        let x1 = wing + notchWidth + offset     // notch right edge (nudged out)

        p.move(to: CGPoint(x: m, y: topY))
        p.addLine(to: CGPoint(x: x0 - r, y: topY))
        p.addQuadCurve(to: CGPoint(x: x0, y: topY - r), control: CGPoint(x: x0, y: topY))
        p.addLine(to: CGPoint(x: x0, y: botY + r))
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: botY), control: CGPoint(x: x0, y: botY))
        p.addLine(to: CGPoint(x: x1 - r, y: botY))
        p.addQuadCurve(to: CGPoint(x: x1, y: botY + r), control: CGPoint(x: x1, y: botY))
        p.addLine(to: CGPoint(x: x1, y: topY - r))
        p.addQuadCurve(to: CGPoint(x: x1 + r, y: topY), control: CGPoint(x: x1, y: topY))
        p.addLine(to: CGPoint(x: W - m, y: topY))
        return p
    }
}

// MARK: - Hex color

extension NSColor {
    /// Parse "#RRGGBB" (or "RRGGBB"). Returns nil on malformed input.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
