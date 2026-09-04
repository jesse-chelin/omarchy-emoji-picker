#!/usr/bin/env python3
"""state.py refuses everything it should, and publishes privately.

The state file is the plugin's only trust boundary against the filesystem, so
each refusal is tested by building the hostile thing and running the real
script against it, not by reading the code and agreeing with it. The parent
directories are part of that boundary: a file can be protected perfectly and
still be reached through a directory somebody swapped.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATE = ROOT / 'state.py'
MAX_BYTES = 65536
NAME = 'emoji-picker.json'


def run(action, state_home, stdin=None):
    env = dict(os.environ)
    env['XDG_STATE_HOME'] = str(state_home)
    result = subprocess.run([sys.executable, str(STATE), action],
                            capture_output=True, text=True, timeout=15,
                            input=stdin, env=env)
    return result.returncode, result.stdout, result.stderr


def refused(out):
    """A refused read is still valid JSON carrying only a reason."""
    try:
        parsed = json.loads(out)
    except ValueError:
        return False
    return list(parsed.keys()) == ['rejected'] and isinstance(parsed['rejected'], str)


def write_failed(out):
    try:
        parsed = json.loads(out)
    except ValueError:
        return False
    return parsed.get('ok') is False and isinstance(parsed.get('reason'), str)


def main():
    problems = []

    def check(name, condition, detail=''):
        if not condition:
            problems.append('%s: %s' % (name, detail or 'failed'))

    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        home = work / 'state'
        directory = home / 'omarchy'
        directory.mkdir(parents=True)
        target = directory / NAME

        # ---- reading ------------------------------------------------------
        code, out, err = run('read', home)
        check('missing file', code == 0 and refused(out), out)

        target.write_text('{"columns":9}', encoding='utf-8')
        os.chmod(target, 0o600)
        code, out, _ = run('read', home)
        check('regular file', code == 0 and '"columns":9' in out, out)

        os.chmod(target, 0o666)
        code, out, err = run('read', home)
        check('world-writable file', code == 0 and refused(out) and 'writable' in err, err)
        os.chmod(target, 0o600)

        link = directory / 'other'
        link.write_text('{}', encoding='utf-8')
        os.link(link, directory / 'hardlink')
        target.unlink()
        os.link(link, target)
        code, out, err = run('read', home)
        check('hard link', code == 0 and refused(out) and 'hard link' in err, err)
        target.unlink()

        target.symlink_to(link)
        code, out, err = run('read', home)
        check('symlink', code == 0 and refused(out) and 'symlink' in err, err)
        target.unlink()

        os.mkfifo(target)
        code, out, err = run('read', home)
        check('fifo', code == 0 and refused(out), err)
        target.unlink()

        target.write_bytes(b'{"pinned":[' + b'"x",' * 20000 + b'"y"]}')
        os.chmod(target, 0o600)
        check('oversized fixture', target.stat().st_size > MAX_BYTES, str(target.stat().st_size))
        code, out, err = run('read', home)
        check('oversized', code == 0 and refused(out) and 'larger than' in err, err)

        target.write_bytes(b'{"k":"' + b'a' * (MAX_BYTES - 10) + b'"}')
        os.chmod(target, 0o600)
        code, out, _ = run('read', home)
        check('at the limit', code == 0 and len(out) == target.stat().st_size, str(len(out)))

        target.write_bytes(b'\xff\xfe\x00garbage')
        os.chmod(target, 0o600)
        code, out, err = run('read', home)
        check('not utf-8', code == 0 and refused(out) and 'UTF-8' in err, err)
        target.unlink()

        # ---- the path to the file, not just the file ----------------------
        # A directory swapped for a symlink is the redirect the final
        # component's O_NOFOLLOW does nothing about.
        elsewhere = work / 'elsewhere'
        elsewhere.mkdir()
        (elsewhere / NAME).write_text('{"columns":7}', encoding='utf-8')
        os.chmod(elsewhere / NAME, 0o600)
        swapped = work / 'swapped'
        swapped.mkdir()
        os.symlink(elsewhere, swapped / 'omarchy')
        code, out, err = run('read', swapped)
        check('parent is a symlink', code == 0 and refused(out) and 'symlink' in err, err)
        code, out, err = run('write', swapped, stdin='{"columns":7}')
        check('write through a symlinked parent', code != 0 and write_failed(out), out)

        loose = work / 'loose'
        (loose / 'omarchy').mkdir(parents=True)
        os.chmod(loose, 0o755)
        os.chmod(loose / 'omarchy', 0o777)
        code, out, err = run('read', loose)
        check('world-writable parent', code == 0 and refused(out) and 'writable by others' in err, err)

        # ---- writing ------------------------------------------------------
        # The base directory is expected to exist, the way $HOME and
        # $XDG_STATE_HOME do; only the plugin's own subdirectory is created.
        fresh = work / 'fresh'
        fresh.mkdir()
        code, out, err = run('write', fresh, stdin='{"pinned":["\U0001F355"]}')
        published = fresh / 'omarchy' / NAME
        check('write creates the directory', code == 0 and published.exists(), err)
        if published.exists():
            check('published mode is 0600', published.stat().st_mode & 0o777 == 0o600,
                  oct(published.stat().st_mode & 0o777))
            check('directory mode is 0700',
                  (fresh / 'omarchy').stat().st_mode & 0o777 == 0o700,
                  oct((fresh / 'omarchy').stat().st_mode & 0o777))
            check('round trip', json.loads(published.read_text(encoding='utf-8'))['pinned'][0] == '\U0001F355')
        check('no temporary left behind',
              [entry for entry in (fresh / 'omarchy').iterdir() if entry.name != NAME] == [],
              str(list((fresh / 'omarchy').iterdir())))

        code, out, err = run('write', fresh, stdin='not json at all')
        check('write refuses non-JSON', code != 0 and write_failed(out), out)
        code, out, err = run('write', fresh, stdin='[1,2,3]')
        check('write refuses a JSON array', code != 0 and write_failed(out), out)
        code, out, err = run('write', fresh, stdin='{"k":"' + 'a' * (MAX_BYTES + 10) + '"}')
        check('write refuses an oversized document', code != 0 and write_failed(out), out)
        check('a refused write leaves the good file alone',
              json.loads(published.read_text(encoding='utf-8'))['pinned'][0] == '\U0001F355')

        code, out, err = run('bogus', fresh)
        check('unknown action', code == 2, str(code))

    if problems:
        print('\n'.join(problems))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
