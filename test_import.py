import sys
import os

try:
    print("Attempting to import qt_app...")
    import qt_app
    print("Import successful.")
except ImportError as e:
    print(f"Import failed: {e}")
    sys.exit(1)
except Exception as e:
    print(f"An error occurred: {e}")
    sys.exit(1)
