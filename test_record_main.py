from Foundation import NSURL
import os
import AVFoundation as AVF
import time

def run_test():
    import app.core.config as config
    from app.core.recorder import ScreenRecorder
    
    url = NSURL.fileURLWithPath_(os.path.abspath("test_meet.mp4"))
    conf = {"width": 640, "height": 480, "fps": 10, "bitrate": 1000000}
    app_conf = {"sys_volume": 1.0, "mic_volume": 1.0}
    
    recorder = ScreenRecorder.alloc().initWithOutputURL_videoConfig_appConfig_(url, conf, app_conf)
    if not recorder:
        print("Failed to init recorder")
        return
        
    def cb(success, err):
        print("Callback:", success, err)
        
    recorder.startWithCallback_(cb)
    print("Recording 3 seconds...")
    time.sleep(3)
    recorder.stop()
    print("Stopped.")

if __name__ == "__main__":
    run_test()
