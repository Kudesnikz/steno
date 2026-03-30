# -*- coding: utf-8 -*-
import sys
import os
import logging
import time
import copy
import subprocess
import certifi
from datetime import datetime

from PyQt6.QtWidgets import QApplication, QMessageBox
from PyQt6.QtGui import QIcon, QFont
from PyQt6.QtCore import QTimer, QObject, pyqtSignal, Qt

# --- Модули приложения ---
from app.core.config import ConfigManager, CONFIG_FILE, VIDEO_QUALITY_PRESETS

# --- Сигналы для связи нативных потоков с UI ---
class RecordingSignals(QObject):
    started = pyqtSignal()
    failed = pyqtSignal(str)

from app.core.ai_worker import AIWorker
from app.ui.ui_main import MainWindow
from app.ui.ui_settings import SettingsDialog
from app.core.permissions import PermissionManager
from app.ui.tray import SystemTrayManager
from app.core.recorder import ScreenRecorder
from Foundation import NSURL

# --- Настройка логирования ---
LOG_DIR = os.path.expanduser("~/Library/Logs/Steno")
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
LOG_FILE = os.path.join(LOG_DIR, "app.log")

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding='utf-8')
    ]
)
logger = logging.getLogger("Steno")

# --- SSL Configuration ---
os.environ['SSL_CERT_FILE'] = certifi.where()
os.environ['REQUESTS_CA_BUNDLE'] = certifi.where()

# --- Константы ---
BASE_PATH = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(BASE_PATH, "assets")

ICON_IDLE = os.path.join(ASSETS_DIR, "icon_idle.png")
ICON_RECORDING = os.path.join(ASSETS_DIR, "icon_recording.png")
ICON_PROCESSING = os.path.join(ASSETS_DIR, "icon_processing.png")
ICON_ERROR = os.path.join(ASSETS_DIR, "icon_error.png")


