# app.py
import rumps
import subprocess
import os
import signal
import json
import threading
import time
import re
import sys
import certifi
import shutil
import logging
from datetime import datetime
from google import genai
from google.genai import types

# --- Custom Recorder Import ---
# Убедись, что recorder.py лежит рядом и обновлен (версия с двумя райтерами)
from recorder import ScreenRecorder

messageAuthor = 'v1.3'
APP_BUNDLE_ID = "com.sergeygalay.steno"

# --- macOS Permission & Native Capture Imports ---
try:
    import objc
    from AVFoundation import (
        AVCaptureDevice, AVMediaTypeAudio, AVAuthorizationStatusAuthorized,
        AVCaptureSession, AVCaptureScreenInput, AVCaptureDeviceInput,
        AVCaptureMovieFileOutput, AVCaptureVideoOrientationLandscapeLeft
    )
    from Quartz import (
        CGPreflightScreenCaptureAccess, CGRequestScreenCaptureAccess,
        CGMainDisplayID
    )
    from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
    from UserNotifications import UNUserNotificationCenter, UNAuthorizationOptionAlert, UNAuthorizationOptionSound, UNAuthorizationOptionBadge
    from AppKit import NSMenu
    from Foundation import NSObject, NSURL, NSRunLoop, NSDate, NSBundle
    HAS_PYOBJC = True
except ImportError as e:
    print(f"PyObjC import error: {e}")
    HAS_PYOBJC = False
except Exception as e:
    print(f"Unexpected error during PyObjC imports: {e}")
    HAS_PYOBJC = False

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

# --- Утилиты ---
def get_meeting_date(filename):
    """
    Алгоритм получения даты встречи:
    1. Из названия файла (Meet_YYYY-MM-DD_HH-MM-SS.mp4)
    2. Дата изменения файла
    3. Дата создания файла
    4. Текущая дата
    """
    # 1. Попытка распарсить из имени файла
    # Ожидаемый формат от рекордера: Meet_DD.MM.YYYY_HH:MM:SS.mp4
    basename = os.path.basename(filename)
    match = re.search(r"Meet_(\d{2}\.\d{2}\.\d{4})_", basename)
    if match:
        return match.group(1)
    
    # 2. Дата изменения
    try:
        mtime = os.path.getmtime(filename)
        return datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")
    except:
        pass

    # 3. Дата создания
    try:
        ctime = os.path.getctime(filename)
        return datetime.fromtimestamp(ctime).strftime("%Y-%m-%d")
    except:
        pass

    # 4. Текущая дата
    return datetime.now().strftime("%Y-%m-%d")

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

