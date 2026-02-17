# -*- coding: utf-8 -*-
import sys
import os
import json
import logging
import threading
import time
import re
import subprocess
import shutil
import certifi
from datetime import datetime

from PyQt6.QtWidgets import (QApplication, QSystemTrayIcon, QMenu, QStyle, 
                             QMessageBox, QInputDialog, QWidget)
from PyQt6.QtGui import QIcon, QAction
from PyQt6.QtCore import QTimer, QThread, pyqtSignal, QObject

from google import genai
from google.genai import types

# --- Custom Recorder Import ---
from recorder import ScreenRecorder
import objc
from Foundation import NSURL

# --- macOS Permission & Native Capture Imports ---
try:
    from AVFoundation import (
        AVCaptureDevice, AVMediaTypeAudio, AVAuthorizationStatusAuthorized
    )
    from Quartz import (
        CGPreflightScreenCaptureAccess, CGRequestScreenCaptureAccess
    )
    from UserNotifications import UNUserNotificationCenter, UNAuthorizationOptionAlert, UNAuthorizationOptionSound, UNAuthorizationOptionBadge
    HAS_PYOBJC = True
except ImportError:
    HAS_PYOBJC = False

# --- Настройка логирования ---
LOG_DIR = os.path.expanduser("~/Library/Logs/Steno")
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
LOG_FILE = os.path.join(LOG_DIR, "qt_app.log")

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding='utf-8')
    ]
)
logger = logging.getLogger("StenoQt")

# --- SSL Configuration ---
os.environ['SSL_CERT_FILE'] = certifi.where()
os.environ['REQUESTS_CA_BUNDLE'] = certifi.where()

# --- Константы и Настройки ---
CONFIG_FILE = os.path.expanduser("~/.recorder_app_config.json")
BASE_PATH = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(BASE_PATH, "assets")

ICON_IDLE = os.path.join(ASSETS_DIR, "icon_idle.png")
ICON_RECORDING = os.path.join(ASSETS_DIR, "icon_recording.png")
ICON_PROCESSING = os.path.join(ASSETS_DIR, "icon_processing.png")
ICON_ERROR = os.path.join(ASSETS_DIR, "icon_error.png")

AI_MODELS = [
    "gemini-3-pro-preview",
    "gemini-3-flash-preview",
    "gemini-flash-lite-latest"
]

DEFAULT_CONFIG = {
    "api_key": "",
    "base_url": "https://gemini-warmup.galaypro.ru",
    "video_device_idx": "0",
    "video_device_name": "Main Screen",
    "model_name": "gemini-3-flash-preview",
    "prompt": "Ты — ИИ-ассистент для составления протоколов встреч. Твоя задача — проанализировать предоставленный медиафайл и вернуть ТОЛЬКО протокол в формате Markdown (оптимизированный для Confluence), строго без вступительных слов, приветствий и пояснений самой нейросети.\n\nИспользуй следующий шаблон:\n# Протокол встречи: [Сформулируй тему]\n**Дата:** [Дата из запроса]\n**Участники:** [Список имен или ролей]\n\n## 1. Саммари (Summary)\n[Краткое, структурированное содержание обсуждения без воды]\n\n## 2. Принятые решения\n* [Список конкретных решений]\n\n## 3. План действий (Action Items)\nОформи строго как таблицу:\n| Задача | Ответственный | Срок |\n| :--- | :--- | :--- |\n| [Описание задачи] | [Имя] | [Дедлайн или -] |",
    "save_dir": os.path.expanduser("~/Movies/ScreenRecordings"),
    "video_quality": "Medium",
    "used_tokens": 0,
    "last_request_tokens": 0
}

VIDEO_QUALITY_PRESETS = {
    "Low": {"width": 960, "height": 540, "fps": 5, "bitrate": 1000000},
    "Medium": {"width": 1280, "height": 720, "fps": 10, "bitrate": 3000000},
    "High": {"width": 1920, "height": 1080, "fps": 30, "bitrate": 8000000},
    "Ultra": {"width": 2560, "height": 1440, "fps": 60, "bitrate": 25000000}
}
messageAuthor = 'v2.0 (Qt)'

