import AVFoundation as AVF
import Foundation

engine = AVF.AVAudioEngine.alloc().init()
input_node = engine.inputNode()

success, err = input_node.setVoiceProcessingEnabled_error_(True, None)

fmt = input_node.outputFormatForBus_(0)
url = Foundation.NSURL.fileURLWithPath_("test_mic.m4a")

settings = {
    AVF.AVFormatIDKey: 1633772320, # kAudioFormatMPEG4AAC
    AVF.AVNumberOfChannelsKey: 2,
    AVF.AVSampleRateKey: 48000.0,
    AVF.AVEncoderBitRateKey: 128000
}

# Используем initForWriting_settings_error_
audio_file, err = AVF.AVAudioFile.alloc().initForWriting_settings_error_(
    url, settings, None
)
print("File:", audio_file, "Err:", err)

def handle_mic(buffer, time):
    if audio_file:
        audio_file.writeFromBuffer_error_(buffer, None)

input_node.installTapOnBus_bufferSize_format_block_(0, 4096, fmt, handle_mic)

engine.startAndReturnError_(None)
print("Recording 3 secs...")
import time; time.sleep(3)
engine.stop()