class MeetAssistantApp(QObject):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.config = ConfigManager.load()
        
        self.is_recording = False
        self.is_processing = False
        self.is_onboarding_active = False
        self.recorder = None
        self.current_filename = None
        self.recording_time = 0
        
        self.recording_timer = QTimer(self)
        self.recording_timer.timeout.connect(self.update_tray_timer)
        
        self.recording_signals = RecordingSignals()
        # АРХ-7 fix: явно QueuedConnection — callback приходит из GCD-потока macOS
        self.recording_signals.started.connect(
            self._on_recording_started, Qt.ConnectionType.QueuedConnection
        )
        self.recording_signals.failed.connect(
            self._on_recording_failed, Qt.ConnectionType.QueuedConnection
        )
        
        # Load Icons
        self.icons = {
            "idle": QIcon(ICON_IDLE),
            "recording": QIcon(ICON_RECORDING),
            "processing": QIcon(ICON_PROCESSING),
            "error": QIcon(ICON_ERROR)
        }
        
        # UI: Main Window
        self.main_window = MainWindow(self.config)
        self.main_window.open_settings_signal.connect(self.open_settings)
        self.main_window.start_recording_signal.connect(self.start_recording)
        self.main_window.stop_recording_signal.connect(self.stop_recording)
        self.main_window.generate_signal.connect(self.start_generation)
        
        # Обработка закрытия главного окна
        self.app.lastWindowClosed.connect(self.on_last_window_closed)

        # UI: Tray Manager
        self.tray_manager = SystemTrayManager(self, self.icons, self.config)
        self.tray_manager.setup_mac_icons(ICON_IDLE, ICON_RECORDING, ICON_PROCESSING, ICON_ERROR)
        self.tray_manager.show()

        if not os.path.exists(CONFIG_FILE):
            QTimer.singleShot(100, self.show_onboarding)

        # АРХ-5: перехватываем Cmd+Q / любой другой юнит завершения
        # (QApplication.quit(), [NSApp terminate:] и т.д.) — сигнал отрабатывается
        # в главном потоке до закрытия event-loopа.
        self.app.aboutToQuit.connect(self._on_about_to_quit)

    def on_tray_activated(self, reason):
        pass

    def on_last_window_closed(self):
        if sys.platform == "darwin":
            from AppKit import NSApp
            NSApp.setActivationPolicy_(1) # NSApplicationActivationPolicyAccessory (только трей)

    def show_main_window(self):
        if not os.path.exists(CONFIG_FILE):
            self.show_onboarding()
        else:
            if sys.platform == "darwin":
                from AppKit import NSApp
                NSApp.setActivationPolicy_(0) # NSApplicationActivationPolicyRegular
                NSApp.activateIgnoringOtherApps_(True)
            self.main_window.showNormal()
            self.main_window.activateWindow()
            self.main_window.raise_()

    def show_onboarding(self):
        self.is_onboarding_active = True
        self.tray_manager.set_onboarding_state(True)
        
        if sys.platform == "darwin":
            from AppKit import NSApp
            NSApp.setActivationPolicy_(0) # NSApplicationActivationPolicyRegular
            NSApp.activateIgnoringOtherApps_(True)
        
        from app.ui.ui_onboarding import OnboardingDialog
        dialog = OnboardingDialog()
        dialog.activateWindow()
        dialog.raise_()
        if dialog.exec():
            self.is_onboarding_active = False
            self.tray_manager.set_onboarding_state(False)
            
            self.config = ConfigManager.load()
            self.main_window.update_config(self.config)
            self.show_main_window()
        else:
            self.quit_app()

    def open_settings(self):
        if sys.platform == "darwin":
            from AppKit import NSApp
            NSApp.setActivationPolicy_(0) # NSApplicationActivationPolicyRegular
            NSApp.activateIgnoringOtherApps_(True)

        if hasattr(self, 'settings_dialog') and self.settings_dialog is not None and self.settings_dialog.isVisible():
            self.settings_dialog.activateWindow()
            self.settings_dialog.raise_()
            return

        self.settings_dialog = SettingsDialog(self.config, self.main_window)
        # Устанавливаем окно модальным только для главного окна, чтобы трей не блокировался
        self.settings_dialog.setWindowModality(Qt.WindowModality.WindowModal)

        def on_accepted():
            self.config = self.settings_dialog.get_updated_config()
            ConfigManager.save(self.config)
            self.main_window.update_config(self.config)
            self.settings_dialog = None

        def on_rejected():
            self.settings_dialog = None

        self.settings_dialog.accepted.connect(on_accepted)
        self.settings_dialog.rejected.connect(on_rejected)
        
        self.settings_dialog.show()
        self.settings_dialog.activateWindow()
        self.settings_dialog.raise_()

    def open_folder(self):
        # АРХ-3 fix: проверяем, что путь — реальная директория
        dir_path = self.config.get("save_dir", "")
        if os.path.isdir(dir_path):
            subprocess.Popen(["open", dir_path])

    def quit_app(self):
        # Сигнал aboutToQuit вызовет _on_about_to_quit до закрытия
        QApplication.quit()

    def _on_about_to_quit(self):
        """КРИТ-1 + АРХ-5: вызывается при любом способе выхода (quit_app, Cmd+Q, terminate).
        Корректно останавливает запись и ждёт воркер до 5 секунд.
        """
        logger.info("_on_about_to_quit: начинаем корректное завершение")
        if self.is_recording:
            self.stop_recording()
        
        # УТ-4 fix: останавливаем все открытые плееры (освобождаем sounddevice/ffmpeg)
        from app.ui.ui_player import PlayerWidget
        for i in range(self.main_window.stacked_widget.count()):
            widget = self.main_window.stacked_widget.widget(i)
            if isinstance(widget, PlayerWidget):
                try:
                    widget.engine.stop()
                except Exception:
                    pass
        
        worker = getattr(self, 'worker', None)
        if worker is not None and worker.isRunning():
            logger.info("Ожидаем завершения AIWorker...")
            worker.cancel()
            if not worker.wait(5000):
                logger.warning("AIWorker не завершился за 5 сек — принудительно завершаем")
                worker.terminate()
                worker.wait(1000)
        
        # УТ-2 fix: освобождаем нативный NSStatusItem
        self.tray_manager.cleanup()

    def toggle_recording(self):
        if self.is_recording:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        if not self.config.get("api_key"):
            QMessageBox.warning(None, "API Key Required", "Please set Google API Key in Settings")
            self.open_settings()
            return

        timestamp = datetime.now().strftime("%d.%m.%Y_%H:%M:%S")
        save_dir = self.config.get("save_dir", "")
        if not save_dir:
            save_dir = os.path.expanduser("~/Movies/Steno")
        if not os.path.exists(save_dir):
            os.makedirs(save_dir)
            
        self.current_filename = os.path.join(save_dir, f"Meet_{timestamp}.mp4")
        mic_filename = os.path.join(save_dir, f"Meet_{timestamp}_mic.m4a")
        json_filename = os.path.join(save_dir, f"Meet_{timestamp}.json")
        
        try:
            import json
            default_name = timestamp.replace("_", " ")
            metadata = {
                "name": default_name,
                "created_at": timestamp
            }
            with open(json_filename, "w", encoding="utf-8") as f:
                json.dump(metadata, f, ensure_ascii=False, indent=4)
        except Exception as e:
            logger.error(f"Failed to create metadata file: {e}")
        
        try:
            url_main = NSURL.fileURLWithPath_(self.current_filename)
            url_mic = NSURL.fileURLWithPath_(mic_filename)
            
            preset = VIDEO_QUALITY_PRESETS.get(self.config.get("video_quality", "Medium"))
            
            self.recorder = ScreenRecorder.alloc().initWithOutputURLs_auxURL_videoConfig_(
                url_main, url_mic, preset
            )
            
            if not self.recorder:
                raise Exception("Failed to init recorder")
                
            def callback(success, error):
                if not success:
                    logger.error(f"Recorder start failed: {error}")
                    self.recording_signals.failed.emit(str(error))
                else:
                    self.recording_signals.started.emit()
            
            self.recorder.startWithCallback_(callback)
            
        except Exception as e:
            logger.exception("Start recording error")
            self._on_recording_failed(str(e))

    def _on_recording_started(self):
        self.is_recording = True
        self.recording_time = 0
        
        show_recording_time = self.config.get("show_recording_time", True)
        self.tray_manager.set_recording_state(True, show_recording_time)
        
        if show_recording_time:
            self.update_tray_timer()
            self.recording_timer.start(1000)
            
        self.main_window.set_recording_state(True)
        self.tray_manager.show_message("Recording Started", f"File: {os.path.basename(self.current_filename)}")

    def _on_recording_failed(self, error_str):
        # КРИТ-4: НЕ вызываем stop_recording() — рекордер в сломанном состоянии.
        # Чистим состояние напрямую без "Files saved" нотификации.
        if self.recorder:
            try:
                self.recorder.stop()
            except Exception:
                pass
            self.recorder = None
        self.is_recording = False
        self.recording_timer.stop()
        self.tray_manager.set_recording_state(False)
        self.main_window.set_recording_state(False)
        self.tray_manager.show_message("Ошибка записи", f"Не удалось начать: {error_str[:120]}")
        self.tray_manager.set_error_state()

    def stop_recording(self):
        if self.recorder:
            self.recorder.stop()
            self.recorder = None
        
        self.is_recording = False
        self.recording_timer.stop()
        
        self.tray_manager.set_recording_state(False)
        self.main_window.set_recording_state(False)
        self.tray_manager.show_message("Recording Stopped", "Files saved.")
        
        QTimer.singleShot(1000, self.main_window.refresh_data)

    def update_tray_timer(self):
        hours = self.recording_time // 3600
        minutes = (self.recording_time % 3600) // 60
        seconds = self.recording_time % 60
        
        time_str = f" {hours:02d}:{minutes:02d}:{seconds:02d} "
        QTimer.singleShot(0, lambda text=time_str: self.tray_manager.set_timer_text(text))
        
        self.recording_time += 1

    def start_generation(self, session_base_path, agent_id):
        if self.is_processing:
            QMessageBox.warning(self.main_window, "Занято", "Уже идет генерация.")
            return
        
        # КРИТ-6 fix: отключаем сигнал старого worker, если он ещё существует
        old_worker = getattr(self, 'worker', None)
        if old_worker is not None:
            try:
                old_worker.finished_signal.disconnect(self.on_processing_finished)
            except TypeError:
                pass  # уже отключен
            
        self.is_processing = True
        self.tray_manager.set_processing_state(True)
        self.main_window.set_generating_state(True)
        
        # УТ-5 fix: передаём замороженную копию конфига в рабочий поток
        self.worker = AIWorker(session_base_path, copy.deepcopy(self.config), agent_id)
        self.worker.finished_signal.connect(self.on_processing_finished)
        self.worker.start()

    def on_processing_finished(self, success, title, message, base_name, agent_id, tokens_used):
        self.is_processing = False
        self.tray_manager.set_processing_state(False)
        self.main_window.set_generating_state(False)
        
        if success and tokens_used > 0:
             self.config["used_tokens"] = self.config.get("used_tokens", 0) + tokens_used
             self.config["last_request_tokens"] = tokens_used
             ConfigManager.save(self.config)
             self.main_window.update_config(self.config) # Update UI with new token count
        
        if not success:
            self.tray_manager.set_error_state()
            QTimer.singleShot(3000, lambda: self.tray_manager.set_processing_state(False))
            
        self.tray_manager.show_message(title, message)
        self.main_window.refresh_data()


