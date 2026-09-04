#!/usr/bin/python3 -I
"""End a process group this plugin owns, and wait until it is gone.

  reap-group.py <pgid> <expected-command-prefix> [grace-seconds]

Signalling the tracked process alone is not enough: a SIGKILL there leaves its
descendants running, holding the clipboard. The helpers make themselves group
leaders so their whole tree can be ended as a unit, and this does that ending:
TERM the group, wait for every member to leave, KILL what is left, wait again,
and report what happened. A reap nobody waited for is a reap nobody can claim
happened.

It runs detached, so it survives the picker being destroyed mid-teardown,
which is exactly when it is needed.

Two checks before signalling anything. The pid must still be the leader of the
group being ended, because a recycled pid that has since joined another group
would otherwise take that group down with it, and its command line must start
with the prefix given by the caller, which is the plugin's own directory. A
group this plugin did not start is never signalled.
"""

import os
import signal
import sys
import time

POLL = 0.02
DEFAULT_GRACE = 1.0


def report(message):
    sys.stderr.write("emoji-picker reap: %s\n" % message)


def proc_field(pid, name):
    try:
        with open("/proc/%d/%s" % (pid, name), "rb") as handle:
            return handle.read()
    except OSError:
        return None


def stat_fields(pid):
    """(state, pgid) from /proc/<pid>/stat, or None if the process is gone.

    The comm field is parenthesised and may itself contain spaces and
    parentheses, so the fields after it are found from the last ')'.
    """
    raw = proc_field(pid, "stat")
    if raw is None:
        return None
    try:
        tail = raw[raw.rindex(b")") + 2:].split()
        return tail[0].decode("ascii", "replace"), int(tail[2])
    except (ValueError, IndexError):
        return None


def process_group_of(pid):
    fields = stat_fields(pid)
    return None if fields is None else fields[1]


def owner_of(pid):
    raw = proc_field(pid, "status")
    if raw is None:
        return None
    for line in raw.split(b"\n"):
        if line.startswith(b"Uid:"):
            try:
                return int(line.split()[1])
            except (ValueError, IndexError):
                return None
    return None


def command_args(pid):
    raw = proc_field(pid, "cmdline")
    if raw is None:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]


def group_members(pgid):
    """Live members of the group. Zombies do not count.

    A process that has exited but whose parent has not reaped it yet still
    appears in /proc with its pgid, holds nothing, and cannot be signalled
    into going away. Counting one would mean waiting out the full grace
    period and then reporting a failure to kill something already dead.
    """
    members = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return members
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        fields = stat_fields(pid)
        if fields is None or fields[0] == "Z":
            continue
        if fields[1] == pgid:
            members.append(pid)
    return members


def wait_for_empty(pgid, deadline):
    while time.monotonic() < deadline:
        if not group_members(pgid):
            return True
        time.sleep(POLL)
    return not group_members(pgid)


def main(argv):
    if len(argv) not in (3, 4):
        report("usage: reap-group.py <pgid> <expected-command-prefix> [grace]")
        return 2
    try:
        pgid = int(argv[1])
    except ValueError:
        report("pgid is not a number: %r" % argv[1])
        return 2
    prefix = argv[2]
    grace = DEFAULT_GRACE
    if len(argv) == 4:
        try:
            grace = max(0.1, min(10.0, float(argv[3])))
        except ValueError:
            pass

    if pgid <= 1:
        report("refusing to signal group %d" % pgid)
        return 2
    if process_group_of(pgid) != pgid:
        # Either it already exited, or the pid was recycled into someone
        # else's group. Neither is ours to signal.
        report("pid %d is not the leader of group %d, nothing to do" % (pgid, pgid))
        return 0
    if owner_of(pgid) != os.getuid():
        report("group %d is not owned by uid %d" % (pgid, os.getuid()))
        return 2
    # A script started by its shebang has the interpreter as argv[0], so the
    # plugin's own path is looked for anywhere in the argument list rather
    # than only at the front. Checking argv[0] would refuse to reap the very
    # helpers this exists for.
    args = command_args(pgid)
    if not any(arg.startswith(prefix) for arg in args):
        report("group %d does not belong to this plugin: %r" % (pgid, " ".join(args)[:120]))
        return 2

    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return 0
    except OSError as error:
        report("could not signal group %d: %s" % (pgid, error))
        return 2

    if wait_for_empty(pgid, time.monotonic() + grace):
        return 0

    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        return 0
    except OSError as error:
        report("could not kill group %d: %s" % (pgid, error))
        return 2

    if wait_for_empty(pgid, time.monotonic() + grace):
        return 0

    report("group %d still has members after SIGKILL: %s"
           % (pgid, ", ".join(str(pid) for pid in group_members(pgid))))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