# --- Воркер ИИ (ОБНОВЛЕННЫЙ ПОД ДВА ФАЙЛА) ---
def process_video_with_ai(video_path, config, app_instance):
    try:
        app_instance.is_processing = True
        app_instance.update_ui_state()
        app_instance.set_state_icon("processing")
        logger.info(f"Starting AI processing logic for: {video_path}")
        
        api_key = config.get("api_key")
        if not api_key:
            logger.error("API Key is missing")
            rumps.notification("AI Error", "Нет API ключа", "Настройте ключ в меню")
            app_instance.is_processing = False
            app_instance.update_ui_state()
            if app_instance.is_recording:
                app_instance.set_state_icon("recording")
            else:
                app_instance.set_state_icon("idle")
            return

        # 1. Определяем файлы для загрузки
        # Основное видео + микрофон (MP4)
        files_to_upload_paths = [video_path]
        
        # Ищем файл микрофона (M4A)
        # Он должен лежать рядом с именем: имя_файла_mic.m4a
        base_name = os.path.splitext(video_path)[0]
        mic_audio_path = base_name + "_mic.m4a"
        
        if os.path.exists(mic_audio_path):
            logger.info(f"Found microphone audio track: {mic_audio_path}")
            files_to_upload_paths.append(mic_audio_path)
        else:
            logger.warning("Microphone audio file not found, processing video only.")

        # 2. Инициализация клиента
        client_kwargs = {"api_key": api_key}
        base_url = config.get("base_url", "").strip()
        if base_url:
            if not base_url.startswith(("http://", "https://")):
                base_url = "https://" + base_url
            client_kwargs["http_options"] = {"baseUrl": base_url}
        
        client = genai.Client(**client_kwargs)

        rumps.notification("AI Обработка", "Загрузка файлов...", f"Файлов: {len(files_to_upload_paths)}")
        
        # 3. Загрузка всех файлов
        uploaded_files = []
        try:
            for path in files_to_upload_paths:
                logger.info(f"Uploading {os.path.basename(path)}...")
                uf = client.files.upload(file=path)
                uploaded_files.append(uf)
        except Exception as upload_err:
            logger.exception("File upload failed")
            raise Exception(f"Ошибка загрузки: {upload_err}")

        # 4. Ожидание процессинга ВСЕХ файлов
        ready_files = []
        for uf in uploaded_files:
            logger.info(f"Waiting for processing: {uf.name} ({uf.display_name})")
            while uf.state.name == "PROCESSING":
                time.sleep(3)
                uf = client.files.get(name=uf.name)

            if uf.state.name == "FAILED":
                logger.error(f"Google failed to process file {uf.name}")
                raise Exception(f"Google не смог обработать файл {uf.display_name}")
            
            ready_files.append(uf)
            logger.info(f"File ready: {uf.name}")
        
        # 5. Генерация контента
        logger.info(f"Generating protocol with model: {config.get('model_name')}")

        # Формируем жесткий User Prompt с датой
        meeting_date = get_meeting_date(video_path)
        user_prompt_text = f"Составь протокол по прикрепленному файлу.\n\nДата встречи: {meeting_date}"
        
        # Системный промпт берем из конфига (редактируемый пользователем)
        system_instruction = config.get("prompt")

        # Собираем контент: [File1, File2, ..., UserPrompt]
        contents = ready_files + [user_prompt_text]

        response = client.models.generate_content(
            model=config.get("model_name"),
            contents=contents,
            config=types.GenerateContentConfig(
                http_options={"timeout": 600000},
                system_instruction=system_instruction
            )
        )

        # --- Token Usage Tracking ---
        if response.usage_metadata:
            total_tokens = response.usage_metadata.total_token_count
            config["used_tokens"] = config.get("used_tokens", 0) + total_tokens
            config["last_request_tokens"] = total_tokens
            ConfigManager.save(config)
            try:
                app_instance.update_token_stats()
            except Exception as e:
                logger.warning(f"Failed to update token stats in UI: {e}")
        # ----------------------------

        txt_path = base_name + "_protocol.txt"
        with open(txt_path, "w", encoding="utf-8") as f:
            f.write(response.text)

        logger.info(f"Protocol saved to: {txt_path}")

        # 6. Удаление файлов из облака
        for uf in ready_files:
            try: 
                client.files.delete(name=uf.name)
                logger.info(f"Remote file deleted: {uf.name}")
            except Exception as delete_err: 
                logger.warning(f"Could not delete remote file: {delete_err}")

        rumps.notification("Готово!", "Протокол сохранен", f"Файл: {os.path.basename(txt_path)}")
        app_instance.is_processing = False
        app_instance.update_ui_state()
        app_instance.refresh_files_menus()
        
        if app_instance.is_recording:
            app_instance.set_state_icon("recording")
        else:
            app_instance.set_state_icon("idle")

    except Exception as e:
        logger.exception("AI worker failed")
        rumps.notification("AI Ошибка", "Сбой обработки", str(e)[:50])
        app_instance.flash_error()
        app_instance.is_processing = False
        app_instance.update_ui_state()
        if app_instance.is_recording:
            app_instance.set_state_icon("recording")
        else:
            app_instance.set_state_icon("idle")

