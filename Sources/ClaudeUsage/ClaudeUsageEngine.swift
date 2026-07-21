import Foundation
import Combine

/// Scans Claude Code transcript JSONLs, watches for account switches,
/// aggregates token usage into 5-minute buckets per account, and
/// computes 5-hour + weekly usage windows.
///
/// Ported from ClaudeUsageTray. The only integration change from the original
/// is the persisted-state location, which now lives under the app's shared
/// Application Support directory (`HandOrbMenu/`), matching `ClaudeSessionStore`.
final class UsageEngine: ObservableObject {

    static let shared = UsageEngine()

    // Published snapshot for the UI
    struct AccountSnapshot: Identifiable {
        var info: AccountInfo
        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var isCurrent: Bool
        var id: String { info.uuid }
    }

    @Published var snapshots: [AccountSnapshot] = []
    @Published var currentAccountUuid: String? = nil
    @Published var menuTitle: String = "…"
    @Published var lastScan: Date? = nil
    @Published var scanning: Bool = false

    private var state = PersistedState()
    private let q = DispatchQueue(label: "claude.usage.engine", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var projectsDir: URL { home.appendingPathComponent(".claude/projects") }
    private var claudeJson: URL { home.appendingPathComponent(".claude.json") }
    private var stateURL: URL {
        // Reuse the app's shared support directory so all Palmo state lives in
        // one place (see ClaudeSessionStore.supportDir).
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HandOrbMenu")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude-usage-state.json")
    }