# --- Утилиты ---
def get_meeting_date(filename):
    basename = os.path.basename(filename)
    match = re.search(r"Meet_(\d{2}\.\d{2}\.\d{4})_", basename)
    if match: return match.group(1)
    
    try: return datetime.fromtimestamp(os.path.getmtime(filename)).strftime("%Y-%m-%d")
    except: pass
    
    try: return datetime.fromtimestamp(os.path.getctime(filename)).strftime("%Y-%m-%d")
    except: pass
    
    return datetime.now().strftime("%Y-%m-%d")

class ConfigManager:
    @staticmethod
    def load():
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
                    return {**DEFAULT_CONFIG, **json.load(f)}
            except: pass
        return DEFAULT_CONFIG.copy()

    @staticmethod
    def save(config):
        with open(CONFIG_FILE, "w") as f:
            json.dump(config, f, indent=4)

class PermissionManager:
    @staticmethod
    def check_all():
        if not HAS_PYOBJC: return
        logger.info("Checking system permissions...")
        
        mic_status = AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)
        if mic_status != AVAuthorizationStatusAuthorized:
            AVCaptureDevice.requestAccessForMediaType_completionHandler_(AVMediaTypeAudio, lambda granted: logger.info(f"Mic permission granted: {granted}"))

        if not CGPreflightScreenCaptureAccess():
            CGRequestScreenCaptureAccess()

        center = UNUserNotificationCenter.currentNotificationCenter()
        options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
        center.requestAuthorizationWithOptions_completionHandler_(options, lambda granted, error: logger.info(f"Notifications permission granted: {granted}"))

# --- AI Worker Thread ---
class AIWorker(QThread):
    finished_signal = pyqtSignal(bool, str, str) # success, title, message

    def __init__(self, video_path, config):
        super().__init__()
        self.video_path = video_path
        self.config = config

    def run(self):
        try:
            logger.info(f"Starting AI processing logic for: {self.video_path}")
            api_key = self.config.get("api_key")
            
            # Проверка ключа
            if not api_key:
                self.finished_signal.emit(False, "AI Error", "Нет API ключа. Настройте ключ в меню.")
                return

            # Файлы
            files_to_upload_paths = [self.video_path]
            base_name = os.path.splitext(self.video_path)[0]
            mic_audio_path = base_name + "_mic.m4a"
            
            if os.path.exists(mic_audio_path):
                files_to_upload_paths.append(mic_audio_path)
            
            # Клиент
            client_kwargs = {"api_key": api_key}
            base_url = self.config.get("base_url", "").strip()
            if base_url:
                if not base_url.startswith(("http://", "https://")):
                    base_url = "https://" + base_url
                client_kwargs["http_options"] = {"baseUrl": base_url}
            
            client = genai.Client(**client_kwargs)
            
            # Загрузка
            uploaded_files = []
            for path in files_to_upload_paths:
                logger.info(f"Uploading {os.path.basename(path)}...")
                uploaded_files.append(client.files.upload(file=path))
            
            # Ожидание
            ready_files = []
            for uf in uploaded_files:
                logger.info(f"Waiting for processing: {uf.name}")
                while uf.state.name == "PROCESSING":
                    time.sleep(3)
                    uf = client.files.get(name=uf.name)
                
                if uf.state.name == "FAILED":
                    raise Exception(f"Google failed to process file {uf.name}")
                ready_files.append(uf)
            
            # Генерация
            logger.info(f"Generating content...")
            meeting_date = get_meeting_date(self.video_path)
            user_prompt = f"Составь протокол по прикрепленному файлу.\n\nДата встречи: {meeting_date}"
            system_instruction = self.config.get("prompt")
            contents = ready_files + [user_prompt]
            
            response = client.models.generate_content(
                model=self.config.get("model_name"),
                contents=contents,
                config=types.GenerateContentConfig(
                    http_options={"timeout": 600000},
                    system_instruction=system_instruction
                )
            )
            
            # Токены
            if response.usage_metadata:
                total_tokens = response.usage_metadata.total_token_count
                self.config["used_tokens"] = self.config.get("used_tokens", 0) + total_tokens
                self.config["last_request_tokens"] = total_tokens
                ConfigManager.save(self.config)

            # Сохранение
            txt_path = base_name + "_protocol.txt"
            with open(txt_path, "w", encoding="utf-8") as f:
                f.write(response.text)
            
            # Удаление с облака
            for uf in ready_files:
                try: client.files.delete(name=uf.name)
                except: pass
            
            self.finished_signal.emit(True, "Готово!", f"Протокол сохранен: {os.path.basename(txt_path)}")

        except Exception as e:
            logger.exception("AI Worker failed")
            self.finished_signal.emit(False, "AI Ошибка", str(e)[:100])

