#!/usr/bin/env python3
"""Regenerate emoji-data.json from the upstream Unicode and CLDR sources.

Run this when a new Unicode emoji release lands, or when the installed
Noto Color Emoji changes. The plugin itself never touches the network:
everything it needs is baked into emoji-data.json at build time.

  ./tools/build-data.py [--sources DIR] [--out FILE]

Sources are downloaded into --sources (default: a temp dir) if missing:
  emoji-test.txt          groups, subgroups, CLDR names, skin tone variants
  annotations.json        CLDR search keywords
  annotationsDerived.json CLDR keywords for derived sequences
  UnicodeData.txt         character names for the text symbol set
  Blocks.txt              block ranges for the text symbol set

Coverage is filtered against the installed emoji font. An emoji whose
codepoints the font does not carry renders as tofu, and a picker full of
boxes is worse than a picker missing this year's additions.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

SOURCES = {
    "emoji-test.txt": "https://unicode.org/Public/emoji/latest/emoji-test.txt",
    "annotations.json": "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-annotations-full/annotations/en/annotations.json",
    "annotationsDerived.json": "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-annotations-derived-full/annotationsDerived/en/annotations.json",
    "UnicodeData.txt": "https://www.unicode.org/Public/UNIDATA/UnicodeData.txt",
    "Blocks.txt": "https://www.unicode.org/Public/UNIDATA/Blocks.txt",
}

EMOJI_FONT = "/usr/share/fonts/noto/NotoColorEmoji.ttf"

TONES = ["1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"]
TONE_NAMES = ["Light", "Medium-Light", "Medium", "Medium-Dark", "Dark"]

# Raycast collapses Unicode's two people groups into one and drops the
# Component group (bare skin tone swatches and hair colors are not things
# anyone wants to insert on their own).
GROUP_MAP = {
    "Smileys & Emotion": "Smileys & People",
    "People & Body": "Smileys & People",
    "Animals & Nature": "Animals & Nature",
    "Food & Drink": "Food & Drink",
    "Travel & Places": "Travel & Places",
    "Activities": "Activities",
    "Objects": "Objects",
    "Symbols": "Symbols",
    "Flags": "Flags",
}
GROUP_ORDER = [
    "Smileys & People",
    "Animals & Nature",
    "Food & Drink",
    "Travel & Places",
    "Activities",
    "Objects",
    "Symbols",
    "Flags",
    "Text Symbols",
]

# Blocks worth offering as insertable text. Everything else in these ranges
# is filtered by general category below; the block list only bounds the sweep.
SYMBOL_BLOCKS = [
    "Latin-1 Supplement",
    "Greek and Coptic",
    "General Punctuation",
    "Superscripts and Subscripts",
    "Currency Symbols",
    "Letterlike Symbols",
    "Number Forms",
    "Arrows",
    "Mathematical Operators",
    "Miscellaneous Technical",
    "Geometric Shapes",
    "Miscellaneous Symbols",
    "Dingbats",
    "Supplemental Arrows-B",
    "Miscellaneous Mathematical Symbols-B",
    "Supplemental Mathematical Operators",
    "Miscellaneous Symbols and Arrows",
]
# Symbols, punctuation, numeric forms and letters. Anything else in those
# blocks is a combining mark, a format control, or unassigned.
SYMBOL_CATEGORIES = {
    "Sm", "Sc", "Sk", "So",
    "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
    "No", "Nl",
    "Lu", "Ll", "Lo", "Lm",
}


def fetch(directory, name):
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        sys.stderr.write("fetching %s\n" % name)
        urllib.request.urlretrieve(SOURCES[name], path)
    return path


def font_charset(path):
    """Codepoints the font carries, as a set, from fontconfig's charset."""
    if not os.path.exists(path):
        sys.stderr.write("warning: %s missing, skipping coverage filter\n" % path)
        return None
    raw = subprocess.run(
        ["fc-query", "-f", "%{charset}", path],
        capture_output=True, text=True, check=True,
    ).stdout
    covered = set()
    for token in raw.split():
        if "-" in token:
            lo, hi = token.split("-", 1)
            covered.update(range(int(lo, 16), int(hi, 16) + 1))
        elif token:
            covered.add(int(token, 16))
    return covered


