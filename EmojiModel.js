.pragma library

// Everything the picker decides, with no QML in it, so qmltestrunner can
// reach it without a running shell. The QML file below is presentation and
// key routing; ranking, sectioning and grid geometry all live here.

var TONE_SUFFIX = ["", " (light)", " (medium-light)", " (medium)", " (medium-dark)", " (dark)"]

// Recently-used weight halves every two weeks. Frecency has to beat a
// mediocre name match without beating an exact one, so the curve saturates
// at FRECENCY_MAX rather than growing with use forever.
var FRECENCY_HALF_LIFE_DAYS = 14
var FRECENCY_MAX = 3000
var FRECENCY_MIDPOINT = 3
var PINNED_BONUS = 100000

function parseData(raw) {
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return { groups: [], toneNames: [], items: [] }
  }
  var items = Array.isArray(data.items) ? data.items : []
  var out = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (!item || !item.e) continue
    // Names arrive in CLDR's mixed case ("A button (blood type)"), and every
    // comparison downstream is lowercase.
    item.nl = String(item.n || "").toLowerCase()
    // Word-boundary form of the name, padded, so " arrow " matches the word
    // and not the middle of "narrower". Precomputed because the alternative
    // is a regex per item per keystroke over four thousand rows.
    item.nw = " " + item.nl.replace(/[^a-z0-9+]+/g, " ").replace(/^ +| +$/g, "") + " "
    out.push(item)
  }
  return {
    groups: Array.isArray(data.groups) ? data.groups : [],
    toneNames: Array.isArray(data.toneNames) ? data.toneNames : [],
    items: out
  }
}

function normalizeQuery(query) {
  return String(query || "").trim().toLowerCase().replace(/\s+/g, " ")
}

function queryTokens(query) {
  var normalized = normalizeQuery(query)
  return normalized ? normalized.split(" ") : []
}

function parseState(raw) {
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    data = null
  }
  if (!data || typeof data !== "object") data = {}
  return {
    pinned: Array.isArray(data.pinned) ? data.pinned.slice() : [],
    usage: data.usage && typeof data.usage === "object" ? data.usage : {},
    keywords: data.keywords && typeof data.keywords === "object" ? data.keywords : {},
    skinTone: clampInt(data.skinTone, 0, 5, 0),
    columns: clampInt(data.columns, 6, 10, 8),
    primaryAction: data.primaryAction === "copy" ? "copy" : "paste",
    recentLimit: clampInt(data.recentLimit, 0, 5, 2)
  }
}

