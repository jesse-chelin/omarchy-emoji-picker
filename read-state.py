#!/usr/bin/python3 -I
"""Read the picker's state file, bounded, and print it on stdout.

QML's FileView reads a whole file into memory with no ceiling, which makes the
state path a hole: it lives in a directory the user can write, and the shell
is a long-lived process. This is the producer-side cap. Nothing larger than
MAX_BYTES ever reaches the QML side, and the picker treats anything it does
get as untrusted regardless.

Every failure prints a JSON object carrying only the reason, and exits 0. A
picker that will not open because its preferences are unreadable is worse than
one that opens with default preferences, so the caller gets a document it can
parse either way; the reason rides along so it can say what happened instead
of silently losing the user's pins. Reasons also go to stderr for the log.

Isolated mode in the shebang (-I) ignores PYTHON* environment variables and
the user site directory, so nothing on the invoking environment can inject
code into this process.
"""

import errno
import json
import os
import stat
import sys

MAX_BYTES = 65536


def refuse(reason, detail=""):
    """Short reason to the caller, full detail to the log.

    The reason is shown in the picker's footer, so it stays a phrase. The
    detail carries the path and the errno, which belong in the shell log and
    not in a status line.
    """
    sys.stderr.write("emoji-picker read-state: %s%s\n"
                     % (reason, ": " + detail if detail else ""))
    # A document, not an error: the caller falls back to defaults and shows
    # the reason rather than pretending an unreadable file was an empty one.
    sys.stdout.write(json.dumps({"rejected": reason[:120]}))
    return 0


def main(argv):
    if len(argv) != 2:
        return refuse("called wrongly", "usage: read-state.py <path>")
    path = argv[1]

    try:
        # O_NOFOLLOW refuses a symlink at the final component, and O_NONBLOCK
        # means a FIFO left at the path fails here rather than hanging the
        # read. Both are properties of the descriptor we then fstat, so there
        # is no window between the check and the read.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        return refuse("no preferences saved yet")
    except OSError as error:
        # O_NOFOLLOW reports ELOOP for a symlink, which is the case worth
        # naming: it is the one an attacker arranges rather than one a user
        # stumbles into.
        if getattr(error, "errno", None) == errno.ELOOP:
            return refuse("it is a symlink, which is never followed", path)
        return refuse("it could not be opened", "%s: %s" % (path, error))

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return refuse("it is not a regular file", path)
        if info.st_uid != os.getuid():
            return refuse("it is owned by another user",
                          "%s: uid %d, not %d" % (path, info.st_uid, os.getuid()))
        if info.st_size > MAX_BYTES:
            # Refused rather than truncated: half a JSON document is not a
            # smaller JSON document, and silently dropping the tail would lose
            # pins without saying so.
            return refuse("it is larger than %d bytes" % MAX_BYTES,
                          "%s: %d bytes" % (path, info.st_size))

        # st_size is a hint, not a guarantee, so the read is capped too.
        raw = os.read(fd, MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return refuse("it grew past %d bytes while being read" % MAX_BYTES, path)
    finally:
        os.close(fd)

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return refuse("it is not valid UTF-8", path)

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