# Codepoints that carry no glyph of their own: the variation selector, the
# zero-width joiner, and the tag characters used by subdivision flags.
def is_invisible(cp):
    return cp in (0xFE0F, 0xFE0E, 0x200D) or 0xE0020 <= cp <= 0xE007F


def covered(codepoints, charset):
    if charset is None:
        return True
    return all(is_invisible(cp) or cp in charset for cp in codepoints)


EMOJI_LINE = re.compile(
    r"^([0-9A-F ]+?)\s*;\s*(\S+)\s*#\s*(\S+)\s+E(\d+\.\d+)\s+(.+?)\s*$"
)


def parse_emoji_test(path):
    """Yield (codepoints, status, char, version, name, group, subgroup)."""
    group = subgroup = ""
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("# group:"):
                group = line.split(":", 1)[1].strip()
                continue
            if line.startswith("# subgroup:"):
                subgroup = line.split(":", 1)[1].strip()
                continue
            if not line.strip() or line.startswith("#"):
                continue
            match = EMOJI_LINE.match(line)
            if not match:
                continue
            cps, status, char, version, name = match.groups()
            codepoints = [int(cp, 16) for cp in cps.split()]
            yield codepoints, status, char, version, name, group, subgroup


def load_keywords(*paths):
    keywords = {}
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        table = data.get("annotations", {}).get("annotations", {})
        for emoji, entry in table.items():
            words = list(entry.get("default", []))
            tts = entry.get("tts")
            if isinstance(tts, list):
                words.extend(tts)
            elif isinstance(tts, str):
                words.append(tts)
            keywords.setdefault(emoji, []).extend(words)
    return keywords


def search_text(name, extra):
    """One lowercase haystack per item, deduped and word-order preserved.

    Search is substring over this string, so a word appearing in both the
    name and the CLDR keywords would otherwise be matched twice for no gain.
    """
    seen = []
    for chunk in [name] + list(extra):
        for word in re.split(r"[\s_:,()\-]+", str(chunk).lower()):
            word = word.strip()
            if word and word not in seen:
                seen.append(word)
    return " ".join(seen)


def build_emoji(sources, charset):
    bases = []
    by_codepoints = {}
    tone_variants = {}
    dropped = {}

    for codepoints, status, char, version, name, group, subgroup in parse_emoji_test(
        fetch(sources, "emoji-test.txt")
    ):
        if status != "fully-qualified":
            continue
        mapped = GROUP_MAP.get(group)
        if mapped is None:
            continue

        tones_used = {cp for cp in codepoints if 0x1F3FB <= cp <= 0x1F3FF}
        if tones_used:
            # A tone variant belongs to the base it modifies, but only the
            # uniform ones are reachable from a single tone choice: the
            # mixed-tone couples are their own thing and Raycast does not
            # offer them either.
            if len(tones_used) != 1:
                continue
            tone = TONES.index("%04X" % next(iter(tones_used)))
            base_key = tuple(cp for cp in codepoints if not 0x1F3FB <= cp <= 0x1F3FF)
            tone_variants.setdefault(base_key, {})[tone] = char
            continue

        if not covered(codepoints, charset):
            dropped[version] = dropped.get(version, 0) + 1
            continue

        key = tuple(codepoints)
        if key in by_codepoints:
            continue
        item = {
            "e": char,
            "n": name,
            "g": mapped,
            "s": subgroup,
            "cp": codepoints,
        }
        by_codepoints[key] = item
        bases.append(item)

    keywords = load_keywords(
        fetch(sources, "annotations.json"),
        fetch(sources, "annotationsDerived.json"),
    )
    for item in bases:
        item["k"] = search_text(item["n"], keywords.get(item["e"], []) + [item["s"]])
        variants = tone_variants.get(tuple(item["cp"]))
        if variants and len(variants) == len(TONES):
            # Every tone or none. A partial set means the font is missing
            # some, and a tone menu with holes in it is a bug report.
            if all(covered([ord(c) for c in variants[i]], charset) for i in range(len(TONES))):
                item["t"] = [variants[i] for i in range(len(TONES))]

    return bases, dropped


