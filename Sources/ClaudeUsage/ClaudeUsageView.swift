import SwiftUI

/// Per-account Claude token-usage bars. Designed to live inside a
/// `MenuBarExtra` popover (see `ClaudeUsageModule`). Expects `UsageEngine` and
/// `NotchController` in the environment.
struct ClaudeUsageView: View {
    @EnvironmentObject var engine: UsageEngine
    @EnvironmentObject var notch: NotchController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude Token Usage")
                    .font(.headline)
                Spacer()
                if engine.scanning { ProgressView().controlSize(.small) }
                Button { engine.rescanNow() } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless)
            }

            if engine.snapshots.isEmpty {
                Text("Scanning ~/.claude transcripts…")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(engine.snapshots.enumerated()), id: \.element.id) { i, snap in
                            AccountCard(snap: snap, index: i)
                        }
                    }
                }
                .frame(maxHeight: 480)
            }

            Divider()
            Toggle(isOn: $notch.enabled) {
                Label("Wrap 5-hour gauge around the notch", systemImage: "sparkles")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let t = engine.lastScan {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

struct AccountCard: View {
    @EnvironmentObject var engine: UsageEngine
    @EnvironmentObject var notch: NotchController
    let snap: UsageEngine.AccountSnapshot
    let index: Int
    @State private var editingLimits = false
    @State private var fiveHText = ""
    @State private var weekText = ""

    private var accountColor: Binding<Color> {
        Binding(
            get: { Color(hex: snap.info.colorHex ?? AccountPalette.defaultHex(index)) },
            set: { newColor in
                engine.updateAccount(snap.info.uuid) { $0.colorHex = newColor.hexString }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accountColor.wrappedValue)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(snap.isCurrent ? Color.primary.opacity(0.5) : .clear, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(snap.info.shortName).font(.subheadline.weight(.semibold))
                    Text(snap.info.email).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let tier = snap.info.tierSignal {
                    Text(tierLabel(tier))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Button {
                    fiveHText = snap.info.fiveHourLimitTokens > 0 ? "\(snap.info.fiveHourLimitTokens / 1_000_000)" : ""
                    weekText = snap.info.weeklyLimitTokens > 0 ? "\(snap.info.weeklyLimitTokens / 1_000_000)" : ""
                    editingLimits.toggle()
                } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
            }

            WindowGauge(label: "5-hour window",
                        window: snap.fiveHour,
                        limit: snap.info.effectiveFiveHourLimit,
                        isEstimate: snap.info.fiveHourLimitIsEstimate,
                        billable: snap.info.useBillableMetric)
            WindowGauge(label: "Weekly window",
                        window: snap.weekly,
                        limit: snap.info.effectiveWeeklyLimit,
                        isEstimate: snap.info.weeklyLimitIsEstimate,
                        billable: snap.info.useBillableMetric)

            if editingLimits {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("5h limit").font(.caption).frame(width: 60, alignment: .leading)
                        TextField("M tokens", text: $fiveHText).textFieldStyle(.roundedBorder).font(.caption)
                        Text("M").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Weekly").font(.caption).frame(width: 60, alignment: .leading)
                        TextField("M tokens", text: $weekText).textFieldStyle(.roundedBorder).font(.caption)
                        Text("M").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Notch color").font(.caption).frame(width: 60, alignment: .leading)
                        ColorPicker("", selection: accountColor, supportsOpacity: false)
                            .labelsHidden()
                        Button("Reset") {
                            engine.updateAccount(snap.info.uuid) { $0.colorHex = nil }
                        }.controlSize(.small).font(.caption2)
                        Spacer()
                    }
                    Toggle("Cost-weight cache reads (0.1x) — matches Claude Code", isOn: Binding(
                        get: { snap.info.useBillableMetric },
                        set: { v in engine.updateAccount(snap.info.uuid) { $0.useBillableMetric = v } }
                    )).font(.caption2)
                    HStack {
                        Spacer()
                        Button("Save") {
                            let fh = Int64(Double(fiveHText) ?? 0) * 1_000_000
                            let wk = Int64(Double(weekText) ?? 0) * 1_000_000
                            engine.updateAccount(snap.info.uuid) {
                                $0.fiveHourLimitTokens = fh
                                $0.weeklyLimitTokens = wk
                            }
                            editingLimits = false
                        }.controlSize(.small)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(snap.isCurrent ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1))
    }

    private func tierLabel(_ t: String) -> String {
        t.replacingOccurrences(of: "default_", with: "")
         .replacingOccurrences(of: "claude_", with: "")
         .replacingOccurrences(of: "_", with: " ")
    }
}

extension Color {
    /// Build from "#RRGGBB"; falls back to gray on malformed input.
    init(hex: String) {
        if let ns = NSColor(hex: hex) { self.init(nsColor: ns) } else { self.init(.gray) }
    }
    /// "#RRGGBB" for persistence.
    var hexString: String { NSColor(self).hexString }
}

struct WindowGauge: View {
    let label: String
    let window: UsageWindow?
    let limit: Int64
    var isEstimate: Bool = false
    let billable: Bool

    private var used: Int64 {
        guard let w = window else { return 0 }
        return billable ? w.counts.weighted : w.counts.total
    }
    private var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(1.0, Double(used) / Double(limit))
    }
    private var barColor: Color {
        switch fraction {
        case 0.85...: return .red
        case 0.6...:  return .orange
        default:      return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let w = window {
                    Text("resets in \(fmtCountdown(to: w.end))")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("idle").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if limit > 0 {
                        Capsule().fill(barColor)
                            .frame(width: max(3, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 6)
            HStack {
                Text(limit > 0
                     ? "\(fmtTokens(used)) / \(fmtTokens(limit))\(isEstimate ? " est." : "")  (\(Int(fraction * 100))%)"
                     : "\(fmtTokens(used)) used")
                    .font(.caption2.monospacedDigit())
                Spacer()
                if let w = window {
                    Text("in \(fmtTokens(w.counts.input + w.counts.cacheCreate)) · out \(fmtTokens(w.counts.output)) · cached \(fmtTokens(w.counts.cacheRead))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
