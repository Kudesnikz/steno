import os
import copy
from PyQt6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QTabWidget, QWidget, 
    QLabel, QLineEdit, QPushButton, QComboBox, QCheckBox, 
    QListWidget, QPlainTextEdit, QFileDialog, QDialogButtonBox, QMessageBox, QSplitter
)
from PyQt6.QtCore import Qt

from app.core.config import ConfigManager, VIDEO_QUALITY_PRESETS, AI_MODELS
from app.__version__ import __version__

class SettingsDialog(QDialog):
    def __init__(self, config, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Настройки")
        self.resize(700, 500)
        self.config = copy.deepcopy(config)
        self.current_agent_idx = -1

        self._apply_macos_styles()

        layout = QVBoxLayout(self)
        
        self.tabs = QTabWidget()
        layout.addWidget(self.tabs)
        
        self.setup_general_tab()
        self.setup_agents_tab()
        
        button_box = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        button_box.accepted.connect(self.accept)
        button_box.rejected.connect(self.reject)
        layout.addWidget(button_box)

    def _apply_macos_styles(self):
        self.setStyleSheet("""
            QDialog {
                background-color: #f5f5f7;
            }
            QLabel {
                color: #1d1d1f;
                font-size: 13px;
                font-weight: 500;
                margin-top: 4px;
            }
            QLineEdit, QPlainTextEdit {
                border: 1px solid #d2d2d7;
                border-radius: 6px;
                padding: 6px 8px;
                background-color: #ffffff;
                color: #1d1d1f;
                font-size: 13px;
                selection-background-color: #007aff;
            }
            QLineEdit:focus, QPlainTextEdit:focus {
                border: 2px solid #007aff;
                padding: 5px 7px; /* компенсируем толщину бордера */
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
            QComboBox {
                border: 1px solid #d2d2d7;
                border-radius: 6px;
                padding: 4px 24px 4px 10px;
                background-color: #ffffff;
                color: #1d1d1f;
                font-size: 13px;
            }
            QComboBox:hover {
                border-color: #c6c6c8;
            }
            QComboBox::drop-down {
                border: none;
                width: 24px;
            }
            QTabWidget::pane {
                border: 1px solid #d2d2d7;
                border-radius: 8px;
                background-color: #ffffff;
                margin-top: -1px;
            }
            QTabWidget::tab-bar {
                alignment: center;
            }
            QTabBar::tab {
                background: #f5f5f7;
                border: 1px solid #d2d2d7;
                padding: 6px 20px;
                color: #1d1d1f;
                font-size: 13px;
                margin-bottom: -1px;
            }
            QTabBar::tab:selected {
                background: #ffffff;
                font-weight: 600;
                border-bottom-color: #ffffff;
            }
            QTabBar::tab:first {
                border-top-left-radius: 6px;
            }
            QTabBar::tab:last {
                border-top-right-radius: 6px;
            }
            QTabBar::tab:middle {
                border-left: none;
                border-right: none;
            }
            QListWidget {
                border: 1px solid #d2d2d7;
                border-radius: 6px;
                background-color: #ffffff;
                outline: 0;
            }
            QListWidget::item {
                height: 32px;
                padding-left: 10px;
                border-radius: 4px;
                margin: 4px 6px;
                color: #1d1d1f;
            }
            QListWidget::item:hover {
                background-color: #f5f5f7;
            }
            QListWidget::item:selected {
                background-color: #007aff;
                color: white;
            }
            QSplitter::handle {
                background-color: transparent;
            }
        """)
        
    def setup_general_tab(self):
        tab = QWidget()
        layout = QVBoxLayout(tab)
        
        # API Key
        self.api_key_input = QLineEdit(self.config.get("api_key", ""))
        self.api_key_input.setEchoMode(QLineEdit.EchoMode.PasswordEchoOnEdit)
        api_key_label = QLabel('Google API Key: (<a href="https://aistudio.google.com/u/1/api-keys" style="color: #007aff; text-decoration: none;">Get API key (VPN required)</a>)')
        api_key_label.setOpenExternalLinks(True)
        layout.addWidget(api_key_label)
        layout.addWidget(self.api_key_input)
        
        # Base URL
        self.base_url_input = QLineEdit(self.config.get("base_url", ""))
        layout.addWidget(QLabel("Base URL:"))
        layout.addWidget(self.base_url_input)
        
        # Save Dir
        save_layout = QHBoxLayout()
        self.save_dir_input = QLineEdit(self.config.get("save_dir", ""))
        browse_btn = QPushButton("Обзор...")
        browse_btn.clicked.connect(self.browse_save_dir)
        save_layout.addWidget(self.save_dir_input)
        save_layout.addWidget(browse_btn)
        layout.addWidget(QLabel("Папка для сохранения:"))
        layout.addLayout(save_layout)
        
        # Quality & Model
        combo_layout = QHBoxLayout()
        
        v_layout = QVBoxLayout()
        self.quality_combo = QComboBox()
        self.quality_combo.addItems(list(VIDEO_QUALITY_PRESETS.keys()))
        self.quality_combo.setCurrentText(self.config.get("video_quality", "Medium"))
        v_layout.addWidget(QLabel("Качество видео:"))
        v_layout.addWidget(self.quality_combo)
        combo_layout.addLayout(v_layout)
        
        m_layout = QVBoxLayout()
        self.model_combo = QComboBox()
        self.model_combo.addItems(AI_MODELS)
        self.model_combo.setCurrentText(self.config.get("model_name", AI_MODELS[0]))
        m_layout.addWidget(QLabel("AI Model:"))
        m_layout.addWidget(self.model_combo)
        combo_layout.addLayout(m_layout)
        
        layout.addLayout(combo_layout)
        
        # Recording Time Checkbox
        self.show_time_checkbox = QCheckBox("Отображать время записи")
        self.show_time_checkbox.setChecked(self.config.get("show_recording_time", True))
        layout.addWidget(self.show_time_checkbox)
        
        layout.addStretch()
        
        # Дополнительная информация (Версия и ссылки)
        info_layout = QVBoxLayout()
        info_layout.setSpacing(4)
        
        version_label = QLabel(f"Версия приложения: {__version__}")
        version_label.setStyleSheet("color: #8e8e93; font-size: 11px;")
        info_layout.addWidget(version_label)
        
        made_by_label = QLabel('<a href="https://github.com/Kudesnikz/steno" style="color: #007aff; text-decoration: none;">Made by Sergey Galay</a>')
        made_by_label.setOpenExternalLinks(True)
        made_by_label.setStyleSheet("font-size: 11px;")
        info_layout.addWidget(made_by_label)
        
        layout.addLayout(info_layout)
        
        self.tabs.addTab(tab, "Общие")
        
    def browse_save_dir(self):
        dir_path = QFileDialog.getExistingDirectory(self, "Выберите папку", self.save_dir_input.text())
        if dir_path:
            self.save_dir_input.setText(dir_path)
            
    def setup_agents_tab(self):
        tab = QWidget()
        layout = QHBoxLayout(tab)
        
        splitter = QSplitter(Qt.Orientation.Horizontal)
        
        # Left side (list + buttons)
        left_widget = QWidget()
        left_layout = QVBoxLayout(left_widget)
        left_layout.setContentsMargins(0,0,0,0)
        
        self.agents_list = QListWidget()
        self.agents_list.currentRowChanged.connect(self.on_agent_selected)
        left_layout.addWidget(self.agents_list)
        
        btn_layout = QHBoxLayout()
        add_btn = QPushButton("+")
        add_btn.clicked.connect(self.add_agent)
        del_btn = QPushButton("-")
        del_btn.clicked.connect(self.delete_agent)
        btn_layout.addWidget(add_btn)
        btn_layout.addWidget(del_btn)
        left_layout.addLayout(btn_layout)
        
        # Right side (form)
        right_widget = QWidget()
        self.right_layout = QVBoxLayout(right_widget)
        self.right_layout.setContentsMargins(0,0,0,0)
        
        self.agent_id_input = QLineEdit()
        self.agent_id_input.textChanged.connect(self.save_current_agent)
        self.right_layout.addWidget(QLabel("ID (системный):"))
        self.right_layout.addWidget(self.agent_id_input)
        
        self.agent_name_input = QLineEdit()
        self.agent_name_input.textChanged.connect(self.save_current_agent)
        self.right_layout.addWidget(QLabel("Название:"))
        self.right_layout.addWidget(self.agent_name_input)
        
        self.agent_prompt_input = QPlainTextEdit()
        self.agent_prompt_input.textChanged.connect(self.save_current_agent)
        self.right_layout.addWidget(QLabel("Промпт:"))
        self.right_layout.addWidget(self.agent_prompt_input)
        
        splitter.addWidget(left_widget)
        splitter.addWidget(right_widget)
        splitter.setSizes([200, 450])
        
        layout.addWidget(splitter)
        self.tabs.addTab(tab, "Агенты")
        
        self.populate_agents()
        
    def populate_agents(self):
        self.agents_list.clear()
        for agent in self.config.get("agents", []):
            self.agents_list.addItem(agent.get("name", "Unknown"))
        
        if self.agents_list.count() > 0:
            self.agents_list.setCurrentRow(0)
            
    def on_agent_selected(self, idx):
        self.current_agent_idx = idx
        if idx >= 0 and idx < len(self.config["agents"]):
            agent = self.config["agents"][idx]
            
            # Block signals to avoid triggering save_current_agent during UI update
            self.agent_id_input.blockSignals(True)
            self.agent_name_input.blockSignals(True)
            self.agent_prompt_input.blockSignals(True)
            
            self.agent_id_input.setText(agent.get("id", ""))
            self.agent_name_input.setText(agent.get("name", ""))
            self.agent_prompt_input.setPlainText(agent.get("prompt", ""))
            
            # default agent ID cannot be changed
            self.agent_id_input.setEnabled(agent.get("id") != "default")
            
            self.agent_id_input.blockSignals(False)
            self.agent_name_input.blockSignals(False)
            self.agent_prompt_input.blockSignals(False)
        else:
            self.agent_id_input.clear()
            self.agent_name_input.clear()
            self.agent_prompt_input.clear()

    def save_current_agent(self):
        idx = self.current_agent_idx
        if idx >= 0 and idx < len(self.config["agents"]):
            self.config["agents"][idx]["id"] = self.agent_id_input.text()
            self.config["agents"][idx]["name"] = self.agent_name_input.text()
            self.config["agents"][idx]["prompt"] = self.agent_prompt_input.toPlainText()
            
            # Update list widget text
            item = self.agents_list.item(idx)
            if item:
                item.setText(self.agent_name_input.text())

    def add_agent(self):
        new_agent = {
            "id": f"agent_{len(self.config['agents'])+1}",
            "name": "Новый агент",
            "prompt": ""
        }
        if "agents" not in self.config:
            self.config["agents"] = []
        self.config["agents"].append(new_agent)
        self.populate_agents()
        self.agents_list.setCurrentRow(len(self.config["agents"]) - 1)

    def delete_agent(self):
        idx = self.current_agent_idx
        if idx >= 0 and idx < len(self.config["agents"]):
            agent = self.config["agents"][idx]
            if agent.get("id") == "default":
                QMessageBox.warning(self, "Ошибка", "Нельзя удалить агента по умолчанию.")
                return
            del self.config["agents"][idx]
            self.current_agent_idx = -1
            self.populate_agents()

    def get_updated_config(self):
        self.config["api_key"] = self.api_key_input.text().strip()
        self.config["base_url"] = self.base_url_input.text().strip()
        self.config["save_dir"] = self.save_dir_input.text().strip()
        self.config["video_quality"] = self.quality_combo.currentText()
        self.config["model_name"] = self.model_combo.currentText()
        self.config["show_recording_time"] = self.show_time_checkbox.isChecked()
        
        # Ensure active_agent_id is valid
        active_id = self.config.get("active_agent_id", "default")
        if not any(a.get("id") == active_id for a in self.config.get("agents", [])):
            if self.config.get("agents"):
                self.config["active_agent_id"] = self.config["agents"][0]["id"]
            else:
                self.config["active_agent_id"] = "default"
                
        return self.config
