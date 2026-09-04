import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "EmojiModel.js" as Model

// A Raycast-shaped emoji and symbol picker: search, pinning, frecency,
// skin tones, custom keywords, category filter and an action panel, over the
// full Unicode emoji set plus the text symbol blocks.
//
// One key catcher owns every keystroke and routes by `mode`. Sub-surfaces
// (action panel, tone menu, keyword editor) draw only; none of them takes
// focus, because a focused item that appears and vanishes hands Qt's focus
// somewhere useless and the picker stops responding to the keyboard.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.jesse-chelin.emoji-picker"
  readonly property string pluginDir: (manifest && manifest.__sourceDir)
    || (Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.jesse-chelin.emoji-picker")

  property bool opened: false
  property string query: ""
  property string categoryFilter: ""
  property int cursor: 0
  property bool cursorActive: true
  property string mode: "grid"

  property var emojiData: ({ groups: [], toneNames: [], items: [] })
  property var byChar: ({})
  property var store: Model.parseState("")
  property var view: ({ rows: [], flat: [], pos: [], columns: 8 })
  property bool fuzzyResults: false
  property bool storeLoaded: false

  property var menuEntries: []
  property int menuIndex: 0
  property string menuKind: ""
  property string keywordDraft: ""
  property string status: ""

  // wtype is what turns a copy into a paste into whatever has focus. Without
  // it the picker still works, so it says so once in the footer and falls
  // back to copying rather than firing a no-op and looking broken.
  property bool canPaste: true
  property string storeRejected: ""
  property var pendingInsert: null
  property string pendingWrite: ""
  property string writingText: ""

  // Every child runs with this and nothing else. A cleared environment is
  // what actually closes BASH_ENV, ENV and the loader hooks, since a script
  // unsetting them has already been started by the time it could. Only the
  // handful of variables the Wayland clipboard tools genuinely need are
  // passed through, and an empty one is omitted rather than passed empty.
  readonly property var childEnvironment: {
    var env = { "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8" }
    var names = ["HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "WAYLAND_SOCKET"]
    for (var i = 0; i < names.length; i++) {
      var value = Quickshell.env(names[i])
      if (value) env[names[i]] = value
    }
    return env
  }

  // A child that never exits would otherwise pin a collector open forever
  // inside a process that lives as long as the session.
  //
  // TERM goes to the helper, which is the leader of its own process group, so
  // it can end the tools it started and hand the clipboard back. If it has
  // not gone by the next tick, the escalation goes to the whole group through
  // reap-group.py rather than to this one pid: a SIGKILL here would leave
  // wl-copy alive and holding the selection, which is the failure this is
  // supposed to prevent.
  component Watchdog: Timer {
    property var proc: null
    property bool escalated: false

    repeat: false
    interval: 3000
    onTriggered: {
      if (!proc || !proc.running) return
      if (escalated) {
        root.reapGroup(proc)
        return
      }
      escalated = true
      proc.signal(15)
      interval = 1000
      restart()
    }

    function arm() {
      escalated = false
      interval = 3000
      restart()
    }

    // Superseded or shutting down: same ladder, started now rather than on a
    // timeout the caller is no longer waiting out.
    function endNow() {
      if (!proc || !proc.running) return
      escalated = true
      interval = 700
      restart()
      proc.signal(15)
    }
  }

  // Ends the helper and everything it started, and waits for the group to
  // actually empty. Detached on purpose: it is needed most while this
  // component is being destroyed, which is exactly when a child of it would
  // be torn down mid-reap. The command prefix is this plugin's own directory,
  // so a recycled pid in someone else's group is never signalled.
  function reapGroup(proc) {
    if (!proc || !proc.running || !proc.processId) return
    Quickshell.execDetached([root.pluginDir + "/reap-group.py",
                             String(proc.processId),
                             root.pluginDir + "/"])
  }

  // Shares the [menu] surface tokens, so a theme that styles the Omarchy
  // menu styles this picker too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent

  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Math.max(Style.space(38), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int contentSpacing: Style.spacing.md
  readonly property int cardWidth: Math.min(Style.space(760), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  readonly property int gridWidth: cardWidth - contentMargin * 2
  readonly property int columns: (store && store.columns) || 8
  readonly property int cellSize: Math.max(Style.space(30), Math.floor(gridWidth / columns))
  readonly property int sectionHeight: Math.max(Style.space(22), Style.font.bodySmall + Style.spacing.md * 2)

  readonly property var currentItem: (view.flat.length > 0 && cursor >= 0 && cursor < view.flat.length)
    ? view.flat[cursor] : null
  readonly property string currentText: Model.withTone(currentItem, store.skinTone)
  readonly property bool currentPinned: currentItem
    ? (store.pinned.indexOf(currentItem.e) >= 0) : false

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    root.opened = true
    root.mode = "grid"
    root.query = ""
    root.categoryFilter = ""
    root.status = ""
    root.cursor = 0
    root.cursorActive = true
    pointerGate.reset()
    root.rebuild()
    // Both answers arrive asynchronously, so whatever needs saying is said by
    // the handler that learns it, not here, where it would report the
    // previous open's answer.
    root.refreshEnvironment()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.mode = "grid"
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ----------------------------------------------------------- model wiring

  function loadData(raw) {
    root.emojiData = Model.parseData(raw)
    root.byChar = Model.itemsByChar(root.emojiData.items)
    root.rebuild()
  }

  function loadStore(raw) {
    var parsed = Model.parseState(raw)
    root.storeRejected = parsed.rejected || ""
    root.store = parsed
    root.storeLoaded = true
    root.rebuild()
    if (root.opened && root.storeRejected)
      root.flash("Preferences file ignored (" + root.storeRejected + "), using defaults")
  }

  // Publishing goes through state.py for the same reason reading does: the
  // path's parent directories are as replaceable as the file, and a rename
  // relative to a checked directory descriptor is the only way to be sure the
  // file that appears is the file that was written. The newest document wins;
  // a save arriving mid-write is queued rather than dropped.
  function saveStore() {
    if (!root.storeLoaded) return
    root.pendingWrite = Model.serializeState(root.store)
    root.startWrite()
  }

  function startWrite() {
    if (stateWriter.running || !root.pendingWrite) return
    root.writingText = root.pendingWrite
    root.pendingWrite = ""
    stateWriter.stdinEnabled = true
    stateWriter.running = true
  }

  function mutateStore(changes) {
    var next = Model.parseState(Model.serializeState(root.store))
    for (var key in changes) next[key] = changes[key]
    root.store = next
    root.saveStore()
  }

  function rebuild() {
    var options = {
      pinned: root.store.pinned,
      pinnedIndex: Model.pinnedIndexOf(root.store.pinned),
      usage: root.store.usage,
      keywords: root.store.keywords,
      byChar: root.byChar,
      group: root.categoryFilter,
      columns: root.columns,
      recentRows: root.store.recentLimit,
      now: Date.now(),
      limit: 600
    }
    var built = Model.buildSections(root.emojiData, root.query, options)
    root.fuzzyResults = built.fuzzy
    root.view = Model.layout(built.sections, root.columns)

    if (root.view.flat.length === 0) root.cursor = 0
    else if (root.cursor >= root.view.flat.length) root.cursor = root.view.flat.length - 1
    else if (root.cursor < 0) root.cursor = 0
    root.cursorActive = root.view.flat.length > 0
    Qt.callLater(root.scrollToCursor)
  }

  function scrollToCursor() {
    if (root.view.flat.length === 0) return
    var row = Model.rowOfCursor(root.view, root.cursor)
    if (row < 0) return
    // A cursor on the first row of a section should show that section's
    // header, or you land on "Flags" with no way to know it.
    var target = (row > 0 && root.view.rows[row - 1].kind === "header") ? row - 1 : row
    grid.positionViewAtIndex(target, ListView.Contain)
  }

  function setQuery(next) {
    root.query = String(next)
    root.cursor = 0
    root.cursorActive = true
    pointerGate.reset()
    root.rebuild()
    return "ok"
  }

  function moveCursor(dx, dy) {
    if (root.view.flat.length === 0) return
    pointerGate.reset()
    root.cursorActive = true
    root.cursor = Model.move(root.view, root.cursor, dx, dy)
    root.scrollToCursor()
  }

  function setCursor(index) {
    if (root.view.flat.length === 0) return "empty"
    root.cursorActive = true
    root.cursor = Math.max(0, Math.min(Number(index) || 0, root.view.flat.length - 1))
    root.scrollToCursor()
    return "ok"
  }

  function cursorFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.cursor = index
  }

  function setCategory(group) {
    root.categoryFilter = String(group || "")
    root.cursor = 0
    root.rebuild()
    return "ok"
  }

  function cycleCategory(delta) {
    var all = [""].concat(root.emojiData.groups)
    var at = all.indexOf(root.categoryFilter)
    if (at < 0) at = 0
    root.setCategory(all[(at + delta + all.length) % all.length])
  }

  // -------------------------------------------------------------- actions

  function flash(message) {
    root.status = message
    statusTimer.restart()
  }

  function recordUse(emoji) {
    var now = Date.now()
    root.mutateStore({ usage: Model.pruneUsage(Model.recordUse(root.store.usage, emoji, now), now, 200) })
  }

  // Run as a child rather than detached, so a failure is observable and a hang
  // is killable. One insert at a time, with the newest request queued: a
  // second paste arriving mid-paste must not race the first for ownership of
  // the clipboard.
  function emitText(text, kind, keepOpen) {
    if (!text) return
    root.pendingInsert = { kind: kind, text: text }
    root.startInsert()
    if (!keepOpen) root.dismiss()
  }

  function startInsert() {
    if (!root.pendingInsert) return
    if (insertProc.running) {
      // Supersede rather than queue behind it: the running paste owns the
      // clipboard, and two of them racing for it is how the wrong character
      // lands. Ending it restores the previous owner, and onExited starts
      // this one.
      insertWatchdog.endNow()
      return
    }
    var job = root.pendingInsert
    root.pendingInsert = null
    insertProc.command = [root.pluginDir + "/insert.py", job.kind, job.text]
    insertProc.running = true
  }

  function insertCurrent(kind, keepOpen) {
    return root.insertToned(root.store.skinTone, kind, keepOpen)
  }

  // The tone submenu inserts with the tone you picked and leaves the default
  // alone, the way Raycast's "Paste with Skin Tone…" does. Changing the
  // default is a preference, and a menu that quietly rewrites one is a menu
  // people stop trusting.
  function insertToned(tone, kind, keepOpen) {
    var item = root.currentItem
    if (!item) return "empty"
    var text = Model.withTone(item, tone)
    var effective = (kind === "paste" && !root.canPaste) ? "copy" : kind
    root.recordUse(item.e)
    root.emitText(text, effective, keepOpen)
    if (keepOpen) root.flash((effective === "copy" ? "Copied " : "Pasted ") + text)
    return "ok"
  }

  function primaryAction() {
    return root.canPaste && root.store.primaryAction === "paste" ? "paste" : "copy"
  }

  function activateIndex(index) {
    if (root.setCursor(index) !== "ok") return "empty"
    return root.insertCurrent(root.primaryAction(), false)
  }

  function installPaste() {
    root.dismiss()
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-install-app", "wtype", "wtype"])
    return "ok"
  }

  function copyUnicode() {
    if (!root.currentItem) return "empty"
    var label = Model.unicodeLabel(root.currentText)
    root.emitText(label, "copy", true)
    root.flash("Copied " + label)
    return "ok"
  }

  function togglePin() {
    if (!root.currentItem) return "empty"
    var pinned = root.currentPinned
    root.mutateStore({ pinned: Model.togglePinned(root.store.pinned, root.currentItem.e) })
    root.rebuild()
    root.flash(pinned ? "Unpinned" : "Pinned " + root.currentText)
    return "ok"
  }

  // ---------------------------------------------------------------- menus

  function openMenu(kind) {
    root.menuKind = kind
    root.menuEntries = root.entriesFor(kind)
    if (root.menuEntries.length === 0) return "empty"
    root.menuIndex = root.defaultMenuIndex(kind)
    root.mode = "menu"
    Qt.callLater(function() { choiceMenu.positionAt(root.menuIndex) })
    return "ok"
  }

  function closeMenu() {
    root.mode = "grid"
    root.menuKind = ""
    root.menuEntries = []
  }

  function entriesFor(kind) {
    var out = []
    if (kind === "actions") {
      var primary = root.primaryAction()
      var needsWtype = root.canPaste ? "" : "needs wtype"
      if (!root.canPaste)
        out.push({ id: "install-wtype", label: "Install wtype", hint: "opens a terminal" })
      out.push({ id: "primary", label: primary === "paste" ? "Paste" : "Copy", hint: "Enter" })
      out.push({ id: primary === "paste" ? "copy" : "paste",
                 label: primary === "paste" ? "Copy" : "Paste",
                 hint: primary === "paste" ? "Ctrl+Enter" : (needsWtype || "Ctrl+Enter") })
      out.push({ id: "keep", label: "Paste and Keep Open", hint: needsWtype || "Ctrl+Shift+Enter" })
      out.push({ id: "unicode", label: "Copy Unicode", hint: "Ctrl+Alt+Shift+C" })
      out.push({ id: "pin", label: root.currentPinned ? "Unpin" : "Pin", hint: "Ctrl+." })
      if (Model.toneCount(root.currentItem) > 0)
        out.push({ id: "tone", label: "Skin Tone…", hint: "Ctrl+T" })
      out.push({ id: "keywords", label: "Assign Keywords…", hint: "Ctrl+E" })
      out.push({ id: "category", label: "Filter by Category…", hint: "Tab" })
      out.push({ id: "prefs", label: "Preferences…", hint: "Ctrl+," })
      return out
    }
    if (kind === "tone") {
      var item = root.currentItem
      if (!item || !item.t) return []
      out.push({ id: "0", label: root.store.skinTone === 0 ? "Default" : "Default (preference)",
                 preview: Model.withTone(item, root.store.skinTone) })
      for (var i = 0; i < item.t.length; i++)
        out.push({ id: String(i + 1), label: root.emojiData.toneNames[i] || ("Tone " + (i + 1)), preview: item.t[i] })
      return out
    }
    if (kind === "category") {
      out.push({ id: "", label: "All Categories" })
      for (var g = 0; g < root.emojiData.groups.length; g++)
        out.push({ id: root.emojiData.groups[g], label: root.emojiData.groups[g] })
      return out
    }
    if (kind === "prefs") {
      out.push({ id: "primaryAction", label: "Primary Action",
                 hint: root.store.primaryAction === "paste" ? "Paste" : "Copy" })
      out.push({ id: "skinTone", label: "Default Skin Tone",
                 hint: root.store.skinTone === 0 ? "Default" : (root.emojiData.toneNames[root.store.skinTone - 1] || "") })
      out.push({ id: "columns", label: "Grid Columns", hint: String(root.store.columns) })
      out.push({ id: "recentLimit", label: "Recently Used Rows", hint: String(root.store.recentLimit) })
      return out
    }
    return out
  }

  function defaultMenuIndex(kind) {
    if (kind === "tone") return root.store.skinTone
    if (kind === "category") {
      var at = root.emojiData.groups.indexOf(root.categoryFilter)
      return at < 0 ? 0 : at + 1
    }
    return 0
  }

  function refreshMenu() {
    root.menuEntries = root.entriesFor(root.menuKind)
  }

  function adjustPreference(index, delta) {
    var entry = root.menuEntries[index]
    if (!entry) return
    if (entry.id === "primaryAction") {
      root.mutateStore({ primaryAction: root.store.primaryAction === "paste" ? "copy" : "paste" })
    } else if (entry.id === "skinTone") {
      root.mutateStore({ skinTone: (root.store.skinTone + delta + 6) % 6 })
    } else if (entry.id === "columns") {
      var cols = root.store.columns + delta
      if (cols < 6) cols = 10
      if (cols > 10) cols = 6
      root.mutateStore({ columns: cols })
      root.rebuild()
    } else if (entry.id === "recentLimit") {
      var rows = root.store.recentLimit + delta
      if (rows < 0) rows = 5
      if (rows > 5) rows = 0
      root.mutateStore({ recentLimit: rows })
      root.rebuild()
    }
    root.refreshMenu()
  }

  function chooseMenu(index) {
    var entry = root.menuEntries[index]
    if (!entry) return
    if (root.menuKind === "actions") {
      root.closeMenu()
      if (entry.id === "primary") root.insertCurrent(root.primaryAction(), false)
      else if (entry.id === "paste") root.insertCurrent("paste", false)
      else if (entry.id === "copy") root.insertCurrent("copy", false)
      else if (entry.id === "keep") root.insertCurrent("paste", true)
      else if (entry.id === "unicode") root.copyUnicode()
      else if (entry.id === "pin") root.togglePin()
      else if (entry.id === "tone") root.openMenu("tone")
      else if (entry.id === "keywords") root.openKeywordEditor()
      else if (entry.id === "category") root.openMenu("category")
      else if (entry.id === "prefs") root.openMenu("prefs")
      else if (entry.id === "install-wtype") root.installPaste()
      return
    }
    if (root.menuKind === "tone") {
      var tone = Number(entry.id)
      root.closeMenu()
      root.insertToned(tone, root.primaryAction(), false)
      return
    }
    if (root.menuKind === "category") {
      root.closeMenu()
      root.setCategory(entry.id)
      return
    }
    if (root.menuKind === "prefs") {
      root.adjustPreference(index, 1)
      return
    }
  }

  // ----------------------------------------------------------- keywords

  function openKeywordEditor() {
    if (!root.currentItem) return "empty"
    root.keywordDraft = String(root.store.keywords[root.currentItem.e] || "")
    root.mode = "keywords"
    return "ok"
  }

  function saveKeywords() {
    var item = root.currentItem
    if (item) {
      var next = {}
      for (var k in root.store.keywords) next[k] = root.store.keywords[k]
      var trimmed = root.keywordDraft.trim()
      if (trimmed) next[item.e] = trimmed
      else delete next[item.e]
      root.mutateStore({ keywords: next })
      root.flash(trimmed ? "Keywords saved" : "Keywords cleared")
    }
    root.mode = "grid"
  }

  // ------------------------------------------------------- support seams

  // Keyboard focus inside a layer-shell surface cannot be synthesised from
  // outside, so every decision input is readable and every move is callable:
  //   omarchy-shell shell call <id> stateJson ""
  function stateJson() {
    var item = root.currentItem
    return JSON.stringify({
      opened: root.opened,
      mode: root.mode,
      writing: stateWriter.running,
      query: root.query,
      category: root.categoryFilter,
      fuzzy: root.fuzzyResults,
      cursor: root.cursor,
      results: root.view.flat.length,
      rows: root.view.rows.length,
      columns: root.columns,
      current: item ? item.e : "",
      currentName: item ? Model.displayName(item, root.store.skinTone) : "",
      currentText: root.currentText,
      pinned: root.store.pinned.length,
      skinTone: root.store.skinTone,
      primaryAction: root.store.primaryAction,
      canPaste: root.canPaste,
      status: root.status,
      menu: root.menuKind,
      menuIndex: root.menuIndex,
      items: root.emojiData.items.length
    })
  }

  function moveBy(spec) {
    var parts = String(spec || "0,0").split(",")
    root.moveCursor(Number(parts[0]) || 0, Number(parts[1]) || 0)
    return "ok"
  }

  function setKeywordDraft(text) {
    root.keywordDraft = String(text || "")
    return "ok"
  }

  function menuOpen(kind) { return root.openMenu(String(kind)) }
  function menuSelect(index) {
    root.menuIndex = Math.max(0, Math.min(Number(index) || 0, root.menuEntries.length - 1))
    choiceMenu.positionAt(root.menuIndex)
    return "ok"
  }
  function menuActivate() { root.chooseMenu(root.menuIndex); return "ok" }

  // ---------------------------------------------------------- key routing

  readonly property string menuTitle: {
    if (menuKind === "actions") return "Actions"
    if (menuKind === "tone") return "Skin Tone"
    if (menuKind === "category") return "Filter by Category"
    if (menuKind === "prefs") return "Preferences"
    return ""
  }

  readonly property int pageRows: Math.max(1, Math.floor(grid.height / Math.max(1, cellSize)) - 1)

  function handleGridKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    event.accepted = true

    if (event.key === Qt.Key_Escape) {
      if (root.categoryFilter) root.setCategory("")
      else if (root.query) root.setQuery("")
      else root.dismiss()
    } else if (event.key === Qt.Key_Tab) {
      root.cycleCategory(1)
    } else if (event.key === Qt.Key_Backtab) {
      root.cycleCategory(-1)
    } else if (ctrl && alt && shift && event.key === Qt.Key_C) {
      root.copyUnicode()
    } else if (ctrl && event.key === Qt.Key_K) {
      root.openMenu("actions")
    } else if (ctrl && event.key === Qt.Key_Period) {
      root.togglePin()
    } else if (ctrl && event.key === Qt.Key_E) {
      root.openKeywordEditor()
    } else if (ctrl && event.key === Qt.Key_T) {
      root.openMenu("tone")
    } else if (ctrl && event.key === Qt.Key_Comma) {
      root.openMenu("prefs")
    } else if (Util.editsFilter(event, root.query)) {
      root.setQuery(Util.editedFilter(event, root.query))
    } else if (event.key === Qt.Key_Left) {
      root.moveCursor(-1, 0)
    } else if (event.key === Qt.Key_Right) {
      root.moveCursor(1, 0)
    } else if (event.key === Qt.Key_Up) {
      root.moveCursor(0, -1)
    } else if (event.key === Qt.Key_Down) {
      root.moveCursor(0, 1)
    } else if (event.key === Qt.Key_PageUp) {
      root.moveCursor(0, -root.pageRows)
    } else if (event.key === Qt.Key_PageDown) {
      root.moveCursor(0, root.pageRows)
    } else if (event.key === Qt.Key_Home) {
      root.setCursor(0)
    } else if (event.key === Qt.Key_End) {
      root.setCursor(root.view.flat.length - 1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!root.cursorActive && root.view.flat.length > 0) root.cursorActive = true
      else if (ctrl && shift) root.insertCurrent("paste", true)
      else if (ctrl) root.insertCurrent(root.primaryAction() === "paste" ? "copy" : "paste", false)
      else root.insertCurrent(root.primaryAction(), false)
    } else if (event.text && event.text.length === 1
               && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
               && !ctrl && !alt) {
      root.setQuery(root.query + event.text)
    } else {
      event.accepted = false
    }
  }

  function handleMenuKey(event) {
    var count = root.menuEntries.length
    event.accepted = true

    if (event.key === Qt.Key_Escape) {
      root.closeMenu()
    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
      if (count > 0) {
        var delta = event.key === Qt.Key_Down ? 1 : -1
        root.menuIndex = (root.menuIndex + delta + count) % count
        choiceMenu.positionAt(root.menuIndex)
      }
    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
      if (root.menuKind === "prefs") root.adjustPreference(root.menuIndex, event.key === Qt.Key_Right ? 1 : -1)
    } else if (event.key === Qt.Key_Home) {
      root.menuIndex = 0
      choiceMenu.positionAt(0)
    } else if (event.key === Qt.Key_End) {
      root.menuIndex = Math.max(0, count - 1)
      choiceMenu.positionAt(root.menuIndex)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.chooseMenu(root.menuIndex)
    } else {
      event.accepted = false
    }
  }

  function handleKeywordKey(event) {
    event.accepted = true

    if (event.key === Qt.Key_Escape) {
      root.mode = "grid"
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.saveKeywords()
    } else if (Util.editsFilter(event, root.keywordDraft)) {
      root.keywordDraft = Util.editedFilter(event, root.keywordDraft)
    } else if (event.text && event.text.length === 1
               && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
               && !(event.modifiers & Qt.ControlModifier)) {
      // Bounded here as well as in the model, so the field cannot grow past
      // what will survive being saved and read back.
      if (root.keywordDraft.length < Model.MAX_KEYWORD_CHARS)
        root.keywordDraft = root.keywordDraft + event.text
    } else {
      event.accepted = false
    }
  }

  // ------------------------------------------------------------ processes

  FileView {
    id: dataFile
    path: root.pluginDir + "/emoji-data.json"
    printErrors: true
    onLoaded: root.loadData(text())
    onLoadFailed: root.loadData("{}")
  }

  // FileView is gone from this path entirely. It takes a string, follows every
  // component of it, reads without a ceiling, and publishes through the same
  // mutable path, none of which is safe for a file in a directory anything
  // running as the user can replace. state.py walks the directory chain with
  // O_NOFOLLOW, checks each component, and reads and renames relative to the
  // descriptor that survived those checks.
  Process {
    id: stateReader
    command: [root.pluginDir + "/state.py", "read"]
    clearEnvironment: true
    environment: root.childEnvironment
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadStore(text)
    }
    onRunningChanged: {
      if (running) stateWatchdog.arm()
      else stateWatchdog.stop()
    }
  }

  Watchdog { id: stateWatchdog; proc: stateReader }

  Process {
    id: stateWriter
    command: [root.pluginDir + "/state.py", "write"]
    clearEnvironment: true
    environment: root.childEnvironment
    // The document goes over stdin, not argv: it is up to 64 KiB and argv is
    // world-readable in /proc.
    onStarted: {
      stateWriter.write(root.writingText)
      stateWriter.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.flash("Preferences could not be saved")
      root.startWrite()
    }
    onRunningChanged: {
      if (running) writerWatchdog.arm()
      else writerWatchdog.stop()
    }
  }

  Watchdog { id: writerWatchdog; proc: stateWriter }

  Process {
    id: pasteProbe
    command: [root.pluginDir + "/insert.py", "probe"]
    clearEnvironment: true
    environment: root.childEnvironment
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.canPaste = String(text).trim() === "1"
        // Never on top of a rejected-preferences message: that one is rarer
        // and the user has probably not seen it before.
        if (root.opened && !root.canPaste && !root.status)
          root.flash("wtype is not installed, so Enter copies. Ctrl+K to install it")
      }
    }
    onRunningChanged: {
      if (running) probeWatchdog.arm()
      else probeWatchdog.stop()
    }
  }

  Watchdog { id: probeWatchdog; proc: pasteProbe }

  Process {
    id: insertProc
    clearEnvironment: true
    environment: root.childEnvironment
    onRunningChanged: {
      if (running) insertWatchdog.arm()
      else insertWatchdog.stop()
    }
    onExited: function(exitCode) {
      // 3 is insert.py saying it copied because wtype is not there. Anything
      // else nonzero is a real failure and the user should hear about it
      // rather than watching nothing happen.
      if (exitCode === 3) {
        root.canPaste = false
        root.flash("wtype is missing, so it was copied instead")
      } else if (exitCode !== 0) {
        root.flash("Could not insert (status " + exitCode + ")")
      }
      root.startInsert()
    }
  }

  Watchdog { id: insertWatchdog; proc: insertProc }

  // Nothing this component started outlives it. Each group is ended and
  // waited out by a detached reaper, because a child of a component being
  // destroyed cannot be relied on to finish the job.
  Component.onDestruction: {
    root.reapGroup(stateReader)
    root.reapGroup(stateWriter)
    root.reapGroup(insertProc)
    root.reapGroup(pasteProbe)
  }

  // Both are re-run on open rather than only at load, so installing wtype or
  // editing the preferences file by hand takes effect at the next summon
  // instead of at the next shell restart.
  function refreshEnvironment() {
    if (!pasteProbe.running) pasteProbe.running = true
    if (!stateReader.running) stateReader.running = true
  }

  Component.onCompleted: root.refreshEnvironment()

  Timer {
    id: statusTimer
    interval: 2200
    onTriggered: root.status = ""
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // --------------------------------------------------------------- surface

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-emoji-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.mode === "grid" ? 0 : 20
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.mode === "menu") { root.handleMenuKey(event); return }
          if (root.mode === "keywords") { root.handleKeywordKey(event); return }
          root.handleGridKey(event)
        }

        ChoiceMenu {
          id: choiceMenu
          anchors.fill: parent
          visible: root.mode === "menu"
          title: root.menuTitle
          entries: root.menuEntries
          selectedIndex: root.menuIndex
          showsPreview: root.menuKind === "tone"
          background: root.background
          foreground: root.foreground
          borderColor: root.borderColor
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onActivated: function(index) { root.menuIndex = index; root.chooseMenu(index) }
          onHovered: function(index) { root.menuIndex = index }
          onDismissed: root.closeMenu()
        }

        // Keyword editing is a one-line prompt rather than a TextField:
        // showing and hiding a focused text item is what breaks keyboard
        // focus in a layer-shell surface.
        Item {
          anchors.fill: parent
          visible: root.mode === "keywords"

          Rectangle {
            anchors.fill: parent
            color: Util.alpha(root.background, 0.66)
            MouseArea { anchors.fill: parent; onClicked: root.mode = "grid" }
          }

          Rectangle {
            width: Style.space(380)
            height: Style.space(120)
            anchors.centerIn: parent
            radius: root.cornerRadius
            color: root.background
            border.width: Style.normalBorderWidth
            border.color: Util.alpha(root.borderColor, 0.7)

            MouseArea { anchors.fill: parent; onClicked: {} }

            Column {
              anchors.fill: parent
              anchors.margins: Style.spacing.panelPadding
              spacing: Style.spacing.md

              Text {
                width: parent.width
                text: "Keywords for " + root.currentText + " " + (root.currentItem ? root.currentItem.n : "")
                color: root.foreground
                opacity: 0.65
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Rectangle {
                width: parent.width
                height: Style.space(34)
                radius: root.cornerRadius
                color: Util.alpha(root.foreground, 0.08)

                Text {
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  text: root.keywordDraft || "Type keywords, space separated"
                  color: root.foreground
                  opacity: root.keywordDraft ? 1 : 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  verticalAlignment: Text.AlignVCenter
                  elide: Text.ElideLeft
                }
              }

              Text {
                width: parent.width
                text: "Enter  Save     Esc  Cancel"
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ------------------------------------------------------- header
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: searchText
            anchors.left: parent.left
            anchors.right: categoryChip.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.query || "Search emojis and symbols…"
            color: root.foreground
            opacity: root.query ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }

          Rectangle {
            id: categoryChip
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: chipLabel.implicitWidth + Style.spacing.rowPaddingX * 2
            height: Style.space(24)
            radius: root.cornerRadius
            color: root.categoryFilter ? Util.alpha(root.accent, 0.22) : Util.alpha(root.foreground, 0.08)

            Text {
              id: chipLabel
              anchors.centerIn: parent
              text: (root.categoryFilter || "All Categories") + "   Tab"
              color: root.foreground
              opacity: root.categoryFilter ? 1 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openMenu("category")
            }
          }
        }

        // --------------------------------------------------------- grid
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          ListView {
            id: grid
            anchors.fill: parent
            model: root.view.rows.length
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: false
            pixelAligned: true
            cacheBuffer: Math.max(0, root.cellSize * 6)
            visible: root.view.flat.length > 0

            delegate: Item {
              id: rowItem
              required property int index

              readonly property var rowData: root.view.rows[index] || ({ kind: "header", title: "" })
              readonly property bool isHeader: rowData.kind === "header"

              width: ListView.view.width
              height: isHeader ? root.sectionHeight : root.cellSize

              Text {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.xs
                visible: rowItem.isHeader
                text: rowItem.isHeader ? (rowItem.rowData.title + "  " + rowItem.rowData.count) : ""
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.capitalization: Font.AllUppercase
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
              }

              Row {
                anchors.left: parent.left
                anchors.top: parent.top
                height: parent.height
                spacing: 0
                visible: !rowItem.isHeader

                Repeater {
                  model: rowItem.isHeader ? 0 : rowItem.rowData.cells.length

                  delegate: Rectangle {
                    id: cell
                    required property int index

                    readonly property var item: rowItem.rowData.cells[index]
                    readonly property int flatIndex: rowItem.rowData.first + index
                    readonly property bool hasCursor: root.cursorActive && flatIndex === root.cursor
                    readonly property bool pinned: cell.item && root.store.pinned.indexOf(cell.item.e) >= 0

                    width: root.cellSize
                    height: root.cellSize
                    radius: root.cornerRadius
                    color: hasCursor ? root.selectedBackground : "transparent"
                    // Some themes make the selected fill nearly the card
                    // colour, and a cursor you have to hunt for is not one.
                    border.width: hasCursor ? Math.max(1, Style.normalBorderWidth) : 0
                    border.color: Util.alpha(root.accent, 0.75)

                    Text {
                      anchors.centerIn: parent
                      text: cell.item ? Model.withTone(cell.item, root.store.skinTone) : ""
                      // Colour emoji ignore this; the text symbol blocks do
                      // not, and default black on a dark card is invisible.
                      color: cell.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Math.round(root.cellSize * 0.54)
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                    }

                    // Pinning is a state, so it gets the accent and a corner
                    // rather than a second copy of the emoji somewhere.
                    Rectangle {
                      visible: cell.pinned
                      anchors.top: parent.top
                      anchors.right: parent.right
                      anchors.margins: Style.space(9)
                      width: Style.space(5)
                      height: width
                      radius: width / 2
                      color: root.accent
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: function(mouse) { root.cursorFromPointer(cell.flatIndex, cell, mouse) }
                      onClicked: root.activateIndex(cell.flatIndex)
                    }
                  }
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            width: parent.width
            spacing: Style.space(8)
            visible: root.view.flat.length === 0

            Text {
              text: "󰞅"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.emojiData.items.length === 0
                ? "Emoji data is missing"
                : "No matches for “" + root.query + "”"
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.emojiData.items.length === 0
                ? "Run tools/build-data.py in the plugin folder"
                : "Backspace to edit the search, or Tab to change category"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }

        // ------------------------------------------------------- footer
        Item {
          width: parent.width
          height: root.footerHeight

          Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.normalBorderWidth
            color: Util.alpha(root.borderColor, 0.28)
          }

          Text {
            id: footerName
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: footerHints.left
            anchors.rightMargin: Style.spacing.md
            // The identity of what the cursor is on, said once. Transient
            // messages borrow the line rather than adding a second one.
            text: {
              if (root.status) return root.status
              if (!root.currentItem) return ""
              return root.currentText + "  " + Model.displayName(root.currentItem, root.store.skinTone)
                + "  ·  " + Model.unicodeLabel(root.currentText)
            }
            color: root.foreground
            opacity: root.status ? 1 : 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            id: footerHints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: (root.primaryAction() === "paste" ? "Enter  Paste" : "Enter  Copy") + "     Ctrl+K  Actions"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
