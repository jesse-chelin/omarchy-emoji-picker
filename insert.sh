#!/bin/bash

# Clipboard and paste helper.
#
#   insert.sh probe           print 1 if pasting is possible, 0 if not
#   insert.sh copy  <text>    leave the text on the clipboard
#   insert.sh paste <text>    paste it, then restore the previous clipboard
#
# The paste path holds the clipboard only while the keystroke lands: a
# foreground wl-copy owns the selection, the Shift+Insert goes to whatever has
# focus, and killing wl-copy hands the selection back to whoever owned it
# before. Anything else would make a picker that quietly eats what you had
# copied. That owner is reaped on every exit path, including a signal, so an
# interrupted paste cannot leave a process holding the clipboard.
#
# Every tool is resolved once against a fixed PATH and checked to be an
# executable regular file, so nothing here depends on the PATH of whatever
# started it. The caller in EmojiPicker.qml also runs this with a cleared
# environment, which is what actually closes BASH_ENV and the loader hooks:
# those are read before the first line of this script runs, so unsetting them
# here would be theatre.

set -uo pipefail

PATH=/usr/local/bin:/usr/bin:/bin
export PATH
unset -v CDPATH GLOBIGNORE IFS

readonly WTYPE_TIMEOUT=2
readonly COPY_TIMEOUT=5
# Long enough for the compositor to return focus after the picker closes.
readonly FOCUS_SETTLE=0.15
# Long enough for the target application to read the selection.
readonly PASTE_SETTLE=0.2

die() {
  printf 'emoji-picker insert: %s\n' "$1" >&2
  exit 2
}

resolve() {
  local name="$1" found
  found=$(command -v -- "$name" 2>/dev/null) || return 1
  [[ $found == /* && -f $found && -x $found ]] || return 1
  printf '%s' "$found"
}

copy_pid=""

# Idempotent, and called from the trap as well as inline: TERM, then KILL if
# it will not go, then reap so nothing is left as a zombie of the shell.
reap_clipboard_owner() {
  local pid="$copy_pid" waited
  copy_pid=""
  [[ -n $pid ]] || return 0
  kill -TERM "$pid" 2>/dev/null
  for waited in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    "$SLEEP" 0.05
  done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

action="${1:-}"

SLEEP=$(resolve sleep) || die "sleep not found on the fixed PATH"

case "$action" in
  probe)
    if resolve wtype >/dev/null; then printf '1'; else printf '0'; fi
    exit 0
    ;;
  copy|paste) ;;
  *)
    die "usage: insert.sh probe|copy <text>|paste <text>"
    ;;
esac

text="${2-}"
[[ -n $text ]] || die "nothing to insert"

WL_COPY=$(resolve wl-copy) || die "wl-copy not found on the fixed PATH"
TIMEOUT=$(resolve timeout) || die "timeout not found on the fixed PATH"

if [[ $action == copy ]]; then
  printf '%s' "$text" | "$TIMEOUT" "$COPY_TIMEOUT" "$WL_COPY" --type text/plain \
    || die "wl-copy failed"
  exit 0
fi

WTYPE=$(resolve wtype) || {
  # No way to synthesise the keystroke. Leave the text on the clipboard rather
  # than doing nothing at all, and say so with a distinct status so the picker
  # can tell the user it copied instead of pasting.
  printf '%s' "$text" | "$TIMEOUT" "$COPY_TIMEOUT" "$WL_COPY" --type text/plain \
    || die "wl-copy failed"
  exit 3
}

trap reap_clipboard_owner EXIT INT TERM HUP

printf '%s' "$text" | "$WL_COPY" --type text/plain --sensitive --foreground &
copy_pid=$!

"$SLEEP" "$FOCUS_SETTLE"
status=0
"$TIMEOUT" "$WTYPE_TIMEOUT" "$WTYPE" -M shift -k Insert -m shift 2>/dev/null || status=4
"$SLEEP" "$PASTE_SETTLE"

reap_clipboard_owner
exit "$status"
