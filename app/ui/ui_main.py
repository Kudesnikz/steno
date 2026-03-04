import logging
from PyQt6.QtWidgets import (
    QMainWindow, QToolBar, QWidget, QSplitter, QListWidget, QStackedWidget, 
    QSizePolicy, QComboBox, QTextBrowser, QVBoxLayout, QHBoxLayout, QListWidgetItem,
    QPushButton, QButtonGroup, QFrame, QLabel, QApplication
)
from PyQt6.QtCore import Qt, pyqtSignal, QEvent, QSize
from PyQt6.QtGui import QColor, QAction
import qtawesome as qta
import markdown

from app.core.data_manager import SessionManager
from app.core.config import ConfigManager
from app.ui.ui_player import PlayerWidget

logger = logging.getLogger("Steno.MainWindow")

class SessionItemWidget(QWidget):
    delete_confirmed = pyqtSignal(object)
    delete_requested = pyqtSignal(object)
    delete_canceled = pyqtSignal(object)

    def __init__(self, session):
        super().__init__()
        self.session = session
        self.state = 'idle'
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setStyleSheet("background-color: transparent;")

        layout = QHBoxLayout(self)
        layout.setContentsMargins(10, 0, 10, 0)
        
        # Иконка статуса
        self.icon_label = QLabel()
        self.icon_label.setStyleSheet("background: transparent;")
        if session.protocols:
            self.icon_label.setPixmap(qta.icon('fa5s.check-square', color='#34c759').pixmap(16, 16))
        elif session.has_video:
            self.icon_label.setPixmap(qta.icon('fa5s.film', color='#8e8e93').pixmap(16, 16))
        layout.addWidget(self.icon_label)
        
        # Текст
        self.text_label = QLabel(session.display_name)
        self.text_label.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        self.text_label.setStyleSheet("color: #1d1d1f; font-size: 13px; font-weight: 500; background: transparent;")
        layout.addWidget(self.text_label)
        
        # Кнопка корзины (изначально видима)
        self.trash_btn = QPushButton()
        self.trash_btn.setIcon(qta.icon('fa5s.trash', color='#8e8e93'))
        self.trash_btn.setFixedSize(24, 24)
        self.trash_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.trash_btn.setToolTip("Удалить запись")
        self.trash_btn.setStyleSheet("background: transparent; border: none;")
        self.trash_btn.clicked.connect(self.request_delete)
        layout.addWidget(self.trash_btn)
        
        # Кнопка отмены (изначально скрыта)
        self.cancel_btn = QPushButton()
        self.cancel_btn.setIcon(qta.icon('fa5s.times-circle', color='#8e8e93'))
        self.cancel_btn.setFixedSize(24, 24)
        self.cancel_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.cancel_btn.setToolTip("Отменить удаление")
        self.cancel_btn.setStyleSheet("background: transparent; border: none;")
        self.cancel_btn.clicked.connect(self.cancel_delete)
        self.cancel_btn.hide()
        layout.addWidget(self.cancel_btn)
        
        # Кнопка подтверждения удаления (изначально скрыта)
        self.confirm_btn = QPushButton()
        self.confirm_btn.setIcon(qta.icon('fa5s.trash', color='#ff3b30'))
        self.confirm_btn.setFixedSize(24, 24)
        self.confirm_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.confirm_btn.setToolTip("Подтвердить удаление")
        self.confirm_btn.setStyleSheet("background: transparent; border: none;")
        self.confirm_btn.clicked.connect(self.confirm_action)
        self.confirm_btn.hide()
        layout.addWidget(self.confirm_btn)

    def set_selected(self, is_selected):
        # Поскольку цвет выделения #F7E391 (светло-желтый), оставляем текст и иконки темными
        self.text_label.setStyleSheet("color: #1d1d1f; font-size: 13px; font-weight: 500; background: transparent;")
        self.trash_btn.setIcon(qta.icon('fa5s.trash', color='#8e8e93'))

    def request_delete(self):
        self.state = 'confirming'
        self.trash_btn.hide()
        self.cancel_btn.show()
        self.confirm_btn.show()
        self.delete_requested.emit(self)

    def cancel_delete(self):
        if self.state != 'idle':
            self.state = 'idle'
            self.cancel_btn.hide()
            self.confirm_btn.hide()
            self.trash_btn.show()
            self.delete_canceled.emit(self)

    def reset_state(self):
        self.cancel_delete()

    def confirm_action(self):
        self.delete_confirmed.emit(self.session)



