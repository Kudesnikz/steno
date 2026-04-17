import re

with open('app/core/recorder.py', 'r') as f:
    content = f.read()

# Изменяем imports
content = re.sub(
    r"import CoreMedia",
    "import CoreMedia\nimport AVFoundation as AVF\nimport platform\nimport subprocess",
    content
)

# Удалим старые импорты AVCapture
content = re.sub(r"AVCaptureSession.*AVCaptureAudioDataOutput,\n?\s*", "", content)
content = re.sub(r"AVCaptureConnection,\s*", "", content)

# Изменяем сигнатуру initWithOutputURLs...
repl_init = """    def initWithOutputURL_videoConfig_appConfig_(self, main_url, config, app_config):
        self = objc.super(ScreenRecorder, self).init()
        if self is None: return None
        
        self.main_url = main_url
        self.config = app_config  # Для получения sys_volume и mic_volume
        
        # Временный url для микрофона
        tmp_mic_path = main_url.path() + "_tmp_mic.m4a"
        self.tmp_mic_url = NSURL.fileURLWithPath_(tmp_mic_path)
        
        self.width = int(config.get("width", 1280))
        self.height = int(config.get("height", 720))
        self.fps = int(config.get("fps", 10))
        self.bitrate = int(config.get("bitrate", 3000000))
        
        # --- WRITER 1: Main (Video + System Audio) ---
        self.main_writer = None
        self.video_input = None
        self.video_adaptor = None
        self.sys_input = None
        
        # --- WRITER 2: Aux (Mic Audio Only) ---
        self.audio_engine = None
        self.audio_file = None
        
        # --- Inputs & Sessions ---
        self.stream = None
        self.video_queue = None
        
        self.is_recording = False
        self.main_session_started = False 
        
        # --- Cleanup Files ---
        for path in [self.main_url.path(), self.tmp_mic_url.path(), self.main_url.path() + ".tmp.mp4"]:
            if os.path.exists(path):
                try: os.remove(path)
                except: pass
"""
content = re.sub(
    r"    # Изменили сигнатуру:\s*def initWithOutputURLs_auxURL_videoConfig_.*?# --- Cleanup Files ---.*?except OSError:\s*logger.error\([^)]+\)",
    repl_init,
    content,
    flags=re.DOTALL
)

repl_writer2 = """        # ==========================================
        # 2. Setup Aux Writer (Mic Audio via AVAudioEngine) -> .m4a
        # ==========================================
        self.audio_engine = AVF.AVAudioEngine.alloc().init()
        input_node = self.audio_engine.inputNode()
        
        # Включаем AEC (Voice Processing)
        if hasattr(input_node, "setVoiceProcessingEnabled_error_"):
            success, err = input_node.setVoiceProcessingEnabled_error_(True, None)
            if not success:
                logger.warning(f"Voice Processing not enabled: {err}")
        
        fmt = input_node.outputFormatForBus_(0)
        
        # Настройки для аудио_файла микрофона
        mic_settings = {
            AVFormatIDKey: 1633772320, # MPEG4AAC
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000.0,
            AVEncoderBitRateKey: 128000
        }
        
        self.audio_file, err_aux = AVF.AVAudioFile.alloc().initForWriting_settings_error_(
            self.tmp_mic_url, mic_settings, None
        )
        if err_aux:
            logger.error(f"Error creating Mic Audio File: {err_aux}")
            return None

        return self"""

content = re.sub(
    r"        # ==========================================\n\s*# 2\. Setup Aux Writer.*?return self",
    repl_writer2,
    content,
    flags=re.DOTALL
)

repl_handle_content = """        # --- Микрофон (AVAudioEngine) ---
        def handle_mic(buffer, time):
            if self.is_recording and self.audio_file:
                try:
                    self.audio_file.writeFromBuffer_error_(buffer, None)
                except Exception as e:
                    logger.error(f"Error writing mic buffer: {e}")

        input_node = self.audio_engine.inputNode()
        fmt = input_node.outputFormatForBus_(0)
        input_node.installTapOnBus_bufferSize_format_block_(0, 4096, fmt, handle_mic)
        
        try:
            self.audio_engine.startAndReturnError_(None)
        except Exception as e:
            logger.error(f"Failed to start audio engine: {e}")

        # --- Экран + Sys Audio (SCK) ---"""

