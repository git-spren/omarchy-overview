// node tests/overview-model.test.js
const assert = require("node:assert/strict")
const path = require("node:path")
const M = require(path.join(__dirname, "..", "OverviewModel.js"))

let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message) }
}

test("parseSetting: zoom presets, numbers and junk", () => {
  assert.equal(M.parseSetting("zoom", "medium"), 1.10)
  assert.equal(M.parseSetting("zoom", " Large "), 1.20)
  assert.equal(M.parseSetting("zoom", 1.5), 1.5)
  assert.equal(M.parseSetting("zoom", "1.3"), 1.3)
  assert.equal(M.parseSetting("zoom", 2.5), undefined)
  assert.equal(M.parseSetting("zoom", "toString"), undefined)
  assert.equal(M.parseSetting("zoom", ""), undefined)
})

test("parseSetting: selectedBorder roles and hex without alpha", () => {
  assert.equal(M.parseSetting("selectedBorder", "Accent"), "accent")
  assert.equal(M.parseSetting("selectedBorder", "#ABC"), "#abc")
  assert.equal(M.parseSetting("selectedBorder", "#a1b2c3"), "#a1b2c3")
  assert.equal(M.parseSetting("selectedBorder", "#a1b2c3d4"), undefined)
  assert.equal(M.parseSetting("selectedBorder", "red"), undefined)
})

test("parseSetting: layout, animate booleans, durations", () => {
  assert.equal(M.parseSetting("layout", "ROWS"), "rows")
  assert.equal(M.parseSetting("layout", "list"), undefined)
  assert.equal(M.parseSetting("animate", true), "current")
  assert.equal(M.parseSetting("animate", "off"), "none")
  assert.equal(M.parseSetting("animate", "all"), "all")
  assert.equal(M.parseSetting("animationDuration", 5), 60)
  assert.equal(M.parseSetting("animationDuration", 5000), 1000)
  assert.equal(M.parseSetting("animationDuration", 0), undefined)
  assert.equal(M.parseSetting("closeFadeEnd", 100), 100)
  assert.equal(M.parseSetting("closeFadeStart", 101), undefined)
})

test("parseSetting: refreshRate and redactNoScreenShare", () => {
  assert.equal(M.parseSetting("refreshRate", "live"), "live")
  assert.equal(M.parseSetting("refreshRate", 0), 0)
  assert.equal(M.parseSetting("refreshRate", 0.1), 0.5)
  assert.equal(M.parseSetting("refreshRate", 61), undefined)
  assert.equal(M.parseSetting("redactNoScreenShare", false), false)
  assert.equal(M.parseSetting("redactNoScreenShare", "false"), undefined)
  assert.equal(M.parseSetting("backdrop", "Wallpaper"), "wallpaper")
  assert.equal(M.parseSetting("backdrop", "dim"), "dim")
  assert.equal(M.parseSetting("backdrop", "black"), undefined)
  assert.equal(M.parseSetting("nope", 1), undefined)
})

test("every default parses", () => {
  for (const key of Object.keys(M.settingDefaults))
    assert.notEqual(M.parseSetting(key, M.settingDefaults[key]), undefined, key)
})

test("findOwnEntry: plugins[] first, then bar layout, else null", () => {
  const id = "git-spren.overview"
  assert.deepEqual(M.findOwnEntry({ plugins: [{ id: "x" }, { id, layout: "rows" }] }, id), { id, layout: "rows" })
  assert.deepEqual(M.findOwnEntry({ bar: { layout: { right: [{ id, zoom: 1.2 }] } } }, id), { id, zoom: 1.2 })
  assert.equal(M.findOwnEntry({ plugins: "junk" }, id), null)
  assert.equal(M.findOwnEntry(null, id), null)
})

test("parseSetArgument: key=value, JSON object, errors", () => {
  assert.deepEqual(M.parseSetArgument("layout=rows"), { changes: { layout: "rows" } })
  assert.deepEqual(M.parseSetArgument(" zoom = 1.3 "), { changes: { zoom: 1.3 } })
  assert.deepEqual(M.parseSetArgument("animate=false"), { changes: { animate: false } })
  assert.deepEqual(M.parseSetArgument('{"zoom":1.3}'), { changes: { zoom: 1.3 } })
  assert.match(M.parseSetArgument("{nope").error, /^invalid JSON/)
  assert.match(M.parseSetArgument("[1]").error, /^usage/)
  assert.match(M.parseSetArgument("=x").error, /^usage/)
})