    init() {
        q.async { [weak self] in
            guard let self else { return }
            self.loadState()
            self.tick()
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 10, repeating: 10)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func rescanNow() { q.async { [weak self] in self?.tick() } }

    func updateAccount(_ uuid: String, mutate: @escaping (inout AccountInfo) -> Void) {
        q.async { [weak self] in
            guard let self, var a = self.state.accounts[uuid] else { return }
            mutate(&a)
            self.state.accounts[uuid] = a
            self.saveState()
            self.publish()
        }
    }

    // MARK: - Main loop

    private func tick() {
        DispatchQueue.main.async { self.scanning = true }
        pollAccount()
        scanTranscripts()
        pruneOld()
        saveState()
        publish()
        DispatchQueue.main.async { self.scanning = false; self.lastScan = Date() }
    }

    // MARK: - Account watching (~/.claude.json oauthAccount)

    private func pollAccount() {
        guard let data = try? Data(contentsOf: claudeJson),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oa = obj["oauthAccount"] as? [String: Any],
              let uuid = oa["accountUuid"] as? String else { return }

        let email = oa["emailAddress"] as? String ?? "unknown"
        let now = Date()
        if var existing = state.accounts[uuid] {
            existing.lastSeen = now
            existing.email = email
            existing.displayName = oa["displayName"] as? String ?? existing.displayName
            existing.organizationName = oa["organizationName"] as? String ?? existing.organizationName
            existing.rateLimitTier = oa["userRateLimitTier"] as? String ?? existing.rateLimitTier
            existing.organizationType = oa["organizationType"] as? String ?? existing.organizationType
            state.accounts[uuid] = existing
        } else {
            state.accounts[uuid] = AccountInfo(
                uuid: uuid, email: email,
                displayName: oa["displayName"] as? String,
                organizationName: oa["organizationName"] as? String,
                rateLimitTier: oa["userRateLimitTier"] as? String,
                organizationType: oa["organizationType"] as? String,
                firstSeen: now, lastSeen: now)
        }
        if state.switches.last?.accountUuid != uuid {
            state.switches.append(AccountSwitch(timestamp: now, accountUuid: uuid))
        }
    }

    /// Which account was active at a given time (based on recorded switches).
    private func accountAt(_ ts: Date) -> String? {
        var result: String? = state.switches.first?.accountUuid
        for s in state.switches {
            if s.timestamp <= ts { result = s.accountUuid } else { break }
        }
        return result
    }

    // MARK: - Transcript scanning

    private func scanTranscripts() {
        guard let en = FileManager.default.enumerator(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }

        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = vals.contentModificationDate?.timeIntervalSince1970,
                  let size = vals.fileSize.map(UInt64.init) else { continue }

            let path = url.path
            var cursor = state.cursors[path] ?? FileCursor(offset: 0, size: 0, mtime: 0)
            if cursor.size == size && cursor.mtime == mtime { continue }   // unchanged
            if size < cursor.offset { cursor.offset = 0 }                   // truncated/rewritten

            if let fh = try? FileHandle(forReadingFrom: url) {
                defer { try? fh.close() }
                try? fh.seek(toOffset: cursor.offset)
                if let data = try? fh.readToEnd(), !data.isEmpty {
                    // Only consume up to the last complete line
                    var consumable = data
                    var tail: UInt64 = 0
                    if data.last != 0x0A, let lastNL = data.lastIndex(of: 0x0A) {
                        consumable = data.subdata(in: data.startIndex..<data.index(after: lastNL))
                        tail = UInt64(data.count - consumable.count)
                    } else if data.last != 0x0A {
                        consumable = Data(); tail = UInt64(data.count)
                    }
                    ingest(lines: consumable)
                    cursor.offset += UInt64(data.count) - tail
                }
            }
            cursor.size = size
            cursor.mtime = mtime
            state.cursors[path] = cursor
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    private func ingest(lines: Data) {
        for chunk in lines.split(separator: 0x0A, omittingEmptySubsequences: true) {
            ingestLine(Data(chunk))
        }
    }

    private func ingestLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let tsStr = obj["timestamp"] as? String else { return }

        let ts = Self.isoFrac.date(from: tsStr) ?? Self.iso.date(from: tsStr) ?? Date()

        // Dedupe: one count per message id + request id (streamed messages
        // repeat identical usage across multiple JSONL lines).
        let msgId = msg["id"] as? String ?? ""
        let reqId = obj["requestId"] as? String ?? (obj["uuid"] as? String ?? UUID().uuidString)
        let key = "\(msgId):\(reqId)"
        let dayEpoch = Int64(ts.timeIntervalSince1970) / 86400
        if state.seenMessages[key] != nil { return }
        state.seenMessages[key] = dayEpoch

        func num(_ k: String) -> Int64 { (usage[k] as? NSNumber)?.int64Value ?? 0 }
        let counts = TokenCounts(input: num("input_tokens"),
                                 output: num("output_tokens"),
                                 cacheCreate: num("cache_creation_input_tokens"),
                                 cacheRead: num("cache_read_input_tokens"))
        guard counts.total > 0 else { return }

        let account = accountAt(ts) ?? state.switches.last?.accountUuid ?? "unknown"
        let bucket = Int64(ts.timeIntervalSince1970) / 300
        var map = state.buckets[account] ?? [:]
        map[bucket] = (map[bucket] ?? TokenCounts()) + counts
        state.buckets[account] = map
    }

    // MARK: - Pruning

    private func pruneOld() {
        let cutoffBucket = Int64(Date().timeIntervalSince1970 - 9 * 86400) / 300
        for (acct, map) in state.buckets {
            state.buckets[acct] = map.filter { $0.key >= cutoffBucket }
        }
        let cutoffDay = Int64(Date().timeIntervalSince1970 - 9 * 86400) / 86400
        state.seenMessages = state.seenMessages.filter { $0.value >= cutoffDay }
        // Keep switch history compact: drop switches older than 9 days except the last-before-cutoff
        let cutoff = Date().addingTimeInterval(-9 * 86400)
        if state.switches.count > 1 {
            var kept: [AccountSwitch] = []
            var lastBefore: AccountSwitch? = nil
            for s in state.switches {
                if s.timestamp < cutoff { lastBefore = s } else { kept.append(s) }
            }
            if let lb = lastBefore { kept.insert(AccountSwitch(timestamp: cutoff, accountUuid: lb.accountUuid), at: 0) }
            state.switches = kept
        }
    }

    // MARK: - Publish snapshot

    private func publish() {
        let now = Date()
        let current = state.switches.last?.accountUuid
        var snaps: [AccountSnapshot] = []
        for (uuid, info) in state.accounts {
            let map = state.buckets[uuid] ?? [:]
            let keys = map.keys.sorted()
            let fiveH = WindowMath.currentWindow(bucketKeys: keys, counts: map, length: 5 * 3600, now: now)
            let weekly = WindowMath.currentWindow(bucketKeys: keys, counts: map, length: 7 * 86400, now: now)
            snaps.append(AccountSnapshot(info: info, fiveHour: fiveH, weekly: weekly, isCurrent: uuid == current))
        }
        snaps.sort { ($0.isCurrent ? 0 : 1, $0.info.email) < ($1.isCurrent ? 0 : 1, $1.info.email) }

        var title = "CT"
        if let cur = snaps.first(where: { $0.isCurrent }) {
            let metricTotal = cur.fiveHour.map {
                cur.info.useBillableMetric ? $0.counts.weighted : $0.counts.total } ?? 0
            if cur.info.effectiveFiveHourLimit > 0 {
                let pct = Int((Double(metricTotal) / Double(cur.info.effectiveFiveHourLimit)) * 100)
                title = "\(cur.info.shortName.prefix(8)) \(pct)%"
            } else {
                title = "\(cur.info.shortName.prefix(8)) \(fmtTokens(metricTotal))"
            }
        }

        DispatchQueue.main.async {
            self.snapshots = snaps
            self.currentAccountUuid = current
            self.menuTitle = title
        }
    }

    // MARK: - State persistence

    private func loadState() {
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = s
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}