content = re.sub(
    r"        # --- Микрофон \(AVCapture\).*?# --- Экран \+ Sys Audio \(SCK\) ---",
    repl_handle_content,
    content,
    flags=re.DOTALL
)

# Убираем старт aux_writer
content = re.sub(
    r"        if self\.main_writer\.startWriting\(\) and self\.aux_writer\.startWriting\(\):",
    "        if self.main_writer.startWriting():",
    content
)

stop_func = """    def _get_ffmpeg_path(self):
        import platform
        base_path = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        arch = platform.machine().lower()
        ffmpeg_name = "ffmpeg_arm64" if arch in ('arm64', 'aarch64') else "ffmpeg_x86_64"
        ffmpeg_bin = os.path.join(base_path, "bin", ffmpeg_name)
        return ffmpeg_bin if os.path.exists(ffmpeg_bin) else "ffmpeg"

    def stop(self):
        logger.info("ScreenRecorder: stop called")
        self.is_recording = False
        
        try:
            if self.stream:
                stop_event = threading.Event()
                def on_stream_stopped(e):
                    stop_event.set()
                self.stream.stopCaptureWithCompletionHandler_(on_stream_stopped)
                stop_event.wait(timeout=3.0)
        except Exception as e: pass

        try:
            if self.audio_engine:
                self.audio_engine.stop()
                self.audio_engine.inputNode().removeTapOnBus_(0)
        except Exception as e: pass

        for inp in [self.video_input, self.sys_input]:
             if inp:
                 try: inp.markAsFinished()
                 except Exception: pass
        
        writers_done = threading.Event()
        
        if self.main_writer:
            def on_writer_done():
                writers_done.set()
            try:
                self.main_writer.finishWritingWithCompletionHandler_(on_writer_done)
            except Exception:
                writers_done.set()
        else:
            writers_done.set()

        writers_done.wait(timeout=5.0)

        # МИКШИРОВАНИЕ
        out_mp4 = self.main_url.path()
        in_m4a = self.tmp_mic_url.path()
        
        if os.path.exists(out_mp4) and os.path.exists(in_m4a):
            try:
                tmp_mp4 = out_mp4 + ".tmp.mp4"
                sys_vol = float(self.config.get("sys_volume", 1.0))
                mic_vol = float(self.config.get("mic_volume", 1.0))

                cmd = [
                    self._get_ffmpeg_path(), "-y",
                    "-i", out_mp4,
                    "-i", in_m4a,
                    "-filter_complex", f"[0:a]volume={sys_vol}[sys]; [1:a]volume={mic_vol}[mic]; [sys][mic]amix=inputs=2:duration=first[a]",
                    "-map", "0:v",
                    "-map", "[a]",
                    "-c:v", "copy",
                    "-loglevel", "quiet",
                    tmp_mp4
                ]
                logger.info("Merging audio tracks via ffmpeg...")
                subprocess.run(cmd, check=True)
                
                os.replace(tmp_mp4, out_mp4)
                os.remove(in_m4a)
                logger.info("Merge completed")
            except Exception as e:
                logger.error(f"Merge error: {e}")

        # Cleanup refs
        self.stream = None
        self.audio_engine = None
        self.video_input = None
        self.sys_input = None
        self.audio_file = None
        self.video_adaptor = None
        self.main_writer = None"""

content = re.sub(
    r"    def stop\(self\):.*?# УТ-1 fix:[^\n]+\n        self\.main_writer = None\n        self\.aux_writer = None",
    stop_func,
    content,
    flags=re.DOTALL
)

# Удалить MICROPHONE HANDLER
content = re.sub(
    r"    # --- MICROPHONE HANDLER \(Aux Writer\) ---.*?self\.mic_input\.appendSampleBuffer_\(sampleBuffer\)",
    "",
    content,
    flags=re.DOTALL
)

with open('app/core/recorder.py', 'w') as f:
    f.write(content)
