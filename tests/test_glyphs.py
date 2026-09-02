#!/usr/bin/env python3
"""Every Nerd Font glyph in the source exists and depicts what it claims.

JavaScript escapes take four hex digits and Nerd Font codepoints take five,
so the glyphs are embedded literally. That makes a wrong one invisible in
review: it is a single character that renders as something else entirely.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# codepoint -> what it must depict, checked by eye once and pinned here.
EXPECTED = {
    0xF0785: 'md-sticker_emoji, a sticker with a smiling face (empty state)',
}
# Nerd Font private use areas.
PRIVATE_USE = [(0xE000, 0xF8FF), (0xF0000, 0xFFFFD), (0x100000, 0x10FFFD)]


def is_private_use(cp):
    return any(lo <= cp <= hi for lo, hi in PRIVATE_USE)


def nerd_font_installed():
    out = subprocess.run(['fc-list', ':', 'family'], capture_output=True, text=True).stdout
    return 'Nerd Font' in out


def font_covers(cp):
    out = subprocess.run(['fc-list', ':charset=%X' % cp, 'family'],
                         capture_output=True, text=True).stdout
    return 'Nerd Font' in out


def main():
    problems = []
    found = set()
    # A bare CI runner has no Nerd Font. The pinning check still runs there;
    # only coverage needs the font present.
    check_coverage = nerd_font_installed()
    if not check_coverage:
        sys.stderr.write('note: no Nerd Font installed, skipped the coverage check\n')
    for path in sorted(ROOT.glob('*.qml')):
        for number, line in enumerate(path.read_text(encoding='utf-8').split('\n'), start=1):
            for char in line:
                cp = ord(char)
                if not is_private_use(cp):
                    continue
                found.add(cp)
                if cp not in EXPECTED:
                    problems.append('%s:%d: glyph U+%X is not pinned in test_glyphs.py'
                                    % (path.name, number, cp))
                elif check_coverage and not font_covers(cp):
                    problems.append('%s:%d: no installed Nerd Font carries U+%X'
                                    % (path.name, number, cp))

    for cp in EXPECTED:
        if cp not in found:
            problems.append('U+%X is pinned but no longer used; drop it' % cp)

    if problems:
        print('\n'.join(sorted(set(problems))))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
