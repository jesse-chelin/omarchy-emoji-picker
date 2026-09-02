#!/usr/bin/env bash
# Everything verifiable without a compositor.
#
# One entry point, so CI and a laptop run the same checks. Each step skips
# with a visible note when the machine lacks the tool rather than silently
# passing.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="/usr/lib/qt6/bin:$PATH"
status=0
note() { printf '%-20s %s\n' "$1" "$2"; }

if command -v omarchy >/dev/null; then
  if omarchy plugin validate . >/dev/null 2>&1; then note "manifest" "ok"
  else note "manifest" "FAILED"; omarchy plugin validate .; status=1; fi
else
  note "manifest" "skipped (no omarchy)"
fi

# qmllint needs the shell's modules importable as `qs.*`, which means a
# directory literally named `qs` pointing at it.
SHELL_DIR="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
if [[ -d $SHELL_DIR ]] && command -v qmllint >/dev/null; then
  imports=$(mktemp -d)
  ln -s "$SHELL_DIR" "$imports/qs"
  # Types injected by the plugin host resolve to bare QObject at lint time,
  # and an id from an enclosing scope inside a delegate is always
  # "unqualified"; neither is actionable.
  out=$(qmllint -I "$imports" ./*.qml 2>&1 | grep -E '^(Warning|Error)' \
    | grep -vE 'not found on type "QObject"|Unqualified access|PanelWindow is not creatable')
  rm -rf "$imports"
  if [[ -z $out ]]; then note "qmllint" "clean"
  else note "qmllint" "FAILED"; echo "$out"; status=1; fi
else
  note "qmllint" "skipped"
fi

if command -v qmltestrunner >/dev/null; then
  log=$(mktemp)
  if QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/ >"$log" 2>&1; then
    note "qml tests" "$(grep -o 'Totals:.*' "$log" | head -1)"
  elif grep -q 'is not installed' "$log"; then
    # QtTest's own TestCase.qml imports modules this file does not, so a bare
    # runner fails to compile the suite rather than to run it. Say which.
    note "qml tests" "FAILED (missing QML module)"
    grep -o 'module "[^"]*" is not installed' "$log" | sort -u
    status=1
  else
    note "qml tests" "FAILED"; cat "$log"; status=1
  fi
  rm -f "$log"
else
  note "qml tests" "skipped (no qmltestrunner)"
fi

# qmllint is clean on a file that binds one property twice; the engine only
# says so at load, and the overlay refuses to open instead.
if out=$(python3 tests/test_qml_structure.py); then note "qml structure" "ok"
else note "qml structure" "FAILED"; echo "$out"; status=1; fi

# The picker trusts emoji-data.json completely at runtime, so it is checked
# here instead.
if out=$(python3 tests/test_data.py 2>/dev/null); then note "emoji data" "ok"
else note "emoji data" "FAILED"; echo "$out"; status=1; fi

# Every Nerd Font glyph in the source has to exist in the font and depict
# what the test pins it to. Shipping a wrong codepoint is silent.
if out=$(python3 tests/test_glyphs.py); then note "glyphs" "ok"
else note "glyphs" "FAILED"; echo "$out"; status=1; fi

if bash -n insert.sh; then note "insert.sh" "ok"
else note "insert.sh" "FAILED"; status=1; fi

exit $status