if __name__ == "__main__":
    PermissionManager.check_all()
    app = QApplication(sys.argv)
    
    font = QFont(".AppleSystemUIFont", 13)
    app.setFont(font)
    
    app.setStyleSheet("""
        QScrollBar:vertical {
            border: none;
            background: transparent;
            width: 14px;
            margin: 0px;
        }
        QScrollBar::handle:vertical {
            background: rgba(150, 150, 150, 0.5);
            min-height: 20px;
            border-radius: 7px;
            margin: 2px;
        }
        QScrollBar::handle:vertical:hover {
            background: rgba(150, 150, 150, 0.7);
        }
        QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
            height: 0px;
            background: none;
        }
        QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {
            background: none;
        }
        QScrollBar:horizontal {
            border: none;
            background: transparent;
            height: 14px;
            margin: 0px;
        }
        QScrollBar::handle:horizontal {
            background: rgba(150, 150, 150, 0.5);
            min-width: 20px;
            border-radius: 7px;
            margin: 2px;
        }
        QScrollBar::handle:horizontal:hover {
            background: rgba(150, 150, 150, 0.7);
        }
        QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
            width: 0px;
            background: none;
        }
        QScrollBar::add-page:horizontal, QScrollBar::sub-page:horizontal {
            background: none;
        }
    """)
    
    app.setQuitOnLastWindowClosed(False)
    assistant = MeetAssistantApp(app)
    sys.exit(app.exec())
