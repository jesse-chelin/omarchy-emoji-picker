#!/usr/bin/env python3
"""read-state.py refuses everything it should, and says why.

The reader is the plugin's only trust boundary against the filesystem, so
each refusal is tested by building the hostile thing and running it, not by
reading the code and agreeing with it.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
READER = ROOT / 'read-state.py'
MAX_BYTES = 65536


def run(path):
    result = subprocess.run([sys.executable, str(READER), str(path)],
                            capture_output=True, text=True, timeout=10)
    return result.returncode, result.stdout, result.stderr


def refused(out):
    """Refusals are still valid JSON carrying only a reason."""
    try:
        parsed = json.loads(out)
    except ValueError:
        return False
    return list(parsed.keys()) == ['rejected'] and isinstance(parsed['rejected'], str)


def main():
    problems = []

    def check(name, condition, detail=''):
        if not condition:
            problems.append('%s: %s' % (name, detail or 'failed'))

    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)

        good = work / 'state.json'
        good.write_text('{"pinned":["\U0001F355"],"columns":9}', encoding='utf-8')
        code, out, _ = run(good)
        check('regular file', code == 0 and '"columns":9' in out, out)

        code, out, _ = run(work / 'missing.json')
        check('missing file', code == 0 and refused(out), out)

        # A symlink at the final component is the classic redirect into
        # something the plugin was never meant to read.
        target = work / 'secret'
        target.write_text('x' * 100, encoding='utf-8')
        link = work / 'link.json'
        link.symlink_to(target)
        code, out, err = run(link)
        check('symlink', code == 0 and refused(out) and 'symlink' in err, err)

        # A FIFO would hang an unbounded reader forever.
        fifo = work / 'fifo.json'
        os.mkfifo(fifo)
        code, out, err = run(fifo)
        check('fifo', code == 0 and refused(out), err)

        code, out, err = run(work)
        check('directory', code == 0 and refused(out), err)

        big = work / 'big.json'
        big.write_bytes(b'{"pinned":[' + b'"x",' * 20000 + b'"y"]}')
        check('oversized fixture', big.stat().st_size > MAX_BYTES, str(big.stat().st_size))
        code, out, err = run(big)
        check('oversized', code == 0 and refused(out) and 'larger than' in err, err)

        edge = work / 'edge.json'
        edge.write_bytes(b'{"k":"' + b'a' * (MAX_BYTES - 10) + b'"}')
        check('edge fixture', edge.stat().st_size <= MAX_BYTES, str(edge.stat().st_size))
        code, out, _ = run(edge)
        check('at the limit', code == 0 and len(out) == edge.stat().st_size, str(len(out)))

        binary = work / 'binary.json'
        binary.write_bytes(b'\xff\xfe\x00garbage')
        code, out, err = run(binary)
        check('not utf-8', code == 0 and refused(out) and 'UTF-8' in err, err)

        code, out, err = run(work / 'a')
        check('never exits nonzero', code == 0, str(code))

    if problems:
        print('\n'.join(problems))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