test("luaString escapes quotes, backslashes and control characters", () => {
  assert.equal(M.luaString("name:web"), '"name:web"')
  assert.equal(M.luaString('a"b\\c'), '"a\\"b\\\\c"')
  assert.equal(M.luaString("x\ny"), '"x\\010y"')
  assert.equal(M.luaString("\x001"), '"\\0001"')
  assert.equal(M.luaString(null), '""')
})

test("hasTag strips the dynamic-tag star", () => {
  assert.equal(M.hasTag(["overview-redact*"], "overview-redact"), true)
  assert.equal(M.hasTag(["overview-redact"], "overview-redact"), true)
  assert.equal(M.hasTag(["overview-redactx"], "overview-redact"), false)
  assert.equal(M.hasTag(null, "overview-hide"), false)
  assert.equal(M.hasTag({ length: 1, 0: "overview-hide*" }, "overview-hide"), true)
  assert.equal(M.hasTag("overview-hide", "overview-hide"), false)
})

// One window's seven getprop answers, in windowProps order.
function propAnswers(nss, o, oi, of, ovr) {
  const v = [nss, o, oi, of, ovr ? ovr[0] : false, ovr ? ovr[1] : false, ovr ? ovr[2] : false]
  return M.windowProps.map((p, i) => JSON.stringify({ [p]: v[i] }))
}
function decAnswers(a, i, f) {
  return [a, i, f].map(v => JSON.stringify({ option: "x", float: v, set: false }))
}
const joinAnswers = parts => parts.join("\n\n\n") + "\n"

test("windowPropsBatch: every prop per window, then the options", () => {
  const b = M.windowPropsBatch(["a1", "b2"]).split("; ")
  assert.equal(b.length, 2 * M.windowProps.length + 3)
  assert.equal(b[0], "getprop address:0xa1 no_screen_share")
  assert.equal(b[M.windowProps.length], "getprop address:0xb2 no_screen_share")
  assert.equal(b[b.length - 1], "getoption decoration:fullscreen_opacity")
})

test("parseWindowProps: no_screen_share in order, fails closed", () => {
  const nf = Array(M.windowProps.length).fill("window not found")
  const ok = M.parseWindowProps(joinAnswers([...propAnswers(true, 1, 1, 1), ...nf,
    ...propAnswers(false, 1, 1, 1), ...decAnswers(1, 1, 1)]), ["a", "b", "c"])
  assert.deepEqual(ok.map, { a: true, b: false, c: false })
  assert.deepEqual(ok.warnings, [])
  const short = M.parseWindowProps('{"no_screen_share": true}', ["a", "b"])
  assert.deepEqual(short.map, {})
  assert.deepEqual(short.opacity, {})
  assert.equal(short.warnings.length, 1)
  const odd = M.parseWindowProps(joinAnswers([...propAnswers(1, 1, 1, 1),
    ...propAnswers(true, 1, 1, 1), ...decAnswers(1, 1, 1)]), ["a", "b"])
  assert.deepEqual(odd.map, { b: true })
  assert.equal(odd.warnings.length, 1)
  assert.deepEqual(M.parseWindowProps("", []), { map: {}, opacity: {}, warnings: [] })
})

test("parseWindowProps: opacity rules, decoration and overrides", () => {
  const r = M.parseWindowProps(joinAnswers([
    ...propAnswers(false, 0.985, 0.86, 1),
    ...propAnswers(false, 0.5, 0.5, 0.5, [true, false, true]),
    ...Array(M.windowProps.length).fill("window not found"),
    ...decAnswers(1, 0.9, 0.8)]), ["a", "b", "c"])
  assert.deepEqual(r.opacity.a, { active: 0.985, inactive: 0.86 * 0.9, fullscreen: 0.8 })
  assert.deepEqual(r.opacity.b, { active: 0.5, inactive: 0.5 * 0.9, fullscreen: 0.5 })
  // Unknown answers count as opaque rules, still under the decoration options.
  assert.deepEqual(r.opacity.c, { active: 1, inactive: 0.9, fullscreen: 0.8 })
  const junk = M.parseWindowProps(joinAnswers([...propAnswers(false, 7, "x", -1),
    "prop not found", "prop not found", "prop not found"]), ["a"])
  assert.deepEqual(junk.opacity.a, { active: 1, inactive: 1, fullscreen: 1 })
})

