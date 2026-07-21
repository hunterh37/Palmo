import Foundation

// MARK: - Claude usage module
//
// Self-contained module (ported from ClaudeUsageTray) that reads Claude Code's
// local transcripts, aggregates token usage per account into rolling 5-hour and
// weekly windows, and renders per-account usage bars — both in a menu-bar
// popover and as progress lines wrapping the Mac notch.
//
// All types in this module are prefixed conceptually with "Claude usage" and
// kept in `Sources/ClaudeUsage/`. No external dependencies; Apple frameworks
// only. Nothing here reads auth tokens or hits the network — usage is derived
// entirely from local files under ~/.claude.

// MARK: - Core data types

struct TokenCounts: Codable, Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheCreate: Int64 = 0
    var cacheRead: Int64 = 0

    var total: Int64 { input + output + cacheCreate + cacheRead }
    /// Tokens excluding cache reads entirely.
    var billable: Int64 { input + output + cacheCreate }
    /// Cost-weighted tokens: cache reads count at 0.1x (they are ~10x cheaper
    /// and are discounted this way against rate limits), everything else 1x.
    /// This mirrors how Claude Code reports 5h/weekly usage.
    var weighted: Int64 { input + output + cacheCreate + cacheRead / 10 }

    static func + (l: TokenCounts, r: TokenCounts) -> TokenCounts {
        TokenCounts(input: l.input + r.input,
                    output: l.output + r.output,
                    cacheCreate: l.cacheCreate + r.cacheCreate,
                    cacheRead: l.cacheRead + r.cacheRead)
    }
    static func += (l: inout TokenCounts, r: TokenCounts) { l = l + r }
}

struct AccountInfo: Codable, Identifiable, Equatable {
    var uuid: String
    var email: String
    var displayName: String?
    var organizationName: String?
    var rateLimitTier: String?
    /// oauthAccount.organizationType (e.g. "claude_pro", "claude_team").
    /// Pro accounts leave rateLimitTier nil, so this is the only tier signal.
    var organizationType: String?
    var firstSeen: Date
    var lastSeen: Date

    /// User-editable limits (0 = unset)
    var fiveHourLimitTokens: Int64 = 0
    var weeklyLimitTokens: Int64 = 0
    /// Which metric limits are compared against
    var useBillableMetric: Bool = true
    /// User-chosen notch line color as "#RRGGBB" (nil = use palette default)
    var colorHex: String? = nil

    var id: String { uuid }
    var shortName: String {
        if let d = displayName, !d.isEmpty { return d }
        return email.components(separatedBy: "@").first ?? email
    }

    /// Tier signal for estimates: prefer the explicit rate-limit tier (Max
    /// plans), else fall back to organizationType (Pro plans report tier as nil
    /// but set organizationType to "claude_pro").
    var tierSignal: String? {
        if let t = rateLimitTier, !t.isEmpty { return t }
        return organizationType
    }

    /// 5h limit to gauge against: user value if set, else a tier estimate.
    var effectiveFiveHourLimit: Int64 {
        fiveHourLimitTokens > 0 ? fiveHourLimitTokens : TierDefaults.fiveHour(tierSignal)
    }
    /// Weekly limit to gauge against: user value if set, else a tier estimate.
    var effectiveWeeklyLimit: Int64 {
        weeklyLimitTokens > 0 ? weeklyLimitTokens : TierDefaults.weekly(tierSignal)
    }
    /// True when the effective 5h limit came from a tier estimate, not a user value.
    var fiveHourLimitIsEstimate: Bool { fiveHourLimitTokens <= 0 && effectiveFiveHourLimit > 0 }
    var weeklyLimitIsEstimate: Bool { weeklyLimitTokens <= 0 && effectiveWeeklyLimit > 0 }
}

