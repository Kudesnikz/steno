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

# import qdarktheme

from PyQt6.QtWidgets import (QApplication, QSystemTrayIcon, QMenu, QStyle, 
                             QMessageBox, QWidget)
from PyQt6.QtGui import QIcon, QAction, QFont, QPixmap, QPainter, QColor, QFontMetrics
from PyQt6.QtCore import QTimer, QThread, pyqtSignal, QObject, Qt, QSize

# --- Custom Recorder Import ---
from recorder import ScreenRecorder
import objc
from Foundation import NSURL

# --- Модули приложения ---
from app.core.config import ConfigManager, CONFIG_FILE
from app.core.ai_worker import AIWorker
from app.ui.ui_main import MainWindow
from app.ui.ui_settings import SettingsDialog

# --- macOS Permission & Native Capture Imports ---
try:
    from AVFoundation import (
        AVCaptureDevice, AVMediaTypeAudio, AVAuthorizationStatusAuthorized
    )
    from Quartz import (
        CGPreflightScreenCaptureAccess, CGRequestScreenCaptureAccess
    )
    from UserNotifications import UNUserNotificationCenter, UNAuthorizationOptionAlert, UNAuthorizationOptionSound, UNAuthorizationOptionBadge
    from AppKit import NSStatusBar, NSVariableStatusItemLength, NSImage, NSMenu, NSMenuItem
    from Foundation import NSObject
    
    class MacTrayHelper(NSObject):
        app_ref = None
        
        def toggleRecording_(self, sender):
            if self.app_ref:
                self.app_ref.toggle_recording()
                
        def stopRecording_(self, sender):
            if self.app_ref:
                self.app_ref.stop_recording()
                
        def showMainWindow_(self, sender):
            if self.app_ref:
                self.app_ref.show_main_window()
                
        def openSettings_(self, sender):
            if self.app_ref:
                self.app_ref.open_settings()
                
        def openFolder_(self, sender):
            if self.app_ref:
                self.app_ref.open_folder()
                
        def quitApp_(self, sender):
            if self.app_ref:
                self.app_ref.quit_app()

    HAS_PYOBJC = True
except ImportError:
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

# --- Константы ---
BASE_PATH = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(BASE_PATH, "assets")

ICON_IDLE = os.path.join(ASSETS_DIR, "icon_idle.png")
ICON_RECORDING = os.path.join(ASSETS_DIR, "icon_recording.png")
ICON_PROCESSING = os.path.join(ASSETS_DIR, "icon_processing.png")
ICON_ERROR = os.path.join(ASSETS_DIR, "icon_error.png")

VIDEO_QUALITY_PRESETS = {
    "Low": {"width": 960, "height": 540, "fps": 5, "bitrate": 1000000},
    "Medium": {"width": 1280, "height": 720, "fps": 10, "bitrate": 3000000},
    "High": {"width": 1920, "height": 1080, "fps": 30, "bitrate": 8000000},
    "Ultra": {"width": 2560, "height": 1440, "fps": 60, "bitrate": 25000000}
}
messageAuthor = 'v2.0 (Qt Notes)'

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

