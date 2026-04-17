import AVFoundation as AVF
import CoreMedia

engine = AVF.AVAudioEngine.alloc().init()
input_node = engine.inputNode()
fmt = input_node.outputFormatForBus_(0)

def handle_mic(buffer, time):
    print("Received buffer:", buffer.frameLength(), "frames")
    # Проверим, можем ли получить доступ к floatChannelData
    try:
        data = buffer.floatChannelData()
        print("Data ptrs:", data)
        # Если data - это указатели, мы можем использовать ctypes
    except Exception as e:
        print("Error floatChannelData:", e)

input_node.installTapOnBus_bufferSize_format_block_(
    0, 4096, fmt, handle_mic
)

print("Starting engine")
engine.startAndReturnError_(None)

import time
time.sleep(2)
engine.stop()