# --- Main Application Class ---
class MeetAssistantApp(QSystemTrayIcon):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.config = ConfigManager.load()
        
        self.is_recording = False
        self.is_processing = False
        self.recorder = None
        self.current_filename = None
        
        # Load Icons
        self.icons = {
            "idle": QIcon(ICON_IDLE),
            "recording": QIcon(ICON_RECORDING),
            "processing": QIcon(ICON_PROCESSING),
            "error": QIcon(ICON_ERROR)
        }
        self.setIcon(self.icons["idle"])
        self.setToolTip("MeetAssistant")
        
        # Menu
        self.menu = QMenu()
        self.recording_action = QAction("Start Recording", self)
        self.recording_action.triggered.connect(self.toggle_recording)
        self.menu.addAction(self.recording_action)

        self.recent_recordings_menu = self.menu.addMenu("Recent Recordings")
        
        self.recent_protocols_menu = self.menu.addMenu("Recent Protocols")
        
        self.menu.addSeparator()
        
        settings_menu = self.menu.addMenu("Settings")
        
        # Video Quality
        self.quality_menu = settings_menu.addMenu("Video Quality")
        self.quality_action_group = None # To implement mutual exclusion logic if needed
        for q_name in VIDEO_QUALITY_PRESETS.keys():
            action = QAction(q_name, self)
            action.setCheckable(True)
            if q_name == self.config.get("video_quality", "Medium"):
                action.setChecked(True)
            action.triggered.connect(lambda checked, n=q_name: self.set_quality(n))
            self.quality_menu.addAction(action)

        # AI Models
        self.model_menu = settings_menu.addMenu("AI Model")
        for model in AI_MODELS:
            action = QAction(model, self)
            action.setCheckable(True)
            if model == self.config['model_name']:
                action.setChecked(True)
            action.triggered.connect(lambda checked, m=model: self.set_model(m))
            self.model_menu.addAction(action)

        settings_menu.addAction("Edit System Prompt...", self.edit_prompt)
        settings_menu.addAction("Set API Key...", self.set_api_key)
        
        self.token_info_action = QAction(self.get_token_text(), self)
        self.token_info_action.setEnabled(False)
        settings_menu.addAction(self.token_info_action)

        self.menu.addSeparator()
        self.menu.addAction("Open Output Folder", self.open_folder)
        self.menu.addSeparator()
        self.menu.addAction("Quit", self.quit_app)
        
        self.setContextMenu(self.menu)
        self.menu.aboutToShow.connect(self.refresh_menu)
        
        self.show()
        
        # Timer for UI updates if needed
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_ui_state)
        self.timer.start(1000)

        logger.info("Qt App initialized")

    def get_token_text(self):
        last = self.config.get("last_request_tokens", 0)
        total = self.config.get("used_tokens", 0)
        return f"Last: {last} | Total: {total}"

    def update_ui_state(self):
        # Update token info proactively
        self.token_info_action.setText(self.get_token_text())

    def refresh_menu(self):
        # Update Recent Recordings
        self.recent_recordings_menu.clear()
        save_dir = self.config["save_dir"]
        if os.path.exists(save_dir) and not self.is_recording and not self.is_processing:
            files = [f for f in os.listdir(save_dir) if f.lower().endswith(".mp4")]
            files.sort(key=lambda x: os.path.getmtime(os.path.join(save_dir, x)), reverse=True)
            for f in files[:10]:
                action = QAction(f, self)
                action.triggered.connect(lambda checked, fname=f: self.process_file(fname))
                self.recent_recordings_menu.addAction(action)
        elif not os.path.exists(save_dir):
            self.recent_recordings_menu.addAction("No folder found").setEnabled(False)
        else:
            self.recent_recordings_menu.addAction("Busy...").setEnabled(False)

        # Update Protocols
        self.recent_protocols_menu.clear()
        if os.path.exists(save_dir):
            p_files = [f for f in os.listdir(save_dir) if f.endswith("_protocol.txt")]
            p_files.sort(key=lambda x: os.path.getmtime(os.path.join(save_dir, x)), reverse=True)
            for f in p_files[:10]:
                action = QAction(f, self)
                action.triggered.connect(lambda checked, fname=f: self.open_file(fname))
                self.recent_protocols_menu.addAction(action)

        # Update Recording Action Text
        if self.is_recording:
             self.recording_action.setText("Stop Recording")
        else:
             self.recording_action.setText("Start Recording")
             
        # Disable recording start if processing
        if self.is_processing:
             self.recording_action.setEnabled(False)
        else:
             self.recording_action.setEnabled(True)

    def set_quality(self, name):
        self.config["video_quality"] = name
        ConfigManager.save(self.config)
        # Refresh checks
        for action in self.quality_menu.actions():
            action.setChecked(action.text() == name)

    def set_model(self, name):
        self.config["model_name"] = name
        ConfigManager.save(self.config)
        for action in self.model_menu.actions():
            action.setChecked(action.text() == name)

    def edit_prompt(self):
        text, ok = QInputDialog.getMultiLineText(None, "Edit Prompt", "System Instruction:", self.config["prompt"])
        if ok:
            self.config["prompt"] = text
            ConfigManager.save(self.config)

    def set_api_key(self):
        text, ok = QInputDialog.getText(None, "API Key", "Google API Key:", text=self.config["api_key"])
        if ok:
            self.config["api_key"] = text.strip()
            ConfigManager.save(self.config)

    def open_folder(self):
        subprocess.call(["open", self.config["save_dir"]])
        
    def open_file(self, filename):
        path = os.path.join(self.config["save_dir"], filename)
        subprocess.call(["open", path])

    def quit_app(self):
        if self.is_recording:
            self.stop_recording()
        QApplication.quit()

    def toggle_recording(self):
        if self.is_recording:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        if not self.config.get("api_key"):
            self.showMessage("API Key Required", "Please set Google API Key in Settings")
            return

        timestamp = datetime.now().strftime("%d.%m.%Y_%H:%M:%S")
        self.current_filename = os.path.join(self.config["save_dir"], f"Meet_{timestamp}.mp4")
        mic_filename = os.path.join(self.config["save_dir"], f"Meet_{timestamp}_mic.m4a")
        
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
                    # Use QTimer to update UI from main thread safe-ish way, or just log
            
            self.recorder.startWithCallback_(callback)
            self.is_recording = True
            self.setIcon(self.icons["recording"])
            self.showMessage("Recording Started", f"File: {os.path.basename(self.current_filename)}")
            
        except Exception as e:
            logger.exception("Start recording error")
            self.showMessage("Error", str(e))
            self.setIcon(self.icons["error"])

    def stop_recording(self):
        if self.recorder:
            self.recorder.stop()
            self.recorder = None
        
        self.is_recording = False
        self.setIcon(self.icons["idle"])
        self.showMessage("Recording Stopped", "Files saved.")
        time.sleep(0.5)
        self.refresh_menu()

    def process_file(self, filename):
        video_path = os.path.join(self.config["save_dir"], filename)
        self.is_processing = True
        self.setIcon(self.icons["processing"])
        self.showMessage("AI Processing", "Uploading and analyzing...")
        
        self.worker = AIWorker(video_path, self.config)
        self.worker.finished_signal.connect(self.on_processing_finished)
        self.worker.start()

    def on_processing_finished(self, success, title, message):
        self.is_processing = False
        if success:
            self.setIcon(self.icons["idle"])
        else:
            self.setIcon(self.icons["error"]) # Blink logic could be added here
            QTimer.singleShot(3000, lambda: self.setIcon(self.icons["idle"]))
            
        self.showMessage(title, message)
        self.refresh_menu()

if __name__ == "__main__":
    PermissionManager.check_all()
    app = QApplication(sys.argv)
    
    # Чтобы иконка не закрывалась при закрытии окон (которых нет, но все же)
    app.setQuitOnLastWindowClosed(False)
    
    tray = MeetAssistantApp(app)
    sys.exit(app.exec())
