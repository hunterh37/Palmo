import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: HandMenuModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if model.cameraAuthorized {
                    CameraPreview(session: model.session, mirrored: model.mirrored)
                    OrbSceneView(orbs: model.orbs, size: geo.size,
                                 videoSize: model.videoSize)
                        .allowsHitTesting(false)
                    OrbLabelOverlay(orbs: model.orbs, size: geo.size,
                                    videoSize: model.videoSize)
                    DismissRingOverlay(orbs: model.orbs,
                                       progress: model.dismissProgress,
                                       size: geo.size,
                                       videoSize: model.videoSize)
                    if let mouseOrb = model.mouseOrb {
                        MouseOrbOverlay(orb: mouseOrb, size: geo.size,
                                        videoSize: model.videoSize)
                    }
                    HandOverlay(hands: model.hands, size: geo.size,
                                videoSize: model.videoSize)
                } else {
                    cameraDeniedNotice
                }
                VStack {
                    if let name = model.launchedName {
                        launchToast(name)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    if model.collapsed {
                        collapsedBar
                    } else {
                        statusBar
                    }
                }
                .animation(.spring(duration: 0.35), value: model.launchedName)
            }
        }
        .background(Color.black)
        .background(WindowAccessor())
        .frame(minWidth: model.collapsed ? CollapseWindowStyler.collapsedSize.width : 720,
               minHeight: model.collapsed ? CollapseWindowStyler.collapsedSize.height : 480)
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
            }
            .buttonStyle(.plain)
            .help("Expand")
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func launchToast(_ name: String) -> some View {
        Label("Opening \(name)", systemImage: "sparkles")
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 16)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
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
