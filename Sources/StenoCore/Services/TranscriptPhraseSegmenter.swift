import Foundation

public enum TranscriptPhraseSegmenter {
    public static let defaultMaximumPhraseDuration: Double = 10
    public static let defaultMaximumTokenGap: Double = 1

    public static func phrases(
        from tokens: [TranscriptSegment],
        maximumPhraseDuration: Double = defaultMaximumPhraseDuration,
        maximumTokenGap: Double = defaultMaximumTokenGap
    ) -> [TranscriptSegment] {
        var builder: PhraseBuilder?
        var phrases: [TranscriptSegment] = []

        for token in tokens.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            if let current = builder,
               shouldStartNewPhrase(
                   current: current,
                   next: token,
                   maximumPhraseDuration: maximumPhraseDuration,
                   maximumTokenGap: maximumTokenGap
               ) {
                phrases.append(current.segment(index: phrases.count))
                builder = nil
            }

            if builder == nil {
                builder = PhraseBuilder(first: token, text: text)
            } else {
                builder?.append(token, text: text)
            }
        }

        if let builder {
            phrases.append(builder.segment(index: phrases.count))
        }

        return phrases
    }

    private static func shouldStartNewPhrase(
        current: PhraseBuilder,
        next: TranscriptSegment,
        maximumPhraseDuration: Double,
        maximumTokenGap: Double
    ) -> Bool {
        if current.source != next.source {
            return true
        }
        if next.startTimeSeconds - current.endTimeSeconds > maximumTokenGap {
            return true
        }
        if next.endTimeSeconds - current.startTimeSeconds > maximumPhraseDuration {
            return true
        }
        return current.endsWithTerminalPunctuation
    }
}

private struct PhraseBuilder {
    let source: RecordingAudioSource
    let startTimeSeconds: Double
    var endTimeSeconds: Double
    private var text: String

    init(first: TranscriptSegment, text: String) {
        source = first.source
        startTimeSeconds = first.startTimeSeconds
        endTimeSeconds = first.endTimeSeconds
        self.text = text
    }

    var endsWithTerminalPunctuation: Bool {
        guard let last = text.last else {
            return false
        }
        return ".!?…".contains(last)
    }

    mutating func append(_ token: TranscriptSegment, text tokenText: String) {
        endTimeSeconds = max(endTimeSeconds, token.endTimeSeconds)
        if shouldAttachWithoutLeadingSpace(tokenText) {
            text += tokenText
        } else {
            text += " " + tokenText
        }
    }

    func segment(index: Int) -> TranscriptSegment {
        TranscriptSegment(
            id: "\(source.rawValue)-phrase-\(Int((startTimeSeconds * 1000).rounded()))-\(index)",
            source: source,
            startTimeSeconds: startTimeSeconds,
            endTimeSeconds: endTimeSeconds,
            text: text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        )
    }

    private func shouldAttachWithoutLeadingSpace(_ tokenText: String) -> Bool {
        tokenText.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }
}