class DraggableToolbar(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self._drag_pos = None

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._drag_pos = event.globalPosition().toPoint()
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._drag_pos:
            delta = event.globalPosition().toPoint() - self._drag_pos
            self.parent().move(self.parent().pos() + delta)
            self._drag_pos = event.globalPosition().toPoint()
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        self._drag_pos = None
        super().mouseReleaseEvent(event)


class MainWindow(QMainWindow):
    # Сигналы
    open_settings_signal = pyqtSignal()
    start_recording_signal = pyqtSignal()
    stop_recording_signal = pyqtSignal()
    generate_signal = pyqtSignal(str, str) # session_base_path, agent_id

    def __init__(self, config):
        super().__init__()
        self.config = config
        self.session_manager = SessionManager(self.config.get("save_dir", ""))
        self.current_sessions = []
        self.is_recording = False
        self.confirming_widget = None
        
        # Перехватываем глобальные события мыши для отмены удаления
        QApplication.instance().installEventFilter(self)
        
        self.setWindowFlag(Qt.WindowType.FramelessWindowHint)
        self.setWindowTitle("")
        self.resize(900, 600)
        
        # Нативный тулбар в macOS
        # self.setUnifiedTitleAndToolBarOnMac(True)
        
        self.setup_toolbar()
        self.setup_ui()
        
        self.refresh_data()

    def eventFilter(self, obj, event):
        if event.type() in (QEvent.Type.MouseButtonPress, QEvent.Type.TouchBegin):
            if self.confirming_widget:
                from PyQt6.QtWidgets import QWidget
                if isinstance(obj, QWidget):
                    # Если клик по кнопкам активного виджета подтверждения — пропускаем
                    current_obj = obj
                    is_btn = False
                    while current_obj:
                        if current_obj in (self.confirming_widget.confirm_btn,
                                           self.confirming_widget.cancel_btn,
                                           self.confirming_widget.trash_btn):
                            is_btn = True
                            break
                        current_obj = current_obj.parent()

                    if is_btn:
                        pass
                    else:
                        self.confirming_widget.reset_state()
                        self.confirming_widget = None
        elif event.type() == QEvent.Type.WindowDeactivate:
            if self.confirming_widget:
                self.confirming_widget.reset_state()
                self.confirming_widget = None
                
        return super().eventFilter(obj, event)

    def showEvent(self, event):
        super().showEvent(event)
        # Настройка нативного тулбара macOS, чтобы он был на одном уровне со "светофором"
        try:
            import objc
            from AppKit import NSView, NSWindowStyleMaskFullSizeContentView
            win_id = int(self.winId())
            ns_view = objc.objc_object(c_void_p=win_id)
            ns_window = ns_view.window()
            if ns_window:
                # NSWindowToolbarStyleUnified = 3
                if hasattr(ns_window, 'setToolbarStyle_'):
                    ns_window.setToolbarStyle_(3)
                ns_window.setTitlebarAppearsTransparent_(True)
                # Позволяет контенту залезать под заголовок (необходимо для современного вида)
                from AppKit import NSWindowStyleMaskTitled, NSWindowStyleMaskClosable, NSWindowStyleMaskMiniaturizable, NSWindowStyleMaskResizable
                ns_window.setStyleMask_(ns_window.styleMask() | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView)
                ns_window.setTitleVisibility_(1)
                # Разрешаем перетаскивание окна за любую пустую область
                ns_window.setMovableByWindowBackground_(True)
        except Exception as e:
            logger.warning(f"Failed to set modern macOS toolbar style: {e}")


    def resizeEvent(self, event):
        super().resizeEvent(event)
        if hasattr(self, 'toolbar_widget'):
            self.toolbar_widget.setFixedWidth(self.width())

    def setup_toolbar(self):
        # Используем DraggableToolbar для перетаскивания окна
        # Важно: создаем как ребенка self (окна), чтобы позиционировать абсолютно
        self.toolbar_widget = DraggableToolbar(self)
        self.toolbar_widget.setFixedHeight(28) # Идеальная высота для выравнивания со светофором (центр y=14)
        self.toolbar_widget.move(0, 0)
        self.toolbar_widget.setStyleSheet("background-color: transparent;")
        
        self.toolbar_layout = QHBoxLayout(self.toolbar_widget)
        # Отступ слева 80px под светофор
        self.toolbar_layout.setContentsMargins(80, 0, 16, 0)
        self.toolbar_layout.setSpacing(10)
        
        # Кнопка Record
        self.record_btn = QPushButton(" Record")
        self.record_btn.setFixedHeight(20) # Уменьшаем высоту кнопки под 28px
        self.record_btn.setIcon(qta.icon('fa5s.circle', color='#ff3b30'))
        self.record_btn.clicked.connect(self.toggle_recording)
        self.toolbar_layout.addWidget(self.record_btn)
        
        # Центральный Spacer
        self.toolbar_layout.addStretch()
        
        # Агенты
        self.agent_combo = QComboBox()
        self.update_agents_combo()
        self.toolbar_layout.addWidget(self.agent_combo)
        
        # Generate
        self.generate_btn = QPushButton(" Generate")
        self.generate_btn.setIcon(qta.icon('fa5s.bolt', color='#f5a623'))
        self.generate_btn.clicked.connect(self.on_generate_clicked)
        self.toolbar_layout.addWidget(self.generate_btn)
        
        # Settings
        self.settings_btn = QPushButton()
        self.settings_btn.setIcon(qta.icon('fa5s.cog', color='#555'))
        self.settings_btn.clicked.connect(self.open_settings_signal.emit)
        self.toolbar_layout.addWidget(self.settings_btn)

    def setup_ui(self):
        self.splitter = QSplitter(Qt.Orientation.Horizontal)
        self.splitter.setStyleSheet("""
            QSplitter {
                border: none;
            }
            QSplitter::handle {
                background-color: transparent;
                width: 0px;
            }
        """)
        
        # Левая часть
        left_panel = QWidget()
        left_panel.setStyleSheet("background-color: #f5f5f7;")
        left_layout = QVBoxLayout(left_panel)
        left_layout.setContentsMargins(0, 8, 0, 8)
        
        self.sessions_list = QListWidget()
        self.sessions_list.currentRowChanged.connect(self.on_session_selected)
        self.sessions_list.setStyleSheet("""
            QListWidget {
                border: none;
                background-color: transparent;
                outline: 0;
            }
            QListWidget::item {
                height: 38px;
                padding-left: 10px;
                border-radius: 6px;
                margin: 2px 10px;
                color: #1d1d1f;
                font-size: 13px;
                font-weight: 500;
            }
            QListWidget::item:hover {
                background-color: #e5e5ea;
            }
            QListWidget::item:selected {
                background-color: #F7E391;
                color: #1d1d1f;
            }
        """)
        left_layout.addWidget(self.sessions_list)
        self.splitter.addWidget(left_panel)
        
        # Правая часть
        right_panel = QWidget()
        right_panel.setStyleSheet("background-color: #ffffff;")
        right_layout = QVBoxLayout(right_panel)
        right_layout.setContentsMargins(0, 0, 0, 0)
        right_layout.setSpacing(0)
        
        # Контейнер для вкладок (Segmented Control)
        self.tabs_wrapper = QWidget()
        self.tabs_wrapper.setStyleSheet("background-color: transparent;")
        tabs_wrapper_layout = QHBoxLayout(self.tabs_wrapper)
        tabs_wrapper_layout.setContentsMargins(0, 10, 0, 10)
        tabs_wrapper_layout.setAlignment(Qt.AlignmentFlag.AlignCenter)
        
        self.tabs_container = QFrame()
        self.tabs_layout = QHBoxLayout(self.tabs_container)
        self.tabs_layout.setContentsMargins(2, 2, 2, 2)
        self.tabs_layout.setSpacing(2)
        self.tabs_container.setStyleSheet("""
            QFrame {
                background-color: rgba(0, 0, 0, 0.06);
                border-radius: 6px;
                border: 1px solid rgba(0, 0, 0, 0.05);
            }
            QPushButton {
                background-color: transparent;
                border: none;
                border-radius: 5px;
                padding: 4px 14px;
                color: #1d1d1f;
                font-size: 13px;
                font-weight: 500;
            }
            QPushButton:checked {
                background-color: #ffffff;
                border: 1px solid rgba(0, 0, 0, 0.1);
            }
        """)
        
        self.tabs_group = QButtonGroup(self)
        self.tabs_group.buttonClicked.connect(self.on_tab_clicked)
        
        tabs_wrapper_layout.addWidget(self.tabs_container)
        self.tabs_wrapper.hide()
        right_layout.addWidget(self.tabs_wrapper)
        
        self.stacked_widget = QStackedWidget()
        self.stacked_widget.setStyleSheet("background-color: transparent; border: none;")
        right_layout.addWidget(self.stacked_widget)
        
        self.splitter.addWidget(right_panel)
        
        self.splitter.setSizes([250, 650])
        
        # Оборачиваем тулбар и сплиттер в центральный виджет
        self.central_wrapper = QWidget()
        self.central_wrapper.setStyleSheet("background-color: #f5f5f7;")
        wrapper_layout = QVBoxLayout(self.central_wrapper)
        wrapper_layout.setContentsMargins(0, 0, 0, 0)
        wrapper_layout.setSpacing(0)
        
        # wrapper_layout.addWidget(self.toolbar_widget) # Тулбар теперь лежит поверх окна
        
        # Добавляем минимальный верхний отступ (был 28, уменьшаем чтобы не было "пустой строки")
        wrapper_layout.setContentsMargins(0, 0, 0, 0)
        wrapper_layout.addWidget(self.splitter)
        
        self.setCentralWidget(self.central_wrapper)
        
        # Убеждаемся, что тулбар находится поверх центрального виджета
        if hasattr(self, 'toolbar_widget'):
            self.toolbar_widget.raise_()

    def update_agents_combo(self):
        self.agent_combo.clear()
        agents = self.config.get("agents", [])
        for agent in agents:
            self.agent_combo.addItem(agent.get("name", "Unknown"), agent.get("id"))
            
        active_id = self.config.get("active_agent_id", "default")
        idx = self.agent_combo.findData(active_id)
        if idx >= 0:
            self.agent_combo.setCurrentIndex(idx)

    def update_config(self, new_config):
        self.config = new_config
        self.session_manager.save_dir = self.config.get("save_dir", "")
        self.update_agents_combo()
        self.refresh_data()

    def set_recording_state(self, is_recording):
        self.is_recording = is_recording
        if is_recording:
            self.record_btn.setIcon(qta.icon('fa5s.stop', color='gray'))
            self.record_btn.setText(" Stop")
        else:
            self.record_btn.setIcon(qta.icon('fa5s.circle', color='#ff3b30'))
            self.record_btn.setText(" Record")

    def set_generating_state(self, is_generating):
        self.generate_btn.setEnabled(not is_generating)
        if is_generating:
            self.generate_btn.setIcon(qta.icon('fa5s.hourglass-half', color='gray'))
            self.generate_btn.setText(" Обработка...")
        else:
            self.generate_btn.setIcon(qta.icon('fa5s.bolt', color='#f5a623'))
            self.generate_btn.setText(" Generate")

    def toggle_recording(self):
        if self.is_recording:
            self.stop_recording_signal.emit()
        else:
            self.start_recording_signal.emit()

    def refresh_data(self):
        self.current_sessions = self.session_manager.scan_sessions()
        
        # Сохраним текущий выбор
        selected_row = self.sessions_list.currentRow()
        
        self.sessions_list.clear()
        
        for session in self.current_sessions:
            item = QListWidgetItem()
            item.setData(Qt.ItemDataRole.UserRole, session.base_path)
            # Используем размер по умолчанию, чтобы не сбить CSS
            item.setSizeHint(QSize(0, 38))
            self.sessions_list.addItem(item)
            
            widget = SessionItemWidget(session)
            widget.delete_requested.connect(self.on_delete_requested)
            widget.delete_canceled.connect(self.on_delete_canceled)
            widget.delete_confirmed.connect(self.on_delete_confirmed)
            
            self.sessions_list.setItemWidget(item, widget)
            
        # Восстановим выбор
        if selected_row >= 0 and selected_row < self.sessions_list.count():
            self.sessions_list.setCurrentRow(selected_row)
        elif self.sessions_list.count() > 0:
            self.sessions_list.setCurrentRow(0)

    def on_delete_requested(self, widget):
        if self.confirming_widget and self.confirming_widget != widget:
            self.confirming_widget.reset_state()
        self.confirming_widget = widget

    def on_delete_canceled(self, widget):
        if self.confirming_widget == widget:
            self.confirming_widget = None

    def on_delete_confirmed(self, session):
        self.confirming_widget = None
        
        # Если удаляемая сессия сейчас открыта в плеере, остановим его
        current_row = self.sessions_list.currentRow()
        if current_row >= 0 and self.current_sessions[current_row].base_name == session.base_name:
            for i in range(self.stacked_widget.count()):
                widget = self.stacked_widget.widget(i)
                if hasattr(widget, 'engine'):
                    widget.engine.stop()
                    
        self.session_manager.delete_session(session.base_name)
        self.refresh_data()

    def on_session_selected(self, idx):
        # Обновляем визуальное состояние выделения в кастомных виджетах
        for i in range(self.sessions_list.count()):
            item = self.sessions_list.item(i)
            widget = self.sessions_list.itemWidget(item)
            if isinstance(widget, SessionItemWidget):
                widget.set_selected(i == idx)

        # Остановка плеера, чтобы освободить ресурсы (ffmpeg и аудио-устройства)
        for i in range(self.stacked_widget.count()):
            widget = self.stacked_widget.widget(i)
            if isinstance(widget, PlayerWidget):
                widget.engine.stop()
                
        # Очистка StackedWidget
        while self.stacked_widget.count() > 0:
            widget = self.stacked_widget.widget(0)
            self.stacked_widget.removeWidget(widget)
            widget.deleteLater()
            
        # Очистка кнопок вкладок
        while self.tabs_layout.count() > 0:
            item = self.tabs_layout.takeAt(0)
            if item.widget():
                self.tabs_group.removeButton(item.widget())
                item.widget().deleteLater()
                
        if idx < 0 or idx >= len(self.current_sessions):
            self.tabs_wrapper.hide()
            return
            
        session = self.current_sessions[idx]
        
        if not session.protocols and not session.has_video:
            browser = QTextBrowser()
            browser.setHtml("<h2 style='color:gray; text-align:center; margin-top:50px;'>Нет данных для отображения</h2>")
            self.stacked_widget.addWidget(browser)
            self.tabs_wrapper.hide()
            return
            
        self.tabs_wrapper.show()
        
        tab_index = 0
        def add_tab(widget, name):
            nonlocal tab_index
            self.stacked_widget.addWidget(widget)
            
            btn = QPushButton(name)
            btn.setCheckable(True)
            if tab_index == 0:
                btn.setChecked(True)
            
            self.tabs_group.addButton(btn, tab_index)
            self.tabs_layout.addWidget(btn)
            tab_index += 1

        # Добавляем вкладки с протоколами
        for agent_id, file_path in session.protocols.items():
            agent = ConfigManager.get_agent_by_id(self.config, agent_id)
            tab_name = agent.get("name") if agent else agent_id
            
            browser = QTextBrowser()
            browser.setStyleSheet("border: none; background-color: transparent;")
            
            try:
                with open(file_path, "r", encoding="utf-8") as f:
                    text = f.read()
                    
                html = markdown.markdown(text, extensions=['tables', 'fenced_code'])
                
                # Читаем текущую тему (теперь всегда светлая, но оставим логику для надежности)
                is_dark = False # Форсируем светлую тему для контента
                bg_color = "#f9f9f9"
                text_color = "#1d1d1f"
                border_color = "#d2d2d7"
                
                styled_html = f"""
                <html><head><style>
                    body {{ 
                        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif; 
                        color: {text_color};
                        line-height: 1.8;
                        font-size: 15px;
                        margin: 0 auto;
                        padding: 20px 40px;
                        max-width: 850px;
                    }}
                    h1, h2, h3, h4, h5, h6 {{
                        color: #1d1d1f;
                        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
                        font-weight: 600;
                        margin-top: 1.5em;
                        margin-bottom: 0.5em;
                        line-height: 1.3;
                    }}
                    h1 {{ font-size: 28px; border-bottom: 1px solid {border_color}; padding-bottom: 0.3em; }}
                    h2 {{ font-size: 22px; border-bottom: 1px solid {border_color}; padding-bottom: 0.3em; }}
                    h3 {{ font-size: 18px; }}
                    p {{ margin-bottom: 1.2em; }}
                    ul, ol {{ margin-bottom: 1.2em; padding-left: 24px; }}
                    li {{ margin-bottom: 0.4em; }}
                    table {{ 
                        border-collapse: collapse; 
                        width: 100%; 
                        margin-top: 20px; 
                        margin-bottom: 24px; 
                        border-radius: 8px;
                        overflow: hidden;
                    }}
                    th, td {{ 
                        border: 1px solid {border_color}; 
                        padding: 10px 14px; 
                        text-align: left; 
                    }}
                    th {{ 
                        background-color: {bg_color}; 
                        font-weight: 600;
                    }}
                    code {{
                        background-color: #f5f5f7;
                        padding: 3px 6px;
                        border-radius: 6px;
                        font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, Courier, monospace;
                        font-size: 0.9em;
                        color: #ff3b30;
                    }}
                    pre {{
                        background-color: #f5f5f7;
                        border-radius: 8px;
                        padding: 16px;
                        overflow-x: auto;
                        margin-bottom: 1.5em;
                        border: 1px solid #e5e5ea;
                    }}
                    pre code {{
                        background-color: transparent;
                        padding: 0;
                        color: #1d1d1f;
                        border-radius: 0;
                    }}
                    blockquote {{
                        border-left: 4px solid #007aff;
                        margin: 0 0 1.5em 0;
                        padding-left: 16px;
                        color: #6e6e73;
                        font-style: italic;
                    }}
                </style></head><body>
                {html}
                </body></html>
                """
                browser.setHtml(styled_html)
            except Exception as e:
                browser.setHtml(f"<h2>Ошибка чтения файла</h2><p>{e}</p>")
                
            add_tab(browser, tab_name)
            
        # Добавляем вкладку плеера в конец
        if session.has_video:
            player_widget = PlayerWidget(session, initial_config=self.config)
            player_widget.config_changed.connect(self.on_player_config_changed)
            add_tab(player_widget, "▶️ Плеер")

        if self.stacked_widget.count() > 0:
            self.stacked_widget.setCurrentIndex(0)
            
        if tab_index <= 1:
            self.tabs_wrapper.hide()

    def on_player_config_changed(self, key, value):
        self.config[key] = value
        ConfigManager.save(self.config)

    def on_tab_clicked(self, button):
        idx = self.tabs_group.id(button)
        if idx >= 0:
            self.stacked_widget.setCurrentIndex(idx)

    def on_generate_clicked(self):
        idx = self.sessions_list.currentRow()
        if idx < 0 or idx >= len(self.current_sessions):
            return
            
        session = self.current_sessions[idx]
        agent_id = self.agent_combo.currentData()
        
        if not agent_id:
            return
            
        self.generate_signal.emit(session.base_path, agent_id)

    def closeEvent(self, event):
        # Останавливаем плеер перед закрытием окна, если он запущен
        from app.ui.ui_player import PlayerWidget
        for i in range(self.stacked_widget.count()):
            widget = self.stacked_widget.widget(i)
            if isinstance(widget, PlayerWidget):
                widget.engine.stop()
        super().closeEvent(event)

