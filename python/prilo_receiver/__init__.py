"""Python host for the native Prilo Windows receiver."""

import ctypes
import json
import sys
from pathlib import Path
from threading import RLock

__all__ = ["Receiver"]
_lock = RLock()
_library = None
_active_receiver = None


def _native():
    global _library
    if sys.platform != "win32":
        raise OSError("Prilo Receiver runs on Windows.")
    if _library is None:
        library = ctypes.CDLL(str(Path(__file__).with_name("prilo_receiver.dll")))
        for name in ("PriloStart", "PriloNewPairingCode", "PriloConnectionDetails"):
            function = getattr(library, name)
            function.argtypes = []
            function.restype = ctypes.c_void_p
        library.PriloStop.argtypes = []
        library.PriloStop.restype = None
        library.PriloFree.argtypes = [ctypes.c_void_p]
        library.PriloFree.restype = None
        _library = library
    return _library


def _read(library, name, field="code"):
    pointer = getattr(library, name)()
    if not pointer:
        raise RuntimeError("Prilo Receiver returned no result.")
    try:
        result = json.loads(ctypes.string_at(pointer))
    finally:
        library.PriloFree(pointer)
    if "error" in result:
        raise RuntimeError(result["error"])
    return result[field], result


class Receiver:
    """Run one receiver in the current Windows desktop session."""

    def __init__(self):
        self._running = False
        self.pairing_code = None
        self.version = ""

    def start(self):
        """Start the receiver and return its one-time pairing code."""
        global _active_receiver
        with _lock:
            if _active_receiver is not None:
                raise RuntimeError("A Prilo Receiver is already running in this Python process.")
            library = _native()
            code, raw = _read(library, "PriloStart")
            self._running = True
            _active_receiver = self
            self.pairing_code = code
            self.version = raw.get("version", "")
            return code

    def new_pairing_code(self):
        with _lock:
            if not self._running:
                raise RuntimeError("Prilo Receiver is not running.")
            self.pairing_code, _ = _read(_native(), "PriloNewPairingCode")
            return self.pairing_code

    def connection_details(self):
        """Return local setup details, including the private access code."""
        with _lock:
            if not self._running:
                raise RuntimeError("Prilo Receiver is not running.")
            details, _ = _read(_native(), "PriloConnectionDetails", "details")
            return details

    def close(self):
        global _active_receiver
        with _lock:
            if self._running:
                _native().PriloStop()
                self._running = False
                _active_receiver = None
                self.pairing_code = None
                self.version = ""

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *_exception):
        self.close()
