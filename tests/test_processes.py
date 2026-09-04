#!/usr/bin/env python3
"""The helpers own a process group, and the reaper empties it.

The review that produced this code was specific: signalling only the tracked
process leaves its descendants holding the clipboard. So the two mechanisms
that prevent that are tested directly. A group leader is built for real, a
child that ignores SIGTERM is put inside it, and reap-group.py is asked to
make it go away.
"""
import importlib.util
import os
import sys

# Importing the helper must not litter the plugin folder with a __pycache__
# that a user would then find in their checkout.
sys.dont_write_bytecode = True

import pathlib
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSERT = ROOT / 'insert.py'
REAPER = ROOT / 'reap-group.py'


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_gone(pid, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not alive(pid):
            return True
        time.sleep(0.02)
    return not alive(pid)


# A leader that starts one stubborn child and then waits. Deliberately ignores
# SIGTERM in the child, which is what makes the KILL escalation observable.
LEADER = '''#!/usr/bin/python3
import os, signal, subprocess, sys, time
try:
    os.setsid()
except OSError:
    try:
        os.setpgrp()
    except OSError:
        pass
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([sys.executable, "-c",
    "import signal,time\\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\\ntime.sleep(120)"])
sys.stdout.write("%d\\n" % child.pid)
sys.stdout.flush()
time.sleep(120)
'''


def main():
    problems = []

    def check(name, condition, detail=''):
        if not condition:
            problems.append('%s: %s' % (name, detail or 'failed'))

    insert = load(INSERT, 'insert_helper')

    # ---- the helper makes itself a group leader ---------------------------
    # Run in a separate interpreter rather than a fork, so this test process
    # keeps a single, ordinary relationship with the children it starts.
    prove = ('import importlib.util, os, sys\n'
             'spec = importlib.util.spec_from_file_location("h", %r)\n'
             'module = importlib.util.module_from_spec(spec)\n'
             'spec.loader.exec_module(module)\n'
             'module.own_process_group()\n'
             'print(os.getpid(), os.getpgid(0))\n') % str(INSERT)
    # -B as well as the flag above: this is a fresh interpreter and it would
    # otherwise write the cache the parent is being careful not to.
    proof = subprocess.run([sys.executable, '-B', '-c', prove],
                           capture_output=True, text=True, timeout=15)
    own_pid, own_pgid = (proof.stdout.split() + ['', ''])[:2]
    check('own_process_group makes the process its own group leader',
          own_pid and own_pid == own_pgid, '%s != %s (%s)' % (own_pid, own_pgid, proof.stderr))

    # ---- stop() escalates from TERM to KILL -------------------------------
    stubborn = subprocess.Popen([sys.executable, '-c',
        'import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(120)'])
    started = time.monotonic()
    insert.stop(stubborn)
    check('stop() kills a process that ignores TERM',
          stubborn.poll() is not None, 'still running')
    check('stop() does not hang on it', time.monotonic() - started < 5,
          '%.1fs' % (time.monotonic() - started))
    insert.stop(stubborn)  # idempotent

    polite = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
    insert.stop(polite)
    check('stop() ends a polite process too', polite.poll() is not None)

    # ---- tool resolution stays inside the fixed directories ---------------
    check('tool directories are all absolute',
          all(directory.startswith('/') for directory in insert.TOOL_DIRECTORIES),
          str(insert.TOOL_DIRECTORIES))
    check('a tool that is not there does not resolve',
          insert.resolve('definitely-not-a-real-tool-xyz') is None)

    # ---- probe answers without a compositor -------------------------------
    probe = subprocess.run([sys.executable, str(INSERT), 'probe'],
                           capture_output=True, text=True, timeout=10)
    check('probe answers 1 or 0', probe.returncode == 0 and probe.stdout in ('0', '1'),
          repr(probe.stdout))
    usage = subprocess.run([sys.executable, str(INSERT), 'bogus'],
                           capture_output=True, text=True, timeout=10)
    check('an unknown action is refused', usage.returncode == 2, str(usage.returncode))

    # ---- the reaper empties a real group ----------------------------------
    with tempfile.TemporaryDirectory() as work:
        leader_path = pathlib.Path(work) / 'leader.py'
        leader_path.write_text(LEADER, encoding='utf-8')
        leader_path.chmod(0o755)

        # Executed directly, so argv[0] is the script path, which is how the
        # plugin starts its helpers and what the reaper checks against.
        leader = subprocess.Popen([str(leader_path)], stdout=subprocess.PIPE)
        descendant = int(leader.stdout.readline().strip())
        time.sleep(0.1)
        check('the leader owns its group', os.getpgid(leader.pid) == leader.pid)
        check('the descendant joined it', os.getpgid(descendant) == leader.pid)

        # Wrong prefix: not ours, so nothing is signalled.
        wrong = subprocess.run([sys.executable, str(REAPER), str(leader.pid), '/definitely/not/here'],
                               capture_output=True, text=True, timeout=15)
        check('a group that is not ours is refused', wrong.returncode == 2, wrong.stderr)
        check('and is left alone', alive(leader.pid) and alive(descendant))

        reaped = subprocess.run([sys.executable, str(REAPER), str(leader.pid), work + '/'],
                                capture_output=True, text=True, timeout=30)
        check('the reaper reports success', reaped.returncode == 0, reaped.stderr)
        # Reap the zombie this test is the parent of before asking whether the
        # pid is gone; in the plugin the shell does that promptly itself.
        try:
            leader.wait(timeout=5)
            exited = True
        except subprocess.TimeoutExpired:
            exited = False
            leader.kill()
            leader.wait(timeout=5)
        check('the leader exited', exited, 'still running after the reaper')
        check('the leader is gone', wait_gone(leader.pid, 5), 'leader %d' % leader.pid)
        check('the descendant is gone too, not just the tracked process',
              wait_gone(descendant, 5), 'descendant %d' % descendant)

        # A pid that is not a group leader is a no-op, not a mistake.
        idle = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        if os.getpgid(idle.pid) != idle.pid:
            noop = subprocess.run([sys.executable, str(REAPER), str(idle.pid), work + '/'],
                                  capture_output=True, text=True, timeout=15)
            check('a non-leader is a no-op', noop.returncode == 0, noop.stderr)
            check('and is left running', alive(idle.pid))
        idle.kill()
        idle.wait(timeout=5)

        for guard in ('1', '0', '-3'):
            refused = subprocess.run([sys.executable, str(REAPER), guard, work + '/'],
                                     capture_output=True, text=True, timeout=15)
            check('pgid %s is refused' % guard, refused.returncode == 2, refused.stderr)

    if problems:
        print('\n'.join(problems))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
