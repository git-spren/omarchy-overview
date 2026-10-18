// Stateless logic of the overview: settings parsing, search scoring, Lua
// quoting, privacy-tag and no_screen_share parsing, spatial navigation and the
// grid column choice. Plain data in, plain data out, so tests/ can run it under
// node; Overview.qml wraps these with the Hyprland / Quickshell objects.

var settingDefaults = {
  zoom: "medium", selectedBorder: "accent", layout: "grid", animate: "all",
  animationDuration: 350, closeFadeStart: 80, closeFadeEnd: 95, refreshRate: 4,
  redactNoScreenShare: true, backdrop: "wallpaper"
}

var zoomLevels = { small: 1.02, medium: 1.10, large: 1.20 }

// Own keys only: `in` would also accept "toString", "constructor", ...
function hasOwn(obj, key) { return Object.prototype.hasOwnProperty.call(obj, key) }

// Normalised value of one setting, or undefined when `raw` is not valid for
// `key`. selectedBorder yields a palette role ("accent", "selected",
// "foreground", "urgent") or a "#rgb" / "#rrggbb" string; the QML side maps
// roles to theme colours.
function parseSetting(key, raw) {
  var s = typeof raw === "string" ? raw.trim().toLowerCase() : ""
  var n = (typeof raw === "number" || (typeof raw === "string" && s !== "")) ? Number(raw) : NaN
  switch (key) {
  case "zoom":
    if (isFinite(n) && n >= 1 && n <= 2) return n
    return hasOwn(zoomLevels, s) ? zoomLevels[s] : undefined
  case "selectedBorder":
    if (s === "accent" || s === "selected" || s === "foreground" || s === "urgent") return s
    // No alpha forms: Qt reads #aarrggbb (alpha first), not CSS #rrggbbaa.
    if (/^#([0-9a-f]{3}|[0-9a-f]{6})$/.test(s)) return s
    return undefined
  case "layout":
    return s === "grid" || s === "rows" || s === "columns" ? s : undefined
  case "animate":
    if (raw === true || s === "true" || s === "on") return "current"
    if (raw === false || s === "false" || s === "off") return "none"
    return s === "current" || s === "all" || s === "none" ? s : undefined
  case "animationDuration":
    return isFinite(n) && n > 0 ? Math.max(60, Math.min(1000, Math.round(n))) : undefined
  case "closeFadeStart":
  case "closeFadeEnd":
    return isFinite(n) && n >= 0 && n <= 100 ? n : undefined
  case "refreshRate":
    if (s === "live") return "live"
    if (!isFinite(n) || n < 0 || n > 60) return undefined
    return n === 0 ? 0 : Math.max(0.5, n)
  case "redactNoScreenShare":
    return raw === true || raw === false ? raw : undefined
  case "backdrop":
    return s === "wallpaper" || s === "dim" ? s : undefined
  }
  return undefined
}

// Our entry in shell.json: plugins[] (where `omarchy plugin enable` puts an
// overlay), else a bar layout section.
function findOwnEntry(config, id) {
  if (!config || typeof config !== "object") return null
  var lists = [config.plugins]
  var layout = config.bar && config.bar.layout
  if (layout) lists.push(layout.left, layout.center, layout.right)
  for (var l = 0; l < lists.length; l++) {
    var list = lists[l]
    if (!Array.isArray(list)) continue
    for (var i = 0; i < list.length; i++)
      if (list[i] && list[i].id === id) return list[i]
  }
  return null
}

// The argument of `set`: "key=value" (value parsed as JSON, else taken as a
// string) or a JSON object. Returns { changes } or { error }; keys and values
// are not checked here.
function parseSetArgument(arg) {
  var text = String(arg || "").trim()
  if (text.charAt(0) === "{") {
    var obj
    try { obj = JSON.parse(text) } catch (e) { return { error: "invalid JSON: " + e } }
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return { error: "expected a JSON object" }
    return { changes: obj }
  }
  var eq = text.indexOf("=")
  if (eq <= 0) return { error: "usage: set key=value | set '{\"key\": value}'" }
  var raw = text.slice(eq + 1).trim()
  var value
  try { value = JSON.parse(raw) } catch (e) { value = raw }
  var changes = {}
  changes[text.slice(0, eq).trim()] = value
  return { changes: changes }
}

// Quote a value as a Lua string literal for the Lua-mode dispatcher.
// execDetached skips the shell, but Hyprland still parses the argument as
// Lua, and special workspace names are free text, so `"`, `\\` and every
// control character (incl. newlines, which would also end the hyprctl
// request) are escaped as \ddd (three digits so a following digit cannot
// be absorbed).
function luaString(value) {
  var s = String(value === undefined || value === null ? "" : value)
  return "\"" + s.replace(/[\\"\x00-\x1f\x7f]/g, function(c) {
    if (c === "\\") return "\\\\"
    if (c === "\"") return "\\\""
    return "\\" + ("00" + c.charCodeAt(0)).slice(-3)
  }) + "\""
}

// Whether a Hyprland tag list carries `tag`. Dynamic tags (from window rules)
// carry a trailing "*". The list from lastIpcObject is array-like, not an Array.
function hasTag(tags, tag) {
  var list = tags && typeof tags.length === "number" && typeof tags !== "string" ? tags : []
  for (var i = 0; i < list.length; i++)
    if (String(list[i]).replace(/\*$/, "") === tag) return true
  return false
}

// Answers of one `hyprctl -j --batch "getprop address:0x… no_screen_share; …"`
// for `addrs`, as { map: address -> bool, warnings: [...] }. Fails closed:
// answers are matched to windows by position, so a count mismatch (hyprctl
// failed, output changed) leaves every window unknown, and an answer that is
// neither a boolean nor "window not found" leaves that one unknown.
function parseNoScreenShare(text, addrs) {
  var parts = String(text || "").split(/\n\s*\n/).map(function(p) { return p.trim() })
    .filter(function(p) { return p !== "" })
  var map = {}, warnings = []
  if (parts.length !== addrs.length) {
    warnings.push("no_screen_share query gave " + parts.length + " answers for "
                  + addrs.length + " windows; not capturing them")
    return { map: map, warnings: warnings }
  }
  for (var i = 0; i < addrs.length; i++) {
    if (parts[i] === "window not found") { map[addrs[i]] = false; continue }
    var v
    try { v = JSON.parse(parts[i]).no_screen_share } catch (e) {}
    if (v === true || v === false) map[addrs[i]] = v
    else warnings.push("unexpected no_screen_share answer " + JSON.stringify(parts[i]))
  }
  return { map: map, warnings: warnings }
}

function wordStart(h, i) { return i === 0 || /[^a-z0-9]/.test(h.charAt(i - 1)) }

// Score of `needle` (lower case) in `hay`, or -1. Substrings beat scattered
// subsequences; word starts and consecutive runs score higher.
function fuzzyScore(needle, hay) {
  var h = String(hay).toLowerCase()
  var at = h.indexOf(needle)
  if (at >= 0) return 1000 + (wordStart(h, at) ? 200 : 0) - Math.min(at, 100)
  var score = 0, j = 0, prev = -2
  for (var i = 0; i < h.length && j < needle.length; i++) {
    if (h.charAt(i) !== needle.charAt(j)) continue
    score += i === prev + 1 ? 10 : wordStart(h, i) ? 8 : 1
    prev = i; j++
  }
  return j === needle.length ? score : -1
}

// Every whitespace-separated token of `query` must fuzzy-match one of
// `fields`; the sum of the best scores, 0 for an empty query, or -1.
function matchScore(fields, query) {
  var tokens = String(query).toLowerCase().split(/\s+/).filter(function(t) { return t.length > 0 })
  if (tokens.length === 0) return 0
  var total = 0
  for (var t = 0; t < tokens.length; t++) {
    var best = -1
    for (var f = 0; f < fields.length; f++) best = Math.max(best, fuzzyScore(tokens[t], fields[f]))
    if (best < 0) return -1
    total += best
  }
  return total
}

// Index into `frames` ({ x, y, w, h, cx, cy }) of the nearest frame from
// `cur` in direction (dx, dy), or -1. Candidates are ranked in tiers: ahead on
// the same line, then wrap on the same line (farthest behind), then ahead on
// another line, then wrap there. "Same line" means the frames overlap on the
// axis perpendicular to the move. `cur` itself may be in `frames`.
function pickSpatial(frames, cur, dx, dy) {
  var c = cur
  var best = [-1, -1, -1, -1], bestScore = [Infinity, Infinity, Infinity, Infinity]
  for (var k = 0; k < frames.length; k++) {
    var g = frames[k]
    if (g === cur) continue
    var ddx = g.cx - c.cx, ddy = g.cy - c.cy
    var primary = ddx * dx + ddy * dy                         // along the direction
    var secondary = Math.abs(ddx * dy) + Math.abs(ddy * dx)   // off-axis drift
    if (Math.abs(primary) <= 1) continue
    var sameLine = dx !== 0
      ? (g.y < c.y + c.h && g.y + g.h > c.y)
      : (g.x < c.x + c.w && g.x + g.w > c.x)
    var ahead = primary > 0
    var tier = sameLine ? (ahead ? 0 : 1) : (ahead ? 2 : 3)
    var score = ahead ? primary + 1.5 * secondary : 1.5 * secondary - Math.abs(primary)
    if (score < bestScore[tier]) { bestScore[tier] = score; best[tier] = k }
  }
  for (var tr = 0; tr < 4; tr++)
    if (best[tr] >= 0) return best[tr]
  return -1
}

// Grid layout: the column count that gives the widest boxes for `n`
// workspaces of the given aspect ratio in an availW x availH area, as
// { cols, boxW }. headerH is taken from each box's height.
function gridMetrics(n, availW, availH, colGap, rowGap, headerH, aspect) {
  if (n === 0) return { cols: 1, boxW: 0 }
  var best = null
  for (var cols = 1; cols <= n; cols++) {
    var rows = Math.ceil(n / cols)
    var w = (availW - colGap * (cols - 1)) / cols
    var h = (availH - rowGap * (rows - 1)) / rows - headerH
    var boxW = Math.max(0, Math.min(w, h * aspect))
    if (!best || boxW > best.boxW) best = { cols: cols, boxW: boxW }
  }
  return best
}

if (typeof module !== "undefined") {
  module.exports = {
    settingDefaults: settingDefaults,
    zoomLevels: zoomLevels,
    hasOwn: hasOwn,
    parseSetting: parseSetting,
    findOwnEntry: findOwnEntry,
    parseSetArgument: parseSetArgument,
    luaString: luaString,
    hasTag: hasTag,
    parseNoScreenShare: parseNoScreenShare,
    fuzzyScore: fuzzyScore,
    matchScore: matchScore,
    pickSpatial: pickSpatial,
    gridMetrics: gridMetrics
  }
}
