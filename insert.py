#!/usr/bin/python3 -I
"""Clipboard and paste helper.

  insert.py probe           print 1 if pasting is possible, 0 if not
  insert.py copy  <text>    leave the text on the clipboard
  insert.py paste <text>    paste it, then restore the previous clipboard

The paste path holds the clipboard only while the keystroke lands: a
foreground wl-copy owns the selection, the Shift+Insert goes to whatever has
focus, and ending wl-copy hands the selection back to whoever owned it before.
Anything else would make a picker that quietly eats what you had copied.

This process makes itself a session and process group leader before doing
anything, so every tool it starts is a member of a group the caller owns and
can signal as a unit. A SIGKILL aimed at this process alone would leave those
tools running with the clipboard in their hands; aimed at the group, it cannot.
Its own pid is therefore its pgid, which is what EmojiPicker.qml hands to
reap-group.py.

Teardown runs on every exit: normal return, SIGTERM, SIGINT, SIGHUP, and an
internal alarm that fires whether or not anyone is supervising. Each tool is
ended with TERM, waited for, KILLed if it will not go, and reaped, so no path
out of here leaves a process owning the selection.

Tools are resolved once against a fixed list of directories rather than
PATH, and isolated mode in the shebang (-I) ignores PYTHON* variables and the
user site directory.
"""

import os
import signal
import stat
import subprocess
import sys
import time

TOOL_DIRECTORIES = ["/usr/local/bin", "/usr/bin", "/bin"]

# Long enough for the compositor to return focus after the picker closes.
FOCUS_SETTLE = 0.15
# Long enough for the target application to read the selection.
PASTE_SETTLE = 0.2
WTYPE_TIMEOUT = 2
COPY_TIMEOUT = 5
# Nothing here should take a second. This bounds the process even when no
# supervisor is watching, for instance when run by hand.
HARD_DEADLINE = 8
GRACE = 0.5

EXIT_OK = 0
EXIT_UNUSABLE = 2
EXIT_COPIED_INSTEAD = 3
EXIT_PASTE_FAILED = 4
EXIT_DEADLINE = 5

running_tools = []


def own_process_group():
    """Become the leader of the group everything below here will join.

    setsid also detaches the controlling terminal, which is the stronger of
    the two; it fails when this process already leads a group or a session,
    and in that case it has nothing to do anyway. What has to hold afterwards
    is that this pid is the pgid, because that is the handle the supervisor
    signals, so it is checked rather than assumed.
    """
    try:
        os.setsid()
    except OSError:
        try:
            os.setpgrp()
        except OSError:
            pass
    if os.getpgid(0) != os.getpid():
        sys.stderr.write("emoji-picker insert: could not own a process group; "
                         "descendants will not be reapable as a unit\n")


def resolve(name):
    for directory in TOOL_DIRECTORIES:
        candidate = os.path.join(directory, name)
        try:
            info = os.stat(candidate)
        except OSError:
            continue
        if stat.S_ISREG(info.st_mode) and os.access(candidate, os.X_OK):
            return candidate
    return None


def stop(process):
    """TERM, wait, KILL, reap. Idempotent, and safe on an exited process."""
    if process is None:
        return
    if process.poll() is None:
        try:
            process.terminate()
        except OSError:
            pass
        deadline = time.monotonic() + GRACE
        while time.monotonic() < deadline and process.poll() is None:
            time.sleep(0.02)
        if process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass
    try:
        process.wait(timeout=GRACE)
    except subprocess.TimeoutExpired:
        pass


def cleanup():
    while running_tools:
        stop(running_tools.pop())


def on_signal(signum, _frame):
    cleanup()
    # Die of the signal that was sent, so the caller sees what happened
    # rather than an invented exit code.
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)


def on_alarm(_signum, _frame):
    cleanup()
    sys.stderr.write("emoji-picker insert: gave up after %d seconds\n" % HARD_DEADLINE)
    os._exit(EXIT_DEADLINE)


def fail(reason):
    sys.stderr.write("emoji-picker insert: %s\n" % reason)
    return EXIT_UNUSABLE


def copy_text(wl_copy, text, sensitive=False):
    command = [wl_copy, "--type", "text/plain"]
    if sensitive:
        command += ["--sensitive", "--foreground"]
    if not sensitive:
        subprocess.run(command, input=text.encode("utf-8"), timeout=COPY_TIMEOUT,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return None
    owner = subprocess.Popen(command, stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    running_tools.append(owner)
    owner.stdin.write(text.encode("utf-8"))
    owner.stdin.close()
    return owner


def main(argv):
    own_process_group()
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGHUP, on_signal)
    signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(HARD_DEADLINE)

    action = argv[1] if len(argv) > 1 else ""

    if action == "probe":
        sys.stdout.write("1" if resolve("wtype") else "0")
        return EXIT_OK

    if action not in ("copy", "paste") or len(argv) != 3:
        return fail("usage: insert.py probe|copy <text>|paste <text>")

    text = argv[2]
    if not text:
        return fail("nothing to insert")

    wl_copy = resolve("wl-copy")
    if not wl_copy:
        return fail("wl-copy was not found in %s" % ", ".join(TOOL_DIRECTORIES))

    try:
        if action == "copy":
            copy_text(wl_copy, text)
            return EXIT_OK

        wtype = resolve("wtype")
        if not wtype:
            # No way to synthesise the keystroke. Leave the text on the
            # clipboard rather than doing nothing, and say so with a distinct
            # status so the picker can tell the user it copied instead.
            copy_text(wl_copy, text)
            return EXIT_COPIED_INSTEAD

        copy_text(wl_copy, text, sensitive=True)
        time.sleep(FOCUS_SETTLE)
        status = EXIT_OK
        try:
            typed = subprocess.run([wtype, "-M", "shift", "-k", "Insert", "-m", "shift"],
                                   timeout=WTYPE_TIMEOUT,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if typed.returncode != 0:
                status = EXIT_PASTE_FAILED
        except (subprocess.TimeoutExpired, OSError):
            status = EXIT_PASTE_FAILED
        time.sleep(PASTE_SETTLE)
        return status
    except subprocess.TimeoutExpired:
        return fail("wl-copy did not finish within %d seconds" % COPY_TIMEOUT)
    except subprocess.CalledProcessError as error:
        return fail("wl-copy exited %d" % error.returncode)
    except OSError as error:
        return fail("could not run a clipboard tool: %s" % error)
    finally:
        signal.alarm(0)
        cleanup()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
