#!/usr/bin/python3 -I
"""Read and write the picker's preferences, descriptor-relative.

  state.py read     print the document, or a refusal, on stdout
  state.py write    read the document from stdin and publish it atomically

Neither operation ever names the file by a path a second time. The state
directory is walked one component at a time from the user's home, each opened
with O_NOFOLLOW | O_DIRECTORY and checked to be owned by this user and not
writable by anyone else, and the file is then opened, replaced and renamed
relative to the directory descriptor that survived those checks. A path
resolved once and used again is a path that can change between the two uses,
and the parent components are as replaceable as the file itself.

QML's FileView cannot do any of that: it takes a string, follows every
component, reads without a ceiling, and publishes through the same mutable
path. Hence this.

Reading never fails the caller. It prints {"rejected": "<reason>"} and exits
0, because a picker that will not open because its preferences are unreadable
is worse than one that opens with default preferences. Writing does fail, with
the reason on stdout as JSON, because silently not saving a pin is worse than
saying so.

Isolated mode in the shebang (-I) ignores PYTHON* environment variables and
the user site directory, so nothing in the environment can inject code here.
"""

import errno
import json
import os
import secrets
import stat
import sys

MAX_BYTES = 65536
FILE_NAME = "emoji-picker.json"
FILE_MODE = 0o600
DIR_MODE = 0o700


class Refused(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


def state_directory_parts():
    """The state directory, as a base path plus the components to walk.

    Only the base is resolved by the kernel in one go; every component after
    it is opened individually and checked. XDG_STATE_HOME is honoured when it
    is absolute, matching what the rest of Omarchy writes.
    """
    xdg = os.environ.get("XDG_STATE_HOME", "")
    if xdg.startswith("/"):
        return xdg, ["omarchy"]
    home = os.environ.get("HOME", "")
    if not home.startswith("/"):
        raise Refused("HOME is not an absolute path", home)
    return home, [".local", "state", "omarchy"]


def check_directory(fd, label):
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode):
        raise Refused("a directory in the path is not a directory", label)
    if info.st_uid != os.getuid():
        raise Refused("a directory in the path is owned by another user",
                      "%s: uid %d" % (label, info.st_uid))
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise Refused("a directory in the path is writable by others",
                      "%s: mode %o" % (label, info.st_mode & 0o777))
    return info


def open_state_directory(create):
    """A descriptor for the state directory, with every component checked.

    Returned open. The caller closes it. Creation is opt-in so that reading
    never brings the directory into existence as a side effect.
    """
    base, parts = state_directory_parts()
    try:
        fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    except OSError as error:
        raise Refused("the home directory could not be opened", "%s: %s" % (base, error))

    try:
        check_directory(fd, base)
        for part in parts:
            try:
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                              dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise Refused("no preferences saved yet", part)
                os.mkdir(part, DIR_MODE, dir_fd=fd)
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                              dir_fd=fd)
            except OSError as error:
                if getattr(error, "errno", None) in (errno.ELOOP, errno.ENOTDIR):
                    raise Refused("a directory in the path is a symlink", part)
                raise Refused("a directory in the path could not be opened",
                              "%s: %s" % (part, error))
            os.close(fd)
            fd = nxt
            check_directory(fd, part)
    except Exception:
        os.close(fd)
        raise
    return fd


