#!/bin/bash

# Put a character on the clipboard, and optionally paste it into whatever
# has focus.
#
#   insert.sh copy  <text>    leave it on the clipboard
#   insert.sh paste <text>    paste it, then restore the previous clipboard
#
# The paste path mirrors omarchy-menu-emoji-insert: a foreground wl-copy owns
# the selection only while the shift+Insert lands, so killing it hands the
# clipboard back to whatever owned it before. Anything else would make a
# picker that quietly eats what you had copied.

set -uo pipefail

action="${1:-}"
text="${2:-}"

[[ -n $action && -n $text ]] || exit 1

case "$action" in
  copy)
    printf '%s' "$text" | wl-copy --type text/plain
    ;;
  paste)
    if ! command -v wtype >/dev/null 2>&1; then
      # No way to synthesise the keystroke, so leave it on the clipboard
      # rather than doing nothing at all.
      printf '%s' "$text" | wl-copy --type text/plain
      exit 0
    fi
    printf '%s' "$text" | wl-copy --type text/plain --sensitive --foreground &
    copy_pid=$!
    sleep 0.15
    wtype -M shift -k Insert -m shift 2>/dev/null || true
    sleep 0.2
    kill "$copy_pid" 2>/dev/null || true
    ;;
  *)
    exit 1
    ;;
esac
