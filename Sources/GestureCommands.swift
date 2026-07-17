import AppKit
import AVFoundation
import QuartzCore
import UserNotifications

/// An action that an air gesture can trigger. User-remappable in Settings.
enum AirCommand: String, CaseIterable, Identifiable, Codable {
    case screenshot, playPause, missionControl, askPalmo, none
    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .playPause: return "Play / Pause"
        case .missionControl: return "Mission Control"
        case .askPalmo: return "Ask \(Brand.name)"
        case .none: return "Do nothing"
        }
    }

    var icon: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .playPause: return "playpause.fill"
        case .missionControl: return "rectangle.3.group"
        case .askPalmo: return "sparkles"
        case .none: return "circle.slash"
        }
    }

    func perform() {
        switch self {
        case .screenshot:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let stamp = ISO8601DateFormatter().string(from: .now)
                .replacingOccurrences(of: ":", with: ".")
            let dest = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Palmo Shot \(stamp).png").path
            task.arguments = ["-x", dest]
            try? task.run()
        case .playPause:
            MediaKey.postPlayPause()
        case .missionControl:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", "Mission Control"]
            try? task.run()
        case .askPalmo:
            NotificationCenter.default.post(name: .openAssistant, object: nil)
        case .none:
            break
        }
    }
}

/// Watches for held air gestures (peace sign, thumbs-up) and fires their
/// mapped commands with hold-to-confirm + cooldown so nothing misfires.
@MainActor
final class GestureCommandEngine {
    /// Hold time before a gesture fires.
    private let holdTime: CFTimeInterval = 0.6
    /// Cooldown between fires of the same gesture.
    private let cooldown: CFTimeInterval = 2.5

    /// Called when a command fires (label for the toast).
    var onFired: ((AirCommand, String) -> Void)?

    /// 0...1 progress ring for whichever gesture is currently held.
    private(set) var holdProgress: CGFloat = 0
    private(set) var holdingLabel: String?

    private var peaceSince: CFTimeInterval?
    private var thumbsSince: CFTimeInterval?
    private var lastFire: [String: CFTimeInterval] = [:]

    func update(hand: DetectedHand?, now: CFTimeInterval) {
        let settings = AppSettings.shared
        holdProgress = 0
        holdingLabel = nil

        track(active: hand?.isPeaceSign == true && settings.peaceCommand != .none,
              since: &peaceSince, key: "peace", now: now,
              command: settings.peaceCommand, emoji: "✌️")
        track(active: hand?.isThumbsUp == true && settings.thumbsUpCommand != .none,
              since: &thumbsSince, key: "thumbs", now: now,
              command: settings.thumbsUpCommand, emoji: "👍")
    }

    private func track(active: Bool, since: inout CFTimeInterval?, key: String,
                       now: CFTimeInterval, command: AirCommand, emoji: String) {
        guard active else { since = nil; return }
        if let last = lastFire[key], now - last < cooldown { return }
        if since == nil { since = now }
        let progress = min(CGFloat((now - since!) / holdTime), 1)
        holdProgress = max(holdProgress, progress)
        holdingLabel = "\(emoji) \(command.label)"
        if progress >= 1 {
            since = nil
            lastFire[key] = now
            command.perform()
            onFired?(command, "\(emoji) \(command.label)")
        }
    }
}

/// Palmo speaks tiny celebrations out loud (optional).
@MainActor
final class VoiceReactor {
    private let synth = AVSpeechSynthesizer()

    func say(_ phrase: String) {
        guard AppSettings.shared.voiceReactions else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: phrase)
        u.rate = 0.52
        u.pitchMultiplier = 1.25
        synth.speak(u)
    }
}

/// Lifetime + daily usage stats, streaks — playful and persistent.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()
    private let d = UserDefaults.standard

    @Published private(set) var appLaunches: Int
    @Published private(set) var clicks: Int
    @Published private(set) var screenshots: Int
    @Published private(set) var handsSeenSeconds: Double
    @Published private(set) var streakDays: Int

    private init() {
        appLaunches = d.integer(forKey: "stat.launches")
        clicks = d.integer(forKey: "stat.clicks")
        screenshots = d.integer(forKey: "stat.shots")
        handsSeenSeconds = d.double(forKey: "stat.handSeconds")
        streakDays = max(d.integer(forKey: "stat.streak"), 0)
        bumpStreakIfNewDay()
    }

    func countLaunch() { appLaunches += 1; d.set(appLaunches, forKey: "stat.launches"); touch() }
    func countClick() { clicks += 1; d.set(clicks, forKey: "stat.clicks"); touch() }
    func countScreenshot() { screenshots += 1; d.set(screenshots, forKey: "stat.shots"); touch() }

    /// Called each frame a hand is visible (dt seconds).
    func addHandTime(_ dt: Double) {
        handsSeenSeconds += dt
        // Persist coarsely to avoid hammering UserDefaults.
        if Int(handsSeenSeconds) % 10 == 0 {
            d.set(handsSeenSeconds, forKey: "stat.handSeconds")
        }
    }

    private func touch() { bumpStreakIfNewDay() }

    private func bumpStreakIfNewDay() {
        let today = Calendar.current.startOfDay(for: .now)
        let last = d.object(forKey: "stat.lastDay") as? Date
        if last == nil {
            streakDays = 1
        } else if let last, !Calendar.current.isDate(last, inSameDayAs: today) {
            let gap = Calendar.current.dateComponents([.day], from: last, to: today).day ?? 99
            streakDays = gap == 1 ? streakDays + 1 : 1
        }
        d.set(today, forKey: "stat.lastDay")
        d.set(streakDays, forKey: "stat.streak")
    }
}

/// A focus (pomodoro) timer that Palmo cheers you through.
@MainActor
final class FocusTimer: ObservableObject {
    @Published private(set) var remaining: Int = 0
    @Published private(set) var running = false
    var totalMinutes = 25
    private var timer: Timer?

    var display: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    func start() {
        remaining = totalMinutes * 60
        running = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        running = false
        remaining = 0
    }

    private func tick() {
        guard running else { return }
        remaining -= 1
        if remaining <= 0 {
            stop()
            let content = UNMutableNotificationContent()
            content.title = "Focus session done! 🎉"
            content.body = "\(Brand.name) is proud of you. Shake those hands out."
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString,
                                      content: content, trigger: nil))
        }
    }
}