# --- Главный класс Приложения ---
class MeetAssistantApp(QObject):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.config = ConfigManager.load()
        
        self.is_recording = False
        self.is_processing = False
        self.recorder = None
        self.current_filename = None
        self.recording_time = 0
        self.timer_item = None
        
        self.mac_tray_helper = None
        if HAS_PYOBJC:
            self.mac_tray_helper = MacTrayHelper.alloc().init()
            self.mac_tray_helper.app_ref = self
        
        self.recording_timer = QTimer(self)
        self.recording_timer.timeout.connect(self.update_tray_timer)
        
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

        # UI: Tray
        self.tray = QSystemTrayIcon()
        self.tray.setIcon(self.icons["idle"])
        self.tray.setToolTip("Steno")
        
        # Tray Menu
        self.menu = QMenu()
        self.recording_action = QAction("Start Recording", self)
        self.recording_action.triggered.connect(self.toggle_recording)
        self.menu.addAction(self.recording_action)

        self.menu.addSeparator()
        self.menu.addAction("Show UI", self.show_main_window)
        self.menu.addAction("Settings...", self.open_settings)
        self.menu.addSeparator()
        self.menu.addAction("Open Output Folder", self.open_folder)
        self.menu.addSeparator()
        self.menu.addAction("Quit", self.quit_app)
        
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.on_tray_activated)
        
        if HAS_PYOBJC:
            # Native Mac Tray initialization
            self.timer_item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSVariableStatusItemLength)
            self.timer_item.retain()
            
            def _load_ns_image(path):
                img = NSImage.alloc().initWithContentsOfFile_(path)
                if img:
                    img.setSize_((18, 18))
                    img.setTemplate_(True)
                return img
                
            self.ns_icons = {
                "idle": _load_ns_image(ICON_IDLE),
                "recording": _load_ns_image(ICON_RECORDING),
                "processing": _load_ns_image(ICON_PROCESSING),
                "error": _load_ns_image(ICON_ERROR)
            }
            
            self.timer_item.button().setImage_(self.ns_icons["idle"])
            self.timer_item.button().setImagePosition_(2) # NSImageLeft
            self.update_native_menu()
        else:
            self.tray.show()

        if not os.path.exists(CONFIG_FILE):
            QTimer.singleShot(100, self.show_onboarding)

    def on_tray_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            # Левый клик по иконке трея
            pass

    def update_native_menu(self):
        if not HAS_PYOBJC or not self.timer_item: return
        ns_menu = NSMenu.alloc().init()
        
        title = "Stop Recording" if self.is_recording else "Start Recording"
        i_rec = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, "toggleRecording:", "")
        i_rec.setTarget_(self.mac_tray_helper)
        ns_menu.addItem_(i_rec)
        
        ns_menu.addItem_(NSMenuItem.separatorItem())
        
        i_ui = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Show UI", "showMainWindow:", "")
        i_ui.setTarget_(self.mac_tray_helper)
        ns_menu.addItem_(i_ui)
        
        i_set = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Settings...", "openSettings:", "")
        i_set.setTarget_(self.mac_tray_helper)
        ns_menu.addItem_(i_set)
        
        ns_menu.addItem_(NSMenuItem.separatorItem())
        
        i_fld = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Open Output Folder", "openFolder:", "")
        i_fld.setTarget_(self.mac_tray_helper)
        ns_menu.addItem_(i_fld)
        
        ns_menu.addItem_(NSMenuItem.separatorItem())
        
        i_quit = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Quit", "quitApp:", "")
        i_quit.setTarget_(self.mac_tray_helper)
        ns_menu.addItem_(i_quit)
        
        self.timer_item.setMenu_(ns_menu)

    def show_main_window(self):
        if not os.path.exists(CONFIG_FILE):
            self.show_onboarding()
        else:
            self.main_window.showNormal()
            self.main_window.activateWindow()

    def show_onboarding(self):
        from app.ui.ui_onboarding import OnboardingDialog
        dialog = OnboardingDialog()
        if dialog.exec():
            self.config = ConfigManager.load()
            self.main_window.update_config(self.config)
            self.show_main_window()

    def open_settings(self):
        dialog = SettingsDialog(self.config, self.main_window)
        if dialog.exec():
            self.config = dialog.get_updated_config()
            ConfigManager.save(self.config)
            self.main_window.update_config(self.config)

    def open_folder(self):
        subprocess.call(["open", self.config.get("save_dir", "")])

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
            QMessageBox.warning(None, "API Key Required", "Please set Google API Key in Settings")
            self.open_settings()
            return

        timestamp = datetime.now().strftime("%d.%m.%Y_%H:%M:%S")
        save_dir = self.config.get("save_dir", "")
        if not os.path.exists(save_dir):
            os.makedirs(save_dir)
            
        self.current_filename = os.path.join(save_dir, f"Meet_{timestamp}.mp4")
        mic_filename = os.path.join(save_dir, f"Meet_{timestamp}_mic.m4a")
        
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
            
            self.recorder.startWithCallback_(callback)
            self.is_recording = True
            self.recording_time = 0
            
            # Обновление UI
            if HAS_PYOBJC:
                self.timer_item.button().setImage_(self.ns_icons["recording"])
                self.update_native_menu()
                if self.config.get("show_recording_time", True):
                    self.update_tray_timer()
                    self.recording_timer.start(1000)
                else:
                    self.timer_item.button().setTitle_("")
            else:
                self.tray.setIcon(self.icons["recording"])
                
            self.recording_action.setText("Stop Recording")
            self.main_window.set_recording_state(True)
            self.tray.showMessage("Recording Started", f"File: {os.path.basename(self.current_filename)}")
            
        except Exception as e:
            logger.exception("Start recording error")
            self.tray.showMessage("Error", str(e))
            self.recording_timer.stop()
            if HAS_PYOBJC:
                self.timer_item.button().setImage_(self.ns_icons["error"])
                self.timer_item.button().setTitle_("")
                self.update_native_menu()
            else:
                self.tray.setIcon(self.icons["error"])

    def stop_recording(self):
        if self.recorder:
            self.recorder.stop()
            self.recorder = None
        
        self.is_recording = False
        self.recording_timer.stop()
        
        # Обновление UI
        if HAS_PYOBJC:
            self.timer_item.button().setImage_(self.ns_icons["idle"])
            self.timer_item.button().setTitle_("")
            self.update_native_menu()
        else:
            self.tray.setIcon(self.icons["idle"])
            
        self.recording_action.setText("Start Recording")
        self.main_window.set_recording_state(False)
        self.tray.showMessage("Recording Stopped", "Files saved.")
        
        # Немного подождем, чтобы файл успел сохраниться и обновим окно
        time.sleep(1)
        self.main_window.refresh_data()

    def update_tray_timer(self):
        hours = self.recording_time // 3600
        minutes = (self.recording_time % 3600) // 60
        seconds = self.recording_time % 60
        
        time_str = f" {hours:02d}:{minutes:02d}:{seconds:02d} "
        
        if self.timer_item and HAS_PYOBJC:
            self.timer_item.button().setTitle_(time_str)
        
        self.recording_time += 1

    def start_generation(self, session_base_path, agent_id):
        if self.is_processing:
            QMessageBox.warning(self.main_window, "Занято", "Уже идет генерация.")
            return
            
        self.is_processing = True
        self.recording_action.setEnabled(False)
        
        if HAS_PYOBJC:
            self.timer_item.button().setImage_(self.ns_icons["processing"])
            self.update_native_menu()
        else:
            self.tray.setIcon(self.icons["processing"])
            
        self.worker = AIWorker(session_base_path, self.config, agent_id)
        self.worker.finished_signal.connect(self.on_processing_finished)
        self.worker.start()

    def on_processing_finished(self, success, title, message, base_name, agent_id):
        self.is_processing = False
        self.recording_action.setEnabled(True)
        
        if HAS_PYOBJC:
            if success:
                self.timer_item.button().setImage_(self.ns_icons["idle"])
            else:
                self.timer_item.button().setImage_(self.ns_icons["error"])
                QTimer.singleShot(3000, lambda: self.timer_item.button().setImage_(self.ns_icons["idle"]))
            self.update_native_menu()
        else:
            if success:
                self.tray.setIcon(self.icons["idle"])
            else:
                self.tray.setIcon(self.icons["error"])
                QTimer.singleShot(3000, lambda: self.tray.setIcon(self.icons["idle"]))
            
        self.tray.showMessage(title, message)
        
        # Обновляем окно
        self.main_window.refresh_data()
        
        # Если окно открыто и выбрана та же сессия, мы могли бы открыть созданный таб, 
        # но пока достаточно того, что мы обновили данные.


if __name__ == "__main__":
    PermissionManager.check_all()
    app = QApplication(sys.argv)
    
    # Применяем нативный macOS шрифт
    font = QFont(".AppleSystemUIFont", 13)
    app.setFont(font)
    
    # Тема отключена для использования нативного оформления macOS
    # (позволяет работать setUnifiedTitleAndToolBarOnMac)
    
    # Кастомная стилизация скроллбара (поскольку Qt сбрасывает нативный скроллбар 
    # из-за прозрачного фона QListWidget)
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
    
    # Чтобы иконка не закрывалась при закрытии окон
    app.setQuitOnLastWindowClosed(False)
    
    assistant = MeetAssistantApp(app)
    sys.exit(app.exec())
