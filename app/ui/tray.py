import os
import logging
from PyQt6.QtWidgets import QSystemTrayIcon, QMenu
from PyQt6.QtGui import QIcon, QAction

logger = logging.getLogger("Steno.Tray")

try:
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

class SystemTrayManager:
    def __init__(self, app_logic, icons, config):
        self.app = app_logic
        self.icons = icons
        self.config = config
        
        # PyQt Tray
        self.tray = QSystemTrayIcon()
        self.tray.setIcon(self.icons["idle"])
        self.tray.setToolTip("Steno")
        
        self.menu = QMenu()
        self.recording_action = QAction("Start Recording", self.app)
        self.recording_action.triggered.connect(self.app.toggle_recording)
        self.menu.addAction(self.recording_action)

        self.menu.addSeparator()
        self.ui_action = self.menu.addAction("Show UI", self.app.show_main_window)
        self.settings_action = self.menu.addAction("Settings...", self.app.open_settings)
        self.menu.addSeparator()
        self.folder_action = self.menu.addAction("Open Output Folder", self.app.open_folder)
        self.menu.addSeparator()
        self.quit_action = self.menu.addAction("Quit", self.app.quit_app)
        
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.app.on_tray_activated)
        
        # Mac Native Tray
        self.mac_tray_helper = None
        self.timer_item = None
        self.ns_icons = {}
        
        if HAS_PYOBJC:
            self.mac_tray_helper = MacTrayHelper.alloc().init()
            self.mac_tray_helper.app_ref = self.app
            
            self.timer_item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSVariableStatusItemLength)
            self.timer_item.retain()
            
            # Since we can't easily extract path from QIcon, we will load NSImage directly in setup
    
    def setup_mac_icons(self, idle_path, recording_path, processing_path, error_path):
        if not HAS_PYOBJC:
            return
            
        def _load_ns_image(path):
            from AppKit import NSImage
            img = NSImage.alloc().initWithContentsOfFile_(path)
            if img:
                img.setSize_((18, 18))
                img.setTemplate_(True)
            return img
            
        self.ns_icons = {
            "idle": _load_ns_image(idle_path),
            "recording": _load_ns_image(recording_path),
            "processing": _load_ns_image(processing_path),
            "error": _load_ns_image(error_path)
        }
        
        if self.timer_item:
            self.timer_item.button().setImage_(self.ns_icons["idle"])
            self.timer_item.button().setImagePosition_(2) # NSImageLeft
            self.update_native_menu()

    def show(self):
        if not HAS_PYOBJC:
            self.tray.show()
            
    def update_native_menu(self):
        if not HAS_PYOBJC or not self.timer_item: return
        from AppKit import NSMenu, NSMenuItem
        
        ns_menu = NSMenu.alloc().init()
        is_onboarding = getattr(self.app, 'is_onboarding_active', False)
        
        title = "Stop Recording" if getattr(self.app, 'is_recording', False) else "Start Recording"
        i_rec = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, "toggleRecording:", "")
        i_rec.setTarget_(self.mac_tray_helper)
        if is_onboarding:
            i_rec.setEnabled_(False)
        ns_menu.addItem_(i_rec)
        
        ns_menu.addItem_(NSMenuItem.separatorItem())
        
        i_ui = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Show UI", "showMainWindow:", "")
        i_ui.setTarget_(self.mac_tray_helper)
        if is_onboarding:
            i_ui.setEnabled_(False)
        ns_menu.addItem_(i_ui)
        
        i_set = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Settings...", "openSettings:", "")
        i_set.setTarget_(self.mac_tray_helper)
        if is_onboarding:
            i_set.setEnabled_(False)
        ns_menu.addItem_(i_set)
        
        ns_menu.addItem_(NSMenuItem.separatorItem())
        
        i_fld = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Open Output Folder", "openFolder:", "")
        i_fld.setTarget_(self.mac_tray_helper)
        if is_onboarding:
            i_fld.setEnabled_(False)
        ns_menu.addItem_(i_fld)
        
        ns_menu.addItem_(NSMenuItem.separatorItem())
        
        i_quit = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Quit", "quitApp:", "")
        i_quit.setTarget_(self.mac_tray_helper)
        ns_menu.addItem_(i_quit)
        
        self.timer_item.setMenu_(ns_menu)

    def set_onboarding_state(self, is_onboarding):
        self.recording_action.setEnabled(not is_onboarding)
        self.ui_action.setEnabled(not is_onboarding)
        self.settings_action.setEnabled(not is_onboarding)
        self.folder_action.setEnabled(not is_onboarding)
        
        if HAS_PYOBJC:
            self.update_native_menu()

    def set_recording_state(self, is_recording, show_recording_time=True):
        if HAS_PYOBJC:
            icon_key = "recording" if is_recording else "idle"
            self.timer_item.button().setImage_(self.ns_icons[icon_key])
            self.update_native_menu()
            if not is_recording or not show_recording_time:
                self.timer_item.button().setTitle_("")
        else:
            self.tray.setIcon(self.icons["recording"] if is_recording else self.icons["idle"])
            
        self.recording_action.setText("Stop Recording" if is_recording else "Start Recording")

    def set_processing_state(self, is_processing):
        self.recording_action.setEnabled(not is_processing)
        icon_key = "processing" if is_processing else "idle"
        
        if HAS_PYOBJC:
            self.timer_item.button().setImage_(self.ns_icons[icon_key])
            self.update_native_menu()
        else:
            self.tray.setIcon(self.icons[icon_key])
            
    def set_error_state(self):
        if HAS_PYOBJC:
            self.timer_item.button().setImage_(self.ns_icons["error"])
            self.timer_item.button().setTitle_("")
            self.update_native_menu()
        else:
            self.tray.setIcon(self.icons["error"])
            
    def set_timer_text(self, text):
        if HAS_PYOBJC and self.timer_item:
            self.timer_item.button().setTitle_(text)
            
    def show_message(self, title, msg):
        self.tray.showMessage(title, msg)
