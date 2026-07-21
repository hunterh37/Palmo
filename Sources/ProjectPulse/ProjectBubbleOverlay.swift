import SwiftUI

/// Draws the project briefing over the camera view: Palmo pinned bottom-left
/// (the summon anchor) with a vertical stack of status "speech bubbles" to its
/// right. When a bubble is expanded, it enlarges and a row of action chips
/// appears beneath it. Positions come from `ProjectBriefingEngine` in
/// normalized (0...1, top-left origin) video space; this view only maps and
/// styles them, matching the aspect-fill convention of the other overlays.
struct ProjectBubbleOverlay: View {
    let bubbles: [PulseBubbleDisplay]
    let actionChips: [PulseActionChip]
    let summonProgress: CGFloat
    let dismissProgress: CGFloat
    var greeting: String = ""
    let anchor: CGPoint
    let mood: BuddyMood
    let gaze: CGPoint
    let size: CGSize
    let videoSize: CGSize

    var body: some View {
        ZStack {
            palmo
            if bubbles.isEmpty, !greeting.isEmpty { greetingBubble }
            ForEach(bubbles) { bubbleView($0) }
            ForEach(actionChips) { chipView($0) }
            if dismissProgress > 0.03 { fistRing }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Palmo anchor

    private var palmo: some View {
        let c = point(anchor)
        let r: CGFloat = 0.10 * drawnSize().height
        return ZStack {
            Circle()
                .fill(Brand.accent.opacity(summonProgress > 0.02 ? 0.28 : 0.14))
                .frame(width: r * 2.3, height: r * 2.3)
                .blur(radius: r * 0.35)
            if summonProgress > 0.02 {
                Circle().stroke(.white.opacity(0.25), lineWidth: 4)
                    .frame(width: r * 2, height: r * 2)
                Circle()
                    .trim(from: 0, to: summonProgress)
                    .stroke(Brand.accent, style: .init(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: r * 2, height: r * 2)
            }
            PalmoAvatarView(mood: mood, gaze: gaze, waving: !bubbles.isEmpty)
                .frame(width: r * 1.9, height: r * 1.9)
        }
        .position(c)
    }

    // MARK: - Idle greeting speech bubble

    private var greetingBubble: some View {
        let drawn = drawnSize()
        // Sit up and to the right of Palmo, like a speech bubble.
        let center = point(CGPoint(x: min(anchor.x + 0.32, 0.66), y: anchor.y - 0.20))
        let maxW = drawn.width * 0.5
        return Text(greeting)
            .font(.system(size: max(drawn.height * 0.026, 11), weight: .semibold,
                          design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: maxW, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(0.62))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Brand.accent.opacity(0.5), lineWidth: 1.5)))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .position(center)
            .transition(.opacity)
    }

    // MARK: - Bubbles

    private func bubbleView(_ b: PulseBubbleDisplay) -> some View {
        let c = point(b.center)
        let w = b.widthNorm * drawnSize().width
        let h = b.heightNorm * drawnSize().height
        let tint = color(b.pulse.state)
        let fontScale = max(h * 0.20, 11)
        return VStack(alignment: .leading, spacing: h * 0.08) {
            HStack(spacing: 6) {
                Image(systemName: b.pulse.state.systemImage)
                    .font(.system(size: fontScale * 0.9, weight: .bold))
                    .foregroundStyle(tint)
                Text(b.pulse.name)
                    .font(.system(size: fontScale * 0.8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(b.pulse.state.label)
                    .font(.system(size: fontScale * 0.62, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }
            Text(b.pulse.headline)
                .font(.system(size: fontScale, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if b.expanded {
                Text(b.pulse.detail)
                    .font(.system(size: fontScale * 0.72))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(h * 0.16)
        .frame(width: w, height: b.expanded ? nil : h, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: h * 0.30, style: .continuous)
                .fill(.black.opacity(b.highlighted ? 0.78 : 0.58))
                .overlay(RoundedRectangle(cornerRadius: h * 0.30, style: .continuous)
                    .strokeBorder(b.highlighted ? .white.opacity(0.9) : tint.opacity(0.7),
                                  lineWidth: b.highlighted ? 2.5 : 1.5)))
        .overlay(alignment: .bottomLeading) { dwellBar(b.dwellProgress, tint: tint, radius: h * 0.30) }
        .shadow(color: tint.opacity(b.highlighted ? 0.5 : 0.25),
                radius: b.highlighted ? 12 : 6, y: 3)
        .position(c)
        .animation(.easeOut(duration: 0.15), value: b.highlighted)
    }

    /// Thin dwell-charge bar along the bottom edge of a highlighted bubble.
    @ViewBuilder
    private func dwellBar(_ progress: CGFloat, tint: Color, radius: CGFloat) -> some View {
        if progress > 0.02 {
            GeometryReader { g in
                Capsule()
                    .fill(tint)
                    .frame(width: g.size.width * progress, height: 3)
                    .offset(y: g.size.height - 3)
            }
        }
    }

    // MARK: - Action chips

    private func chipView(_ chip: PulseActionChip) -> some View {
        let c = point(chip.center)
        let r = chip.radiusNorm * drawnSize().height * (chip.highlighted ? 1.15 : 1.0)
        return ZStack {
            Circle()
                .fill(Brand.accent.opacity(chip.highlighted ? 0.9 : 0.5))
                .frame(width: r * 2, height: r * 2)
                .overlay(Circle().strokeBorder(.white.opacity(chip.highlighted ? 0.9 : 0.4),
                                               lineWidth: chip.highlighted ? 2.5 : 1.5))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Image(systemName: chip.action.systemImage)
                .font(.system(size: max(r * 0.6, 9), weight: .bold))
                .foregroundStyle(.white)
            if chip.dwellProgress > 0.02 {
                Circle()
                    .trim(from: 0, to: chip.dwellProgress)
                    .stroke(.white, style: .init(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: r * 2.5, height: r * 2.5)
            }
            Text(chip.action.label)
                .font(.system(size: max(r * 0.42, 9), weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 2)
                .offset(y: r * 1.9)
        }
        .position(c)
    }

    private var fistRing: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: dismissProgress)
                .stroke(Color.red, style: .init(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 44, height: 44)
        .position(x: size.width / 2, y: size.height / 2)
    }

    private func color(_ state: PulseState) -> Color {
        let t = state.tint
        return Color(red: t.r, green: t.g, blue: t.b)
    }

    // Aspect-fill mapping, matching every other overlay.
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
