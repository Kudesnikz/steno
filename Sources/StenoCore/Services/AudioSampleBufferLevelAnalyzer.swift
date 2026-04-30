import AVFoundation
import CoreMedia
import Foundation

enum AudioSampleBufferLevelAnalyzer {
    static func level(for sampleBuffer: CMSampleBuffer) -> RecordingAudioLevel {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return RecordingAudioLevel()
        }

        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            return RecordingAudioLevel()
        }

        var audioBufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &audioBufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, audioBufferListSize > 0 else {
            return RecordingAudioLevel()
        }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: rawList.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return RecordingAudioLevel()
        }

        let buffers = UnsafeMutableAudioBufferListPointer(rawList.assumingMemoryBound(to: AudioBufferList.self))
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        guard bitsPerChannel > 0 else {
            return RecordingAudioLevel()
        }

        var sumSquares = 0.0
        var peak = 0.0
        var count = 0

        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            if isFloat, bitsPerChannel == 32 {
                consumeFloat32(data: data, byteCount: Int(buffer.mDataByteSize), sumSquares: &sumSquares, peak: &peak, count: &count)
            } else if isFloat, bitsPerChannel == 64 {
                consumeFloat64(data: data, byteCount: Int(buffer.mDataByteSize), sumSquares: &sumSquares, peak: &peak, count: &count)
            } else if isSignedInteger, bitsPerChannel == 16 {
                consumeInt16(data: data, byteCount: Int(buffer.mDataByteSize), sumSquares: &sumSquares, peak: &peak, count: &count)
            } else if isSignedInteger, bitsPerChannel == 32 {
                consumeInt32(data: data, byteCount: Int(buffer.mDataByteSize), sumSquares: &sumSquares, peak: &peak, count: &count)
            }
        }

        guard count > 0 else {
            return RecordingAudioLevel()
        }
        return RecordingAudioLevel(rms: sqrt(sumSquares / Double(count)), peak: peak)
    }

    private static func consumeFloat32(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        sumSquares: inout Double,
        peak: inout Double,
        count: inout Int
    ) {
        let values = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.stride)
        for index in 0..<(byteCount / MemoryLayout<Float>.stride) {
            consume(Double(values[index]), sumSquares: &sumSquares, peak: &peak, count: &count)
        }
    }

    private static func consumeFloat64(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        sumSquares: inout Double,
        peak: inout Double,
        count: inout Int
    ) {
        let values = data.bindMemory(to: Double.self, capacity: byteCount / MemoryLayout<Double>.stride)
        for index in 0..<(byteCount / MemoryLayout<Double>.stride) {
            consume(values[index], sumSquares: &sumSquares, peak: &peak, count: &count)
        }
    }

    private static func consumeInt16(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        sumSquares: inout Double,
        peak: inout Double,
        count: inout Int
    ) {
        let values = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.stride)
        for index in 0..<(byteCount / MemoryLayout<Int16>.stride) {
            consume(Double(values[index]) / Double(Int16.max), sumSquares: &sumSquares, peak: &peak, count: &count)
        }
    }

    private static func consumeInt32(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        sumSquares: inout Double,
        peak: inout Double,
        count: inout Int
    ) {
        let values = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.stride)
        for index in 0..<(byteCount / MemoryLayout<Int32>.stride) {
            consume(Double(values[index]) / Double(Int32.max), sumSquares: &sumSquares, peak: &peak, count: &count)
        }
    }

    private static func consume(_ value: Double, sumSquares: inout Double, peak: inout Double, count: inout Int) {
        guard value.isFinite else {
            return
        }
        let magnitude = abs(value)
        sumSquares += magnitude * magnitude
        peak = max(peak, magnitude)
        count += 1
    }
}