# --- GUI Приложение ---
class RecorderApp(rumps.App):
    def __init__(self):
        initial_icon = ICON_IDLE if os.path.exists(ICON_IDLE) else None
        title = "Rec" if initial_icon is None else ""
        
        super(RecorderApp, self).__init__(name=title, icon=initial_icon, quit_button=None)
        self.config = ConfigManager.load()
        self.is_recording = False
        self.is_processing = False
        
        # Native Capture Properties
        self.recorder = None
        self.current_filename = None
        self.mic_audio_filename = None
        
        if not os.path.exists(self.config["save_dir"]):
            os.makedirs(self.config["save_dir"])

        self.recent_recordings_menu = rumps.MenuItem("Recent Recordings")
        self.recent_protocols_menu = rumps.MenuItem("Recent Protocols")
        self.build_menu()
        
        # Таймер для обновления меню (не слишком частый)
        self.refresh_timer = threading.Timer(1.0, self.refresh_files_menus)
        self.refresh_timer.start()
        
        if HAS_PYOBJC:
            self._delegate = MenuDelegate.alloc().initWithApp_(self)
            self._menu._menu.setDelegate_(self._delegate)
        
        logger.info("Steno initialized (Dual-Stream Mode)")

    @rumps.timer(30)
    def auto_refresh_menu(self, _):
        if not self.is_recording:
            self.refresh_files_menus()

    def set_state_icon(self, state):
        icons = {
            "idle": (ICON_IDLE, "Rec"),
            "recording": (ICON_RECORDING, "🔴 Rec"),
            "processing": (ICON_PROCESSING, "⚙️ Rec"),
            "error": (ICON_ERROR, "⚠️ Rec")
        }
        path, text = icons.get(state, (None, "Rec"))
        if path and os.path.exists(path):
            self.icon = path
            self.title = ""
        else:
            self.icon = None
            self.title = text
            
        # Trigger UI update whenever icon/state changes context
        self.update_ui_state()

    @rumps.timer(0.5)
    def update_ui_state(self, _=None):
        """
        Updates the enabled/disabled state of menu items based on current app state.
        Runs periodically on the main thread to ensure UI safety.
        
        Rules:
        1. If Processing (is_processing=True):
           - Disable "Recent Recordings" (prevent parallel AI)
           - Disable "Start Recording" (prevent recording during AI) -> BUT allow "Stop" if recording.
           
        2. If Recording (is_recording=True):
           - Disable "Recent Recordings" (prevent AI during recording)
           - "Start Recording" becomes "Stop" and must remain enabled.
        """
        if not HAS_PYOBJC:
            return

        # Determine states
        # Can we start a new recording? Only if not recording AND not processing
        can_start_new_recording = not self.is_recording and not self.is_processing
        
        # Can we stop? Only if recording
        can_stop = self.is_recording
        
        # Can we use Recent Recordings? Only if IDLE (not recording AND not processing)
        can_use_recent = not (self.is_recording or self.is_processing)

        # 1. Update Recent Recordings Menu
        if hasattr(self, 'recent_recordings_menu') and hasattr(self.recent_recordings_menu, '_menuitem'):
            try:
                self.recent_recordings_menu._menuitem.setEnabled_(can_use_recent)
            except Exception:
                pass

        # 2. Update Start/Stop Button
        # We need to find the item because its key changes ("Start Recording" <-> "Stop")
        start_stop_item = None
        if "Start Recording" in self.menu:
            start_stop_item = self.menu["Start Recording"]
            # If item is "Start Recording", enable only if can_start_new_recording
            if hasattr(start_stop_item, '_menuitem'):
                try:
                    start_stop_item._menuitem.setEnabled_(can_start_new_recording)
                except Exception:
                    pass
                
        elif "Stop" in self.menu:
            start_stop_item = self.menu["Stop"]
            # If item is "Stop", it should generally be enabled if we are recording
            if hasattr(start_stop_item, '_menuitem'):
                try:
                    start_stop_item._menuitem.setEnabled_(True)
                except Exception:
                    pass

    def flash_error(self):
        def blink():
            for _ in range(6):
                self.set_state_icon("error")
                time.sleep(0.5)
                self.set_state_icon("idle")
                time.sleep(0.5)
        threading.Thread(target=blink, daemon=True).start()

    def build_menu(self):
        self.model_menu = rumps.MenuItem("AI Model")
        for model in AI_MODELS:
            item = rumps.MenuItem(model, callback=self.select_ai_model)
            if model == self.config["model_name"]: item.state = 1
            self.model_menu.add(item)

        self.menu = [
            "Start Recording",
            self.recent_recordings_menu,
            self.recent_protocols_menu,
            None,
            "Settings",
            rumps.MenuItem("Open Output Folder", callback=self.open_folder),
            None,
            rumps.MenuItem("Made by Sergey Galay", callback=self.open_link),
            rumps.MenuItem("Quit", callback=rumps.quit_application)
        ]

        # Video Quality Menu
        self.quality_menu = rumps.MenuItem("Video Quality")
        for q_name in VIDEO_QUALITY_PRESETS.keys():
            item = rumps.MenuItem(q_name, callback=self.select_video_quality)
            if q_name == self.config.get("video_quality", "Medium"):
                item.state = 1
            self.quality_menu.add(item)

        self.menu["Settings"].add(self.quality_menu)
        self.menu["Settings"].add(self.model_menu)
        self.menu["Settings"].add(rumps.MenuItem("Edit System Prompt...", callback=self.edit_prompt))
        self.menu["Settings"].add(rumps.MenuItem("Set API Key...", callback=self.set_api_key))
        self.menu["Settings"].add(rumps.MenuItem("Reset Permissions (All)", callback=self.reset_permissions))
        self.menu["Settings"].add(rumps.MenuItem("Reset Permissions + Restart", callback=self.reset_permissions_and_restart))
        
        self.menu["Settings"].add(None)
        
        last = self.config.get("last_request_tokens", 0)
        total = self.config.get("used_tokens", 0)
        
        self.last_request_item = rumps.MenuItem(f"Last request: {last}", callback=None)
        self.total_tokens_item = rumps.MenuItem(f"Used tokens: {total}", callback=None)
        
        self.menu["Settings"].add(self.last_request_item)
        self.menu["Settings"].add(self.total_tokens_item)
        
        self.menu["Settings"].add(None)
        self.menu["Settings"].add(messageAuthor)
        
        if HAS_PYOBJC:
            try:
                self.last_request_item._menuitem.setEnabled_(False)
                self.total_tokens_item._menuitem.setEnabled_(False)
            except:
                pass

    def update_token_stats(self):
        last = self.config.get("last_request_tokens", 0)
        total = self.config.get("used_tokens", 0)
        if hasattr(self, 'last_request_item'):
            self.last_request_item.title = f"Last request: {last}"
        if hasattr(self, 'total_tokens_item'):
            self.total_tokens_item.title = f"Used tokens: {total}"

    def select_video_quality(self, sender):
        self.config["video_quality"] = sender.title
        for item in self.quality_menu.values():
            item.state = 1 if item.title == sender.title else 0
        ConfigManager.save(self.config)

    def select_ai_model(self, sender):
        self.config["model_name"] = sender.title
        for item in self.model_menu.values():
            item.state = 1 if item.title == sender.title else 0
        ConfigManager.save(self.config)

    def edit_prompt(self, _):
        w = rumps.Window("Edit System Prompt", "Instructions for Gemini:", self.config["prompt"], dimensions=(600, 200))
        r = w.run()
        if r.clicked:
            self.config["prompt"] = r.text.strip()
            ConfigManager.save(self.config)

    def set_api_key(self, _):
        w = rumps.Window("Google API Key", default_text=self.config["api_key"], dimensions=(600, 50))
        r = w.run()
        if r.clicked:
            self.config["api_key"] = r.text.strip()
            ConfigManager.save(self.config)

    def reset_permissions(self, _):
        try:
            result = subprocess.run(
                ["tccutil", "reset", "All", APP_BUNDLE_ID],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                details = (result.stderr or result.stdout or "Unknown error").strip()
                rumps.alert(
                    "Reset Failed",
                    f"Не удалось сбросить разрешения.\n\n{details}"
                )
                return

            # Opens the exact privacy pane so the user can re-enable screen access immediately.
            subprocess.call(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"])
            rumps.alert(
                "Permission Reset",
                "Все разрешения для Steno сброшены (включая Screen Recording и Microphone).\n"
                "1. Закройте Steno.\n"
                "2. Запустите снова только из /Applications.\n"
                "3. Нажмите Start Recording и выдайте доступы заново."
            )
        except Exception as e:
            rumps.alert("Reset Failed", f"Ошибка при сбросе разрешений: {e}")

    def reset_permissions_and_restart(self, _):
        try:
            result = subprocess.run(
                ["tccutil", "reset", "All", APP_BUNDLE_ID],
                capture_output=True,
                text=True
            )
            if result.returncode != 0:
                details = (result.stderr or result.stdout or "Unknown error").strip()
                rumps.alert(
                    "Reset Failed",
                    f"Не удалось сбросить разрешения.\n\n{details}"
                )
                return

            bundle_path = None
            if HAS_PYOBJC:
                try:
                    bundle_path = NSBundle.mainBundle().bundlePath()
                except Exception:
                    bundle_path = None

            if bundle_path and os.path.exists(bundle_path):
                subprocess.Popen(["open", "-n", bundle_path])
                rumps.quit_application()
            else:
                rumps.alert(
                    "Permissions Reset",
                    "Разрешения сброшены, но путь к .app не найден.\n"
                    "Перезапустите приложение вручную из /Applications."
                )
        except Exception as e:
            rumps.alert("Reset Failed", f"Ошибка при сбросе разрешений: {e}")
            
    def open_folder(self, _):
        subprocess.call(["open", self.config["save_dir"]])

    def open_link(self, _):
        subprocess.call(["open", "https://t.me/galay_ss"])

    @rumps.clicked("Start Recording")
    def record_switch(self, sender):
        # Protection against starting recording while processing
        if self.is_processing and not self.is_recording:
            rumps.alert("Busy", "Идет обработка видео. Пожалуйста, подождите.")
            return

        if not self.is_recording:
            if not self.config.get("api_key"):
                rumps.alert("API Key Required", "Пожалуйста, установите API ключ Google.")
                return
            self.start_recording(sender)
        else:
            self.stop_recording(sender)

    # --- START RECORDING (ОБНОВЛЕННЫЙ) ---
    def start_recording(self, sender):
        timestamp = datetime.now().strftime("%d.%m.%Y_%H:%M:%S")
        
        # 1. Основной файл (Видео + Системный звук)
        self.current_filename = os.path.join(self.config["save_dir"], f"Meet_{timestamp}.mp4")
        # 2. Микрофон (только аудио, формат M4A)
        self.mic_audio_filename = os.path.join(self.config["save_dir"], f"Meet_{timestamp}_mic.m4a")
        
        logger.info(f"Starting Recording. Main: {self.current_filename}, Mic: {self.mic_audio_filename}")
        
        try:
            url_main = NSURL.fileURLWithPath_(self.current_filename)
            url_mic = NSURL.fileURLWithPath_(self.mic_audio_filename)
            
            # Получаем настройки качества
            quality_key = self.config.get("video_quality", "Medium")
            preset = VIDEO_QUALITY_PRESETS.get(quality_key, VIDEO_QUALITY_PRESETS["Medium"])

            # ВАЖНО: Инициализация рекордера с двумя URL и конфигом
            self.recorder = ScreenRecorder.alloc().initWithOutputURLs_auxURL_videoConfig_(
                url_main, url_mic, preset
            )
            
            if not self.recorder:
                raise Exception("Failed to initialize ScreenRecorder")

            # Callback для обработки результата запуска записи
            def start_callback(success, error_msg):
                if not success:
                    logger.error(f"Failed to start recording: {error_msg}")
                    rumps.alert("Recording Error", f"Не удалось начать запись: {error_msg}\n\nПроверьте права доступа в System Settings -> Privacy & Security -> Screen Recording.")
                    # Сбрасываем UI в исходное состояние
                    self.is_recording = False
                    sender.title = "Start Recording"
                    self.set_state_icon("idle")
                    self.recorder = None

            self.recorder.startWithCallback_(start_callback)
            
            self.is_recording = True
            sender.title = "Stop"
            self.set_state_icon("recording")
            
        except Exception as e:
            logger.exception("Recording failed to start")
            rumps.alert("Error", str(e))
            self.set_state_icon("error")

    def stop_recording(self, sender):
        logger.info("Stopping native recording...")
        if self.recorder:
            self.recorder.stop()
        
        self.is_recording = False
        sender.title = "Start Recording"
        self.set_state_icon("idle")
        
        rumps.notification("Готово", "Файлы сохранены", os.path.basename(self.current_filename))
        # Даем время на закрытие файлов
        time.sleep(1.0)
        self.refresh_files_menus()

    # --- REFRESH MENU (С ФИЛЬТРАЦИЕЙ СИСТЕМНЫХ ФАЙЛОВ) ---
    def refresh_files_menus(self, _=None):
        try:
            # Очистка меню видео
            for item_title in list(self.recent_recordings_menu.keys()):
                del self.recent_recordings_menu[item_title]
            
            save_dir = self.config["save_dir"]
            if os.path.exists(save_dir):
                # Показываем только .mp4 (основные файлы). 
                # .m4a (системные) скрыты, они подтянутся автоматически при обработке.
                files = [f for f in os.listdir(save_dir) if f.lower().endswith(".mp4")]
                files.sort(key=lambda x: os.path.getmtime(os.path.join(save_dir, x)), reverse=True)
                
                if files:
                    for f in files[:10]:
                        self.recent_recordings_menu.add(rumps.MenuItem(f, callback=self.process_selected_file))
                else:
                    self.recent_recordings_menu.add(rumps.MenuItem("Empty", callback=None))

            # Очистка меню протоколов
            for item_title in list(self.recent_protocols_menu.keys()):
                del self.recent_protocols_menu[item_title]

            if os.path.exists(save_dir):
                p_files = [f for f in os.listdir(save_dir) if f.endswith("_protocol.txt")]
                p_files.sort(key=lambda x: os.path.getmtime(os.path.join(save_dir, x)), reverse=True)
                if p_files:
                    for f in p_files[:10]:
                        self.recent_protocols_menu.add(rumps.MenuItem(f, callback=self.open_protocol_file))
                else:
                    self.recent_protocols_menu.add(rumps.MenuItem("Empty", callback=None))
        except Exception as e:
            logger.warning(f"Menu refresh warning: {e}")

    def open_protocol_file(self, sender):
        subprocess.call(["open", os.path.join(self.config["save_dir"], sender.title)])

    def process_selected_file(self, sender):
        video_path = os.path.join(self.config["save_dir"], sender.title)
        if os.path.exists(video_path):
            # Запускаем в отдельном потоке
            threading.Thread(target=process_video_with_ai, args=(video_path, self.config, self), daemon=True).start()

if HAS_PYOBJC:
    class MenuDelegate(NSObject):
        def initWithApp_(self, app):
            self = objc.super(MenuDelegate, self).init()
            if self: self.app = app
            return self
        
        def menuWillOpen_(self, menu):
            if not self.app.is_recording:
                self.app.refresh_files_menus()

if __name__ == "__main__":
    PermissionManager.check_all()
    RecorderApp().run() 