function clampInt(value, min, max, fallback) {
  var n = Math.round(Number(value))
  if (isNaN(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

// The character actually inserted: the base emoji unless a tone is set and
// this emoji has a variant for it. Tone 0 is "default", not "light".
function withTone(item, tone) {
  if (!item) return ""
  if (!tone || !item.t || !item.t[tone - 1]) return item.e
  return item.t[tone - 1]
}

function toneCount(item) {
  return item && item.t ? item.t.length : 0
}

function displayName(item, tone) {
  if (!item) return ""
  var suffix = item.t && tone ? (TONE_SUFFIX[tone] || "") : ""
  return String(item.n || "") + suffix
}

// "U+1F44B U+1F3FB". Built from the emitted character rather than the base
// entry so the label always describes what Enter would insert.
function unicodeLabel(text) {
  var out = []
  var chars = String(text || "")
  for (var i = 0; i < chars.length; i++) {
    var code = chars.codePointAt(i)
    if (code === undefined) break
    if (code > 0xFFFF) i++
    var hex = code.toString(16).toUpperCase()
    while (hex.length < 4) hex = "0" + hex
    out.push("U+" + hex)
  }
  return out.join(" ")
}

function frecency(usage, key, now) {
  var entry = usage ? usage[key] : null
  if (!entry) return 0
  var count = Number(entry.n) || 0
  if (count <= 0) return 0
  var ageDays = Math.max(0, (now - (Number(entry.t) || 0)) / 86400000)
  return count * Math.pow(0.5, ageDays / FRECENCY_HALF_LIFE_DAYS)
}

function frecencyBonus(score) {
  if (score <= 0) return 0
  return FRECENCY_MAX * (score / (score + FRECENCY_MIDPOINT))
}

function wordPrefixHit(haystack, token) {
  if (!haystack) return false
  if (haystack.lastIndexOf(token, 0) === 0) return true
  return haystack.indexOf(" " + token) >= 0
}

function wordEqualsHit(haystack, token) {
  if (!haystack) return false
  return (" " + haystack + " ").indexOf(" " + token + " ") >= 0
}

// A token has to hit something, or the item is not a result at all. The
// tiers are ordered so that what the emoji is called beats what it is
// merely tagged with.
//
// Whole-word beats prefix-of-the-whole-name on purpose. The text symbol
// blocks are full of long descriptive names, and ranking prefixes first put
// "arrow pointing downwards then curving leftwards" above "up arrow" for the
// query "arrow".
function tokenScore(item, token, custom) {
  var name = item.nl
  if (name === token) return 1000
  if (wordEqualsHit(item.nw, token)) return 700
  if (name.lastIndexOf(token, 0) === 0) return 600
  if (wordPrefixHit(item.nw, token)) return 450
  if (custom) {
    if (wordEqualsHit(custom, token)) return 440
    if (wordPrefixHit(custom, token)) return 430
    if (custom.indexOf(token) >= 0) return 300
  }
  if (wordPrefixHit(item.k, token)) return 300
  if (name.indexOf(token) >= 0) return 200
  if (item.k.indexOf(token) >= 0) return 120
  return 0
}

// Emoji edge out text symbols on an otherwise equal match. Someone typing
// "star" in an emoji picker means the star, not U+22C6 STAR OPERATOR.
function groupBonus(item) {
  return item.g === "Text Symbols" ? 0 : 40
}

// Typo tolerance, used only when the strict pass found nothing at all.
// Raycast falls back to an AI lookup there; offline, a subsequence match is
// the honest equivalent and still finds "grnning" -> "grinning face".
function subsequenceScore(haystack, token) {
  if (token.length < 2) return 0
  var hi = 0
  var gaps = 0
  var last = -1
  for (var i = 0; i < token.length; i++) {
    hi = haystack.indexOf(token.charAt(i), hi)
    if (hi < 0) return 0
    if (last >= 0) gaps += hi - last - 1
    last = hi
    hi++
  }
  return Math.max(10, 80 - gaps)
}

function rank(items, query, opts) {
  var options = opts || {}
  var tokens = queryTokens(query)
  var pinnedIndex = options.pinnedIndex || {}
  var usage = options.usage || {}
  var keywords = options.keywords || {}
  var now = options.now || Date.now()
  var group = options.group || ""
  var tone = options.tone || 0
  var limit = options.limit === undefined ? 500 : options.limit

  var strict = []
  var loose = []

  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (group && item.g !== group) continue

    var pinned = pinnedIndex[item.e] !== undefined
    var bonus = (pinned ? PINNED_BONUS - pinnedIndex[item.e] : 0)
      + frecencyBonus(frecency(usage, item.e, now))

    bonus += groupBonus(item)

    if (tokens.length === 0) {
      strict.push({ item: item, score: bonus, order: i })
      continue
    }

    var custom = keywords[item.e] ? String(keywords[item.e]).toLowerCase() : ""
    var total = 0
    var matched = true
    for (var t = 0; t < tokens.length; t++) {
      var s = tokenScore(item, tokens[t], custom)
      if (s === 0) { matched = false; break }
      total += s
    }
    if (matched) {
      strict.push({ item: item, score: bonus + total, order: i })
      continue
    }
    if (strict.length === 0) {
      var fuzzy = 0
      for (var f = 0; f < tokens.length; f++) {
        var fs = subsequenceScore(item.nl, tokens[f])
        if (fs === 0) { fuzzy = 0; break }
        fuzzy += fs
      }
      if (fuzzy > 0) loose.push({ item: item, score: bonus + fuzzy, order: i })
    }
  }

  var pool = strict.length > 0 ? strict : loose
  pool.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    var an = a.item.nl.length, bn = b.item.nl.length
    if (an !== bn) return an - bn
    return a.order - b.order
  })

  var out = []
  var max = limit > 0 ? Math.min(limit, pool.length) : pool.length
  for (var o = 0; o < max; o++) out.push(pool[o].item)
  return { items: out, fuzzy: strict.length === 0 && loose.length > 0 }
}

function pinnedIndexOf(pinned) {
  var index = {}
  for (var i = 0; i < pinned.length; i++) index[pinned[i]] = i
  return index
}

function itemsByChar(items) {
  var index = {}
  for (var i = 0; i < items.length; i++) index[items[i].e] = items[i]
  return index
}

// Browsing shows Pinned and Recently Used above the Unicode categories, the
// way Raycast does. Searching collapses to one ranked list: two orderings on
// one screen would disagree about what "first" means.
function buildSections(data, query, opts) {
  var options = opts || {}
  var tokens = queryTokens(query)
  var group = options.group || ""
  var pinned = options.pinned || []
  var byChar = options.byChar || itemsByChar(data.items)

  if (tokens.length > 0) {
    var ranked = rank(data.items, query, options)
    return {
      sections: ranked.items.length ? [{ title: ranked.fuzzy ? "Closest matches" : "Results", items: ranked.items }] : [],
      fuzzy: ranked.fuzzy
    }
  }

  var sections = []

  if (!group) {
    var pinnedItems = []
    for (var p = 0; p < pinned.length; p++) {
      if (byChar[pinned[p]]) pinnedItems.push(byChar[pinned[p]])
    }
    if (pinnedItems.length) sections.push({ title: "Pinned", items: pinnedItems })

    var recentLimit = options.recentRows === undefined ? 2 : options.recentRows
    if (recentLimit > 0) {
      var recent = recentItems(data.items, options.usage, options.now || Date.now(),
                              recentLimit * (options.columns || 8), options.pinnedIndex || {})
      if (recent.length) sections.push({ title: "Recently Used", items: recent })
    }
  }

  var groups = group ? [group] : data.groups
  for (var g = 0; g < groups.length; g++) {
    var bucket = []
    for (var i = 0; i < data.items.length; i++) {
      if (data.items[i].g === groups[g]) bucket.push(data.items[i])
    }
    if (bucket.length) sections.push({ title: groups[g], items: bucket })
  }

  return { sections: sections, fuzzy: false }
}