def parse_blocks(path):
    blocks = []
    pattern = re.compile(r"^([0-9A-F]+)\.\.([0-9A-F]+);\s*(.+?)\s*$")
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = pattern.match(line)
            if match:
                lo, hi, name = match.groups()
                blocks.append((int(lo, 16), int(hi, 16), name))
    return blocks


def build_symbols(sources, emoji_chars):
    blocks = parse_blocks(fetch(sources, "Blocks.txt"))
    wanted = [b for b in blocks if b[2] in SYMBOL_BLOCKS]
    if len(wanted) != len(SYMBOL_BLOCKS):
        missing = set(SYMBOL_BLOCKS) - {b[2] for b in wanted}
        sys.stderr.write("warning: block names not found: %s\n" % ", ".join(sorted(missing)))

    text_charset = font_charset(EMOJI_FONT)
    items = []
    seen = set()
    with open(fetch(sources, "UnicodeData.txt"), encoding="utf-8") as handle:
        for line in handle:
            fields = line.split(";")
            if len(fields) < 3:
                continue
            cp = int(fields[0], 16)
            name, category = fields[1], fields[2]
            if category not in SYMBOL_CATEGORIES:
                continue
            block = next((b for b in wanted if b[0] <= cp <= b[1]), None)
            if block is None:
                continue
            if name.startswith("<"):
                name = fields[10] or name
            char = chr(cp)
            if char in emoji_chars or char in seen:
                continue
            # A symbol the emoji font also claims will be drawn as an emoji
            # glyph and duplicates an entry the emoji set already has.
            if text_charset and cp in text_charset:
                continue
            seen.add(char)
            items.append({
                "e": char,
                "n": name.lower(),
                "g": "Text Symbols",
                "s": block[2].lower(),
                "cp": [cp],
                "k": search_text(name, [block[2]]),
            })
    return items


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", default=None)
    parser.add_argument("--out", default=None)
    parser.add_argument("--no-symbols", action="store_true")
    args = parser.parse_args()

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args.out or os.path.join(here, "emoji-data.json")
    sources = args.sources or tempfile.mkdtemp(prefix="emoji-sources-")
    os.makedirs(sources, exist_ok=True)

    charset = font_charset(EMOJI_FONT)
    emoji, dropped = build_emoji(sources, charset)
    symbols = [] if args.no_symbols else build_symbols(sources, {i["e"] for i in emoji})

    items = emoji + symbols
    for item in items:
        item["u"] = " ".join("U+%04X" % cp for cp in item["cp"])
        del item["cp"]

    groups = [g for g in GROUP_ORDER if any(i["g"] == g for i in items)]
    payload = {
        "groups": groups,
        "toneNames": TONE_NAMES,
        "items": items,
    }
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")

    tone_capable = sum(1 for i in items if i.get("t"))
    sys.stderr.write(
        "wrote %s: %d emoji, %d text symbols, %d with skin tones\n"
        % (out, len(emoji), len(symbols), tone_capable)
    )
    for group in groups:
        sys.stderr.write("  %-18s %d\n" % (group, sum(1 for i in items if i["g"] == group)))
    if dropped:
        sys.stderr.write(
            "  dropped (font lacks the glyph): %s\n"
            % ", ".join("E%s:%d" % (v, n) for v, n in sorted(dropped.items()))
        )


if __name__ == "__main__":
    main()
