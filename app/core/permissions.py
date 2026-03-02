import logging

logger = logging.getLogger("Steno.Permissions")

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

class PermissionManager:
    @staticmethod
    def check_all():
        if not HAS_PYOBJC:
            return
            
        logger.info("Checking system permissions...")
        
        # Check Microphone Permission
        mic_status = AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)
        if mic_status != AVAuthorizationStatusAuthorized:
            AVCaptureDevice.requestAccessForMediaType_completionHandler_(
                AVMediaTypeAudio, 
                lambda granted: logger.info(f"Mic permission granted: {granted}")
            )

        # Check Screen Capture Permission
        if not CGPreflightScreenCaptureAccess():
            CGRequestScreenCaptureAccess()

        # Check Notifications Permission
        center = UNUserNotificationCenter.currentNotificationCenter()
        options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
        center.requestAuthorizationWithOptions_completionHandler_(
            options, 
            lambda granted, error: logger.info(f"Notifications permission granted: {granted}")
        )
