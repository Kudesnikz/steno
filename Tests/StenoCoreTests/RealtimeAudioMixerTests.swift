import AVFoundation
@testable import StenoCore
import XCTest

final class RealtimeAudioMixerTests: XCTestCase {
    func testMixerCombinesInterleavedSystemAndMicrophoneBuffers() throws {
        let mixer = RealtimeAudioMixer()
        let frameCount = 4_410
        var rendered: [MixedRecordingAudioBuffer] = []

        for chunkIndex in 0..<12 {
            let startTime = Double(chunkIndex) * 0.1
            rendered += mixer.append(
                try makeConstantBuffer(format: mixer.outputFormat, frameCount: frameCount, value: 0.10),
                source: .system,
                startTimeSeconds: startTime
            )
            rendered += mixer.append(
                try makeConstantBuffer(format: mixer.outputFormat, frameCount: frameCount, value: 0.20),
                source: .microphone,
                startTimeSeconds: startTime
            )
        }
        rendered += mixer.flush()

        XCTAssertFalse(rendered.isEmpty)
        let peak = rendered.map { peakLevel($0.pcmBuffer) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.25)
        XCTAssertLessThanOrEqual(peak, 0.95)
    }
}

private func makeConstantBuffer(format: AVAudioFormat, frameCount: Int, value: Float) throws -> AVAudioPCMBuffer {
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
    ))
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let channels = try XCTUnwrap(buffer.floatChannelData)
    for channelIndex in 0..<Int(format.channelCount) {
        for frameIndex in 0..<frameCount {
            channels[channelIndex][frameIndex] = value
        }
    }
    return buffer
}

private func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else {
        return 0
    }
    var peak = Float(0)
    for channelIndex in 0..<Int(buffer.format.channelCount) {
        for frameIndex in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channels[channelIndex][frameIndex]))
        }
    }
    return peak
}
