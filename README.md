# Emoji Picker

A Raycast-style emoji and symbol picker for the Omarchy shell. Search the
full Unicode emoji set plus the text symbol blocks, pin what you use, and
insert with a keystroke.

![Emoji Picker](preview.png)

## What it does

| | |
|---|---|
| Search | Names, CLDR keywords and your own keywords, all at once |
| Ranking | Pinned first, then how often and how recently you used it, then match quality |
| Typo fallback | When nothing matches, a subsequence pass finds `grnning` -> grinning face |
| Browse | Pinned and Recently Used above the eight Unicode categories |
| Categories | Tab cycles the filter, or pick one from the action panel |
| Skin tones | A default tone in preferences, and a per-insert tone submenu with previews |
| Pinning | Pinned emoji stay at the top of the grid, marked with an accent dot |
| Custom keywords | Assign your own words to any emoji or symbol |
| Text symbols | 2,282 arrows, math operators, currency signs, punctuation and Greek letters |
| Actions | Paste, copy, paste and keep open, copy the codepoint, pin, assign keywords |
| Preferences | Primary action, default skin tone, 6 to 10 grid columns, recent rows |

## Install

```sh
omarchy plugin add https://github.com/jesse-chelin/omarchy-emoji-picker --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + PERIOD", "Emoji Picker", "omarchy-shell shell toggle io.github.jesse-chelin.emoji-picker")
```

Omarchy ships `SUPER + CTRL + E` pointed at its own built-in picker. To take
that key instead, unbind it first:

```lua
hl.unbind("SUPER + CTRL + E")
o.bind("SUPER + CTRL + E", "Emoji Picker", "omarchy-shell shell toggle io.github.jesse-chelin.emoji-picker")
```

The built-in picker stays installed either way and is still reachable from the
Omarchy menu under Emoji.

## Keys

| Key | Action |
|---|---|
| Type | Search |
| Backspace, Ctrl+Backspace, Ctrl+U | Delete a character, a word, the lot |
| Arrows, Page Up/Down, Home, End | Move the cursor |
| Enter | Primary action, paste by default |
| Ctrl+Enter | The other one, copy by default |
| Ctrl+Shift+Enter | Paste and keep the picker open |
| Ctrl+Alt+Shift+C | Copy the codepoint, for example `U+1F600` |
| Ctrl+. | Pin or unpin |
| Ctrl+T | Skin tone submenu for this insert |
| Ctrl+E | Assign custom keywords |
| Tab, Shift+Tab | Cycle the category filter |
| Ctrl+K | Action panel |
| Ctrl+, | Preferences |
| Esc | Clear the category, then the search, then close |

## Pasting needs wtype

Inserting into the focused window is a synthesised `Shift+Insert`, which needs
the `wtype` package. Omarchy installs it by default, so most systems already
have it.

If it is missing, the picker says so in the footer and Enter copies instead of
firing a paste that goes nowhere, and **Ctrl+K** offers **Install wtype**. That
action runs `omarchy install app wtype wtype`, which is Omarchy's own
installer: it opens a floating terminal and runs `omarchy pkg add` there, so
any password prompt appears somewhere you can answer it. The plugin itself uses no
sudo or pkexec, and ships no installer of its own. Installing by hand
does the same thing:

```sh
omarchy pkg add wtype
```

The paste path holds the clipboard only while the keystroke lands, so whatever
you had copied before is still there afterwards.

## State

Pins, usage counts, custom keywords and preferences live in
`~/.local/state/omarchy/emoji-picker.json`, written `0600`. Delete it to start
over. That file is the only thing the plugin writes outside its own folder.

## Trust boundaries

The picker runs inside a process that lives as long as your session, so the
two places where something outside it gets a say are deliberately narrow.

**The preferences file.** It sits in a directory anything running as you can
write, so both reading and writing go through `state.py` rather than through
QML, which takes a path, follows every component of it, and reads without a
ceiling. That helper walks the directory chain one component at a time from
your home, opening each with `O_NOFOLLOW | O_DIRECTORY` and checking it is
owned by you and not writable by anyone else, then opens, reads and renames
**relative to the directory descriptor** that survived those checks. A path
resolved once and used again is a path that can change in between, and the
parent directories are as replaceable as the file.