function recentItems(items, usage, now, limit, pinnedIndex) {
  if (!usage || limit <= 0) return []
  var scored = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (pinnedIndex && pinnedIndex[item.e] !== undefined) continue
    var score = frecency(usage, item.e, now)
    if (score > 0) scored.push({ item: item, score: score })
  }
  scored.sort(function(a, b) { return b.score - a.score })
  var out = []
  for (var s = 0; s < scored.length && s < limit; s++) out.push(scored[s].item)
  return out
}

// Rows are what the ListView renders: a header, or up to `columns` cells.
// `flat` is the cursor's coordinate space, and `pos` maps a cursor back to
// the row and column it lives in, which is what up/down movement needs.
function layout(sections, columns) {
  var cols = Math.max(1, Math.round(columns || 8))
  var rows = []
  var flat = []
  var pos = []

  for (var s = 0; s < sections.length; s++) {
    var section = sections[s]
    if (!section.items.length) continue
    rows.push({ kind: "header", title: section.title, count: section.items.length })
    for (var i = 0; i < section.items.length; i += cols) {
      var cells = section.items.slice(i, i + cols)
      var rowIndex = rows.length
      rows.push({ kind: "cells", cells: cells, first: flat.length })
      for (var c = 0; c < cells.length; c++) {
        pos.push({ row: rowIndex, col: c })
        flat.push(cells[c])
      }
    }
  }
  return { rows: rows, flat: flat, pos: pos, columns: cols }
}

function rowOfCursor(view, index) {
  if (!view.pos.length) return -1
  var clamped = Math.max(0, Math.min(index, view.pos.length - 1))
  return view.pos[clamped].row
}

// Left/right walk the flat order so they cross section boundaries; up/down
// step to the neighbouring cell row and keep the column where they can.
function move(view, index, dx, dy) {
  if (!view.flat.length) return 0
  var current = Math.max(0, Math.min(index, view.flat.length - 1))

  if (dx) {
    var next = current + dx
    if (next < 0) next = view.flat.length - 1
    if (next >= view.flat.length) next = 0
    return next
  }
  if (!dy) return current

  var here = view.pos[current]
  var step = dy > 0 ? 1 : -1
  var row = here.row + step
  var remaining = Math.abs(dy)
  var target = current

  while (row >= 0 && row < view.rows.length) {
    if (view.rows[row].kind === "cells") {
      var cells = view.rows[row].cells.length
      target = view.rows[row].first + Math.min(here.col, cells - 1)
      remaining--
      if (remaining === 0) return target
      here = view.pos[target]
    }
    row += step
  }
  // Falling off the top or bottom parks on the first or last cell rather
  // than wrapping: a grid that wraps vertically loses people.
  return remaining === Math.abs(dy) ? (dy > 0 ? view.flat.length - 1 : 0) : target
}

function togglePinned(pinned, emoji) {
  var out = []
  var found = false
  for (var i = 0; i < pinned.length; i++) {
    if (pinned[i] === emoji) { found = true; continue }
    out.push(pinned[i])
  }
  if (!found) out.unshift(emoji)
  return out
}

function recordUse(usage, emoji, now) {
  var next = {}
  for (var k in usage) next[k] = usage[k]
  var entry = next[emoji] || { n: 0, t: 0 }
  next[emoji] = { n: (Number(entry.n) || 0) + 1, t: now }
  return next
}

// Usage entries that have decayed past visibility are dead weight in a file
// that is rewritten on every insert.
function pruneUsage(usage, now, keep) {
  var scored = []
  for (var k in usage) {
    var score = frecency(usage, k, now)
    if (score > 0.01) scored.push({ key: k, score: score })
  }
  scored.sort(function(a, b) { return b.score - a.score })
  var out = {}
  var max = Math.min(scored.length, keep || 200)
  for (var i = 0; i < max; i++) out[scored[i].key] = usage[scored[i].key]
  return out
}

function serializeState(state) {
  return JSON.stringify({
    version: 1,
    pinned: state.pinned,
    usage: state.usage,
    keywords: state.keywords,
    skinTone: state.skinTone,
    columns: state.columns,
    primaryAction: state.primaryAction,
    recentLimit: state.recentLimit
  }, null, 2) + "\n"
}
