#!/usr/bin/env python3
"""Invariants of the generated emoji-data.json.

The picker trusts this file completely: it never validates a row at runtime,
because 4,000 rows checked on every keystroke is a cost paid for nothing.
The checking happens once, here, at build time.
"""
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / 'emoji-data.json'
EMOJI_FONT = '/usr/share/fonts/noto/NotoColorEmoji.ttf'
INVISIBLE = {0xFE0F, 0xFE0E, 0x200D}


def font_charset(path):
    if not os.path.exists(path):
        return None
    raw = subprocess.run(['fc-query', '-f', '%{charset}', path],
                         capture_output=True, text=True, check=True).stdout
    covered = set()
    for token in raw.split():
        if '-' in token:
            lo, hi = token.split('-', 1)
            covered.update(range(int(lo, 16), int(hi, 16) + 1))
        elif token:
            covered.add(int(token, 16))
    return covered


def codepoints(text):
    out = []
    index = 0
    while index < len(text):
        code = ord(text[index])
        out.append(code)
        index += 1
    return out


def main():
    if not DATA.exists():
        print('emoji-data.json is missing; run tools/build-data.py')
        return 1

    data = json.loads(DATA.read_text(encoding='utf-8'))
    problems = []
    items = data.get('items', [])

    if len(items) < 1500:
        problems.append('only %d items; the generator produced a truncated set' % len(items))
    if len(data.get('toneNames', [])) != 5:
        problems.append('toneNames must list the five Fitzpatrick tones')

    groups = data.get('groups', [])
    seen = {}
    tone_capable = 0

    for item in items:
        char = item.get('e', '')
        if not char:
            problems.append('item with no character: %r' % item)
            continue
        if char in seen:
            problems.append('duplicate character %r (also at index %d)' % (char, seen[char]))
        seen[char] = len(seen)

        for field in ('n', 'g', 'k', 'u'):
            if not item.get(field):
                problems.append('%r is missing %s' % (char, field))
        if item.get('g') not in groups:
            problems.append('%r is in group %r, which is not in groups[]' % (char, item.get('g')))

        expected = ' '.join('U+%04X' % cp for cp in codepoints(char))
        if item.get('u') != expected:
            problems.append('%r has u=%r, expected %r' % (char, item.get('u'), expected))

        tones = item.get('t')
        if tones is not None:
            tone_capable += 1
            if len(tones) != 5:
                problems.append('%r has %d skin tones, expected 5' % (char, len(tones)))
            elif len(set(tones)) != 5 or char in tones:
                problems.append('%r has duplicate or identity skin tone variants' % char)

    if tone_capable < 100:
        problems.append('only %d items carry skin tones; expected the whole people set' % tone_capable)

    charset = font_charset(EMOJI_FONT)
    if charset is not None:
        # A codepoint the font does not carry renders as a hollow box, and a
        # grid of boxes is worse than a shorter grid.
        missing = []
        for item in items:
            if item.get('g') == 'Text Symbols':
                continue
            for cp in codepoints(item['e']):
                if cp in INVISIBLE or 0xE0020 <= cp <= 0xE007F:
                    continue
                if cp not in charset:
                    missing.append('%s (U+%04X)' % (item['e'], cp))
                    break
        if missing:
            problems.append('%d emoji use codepoints the installed emoji font lacks: %s'
                            % (len(missing), ', '.join(missing[:8])))
    else:
        sys.stderr.write('note: %s missing, skipped the coverage check\n' % EMOJI_FONT)

    if problems:
        print('\n'.join(problems[:40]))
        if len(problems) > 40:
            print('... and %d more' % (len(problems) - 40))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