def read_document(dir_fd):
    try:
        # O_NOFOLLOW refuses a symlink at the final component, O_NONBLOCK
        # means a FIFO left there fails instead of hanging, and the fstat
        # below describes this descriptor, not the name, so nothing can be
        # swapped in between the check and the read.
        fd = os.open(FILE_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                     dir_fd=dir_fd)
    except FileNotFoundError:
        raise Refused("no preferences saved yet")
    except OSError as error:
        if getattr(error, "errno", None) == errno.ELOOP:
            raise Refused("it is a symlink, which is never followed")
        raise Refused("it could not be opened", str(error))

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise Refused("it is not a regular file")
        if info.st_uid != os.getuid():
            raise Refused("it is owned by another user", "uid %d" % info.st_uid)
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise Refused("it is writable by others", "mode %o" % (info.st_mode & 0o777))
        if info.st_nlink != 1:
            # A second name for the file is a second way to change it, and
            # this plugin only ever publishes by rename, which yields one.
            raise Refused("it has more than one hard link", "%d links" % info.st_nlink)
        if info.st_size > MAX_BYTES:
            raise Refused("it is larger than %d bytes" % MAX_BYTES, "%d bytes" % info.st_size)
        raw = os.read(fd, MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise Refused("it grew past %d bytes while being read" % MAX_BYTES)
    finally:
        os.close(fd)

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused("it is not valid UTF-8")


def write_document(dir_fd, text):
    """Publish by rename, inside the directory we already hold open.

    The temporary name is unpredictable and created O_EXCL at 0600, so it is
    never briefly readable by anyone else, and the rename is relative to the
    same descriptor, so the file that appears is the file that was written.
    """
    temporary = ".%s.%s.tmp" % (FILE_NAME, secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 FILE_MODE, dir_fd=dir_fd)
    try:
        # umask masks the creation mode, so the mode is set again on the
        # descriptor and then read back rather than assumed.
        os.fchmod(fd, FILE_MODE)
        if stat.S_IMODE(os.fstat(fd).st_mode) != FILE_MODE:
            raise Refused("the temporary file did not take mode %o" % FILE_MODE)
        os.write(fd, text.encode("utf-8"))
        os.fsync(fd)
    except Exception:
        os.close(fd)
        try:
            os.unlink(temporary, dir_fd=dir_fd)
        except OSError:
            pass
        raise
    os.close(fd)

    try:
        os.rename(temporary, FILE_NAME, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError as error:
        try:
            os.unlink(temporary, dir_fd=dir_fd)
        except OSError:
            pass
        raise Refused("the preferences could not be published", str(error))
    os.fsync(dir_fd)


def read_stdin():
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise Refused("the document is larger than %d bytes" % MAX_BYTES)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused("the document is not valid UTF-8")
    try:
        parsed = json.loads(text)
    except ValueError as error:
        raise Refused("the document is not JSON", str(error))
    if not isinstance(parsed, dict):
        raise Refused("the document is not a JSON object")
    return text


def report(reason, detail=""):
    sys.stderr.write("emoji-picker state: %s%s\n" % (reason, ": " + detail if detail else ""))


def main(argv):
    if len(argv) != 2 or argv[1] not in ("read", "write"):
        report("called wrongly", "usage: state.py read|write")
        return 2
    action = argv[1]

    if action == "read":
        try:
            dir_fd = open_state_directory(create=False)
        except Refused as refusal:
            report(refusal.reason, refusal.detail)
            sys.stdout.write(json.dumps({"rejected": refusal.reason[:120]}))
            return 0
        try:
            text = read_document(dir_fd)
        except Refused as refusal:
            report(refusal.reason, refusal.detail)
            sys.stdout.write(json.dumps({"rejected": refusal.reason[:120]}))
            return 0
        finally:
            os.close(dir_fd)
        sys.stdout.write(text)
        return 0

    try:
        text = read_stdin()
        dir_fd = open_state_directory(create=True)
    except Refused as refusal:
        report(refusal.reason, refusal.detail)
        sys.stdout.write(json.dumps({"ok": False, "reason": refusal.reason[:120]}))
        return 1
    try:
        write_document(dir_fd, text)
    except Refused as refusal:
        report(refusal.reason, refusal.detail)
        sys.stdout.write(json.dumps({"ok": False, "reason": refusal.reason[:120]}))
        return 1
    except OSError as error:
        report("the preferences could not be written", str(error))
        sys.stdout.write(json.dumps({"ok": False, "reason": "they could not be written"}))
        return 1
    finally:
        os.close(dir_fd)
    sys.stdout.write(json.dumps({"ok": True}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