/// Rough per-tier token windows. Anthropic does not publish exact token
/// limits, so these are estimates meant only to render a progress bar; users
/// can override per account. 0 = unknown tier (bar stays empty).
enum TierDefaults {
    private static func normalized(_ tier: String?) -> String {
        (tier ?? "").lowercased()
    }
    // 5h limits in cost-weighted tokens (cache reads at 0.1x). max_5x is
    // calibrated to an observed Claude Code reading (~4.2M weighted ≈ 18%).
    static func fiveHour(_ tier: String?) -> Int64 {
        let t = normalized(tier)
        if t.contains("max_20x") { return 92_000_000 }
        if t.contains("max_5x")  { return 23_000_000 }
        // "claude_pro" (organizationType) or an explicit "pro" rate-limit tier.
        if t.contains("pro")     { return 5_000_000 }
        return 0
    }
    static func weekly(_ tier: String?) -> Int64 {
        let t = normalized(tier)
        if t.contains("max_20x") { return 1_840_000_000 }
        if t.contains("max_5x")  { return 460_000_000 }
        if t.contains("pro")     { return 100_000_000 }
        return 0
    }
}

/// Default per-account colors for the notch gauge, assigned by account order
/// until the user overrides one.
enum AccountPalette {
    static let hexes = ["#30D0C0", "#5E5CE6", "#FF9F0A", "#FF375F",
                        "#32D74B", "#FFD60A", "#BF5AF2", "#64D2FF"]
    static func defaultHex(_ index: Int) -> String {
        hexes[((index % hexes.count) + hexes.count) % hexes.count]
    }
}

/// Records when the logged-in account changed, so usage can be
/// attributed to whichever account was active at each timestamp.
struct AccountSwitch: Codable {
    var timestamp: Date
    var accountUuid: String
}

/// 5-minute usage bucket, keyed by epoch/300, per account
typealias BucketMap = [String: [Int64: TokenCounts]]  // accountUuid -> bucketKey -> counts

struct FileCursor: Codable {
    var offset: UInt64
    var size: UInt64
    var mtime: Double
}

// MARK: - Persisted state

struct PersistedState: Codable {
    var accounts: [String: AccountInfo] = [:]
    var switches: [AccountSwitch] = []
    var buckets: BucketMap = [:]
    var cursors: [String: FileCursor] = [:]          // file path -> cursor
    var seenMessages: [String: Int64] = [:]          // dedupe key -> day epoch (for pruning)
    var firstRun: Date = Date()
}

// MARK: - Window math

struct UsageWindow {
    var start: Date
    var end: Date
    var counts: TokenCounts
    var isActive: Bool
}

enum WindowMath {
    /// Claude-style anchored windows: a window opens at the first usage
    /// after the previous window expired and lasts `length`.
    /// Returns the window containing `now` (if any) computed from sorted bucket keys.
    static func currentWindow(bucketKeys: [Int64], counts: [Int64: TokenCounts],
                              length: TimeInterval, now: Date) -> UsageWindow? {
        guard !bucketKeys.isEmpty else { return nil }
        var windowStart: Int64? = nil
        for k in bucketKeys {
            let t = k * 300
            if let ws = windowStart, Double(t) < Double(ws) + length {
                continue
            }
            windowStart = t
        }
        guard let ws = windowStart else { return nil }
        let start = Date(timeIntervalSince1970: Double(ws))
        let end = start.addingTimeInterval(length)
        guard now < end else { return nil }
        var sum = TokenCounts()
        for k in bucketKeys where k * 300 >= ws && Double(k * 300) < Double(ws) + length {
            sum += counts[k] ?? TokenCounts()
        }
        return UsageWindow(start: start, end: end, counts: sum, isActive: true)
    }
}

// MARK: - Formatting helpers

func fmtTokens(_ n: Int64) -> String {
    let d = Double(n)
    switch abs(d) {
    case 1_000_000_000...: return String(format: "%.2fB", d / 1_000_000_000)
    case 1_000_000...:     return String(format: "%.1fM", d / 1_000_000)
    case 1_000...:         return String(format: "%.1fK", d / 1_000)
    default:               return "\(n)"
    }
}

func fmtCountdown(to date: Date) -> String {
    let s = max(0, Int(date.timeIntervalSinceNow))
    let h = s / 3600, m = (s % 3600) / 60
    if h > 24 { return "\(h / 24)d \(h % 24)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
