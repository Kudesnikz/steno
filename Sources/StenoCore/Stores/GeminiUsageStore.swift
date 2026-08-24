import CryptoKit
import Foundation

public struct GeminiUsageSnapshot: Hashable, Sendable {
    public var requestsLastMinute: Int
    public var requestsToday: Int
    public var successfulRequestsToday: Int
    public var tokensToday: ReportTokens
    public var tokensByModelToday: [String: ReportTokens]
    public var requestsByKindToday: [GeminiUsageKind: Int]
    public var nextDailyReset: Date
    public var blockedUntil: Date?

    public init(
        requestsLastMinute: Int,
        requestsToday: Int,
        successfulRequestsToday: Int,
        tokensToday: ReportTokens,
        tokensByModelToday: [String: ReportTokens] = [:],
        requestsByKindToday: [GeminiUsageKind: Int] = [:],
        nextDailyReset: Date,
        blockedUntil: Date?
    ) {
        self.requestsLastMinute = requestsLastMinute
        self.requestsToday = requestsToday
        self.successfulRequestsToday = successfulRequestsToday
        self.tokensToday = tokensToday
        self.tokensByModelToday = tokensByModelToday
        self.requestsByKindToday = requestsByKindToday
        self.nextDailyReset = nextDailyReset
        self.blockedUntil = blockedUntil
    }
}
public actor GeminiUsageStore {
    private let fileManager: FileManager
    private let url: URL
    private var ledger: GeminiUsageLedger

    public init(
        url: URL = UserPaths.stenoDirectory.appending(path: "gemini-usage.json"),
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(GeminiUsageLedger.self, from: data) {
            ledger = stored
        } else {
            ledger = GeminiUsageLedger()
        }
    }

    public nonisolated static func credentialFingerprint(_ apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public func record(apiKey: String, event: GeminiUsageEvent) {
        let fingerprint = Self.credentialFingerprint(apiKey)
        var events = ledger.eventsByCredential[fingerprint] ?? []
        events.append(event)
        let cutoff = Date().addingTimeInterval(-32 * 86_400)
        ledger.eventsByCredential[fingerprint] = events.filter { $0.timestamp >= cutoff }
        persist()
    }

    public func setBlockedUntil(apiKey: String, date: Date?) {
        let fingerprint = Self.credentialFingerprint(apiKey)
        ledger.blockedUntilByCredential[fingerprint] = date
        persist()
    }

    public func snapshot(apiKey: String, now: Date = Date()) -> GeminiUsageSnapshot {
        let fingerprint = Self.credentialFingerprint(apiKey)
        let events = ledger.eventsByCredential[fingerprint] ?? []
        let minuteCutoff = now.addingTimeInterval(-60)
        let reset = Self.currentDailyWindowStart(now: now)
        let today = events.filter { $0.timestamp >= reset && $0.timestamp <= now }
        let tokens = today.compactMap(\.tokens).reduce(ReportTokens(input: 0, output: 0, total: 0)) { result, next in
            ReportTokens(
                input: result.input + next.input,
                output: result.output + next.output,
                total: result.total + next.total
            )
        }
        let blocked = ledger.blockedUntilByCredential[fingerprint].flatMap { $0 > now ? $0 : nil }
        let tokensByModel = Dictionary(grouping: today, by: \.model).mapValues { modelEvents in
            modelEvents.compactMap(\.tokens).reduce(ReportTokens(input: 0, output: 0, total: 0)) { result, next in
                ReportTokens(
                    input: result.input + next.input,
                    output: result.output + next.output,
                    total: result.total + next.total
                )
            }
        }
        let requestsByKind = Dictionary(grouping: today, by: \.kind).mapValues(\.count)
        return GeminiUsageSnapshot(
            requestsLastMinute: events.filter { $0.timestamp >= minuteCutoff && $0.timestamp <= now }.count,
            requestsToday: today.count,
            successfulRequestsToday: today.filter(\.succeeded).count,
            tokensToday: tokens,
            tokensByModelToday: tokensByModel,
            requestsByKindToday: requestsByKind,
            nextDailyReset: Self.nextDailyReset(after: now),
            blockedUntil: blocked
        )
    }

    public nonisolated static func nextDailyReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    private nonisolated static func currentDailyWindowStart(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        return calendar.startOfDay(for: now)
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(ledger).write(to: url, options: .atomic)
        } catch {
            AppLog.warning("Could not persist Gemini usage ledger: \(error.localizedDescription)", category: .ai)
        }
    }
}