The file itself must be a regular file, owned by you, not writable by others,
with a single hard link, and no larger than 64 KiB, and it is refused rather
than truncated. Publishing is a rename inside that same descriptor from a
temporary created `O_EXCL` at `0600`, with the mode read back rather than
assumed, so it is never briefly readable by anyone else. Whatever survives is
rebuilt field by field with the same bounds it is written under, into
prototype-free maps that refuse `__proto__`, `constructor` and `prototype` as
keys. A file that is refused costs you your pins, not your session: the picker
opens on defaults and says in the footer why.

**The child processes.** A probe for `wtype`, the clipboard helper, the
preferences reader and writer, and the optional `wtype` install. Each runs
with a cleared environment holding only `PATH`, `LANG`, the state directory
variables and the Wayland socket variables, so `BASH_ENV` and the loader hooks
cannot reach them. `insert.py` resolves every tool it uses against a fixed
list of directories, checks each is an executable regular file, and gives each
its own timeout.

Each helper makes itself the leader of its own process group before doing
anything, and everything it starts joins that group. That matters for
teardown: a `SIGKILL` aimed at the helper alone would leave `wl-copy` running
with your clipboard in its hands. So the escalation goes to the group.
`TERM` first, to the helper, which ends its tools and hands the clipboard
back; if it has not gone a second later, `reap-group.py` signals the whole
group, waits for it to actually empty, `KILL`s what is left and waits again. It
runs detached so it survives the picker being destroyed, which is when it is
needed most, and it refuses to signal a group whose leader is not still the
leader or whose command line does not mention this plugin. The same ladder
runs when an insert is superseded by a newer one and when the picker itself is
destroyed, so nothing it started outlives it.

`insert.py` also carries its own alarm, so it bounds itself even when run by
hand with nobody supervising, and its teardown runs on normal return, on
`SIGTERM`, `SIGINT` and `SIGHUP`, and on that alarm.

The emoji data file is read with QML's `FileView` because it lives inside the
plugin's own checkout: anyone able to rewrite it can rewrite the QML beside it,
so a size check there would be a check against nothing.

**The pixels.** Every `Text` element is pinned to `textFormat: Text.PlainText`,
so a search string, a saved keyword or an emoji name that happens to look like
HTML is shown, never interpreted — Qt's default is `AutoText`, which sniffs
the string for markup. A structural check fails the build if a `Text` without
that binding is ever added.

## Removal

```sh
omarchy plugin remove io.github.jesse-chelin.emoji-picker
rm -f ~/.local/state/omarchy/emoji-picker.json
```

Then remove the binding you added to `~/.config/hypr/bindings.lua`, including
the `hl.unbind("SUPER + CTRL + E")` line if you used it, and run
`hyprctl reload`. The plugin registers nothing with any service, holds no
credentials, and leaves nothing else behind.

## Regenerating the emoji data

`emoji-data.json` is generated from Unicode and CLDR at build time, so the
plugin never touches the network:

```sh
./tools/build-data.py
```

It filters against the installed Noto Color Emoji, because an emoji whose
glyph the font lacks renders as a hollow box. Rerun it after a Unicode
release or a font update.

## Development

```sh
./check.sh
```

Runs the manifest validation, `qmllint`, the QML unit tests, the structural
scans that `qmllint` misses, the data invariants and the glyph check. It is
the same command CI runs.

The picker exposes its whole state machine over IPC, because keyboard focus
inside a layer-shell surface cannot be synthesised from outside:

```sh
id=io.github.jesse-chelin.emoji-picker
omarchy-shell shell call $id stateJson ""
omarchy-shell shell call $id setQuery "pizza"
omarchy-shell shell call $id moveBy "1,0"
omarchy-shell shell call $id menuOpen actions
```

Overlays are held by a `Loader` keyed on the source URL, so edits to the QML
need `omarchy-restart-shell` to take effect.

## License

MIT
