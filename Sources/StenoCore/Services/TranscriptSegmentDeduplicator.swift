import Foundation

public enum TranscriptSegmentDeduplicator {
    public static let echoSimilarityThreshold = 0.82

    public static func deduplicate(
        _ segments: [TranscriptSegment],
        echoSimilarityThreshold: Double = echoSimilarityThreshold
    ) -> [TranscriptSegment] {
        var unique: [TranscriptSegment] = []
        for segment in segments.sorted(by: sortByTimelineAndSystemPriority) {
            let normalized = segment.text.normalizedTranscriptText
            guard !normalized.isEmpty else {
                continue
            }
            guard !isNearDuplicate(segment, in: unique) else {
                continue
            }
            unique.append(segment)
        }

        return unique.filter { segment in
            !isMicrophoneEcho(segment, comparedTo: unique, threshold: echoSimilarityThreshold)
        }
    }

    public static func filterForAppend(
        candidates: [TranscriptSegment],
        existingSegments: [TranscriptSegment],
        echoSimilarityThreshold: Double = echoSimilarityThreshold
    ) -> [TranscriptSegment] {
        var accepted = existingSegments
        var result: [TranscriptSegment] = []

        for candidate in candidates.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let normalized = candidate.text.normalizedTranscriptText
            guard !normalized.isEmpty else {
                continue
            }
            guard !isNearDuplicate(candidate, in: accepted) else {
                continue
            }
            guard !isMicrophoneEcho(candidate, comparedTo: accepted, threshold: echoSimilarityThreshold) else {
                continue
            }
            result.append(candidate)
            accepted.append(candidate)
        }

        return result
    }

    private static func sortByTimelineAndSystemPriority(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startTimeSeconds != rhs.startTimeSeconds {
            return lhs.startTimeSeconds < rhs.startTimeSeconds
        }
        if lhs.source != rhs.source {
            return lhs.source == .system
        }
        return lhs.id < rhs.id
    }

    private static func isNearDuplicate(_ candidate: TranscriptSegment, in existing: [TranscriptSegment]) -> Bool {
        existing.contains { segment in
            segment.source == candidate.source &&
                abs(segment.startTimeSeconds - candidate.startTimeSeconds) < 1.5 &&
                segment.text.normalizedTranscriptText == candidate.text.normalizedTranscriptText
        }
    }

    private static func isMicrophoneEcho(
        _ candidate: TranscriptSegment,
        comparedTo existing: [TranscriptSegment],
        threshold: Double
    ) -> Bool {
        guard candidate.source == .microphone else {
            return false
        }

        let candidateText = candidate.text.normalizedTranscriptText
        return existing.contains { segment in
            guard segment.source == .system, timeRangesOverlap(candidate, segment) else {
                return false
            }
            return similarity(candidateText, segment.text.normalizedTranscriptText) >= threshold
        }
    }

    private static func timeRangesOverlap(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        lhs.startTimeSeconds <= rhs.endTimeSeconds + 0.75 &&
            rhs.startTimeSeconds <= lhs.endTimeSeconds + 0.75
    }

    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = lhs.normalizedTranscriptText
        let right = rhs.normalizedTranscriptText
        guard !left.isEmpty, !right.isEmpty else {
            return left == right ? 1 : 0
        }
        let maxCount = max(left.count, right.count)
        guard maxCount > 0 else {
            return 1
        }
        return 1 - (Double(levenshteinDistance(left, right)) / Double(maxCount))
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else {
            return right.count
        }
        guard !right.isEmpty else {
            return left.count
        }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftIndex in 1...left.count {
            current[0] = leftIndex
            for rightIndex in 1...right.count {
                let cost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }
}

private extension String {
    var normalizedTranscriptText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}