test("lastFocusedIndex: lowest focusHistoryID, first without any", () => {
  assert.equal(M.lastFocusedIndex([{ focusHistoryID: 4 }, { focusHistoryID: 1 }, { focusHistoryID: 2 }]), 1)
  assert.equal(M.lastFocusedIndex([undefined, { focusHistoryID: 3 }]), 1)
  assert.equal(M.lastFocusedIndex([{}, undefined]), 0)
  assert.equal(M.lastFocusedIndex([]), -1)
})

test("landingOpacity: active, inactive, fullscreen, unknown", () => {
  const o = { active: 0.985, inactive: 0.86, fullscreen: 1 }
  assert.equal(M.landingOpacity(o, false, true), 0.985)
  assert.equal(M.landingOpacity(o, false, false), 0.86)
  assert.equal(M.landingOpacity(o, true, false), 1)
  assert.equal(M.landingOpacity(undefined, false, false), 1)
})

test("fuzzyScore: substring beats subsequence, word starts win", () => {
  assert.equal(M.fuzzyScore("xyz", "Firefox"), -1)
  assert.ok(M.fuzzyScore("fox", "Firefox") > M.fuzzyScore("ffx", "Firefox"))
  assert.ok(M.fuzzyScore("fire", "Firefox") > M.fuzzyScore("fox", "Firefox"))
  assert.ok(M.fuzzyScore("mo", "Mozilla Firefox") > M.fuzzyScore("mo", "Hammock"))
  assert.ok(M.fuzzyScore("ff", "Firefox") > 0)
})

test("matchScore: every token must match some field", () => {
  const fields = ["Inbox - Mail", "thunderbird"]
  assert.equal(M.matchScore(fields, ""), 0)
  assert.equal(M.matchScore(fields, "   "), 0)
  assert.ok(M.matchScore(fields, "inbox thunder") > 0)
  assert.equal(M.matchScore(fields, "inbox firefox"), -1)
})

function frame(x, y, w, h) { return { x, y, w, h, cx: x + w / 2, cy: y + h / 2 } }

test("pickSpatial: nearest ahead on the line, wrap, then other lines", () => {
  // Two rows of three: indices 0 1 2 / 3 4 5
  const f = [frame(0, 0, 100, 100), frame(200, 0, 100, 100), frame(400, 0, 100, 100),
             frame(0, 200, 100, 100), frame(200, 200, 100, 100), frame(400, 200, 100, 100)]
  assert.equal(M.pickSpatial(f, f[0], 1, 0), 1)
  assert.equal(M.pickSpatial(f, f[2], 1, 0), 0)   // wrap to the farthest behind
  assert.equal(M.pickSpatial(f, f[1], 0, 1), 4)
  assert.equal(M.pickSpatial(f, f[4], 0, 1), 1)   // wrap upwards in the same column
  assert.equal(M.pickSpatial([f[0]], f[0], 1, 0), -1)
  // Nothing on the same line ahead or behind: go to another line.
  const g = [frame(0, 0, 100, 100), frame(300, 300, 100, 100)]
  assert.equal(M.pickSpatial(g, g[0], 1, 0), 1)
})

test("gridMetrics: widest boxes for the aspect ratio", () => {
  assert.deepEqual(M.gridMetrics(0, 1000, 1000, 10, 10, 20, 16 / 9), { cols: 1, boxW: 0 })
  assert.equal(M.gridMetrics(1, 1600, 900, 10, 10, 0, 16 / 9).cols, 1)
  assert.equal(M.gridMetrics(4, 1600, 900, 10, 10, 0, 16 / 9).cols, 2)
  const wide = M.gridMetrics(3, 3000, 400, 10, 10, 0, 16 / 9)
  assert.equal(wide.cols, 3)
  assert.ok(wide.boxW > 0)
})

if (failed) { console.log(failed + " failed"); process.exit(1) }
