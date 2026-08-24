import Foundation
@testable import StenoCore
import XCTest

final class GeminiPersistenceTests: XCTestCase {
    func testManifestRequiresEveryExpectedActivePartAndSafetyMargin() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let part = RemoteMediaPart(
            index: 0,
            startSeconds: 0,
            durationSeconds: 60,
            resourceName: "files/one",
            uri: "gemini://one",
            mimeType: "video/mp4",
            sizeBytes: 10,
            state: "ACTIVE",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600)
        )
        var manifest = RemoteMediaManifest(
            sourceFingerprint: "source",
            credentialFingerprint: "credential",
            baseURLFingerprint: "base",
            parts: [part],
            expectedPartCount: 2
        )

        XCTAssertFalse(manifest.isComplete)
        XCTAssertFalse(manifest.isReusable(
            sourceFingerprint: "source",
            credentialFingerprint: "credential",
            baseURLFingerprint: "base",
            now: now
        ))

        var second = part
        second.index = 1
        second.resourceName = "files/two"
        second.uri = "gemini://two"
        manifest.parts.append(second)
        XCTAssertTrue(manifest.isReusable(
            sourceFingerprint: "source",
            credentialFingerprint: "credential",
            baseURLFingerprint: "base",
            now: now
        ))
        XCTAssertFalse(manifest.isReusable(
            sourceFingerprint: "source",
            credentialFingerprint: "other-key",
            baseURLFingerprint: "base",
            now: now
        ))

        manifest.parts[1].expiresAt = now.addingTimeInterval(299)
        XCTAssertFalse(manifest.isReusable(
            sourceFingerprint: "source",
            credentialFingerprint: "credential",
            baseURLFingerprint: "base",
            now: now
        ))
    }

    func testUsageLedgerUsesPacificMidnightAcrossDST() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = GeminiUsageStore(url: directory.appending(path: "ledger.json"))
        let formatter = ISO8601DateFormatter()
        let beforeDST = try XCTUnwrap(formatter.date(from: "2026-11-01T07:00:00Z"))
        let reset = GeminiUsageStore.nextDailyReset(after: beforeDST)
        XCTAssertEqual(reset, formatter.date(from: "2026-11-02T08:00:00Z"))

        await store.record(
            apiKey: "key-a",
            event: GeminiUsageEvent(
                timestamp: beforeDST.addingTimeInterval(60),
                model: "gemini-flash-lite-latest",
                kind: .chat,
                succeeded: true,
                statusCode: 200,
                tokens: ReportTokens(input: 7, output: 3, total: 10)
            )
        )
        let snapshot = await store.snapshot(apiKey: "key-a", now: beforeDST.addingTimeInterval(120))
        XCTAssertEqual(snapshot.requestsToday, 1)
        XCTAssertEqual(snapshot.successfulRequestsToday, 1)
        XCTAssertEqual(snapshot.tokensToday.total, 10)
        XCTAssertEqual(snapshot.tokensByModelToday["gemini-flash-lite-latest"]?.total, 10)
        XCTAssertEqual(snapshot.requestsByKindToday[.chat], 1)
        let otherKeySnapshot = await store.snapshot(apiKey: "key-b", now: beforeDST.addingTimeInterval(120))
        XCTAssertEqual(otherKeySnapshot.requestsToday, 0)
    }

    func testRateLimitParserUsesRetryInfoAndRetryAfterPrecedence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = #"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"17.5s"},{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerMinute"}]}]}}"#
        let data = try XCTUnwrap(payload.data(using: .utf8))
        XCTAssertEqual(
            GeminiRateLimitParser.retryDate(retryAfter: nil, data: data, now: now),
            now.addingTimeInterval(17.5)
        )
        XCTAssertEqual(
            GeminiRateLimitParser.retryDate(retryAfter: "9", data: data, now: now),
            now.addingTimeInterval(9)
        )
    }

    func testGeminiSplitThresholdsAreStrictlyGreaterThanLimits() {
        XCTAssertFalse(AIMediaPreparationService.requiresGeminiSplitting(
            sizeBytes: AIMediaPreparationService.splitTriggerBytes,
            durationSeconds: AIMediaPreparationService.splitTriggerSeconds
        ))
        XCTAssertTrue(AIMediaPreparationService.requiresGeminiSplitting(
            sizeBytes: AIMediaPreparationService.splitTriggerBytes + 1,
            durationSeconds: AIMediaPreparationService.splitTriggerSeconds
        ))
        XCTAssertTrue(AIMediaPreparationService.requiresGeminiSplitting(
            sizeBytes: AIMediaPreparationService.splitTriggerBytes,
            durationSeconds: AIMediaPreparationService.splitTriggerSeconds + 0.001
        ))
        XCTAssertLessThan(AIMediaPreparationService.targetPartBytes, AIMediaPreparationService.splitTriggerBytes)
        XCTAssertLessThan(AIMediaPreparationService.targetPartSeconds, AIMediaPreparationService.splitTriggerSeconds)
        XCTAssertFalse(AIMediaPreparationService.shouldSplitGeminiMedia(
            sizeBytes: AIMediaPreparationService.splitTriggerBytes + 1,
            durationSeconds: AIMediaPreparationService.splitTriggerSeconds + 1,
            isEnabled: false
        ))
        XCTAssertTrue(AIMediaPreparationService.shouldSplitGeminiMedia(
            sizeBytes: AIMediaPreparationService.splitTriggerBytes + 1,
            durationSeconds: AIMediaPreparationService.splitTriggerSeconds,
            isEnabled: true
        ))
    }
}
