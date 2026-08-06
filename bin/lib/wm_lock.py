#!/usr/bin/env python3
"""wm_lock: the shared with_locked() context manager for a flock-guarded
read-modify-write of a small on-disk JSON store. Used by wm-state.py (its
original home) and bin/lib/pr-eval.py (issue #180)."""
import contextlib
import os

try:
    import fcntl
except ImportError:  # non-POSIX platform; with_locked degrades to best-effort
    fcntl = None


@contextlib.contextmanager
def with_locked(path):
    """Serialize a read-modify-write of a shared store across processes.

    write_json is atomic (os.replace), so no file is ever corrupted, but a
    whole-dict read-modify-write from two processes is last-writer-wins - a
    concurrent watcher fire()-and-ack and a Stop-hook ack can each discard the
    other's key. Holding an exclusive flock on <path>.lock across the entire
    read->modify->write closes that window. Best-effort only on a platform
    without fcntl (fcntl is None): there is no lock to take there, so it
    proceeds without one rather than hard-fail, since the atomic replace still
    prevents corruption. On a POSIX system where fcntl IS available, a
    flock() failure is never silently swallowed - it is re-raised so the
    caller sees a loud, actionable error instead of silently losing the very
    mutual exclusion this function exists to provide (issue #79)."""
    lock_path = path + ".lock"
    fh = None
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        fh = open(lock_path, "w")
        if fcntl is not None:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            except OSError as e:
                raise OSError(
                    "with_locked: failed to acquire exclusive lock on %s (%s) - if "
                    "WINGMAN_HOME is on a network filesystem, confirm it supports "
                    "advisory (flock) locking" % (lock_path, e)
                ) from e
        yield
    finally:
        if fh is not None:
            if fcntl is not None:
                try:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
            fh.close()
