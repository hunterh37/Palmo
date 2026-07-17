import SwiftUI
import AppKit

/// Content of the macOS menu bar (tray) popover: a compact live webcam view
/// with the hand skeleton overlay, plus the full set of app controls.
struct MenuBarView: View {
    @EnvironmentObject private var model: HandMenuModel

    private let previewSize = CGSize(width: 300, height: 170)

    var body: some View {
        VStack(spacing: 10) {
            compactPreview
            controls
            footer
        }
        .padding(12)
        .frame(width: 324)
    }

    // MARK: - Compact webcam view

    private var compactPreview: some View {
        ZStack {
            if model.cameraAuthorized {
                CameraPreview(session: model.session, mirrored: model.mirrored)
                MiniHandOverlay(hands: model.hands, size: previewSize,
                                videoSize: model.videoSize)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "video.slash")
                    Text("Camera access denied")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))
            }
            VStack {
                Spacer()
                HStack {
                    Label(model.statusText, systemImage: "hand.raised")
                        .lineLimit(1)
                    Spacer()
                    Text("\(model.fps) fps")
                }
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(0.12)))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 6) {
            Toggle(isOn: $model.mouseModeEnabled) {
                Label("Mouse control", systemImage: "cursorarrow")
            }
            Toggle(isOn: $model.mirrored) {
                Label("Mirror preview", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            Toggle(isOn: $model.collapsed) {
                Label("Collapse to overlay", systemImage: "rectangle.inset.topright.filled")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button {
                CollapseWindowStyler.shared.showMainWindow()
            } label: {
                Label("Show Window", systemImage: "macwindow")
            }
            Spacer()
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .controlSize(.small)
    }
}

/// Lightweight hand-skeleton dots for the tray preview (tips + wrist only,
/// so it stays readable at small sizes).
private struct MiniHandOverlay: View {
    let hands: [DetectedHand]
    let size: CGSize
    let videoSize: CGSize

    private static let tips: Set<HandJointID> = [
        .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip, .wrist,
    ]

    var body: some View {
        Canvas { ctx, _ in
            for hand in hands {
                let color: Color = hand.isOpenPalmUp ? .cyan
                    : (hand.isLeft ? .blue : .orange)
                for (id, p) in hand.points where Self.tips.contains(id) {
                    let c = point(p)
                    let r: CGFloat = id == .wrist ? 4 : 2.5
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(color))
                }
                if hand.isPinching,
                   let thumb = hand.points[.thumbTip],
                   let index = hand.points[.indexTip] {
                    var path = Path()
                    path.move(to: point(thumb))
                    path.addLine(to: point(index))
                    ctx.stroke(path, with: .color(.yellow), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ p: CGPoint) -> CGPoint {
        guard videoSize.width > 0, videoSize.height > 0 else {
            return CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        let drawn = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let offset = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)
        return CGPoint(x: offset.x + p.x * drawn.width,
                       y: offset.y + p.y * drawn.height)
    }
}
