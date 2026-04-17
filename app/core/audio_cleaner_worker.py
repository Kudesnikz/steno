from PyQt6.QtCore import QThread, pyqtSignal
from app.core.audio_cleaner import AudioCleaner

class AudioCleanerWorker(QThread):
    progress_signal = pyqtSignal(int, str)
    finished_signal = pyqtSignal(bool, str)

    def __init__(self, video_path: str, mic_wav_path: str, output_path: str):
        super().__init__()
        self.video_path = video_path
        self.mic_wav_path = mic_wav_path
        self.output_path = output_path
        self.cleaner = AudioCleaner()

    def run(self):
        try:
            def progress_cb(pct, msg):
                self.progress_signal.emit(pct, msg)

            success = self.cleaner.process(self.video_path, self.mic_wav_path, self.output_path, progress_callback=progress_cb)
            if success:
                self.finished_signal.emit(True, "Аудио успешно обработано")
            elif self.cleaner.is_cancelled:
                self.finished_signal.emit(False, "Обработка отменена")
            else:
                self.finished_signal.emit(False, "Ошибка обработки аудио")
        except Exception as e:
            self.finished_signal.emit(False, f"Ошибка: {str(e)}")

    def cancel(self):
        self.cleaner.is_cancelled = True
