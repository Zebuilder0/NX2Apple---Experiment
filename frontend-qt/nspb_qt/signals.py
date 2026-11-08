"""Signals emitted from worker threads.

A build, an archive, an install or a device scan ends on its own thread and tells the window through the model's
signals. When the player closes the app while one runs, the model is gone before the thread ends, and PySide raises
RuntimeError ("Signal source has been deleted") on that thread. Nothing is left to tell then, so the emit is dropped.
"""
from __future__ import annotations


def emit_safely(signal, *args) -> bool:
    """Emit `signal`; False when its object is already deleted (the app is closing)."""
    try:
        signal.emit(*args)
        return True
    except RuntimeError:
        return False
