import os
import subprocess
import copy
from PyQt6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QLabel, 
    QPushButton, QLineEdit, QWidget, QSpacerItem, 
    QSizePolicy, QFrame
)
from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QFont, QIcon

from app.core.config import ConfigManager, DEFAULT_CONFIG

try:
    from AVFoundation import AVCaptureDevice, AVMediaTypeAudio, AVAuthorizationStatusAuthorized
    from Quartz import CGPreflightScreenCaptureAccess, CGRequestScreenCaptureAccess
    HAS_MAC_API = True
except ImportError:
    HAS_MAC_API = False

class OnboardingDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Добро пожаловать в Meet Assistant")
        self.setFixedSize(550, 480)
        self.setModal(True)
        self.setWindowFlags(Qt.WindowType.Dialog | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.WindowCloseButtonHint | Qt.WindowType.WindowMinimizeButtonHint)
        
        self.config = copy.deepcopy(DEFAULT_CONFIG)
        
        self._apply_styles()
        self._setup_ui()
        
        # Начинаем поллинг статусов прав
        self.check_timer = QTimer(self)
        self.check_timer.timeout.connect(self._check_permissions)
        self.check_timer.start(1000)
        
        # Первичная проверка и (опционально) запрос прав
        self._initial_permission_request()

    def _apply_styles(self):
        self.setStyleSheet("""
            QDialog {
                background-color: #f5f5f7;
            }
            QLabel {
                color: #1d1d1f;
                font-size: 14px;
            }
            QLabel#titleLabel {
                font-size: 22px;
                font-weight: bold;
                margin-bottom: 10px;
            }
            QLabel#descLabel {
                font-size: 13px;
                color: #555555;
                margin-bottom: 20px;
            }
            QLineEdit {
                border: 1px solid #d2d2d7;
                border-radius: 6px;
                padding: 8px 10px;
                background-color: #ffffff;
                color: #1d1d1f;
                font-size: 14px;
                selection-background-color: #007aff;
            }
            QLineEdit:focus {
                border: 2px solid #007aff;
                padding: 7px 9px;
            }
            QPushButton {
                background-color: #ffffff;
                border: 1px solid #d2d2d7;
                border-radius: 6px;
                padding: 6px 16px;
                color: #1d1d1f;
                font-size: 13px;
                font-weight: 500;
            }
            QPushButton:hover {
                background-color: #f0f0f0;
            }
            QPushButton:pressed {
                background-color: #e5e5ea;
            }
            QPushButton#okButton {
                background-color: #007aff;
                color: white;
                border: none;
                font-weight: bold;
                padding: 10px 20px;
            }
            QPushButton#okButton:hover {
                background-color: #006ce4;
            }
            QPushButton#okButton:disabled {
                background-color: #a0cbfc;
                color: rgba(255, 255, 255, 0.7);
            }
            QFrame#card {
                background-color: #ffffff;
                border-radius: 10px;
                border: 1px solid #d2d2d7;
            }
        """)

    def _setup_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(30, 30, 30, 30)
        
        # Заголовок
        title = QLabel("Настройка Meet Assistant")
        title.setObjectName("titleLabel")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        main_layout.addWidget(title)
        
        desc = QLabel("Для правильной работы приложению требуются следующие доступы\nи настроенный API ключ Google Gemini.")
        desc.setObjectName("descLabel")
        desc.setAlignment(Qt.AlignmentFlag.AlignCenter)
        main_layout.addWidget(desc)
        
        # Карточка с правами
        permissions_card = QFrame()
        permissions_card.setObjectName("card")
        perm_layout = QVBoxLayout(permissions_card)
        perm_layout.setContentsMargins(20, 20, 20, 20)
        perm_layout.setSpacing(15)
        
        # 1. Запись экрана
        screen_layout = QHBoxLayout()
        self.screen_icon = QLabel("🔴")
        self.screen_label = QLabel("Запись экрана")
        self.screen_label.setStyleSheet("font-weight: bold;")
        self.screen_btn = QPushButton("Настройки")
        self.screen_btn.clicked.connect(self._open_screen_settings)
        screen_layout.addWidget(self.screen_icon)
        screen_layout.addWidget(self.screen_label)
        screen_layout.addStretch()
        screen_layout.addWidget(self.screen_btn)
        perm_layout.addLayout(screen_layout)
        
        # Разделитель
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        line.setFrameShadow(QFrame.Shadow.Sunken)
        line.setStyleSheet("background-color: #e5e5ea; max-height: 1px;")
        perm_layout.addWidget(line)
        
        # 2. Микрофон
        mic_layout = QHBoxLayout()
        self.mic_icon = QLabel("🔴")
        self.mic_label = QLabel("Микрофон")
        self.mic_label.setStyleSheet("font-weight: bold;")
        self.mic_btn = QPushButton("Настройки")
        self.mic_btn.clicked.connect(self._open_mic_settings)
        mic_layout.addWidget(self.mic_icon)
        mic_layout.addWidget(self.mic_label)
        mic_layout.addStretch()
        mic_layout.addWidget(self.mic_btn)
        perm_layout.addLayout(mic_layout)
        
        main_layout.addWidget(permissions_card)
        
        main_layout.addSpacing(20)
        
        # API Ключ
        api_card = QFrame()
        api_card.setObjectName("card")
        api_layout = QVBoxLayout(api_card)
        api_layout.setContentsMargins(20, 15, 20, 20)
        
        api_header = QHBoxLayout()
        api_title = QLabel("Google Gemini API Key")
        api_title.setStyleSheet("font-weight: bold;")
        api_link = QLabel('<a href="https://aistudio.google.com/app/apikey" style="color: #007aff; text-decoration: none;">Получить ключ (нужен VPN)</a>')
        api_link.setOpenExternalLinks(True)
        api_link.setStyleSheet("font-size: 12px;")
        api_header.addWidget(api_title)
        api_header.addStretch()
        api_header.addWidget(api_link)
        
        api_layout.addLayout(api_header)
        
        self.api_input = QLineEdit()
        self.api_input.setPlaceholderText("AIzaSy...")
        self.api_input.setEchoMode(QLineEdit.EchoMode.PasswordEchoOnEdit)
        self.api_input.textChanged.connect(self._validate_form)
        api_layout.addWidget(self.api_input)
        
        main_layout.addWidget(api_card)
        
        main_layout.addStretch()
        
        # Кнопка завершения
        btn_layout = QHBoxLayout()
        btn_layout.addStretch()
        self.ok_btn = QPushButton("Начать работу")
        self.ok_btn.setObjectName("okButton")
        self.ok_btn.setDisabled(True)
        self.ok_btn.clicked.connect(self._on_ok_clicked)
        btn_layout.addWidget(self.ok_btn)
        main_layout.addLayout(btn_layout)

    def _initial_permission_request(self):
        if not HAS_MAC_API:
            return
            
        # Запрашиваем права на экран если их нет
        if not CGPreflightScreenCaptureAccess():
            CGRequestScreenCaptureAccess()
            
        # Запрашиваем права на микрофон
        status = AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)
        if status != AVAuthorizationStatusAuthorized:
            AVCaptureDevice.requestAccessForMediaType_completionHandler_(AVMediaTypeAudio, lambda granted: None)

    def _check_permissions(self):
        has_screen = True
        has_mic = True
        
        if HAS_MAC_API:
            has_screen = CGPreflightScreenCaptureAccess()
            status = AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)
            has_mic = (status == AVAuthorizationStatusAuthorized)
            
        # Обновляем UI
        if has_screen:
            self.screen_icon.setText("🟢")
            self.screen_btn.hide()
        else:
            self.screen_icon.setText("🔴")
            self.screen_btn.show()
            
        if has_mic:
            self.mic_icon.setText("🟢")
            self.mic_btn.hide()
        else:
            self.mic_icon.setText("🔴")
            self.mic_btn.show()
            
        self.has_screen = has_screen
        self.has_mic = has_mic
        
        self._validate_form()

    def _open_screen_settings(self):
        subprocess.call(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"])

    def _open_mic_settings(self):
        subprocess.call(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"])

    def _validate_form(self):
        has_key = len(self.api_input.text().strip()) > 5
        
        if getattr(self, 'has_screen', False) and getattr(self, 'has_mic', False) and has_key:
            self.ok_btn.setEnabled(True)
        else:
            self.ok_btn.setEnabled(False)

    def _on_ok_clicked(self):
        self.config["api_key"] = self.api_input.text().strip()
        ConfigManager.save(self.config)
        self.accept()

    def accept(self):
        # АРХ-6: останавливаем polling-таймер при любом закрытии диалога
        self.check_timer.stop()
        super().accept()

    def reject(self):
        # АРХ-6: Escape / закрытие окна — тоже останавливаем таймер
        self.check_timer.stop()
        super().reject()
