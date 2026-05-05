import AVFoundation
import CoreMedia
import Foundation

enum RealtimeRecordingWriterError: LocalizedError, Sendable {
    case cannotAddVideoInput
    case cannotAddAudioInput
    case writerFailed(String)
    case retimingFailed(OSStatus)
    case audioFormatDescriptionFailed(OSStatus)
    case audioSampleBufferCreationFailed(OSStatus)
    case audioDataBufferCreationFailed(OSStatus)
    case noSamplesWritten

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput:
            "Cannot add realtime video input."
        case .cannotAddAudioInput:
            "Cannot add realtime audio input."
        case let .writerFailed(message):
            "Realtime recording writer failed: \(message)"
        case let .retimingFailed(status):
            "Failed to retime video sample buffer: \(status)."
        case let .audioFormatDescriptionFailed(status):
            "Failed to create audio format description: \(status)."
        case let .audioSampleBufferCreationFailed(status):
            "Failed to create audio sample buffer: \(status)."
        case let .audioDataBufferCreationFailed(status):
            "Failed to attach audio data buffer: \(status)."
        case .noSamplesWritten:
            "No samples were written to the recording."
        }
    }
}

final class RealtimeRecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let audioFormat: AVAudioFormat
    private var didStartSession = false
    private var didFinish = false
    private var didWriteVideo = false
    private var didWriteAudio = false
    private var droppedVideoFrameCount = 0
    private var droppedAudioBufferCount = 0
    private var lastDropLog = Date.distantPast

    init(outputURL: URL, preset: VideoQualityPreset, audioFormat: AVAudioFormat) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        self.audioFormat = audioFormat

        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: preset.width,
                AVVideoHeightKey: preset.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: preset.bitrate,
                    AVVideoExpectedSourceFrameRateKey: preset.fps,
                    AVVideoMaxKeyFrameIntervalKey: max(preset.fps * 2, 1),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true

        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioFormat.sampleRate,
                AVNumberOfChannelsKey: Int(audioFormat.channelCount),
                AVEncoderBitRateKey: 192_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw RealtimeRecordingWriterError.cannotAddVideoInput
        }
        writer.add(videoInput)

        guard writer.canAdd(audioInput) else {
            throw RealtimeRecordingWriterError.cannotAddAudioInput
        }
        writer.add(audioInput)

        AppLog.info(
            "Configured realtime writer width=\(preset.width) height=\(preset.height) fps=\(preset.fps) bitrate=\(preset.bitrate) audioRate=\(Int(audioFormat.sampleRate)) audioChannels=\(audioFormat.channelCount)",
            category: .recording
        )
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, startTimeSeconds: Double) throws {
        try lock.withLock {
            try ensureWritable()
            let timestamp = timestamp(for: startTimeSeconds)
            try startSessionIfNeeded(at: timestamp)
            guard videoInput.isReadyForMoreMediaData else {
                droppedVideoFrameCount += 1
                logDropsIfNeeded()
                return
            }
            let retimedBuffer = try retimedSampleBuffer(sampleBuffer, presentationTimeStamp: timestamp)
            guard videoInput.append(retimedBuffer) else {
                throw currentWriterError()
            }
            didWriteVideo = true
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer, startTimeSeconds: Double) throws {
        try lock.withLock {
            try ensureWritable()
            let timestamp = timestamp(for: startTimeSeconds)
            try startSessionIfNeeded(at: timestamp)
            guard audioInput.isReadyForMoreMediaData else {
                droppedAudioBufferCount += 1
                logDropsIfNeeded()
                return
            }
            let sampleBuffer = try audioSampleBuffer(from: buffer, presentationTimeStamp: timestamp)
            guard audioInput.append(sampleBuffer) else {
                throw currentWriterError()
            }
            didWriteAudio = true
        }
    }

    func finish() async throws {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !didFinish else {
                return false
            }
            didFinish = true
            return true
        }
        guard shouldFinish else {
            return
        }

        guard didStartSession, didWriteVideo || didWriteAudio else {
            writer.cancelWriting()
            throw RealtimeRecordingWriterError.noSamplesWritten
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let start = Date()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.finishWriting {
                switch self.writer.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: self.currentWriterError())
                default:
                    continuation.resume()
                }
            }
        }
        AppLog.info(
            "Realtime writer finished duration=\(String(format: "%.2f", Date().timeIntervalSince(start)))s droppedVideo=\(droppedVideoFrameCount) droppedAudio=\(droppedAudioBufferCount)",
            category: .recording
        )
    }

    func cancel() {
        lock.withLock {
            guard !didFinish else {
                return
            }
            didFinish = true
            writer.cancelWriting()
        }
    }

    private func ensureWritable() throws {
        guard !didFinish else {
            throw RealtimeRecordingWriterError.writerFailed("Writer is already finishing.")
        }
        switch writer.status {
        case .unknown, .writing:
            return
        case .failed, .cancelled:
            throw currentWriterError()
        case .completed:
            throw RealtimeRecordingWriterError.writerFailed("Writer already completed.")
        @unknown default:
            throw RealtimeRecordingWriterError.writerFailed("Unexpected writer status.")
        }
    }

    private func startSessionIfNeeded(at timestamp: CMTime) throws {
        guard !didStartSession else {
            return
        }
        guard writer.startWriting() else {
            throw currentWriterError()
        }
        writer.startSession(atSourceTime: .zero)
        didStartSession = true
        AppLog.info("Realtime writer session started firstTimestamp=\(timestamp.seconds)", category: .recording)
    }

    private func timestamp(for startTimeSeconds: Double) -> CMTime {
        let timescale = CMTimeScale(Int32(audioFormat.sampleRate.rounded()))
        return CMTime(value: CMTimeValue((max(0, startTimeSeconds) * audioFormat.sampleRate).rounded()), timescale: timescale)
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, presentationTimeStamp: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        guard timingStatus == noErr else {
            throw RealtimeRecordingWriterError.retimingFailed(timingStatus)
        }

        timing.presentationTimeStamp = presentationTimeStamp
        timing.decodeTimeStamp = .invalid

        var outputBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &outputBuffer
        )
        guard status == noErr, let outputBuffer else {
            throw RealtimeRecordingWriterError.retimingFailed(status)
        }
        return outputBuffer
    }

    private func audioSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime
    ) throws -> CMSampleBuffer {
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw RealtimeRecordingWriterError.audioFormatDescriptionFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Int32(buffer.format.sampleRate.rounded()))),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: Int(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else {
            throw RealtimeRecordingWriterError.audioSampleBufferCreationFailed(createStatus)
        }

        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard dataStatus == noErr else {
            throw RealtimeRecordingWriterError.audioDataBufferCreationFailed(dataStatus)
        }
        return sampleBuffer
    }

    private func currentWriterError() -> any Error {
        if let error = writer.error {
            return RealtimeRecordingWriterError.writerFailed(error.localizedDescription)
        }
        return RealtimeRecordingWriterError.writerFailed("status=\(writer.status.rawValue)")
    }

    private func logDropsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastDropLog) >= 1 else {
            return
        }
        lastDropLog = now
        AppLog.warning(
            "Realtime writer backpressure droppedVideo=\(droppedVideoFrameCount) droppedAudio=\(droppedAudioBufferCount)",
            category: .recording
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
