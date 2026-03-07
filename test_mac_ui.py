import sys
import traceback
try:
    import objc
    from AppKit import NSView, NSWindowStyleMaskFullSizeContentView
    print("Success loading AppKit!")
except Exception as e:
    print("Failed to load AppKit:")
    traceback.print_exc()
