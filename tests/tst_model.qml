import QtQuick
import QtTest
import "../EmojiModel.js" as Model

// Everything the picker decides is in EmojiModel.js precisely so it can be
// tested without a shell, a compositor or a font.
TestCase {
  id: suite
  name: "EmojiModel"

  property var sample: ({
    groups: ["Smileys & People", "Food & Drink", "Text Symbols"],
    toneNames: ["Light", "Medium-Light", "Medium", "Medium-Dark", "Dark"],
    items: [
      { e: "😀", n: "grinning face", g: "Smileys & People", s: "face-smiling", k: "grinning face smile happy", u: "U+1F600" },
      { e: "👋", n: "waving hand", g: "Smileys & People", s: "hand-fingers-open", k: "waving hand hello hi wave", u: "U+1F44B",
        t: ["👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"] },
      { e: "🍕", n: "pizza", g: "Food & Drink", s: "food-prepared", k: "pizza cheese slice food", u: "U+1F355" },
      { e: "🍔", n: "hamburger", g: "Food & Drink", s: "food-prepared", k: "hamburger burger food", u: "U+1F354" },
      { e: "→", n: "rightwards arrow", g: "Text Symbols", s: "arrows", k: "rightwards arrow arrows", u: "U+2192" }
    ]
  })

  function data() { return Model.parseData(JSON.stringify(suite.sample)) }

  function test_parse_lowercases_names() {
    var parsed = Model.parseData(JSON.stringify({ items: [{ e: "🅰", n: "A Button (blood type)", k: "a" }] }))
    compare(parsed.items.length, 1)
    compare(parsed.items[0].nl, "a button (blood type)")
  }

  function test_parse_survives_garbage() {
    var parsed = Model.parseData("not json at all")
    compare(parsed.items.length, 0)
    compare(parsed.groups.length, 0)
  }

  function test_state_defaults_and_clamping() {
    var state = Model.parseState("{}")
    compare(state.columns, 8)
    compare(state.skinTone, 0)
    compare(state.primaryAction, "paste")
    compare(Model.parseState('{"columns":99}').columns, 10)
    compare(Model.parseState('{"columns":1}').columns, 6)
    compare(Model.parseState('{"skinTone":"3"}').skinTone, 3)
    compare(Model.parseState('{"primaryAction":"copy"}').primaryAction, "copy")
  }

  function test_state_round_trips() {
    var state = Model.parseState("{}")
    state.pinned = ["🍕"]
    state.keywords = { "🍕": "friday" }
    var back = Model.parseState(Model.serializeState(state))
    compare(back.pinned.length, 1)
    compare(back.keywords["🍕"], "friday")
  }

  function test_tone_applies_only_where_supported() {
    var d = data()
    compare(Model.withTone(d.items[1], 3), "👋🏽")
    compare(Model.withTone(d.items[1], 0), "👋")
    compare(Model.withTone(d.items[0], 3), "😀")
    compare(Model.toneCount(d.items[0]), 0)
    compare(Model.toneCount(d.items[1]), 5)
  }

  function test_display_name_marks_tone() {
    var d = data()
    compare(Model.displayName(d.items[1], 0), "waving hand")
    compare(Model.displayName(d.items[1], 1), "waving hand (light)")
    compare(Model.displayName(d.items[0], 1), "grinning face")
  }

  function test_unicode_label_handles_surrogate_pairs() {
    compare(Model.unicodeLabel("😀"), "U+1F600")
    compare(Model.unicodeLabel("→"), "U+2192")
    compare(Model.unicodeLabel("👋🏽"), "U+1F44B U+1F3FD")
  }

  function test_exact_name_wins_over_keyword() {
    var d = data()
    var out = Model.rank(d.items, "pizza", {})
    compare(out.items[0].e, "🍕")
    compare(out.fuzzy, false)
  }

  function test_whole_word_beats_prefix_of_a_longer_name() {
    var items = Model.parseData(JSON.stringify({ items: [
      { e: "⤶", n: "arrow pointing downwards then curving leftwards", g: "Text Symbols", k: "arrow" },
      { e: "⬆️", n: "up arrow", g: "Symbols", k: "up arrow direction" }
    ] })).items
    var out = Model.rank(items, "arrow", {})
    compare(out.items[0].e, "⬆️")
  }

  function test_emoji_edges_out_a_text_symbol_on_a_tie() {
    var items = Model.parseData(JSON.stringify({ items: [
      { e: "⋆", n: "star operator", g: "Text Symbols", k: "star operator" },
      { e: "⭐", n: "star", g: "Symbols", k: "star" }
    ] })).items
    compare(Model.rank(items, "star", {}).items[0].e, "⭐")
  }

  function test_word_match_does_not_fire_mid_word() {
    var items = Model.parseData(JSON.stringify({ items: [
      { e: "x", n: "narrower thing", g: "Symbols", k: "narrower" }
    ] })).items
    // "arrow" appears inside "narrower", so it still matches, but only in the
    // weakest tier rather than as a word.
    var out = Model.rank(items, "arrow", {})
    compare(out.items.length, 1)
    verify(Model.rank(items, "arrow", {}).items[0].e === "x")
  }

  function test_all_tokens_must_match() {
    var d = data()
    compare(Model.rank(d.items, "waving hand", {}).items.length, 1)
    compare(Model.rank(d.items, "waving pizza", {}).items.length, 0)
  }

  function test_keyword_match_is_found() {
    var d = data()
    var out = Model.rank(d.items, "hello", {})
    compare(out.items.length, 1)
    compare(out.items[0].e, "👋")
  }

  function test_custom_keywords_are_searchable() {
    var d = data()
    var out = Model.rank(d.items, "friday", { keywords: { "🍕": "friday night" } })
    compare(out.items.length, 1)
    compare(out.items[0].e, "🍕")
  }

  function test_pinned_sorts_first() {
    var d = data()
    var out = Model.rank(d.items, "food", { pinnedIndex: { "🍔": 0 } })
    compare(out.items[0].e, "🍔")
  }

  function test_frecency_lifts_but_does_not_beat_an_exact_name() {
    var d = data()
    var now = 1000000000000
    // Burgers used ten times recently still lose "pizza" to the emoji
    // actually called pizza.
    var out = Model.rank(d.items, "pizza", { usage: { "🍔": { n: 10, t: now } }, now: now })
    compare(out.items[0].e, "🍕")
    // With no name match to anchor it, the used one leads.
    var food = Model.rank(d.items, "food", { usage: { "🍔": { n: 10, t: now } }, now: now })
    compare(food.items[0].e, "🍔")
  }

  function test_frecency_decays() {
    var now = 1000000000000
    var usage = { "🍕": { n: 4, t: now - 86400000 * 28 } }
    var fresh = Model.frecency({ "🍕": { n: 4, t: now } }, "🍕", now)
    var stale = Model.frecency(usage, "🍕", now)
    verify(stale < fresh)
    fuzzyCompare(stale, 1.0, 0.001)
  }

  function test_fuzzy_fallback_only_when_nothing_matched() {
    var d = data()
    var out = Model.rank(d.items, "grnning", {})
    compare(out.fuzzy, true)
    compare(out.items[0].e, "😀")
    // A strict hit suppresses the fallback entirely.
    compare(Model.rank(d.items, "pizza", {}).fuzzy, false)
  }

  function test_group_filter_restricts_results() {
    var d = data()
    var out = Model.rank(d.items, "", { group: "Food & Drink" })
    compare(out.items.length, 2)
  }

  function test_browse_sections_lead_with_pinned_and_recent() {
    var d = data()
    var now = 1000000000000
    var built = Model.buildSections(d, "", {
      pinned: ["🍕"],
      pinnedIndex: { "🍕": 0 },
      usage: { "👋": { n: 3, t: now } },
      now: now,
      columns: 8,
      recentRows: 2
    })
    compare(built.sections[0].title, "Pinned")
    compare(built.sections[0].items[0].e, "🍕")
    compare(built.sections[1].title, "Recently Used")
    compare(built.sections[1].items[0].e, "👋")
    compare(built.sections[2].title, "Smileys & People")
  }

  function test_pinned_is_not_repeated_in_recent() {
    var d = data()
    var now = 1000000000000
    var built = Model.buildSections(d, "", {
      pinned: ["🍕"], pinnedIndex: { "🍕": 0 },
      usage: { "🍕": { n: 9, t: now } }, now: now, columns: 8, recentRows: 2
    })
    compare(built.sections[0].title, "Pinned")
    compare(built.sections[1].title, "Smileys & People")
  }

  function test_search_collapses_to_one_section() {
    var d = data()
    var built = Model.buildSections(d, "food", { pinned: ["🍕"], pinnedIndex: { "🍕": 0 } })
    compare(built.sections.length, 1)
    compare(built.sections[0].title, "Results")
  }

  function test_fuzzy_section_says_so() {
    var d = data()
    compare(Model.buildSections(d, "grnning", {}).sections[0].title, "Closest matches")
  }

  function test_layout_rows_and_cursor_map() {
    var sections = [
      { title: "Pinned", items: [{ e: "a" }, { e: "b" }, { e: "c" }] },
      { title: "Food", items: [{ e: "d" }, { e: "e" }] }
    ]
    var view = Model.layout(sections, 2)
    // header, 2 cell rows, header, 1 cell row
    compare(view.rows.length, 5)
    compare(view.rows[0].kind, "header")
    compare(view.rows[1].cells.length, 2)
    compare(view.rows[2].cells.length, 1)
    compare(view.flat.length, 5)
    compare(view.pos[2].row, 2)
    compare(view.pos[2].col, 0)
    compare(view.rows[4].first, 3)
  }

  function test_layout_skips_empty_sections() {
    var view = Model.layout([{ title: "Nothing", items: [] }], 4)
    compare(view.rows.length, 0)
    compare(view.flat.length, 0)
  }

  function test_horizontal_move_crosses_sections_and_wraps() {
    var view = Model.layout([
      { title: "A", items: [{ e: "a" }, { e: "b" }] },
      { title: "B", items: [{ e: "c" }] }
    ], 2)
    compare(Model.move(view, 1, 1, 0), 2)
    compare(Model.move(view, 2, 1, 0), 0)
    compare(Model.move(view, 0, -1, 0), 2)
  }

  function test_vertical_move_keeps_column_and_clamps() {
    var view = Model.layout([{ title: "A", items: [{ e: "a" }, { e: "b" }, { e: "c" }] }], 2)
    // a b / c   -> down from b (col 1) clamps onto c
    compare(Model.move(view, 1, 0, 1), 2)
    compare(Model.move(view, 2, 0, -1), 0)
  }

  function test_vertical_move_does_not_wrap() {
    var view = Model.layout([{ title: "A", items: [{ e: "a" }, { e: "b" }] }], 2)
    compare(Model.move(view, 0, 0, -1), 0)
    compare(Model.move(view, 0, 0, 1), 1)
  }

  function test_page_move_stops_at_the_end() {
    var view = Model.layout([{ title: "A", items: [{ e: "a" }, { e: "b" }, { e: "c" }, { e: "d" }] }], 2)
    compare(Model.move(view, 0, 0, 10), 2)
  }

  function test_row_of_cursor() {
    var view = Model.layout([{ title: "A", items: [{ e: "a" }, { e: "b" }, { e: "c" }] }], 2)
    compare(Model.rowOfCursor(view, 0), 1)
    compare(Model.rowOfCursor(view, 2), 2)
  }

  function test_pin_toggles_and_orders_most_recent_first() {
    var pinned = Model.togglePinned([], "🍕")
    compare(pinned.length, 1)
    pinned = Model.togglePinned(pinned, "🍔")
    compare(pinned[0], "🍔")
    pinned = Model.togglePinned(pinned, "🍕")
    compare(pinned.length, 1)
    compare(pinned[0], "🍔")
  }

  function test_record_use_increments() {
    var usage = Model.recordUse({}, "🍕", 5)
    compare(usage["🍕"].n, 1)
    usage = Model.recordUse(usage, "🍕", 9)
    compare(usage["🍕"].n, 2)
    compare(usage["🍕"].t, 9)
  }

  function test_prune_drops_decayed_and_caps() {
    var now = 1000000000000
    var usage = {
      "🍕": { n: 5, t: now },
      "🍔": { n: 1, t: now - 86400000 * 365 },
      "👋": { n: 2, t: now }
    }
    var pruned = Model.pruneUsage(usage, now, 2)
    compare(Object.keys(pruned).length, 2)
    verify(pruned["🍕"] !== undefined)
    verify(pruned["🍔"] === undefined)
  }

  function test_empty_query_browse_has_no_limit_surprise() {
    var d = data()
    var built = Model.buildSections(d, "", { columns: 8, recentRows: 0 })
    var total = 0
    for (var i = 0; i < built.sections.length; i++) total += built.sections[i].items.length
    compare(total, d.items.length)
  }
}
