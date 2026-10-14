import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "components"

// Exposé-style overview: every mapped window as a live thumbnail, one column
// per occupied workspace. Hosted by omarchy-shell as an "overlay" plugin, so
// the host drives open()/close() and reads `opened`; self-dismissal must tell
// the host via shell.hide(id) or `omarchy-shell shell toggle` desyncs.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property var targetScreen: null

  // groups: [{ workspace, label, sub, toplevels: [HyprlandToplevel], firstIndex }], one per workspace
  // flat:   [{ group, item, toplevel }] in group order, for keyboard navigation
  property var groups: []
  property string groupSignature: ""
  property var flat: []
  property int selectedIndex: -1

  readonly property string pluginId: (root.manifest && root.manifest.id) || "git-spren.overview"

  // Theme: share the [menu] surface tokens like the other Omarchy overlays.
  // The menu scrim can be quite transparent; thumbnails need a calmer backdrop.
  readonly property color scrim: Util.alpha(Color.menu.scrim, Math.max(Color.menu.scrim.a, 0.82))
  readonly property color surface: Color.menu.background
  readonly property color text: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color selectedBorder: Color.menu.selectedBorder
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property color zebraColor: Util.alpha(Color.foreground, 0.045)

  // ---- user settings (~/.config/omarchy/git-spren.overview.json, hot-reloaded) ----
  //   zoom:           "small" | "medium" | "large" | number 1.0–2.0   (default medium)
  //   selectedBorder: "accent" | "selected" | "foreground" | "urgent" | "#rrggbb"  (default accent)
  //   layout:         "columns" (one column per workspace) | "rows" (one row per workspace,
  //                   left-aligned; more than three workspaces wrap into two columns) |
  //                   "grid" (a box per workspace replicating the monitor, windows at
  //                   their real position and size)
  //   animate:        true | false  (default true) - windows of the current workspace fly
  //                   from their real place on screen into their thumbnail slot
  //   animationDuration: milliseconds for that flight (default 240, 60-1000)
  readonly property string settingsPath: Quickshell.env("HOME") + "/.config/omarchy/git-spren.overview.json"
  property var settings: ({})
  readonly property var zoomLevels: ({ small: 1.02, medium: 1.10, large: 1.20 })
  readonly property real selectedZoom: {
    var z = root.settings.zoom
    if (typeof z === "number" && z >= 1 && z <= 2) return z
    var key = String(z || "medium").toLowerCase()
    return root.zoomLevels[key] !== undefined ? root.zoomLevels[key] : root.zoomLevels.medium
  }
  readonly property color selectedBorderColor: root.colorSetting(root.settings.selectedBorder, root.accent)
  readonly property string layoutMode: {
    var v = String(root.settings.layout || "columns").toLowerCase()
    return v === "rows" || v === "grid" ? v : "columns"
  }
  readonly property bool layoutRows: root.layoutMode === "rows"
  readonly property bool layoutGrid: root.layoutMode === "grid"
  readonly property bool animate: root.settings.animate !== false
  readonly property int animationMs: {
    var v = Number(root.settings.animationDuration)
    return isFinite(v) && v > 0 ? Math.max(60, Math.min(1000, Math.round(v))) : 240
  }

  // Fly-in phases: 0 closed, 1 opened but thumbnails still hidden (waiting for
  // fresh window geometry), 2 thumbnails flying / shown.
  property int flyPhase: 0
  property bool flying: false

  function colorSetting(value, fallback) {
    var v = String(value || "").trim().toLowerCase()
    if (!v || v === "accent") return root.accent
    if (v === "selected") return Color.menu.selectedBorder
    if (v === "foreground") return Color.foreground
    if (v === "urgent") return root.urgent
    if (/^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/.test(v)) return v
    console.warn("git-spren.overview: unknown selectedBorder value", value, "- using accent")
    return fallback
  }

  // Strip // and /* */ comments and trailing commas (outside strings) so the
  // settings file can be JSONC, like Omarchy's own menu config.
  function stripJsonc(text) {
    var out = "", i = 0, n = text.length, inStr = false
    while (i < n) {
      var ch = text[i]
      if (inStr) {
        out += ch
        if (ch === "\\" && i + 1 < n) { out += text[i + 1]; i += 2; continue }
        if (ch === "\"") inStr = false
        i++; continue
      }
      if (ch === "\"") { inStr = true; out += ch; i++; continue }
      if (ch === "/" && text[i + 1] === "/") { while (i < n && text[i] !== "\n") i++; continue }
      if (ch === "/" && text[i + 1] === "*") { i += 2; while (i < n && !(text[i] === "*" && text[i + 1] === "/")) i++; i += 2; continue }
      out += ch; i++
    }
    return out.replace(/,(\s*[}\]])/g, "$1")
  }

  function applySettings(raw) {
    var text = root.stripJsonc(String(raw || "")).trim()
    if (!text) { root.settings = ({}); return }
    try {
      var parsed = JSON.parse(text)
      root.settings = (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : ({})
    } catch (e) {
      console.warn("git-spren.overview: cannot parse " + root.settingsPath + ":", e)
    }
  }

  FileView {
    path: root.settingsPath
    watchChanges: true
    onLoaded: root.applySettings(text())
    onFileChanged: reload()
    onLoadFailed: function(error) { root.settings = ({}) }   // no file = defaults
  }

  // Layout knobs (all in shell-scaled px).
  readonly property int outerMargin: Style.space(56)
  readonly property int columnGap: Style.space(28)
  readonly property int thumbGap: Style.space(18)
  readonly property int headerHeight: Style.space(44)
  readonly property int captionHeight: Style.space(26)
  readonly property int maxColumnWidth: Style.space(800)
  readonly property int minColumnWidth: Style.space(180)
  readonly property int maxThumbHeight: Style.space(480)
  // rows layout
  readonly property int rowGap: Style.space(24)
  readonly property int headerWidth: Style.space(150)
  readonly property int maxRowHeight: Style.space(440)
  readonly property int minRowHeight: Style.space(150)
  readonly property int maxThumbWidth: Style.space(720)
  readonly property int minThumbWidth: Style.space(160)

  readonly property real availWidth: Math.max(0, panel.width - outerMargin * 2)
  readonly property real availHeight: Math.max(0, panel.height - outerMargin * 2)
  readonly property int groupCount: root.groups.length
  readonly property real columnWidth: groupCount === 0 ? 0
    : Math.max(minColumnWidth, Math.min(maxColumnWidth, (availWidth - columnGap * (groupCount - 1)) / groupCount))
  // Grid layout: pick the column count that gives the widest boxes for the
  // focused monitor's aspect ratio.
  readonly property int gridHeaderHeight: Style.space(34)
  readonly property var gridMetrics: {
    var n = root.groupCount
    if (n === 0) return { cols: 1, boxW: 0 }
    var mon = root.monitorLogicalRect(Hyprland.focusedMonitor)
    var aspect = mon.h > 0 ? mon.w / mon.h : 16 / 9
    var best = null
    for (var cols = 1; cols <= n; cols++) {
      var rows = Math.ceil(n / cols)
      var w = (root.availWidth - root.columnGap * (cols - 1)) / cols
      var h = (root.availHeight - root.rowGap * (rows - 1)) / rows - root.gridHeaderHeight
      var boxW = Math.max(0, Math.min(w, h * aspect))
      if (!best || boxW > best.boxW) best = { cols: cols, boxW: boxW }
    }
    return best
  }

  // Logical size and origin of a HyprlandMonitor (falls back to the overlay's own size).
  function monitorLogicalRect(mon) {
    var ipc = mon && mon.lastIpcObject && typeof mon.lastIpcObject === "object" ? mon.lastIpcObject : null
    var scale = ipc && ipc.scale > 0 ? ipc.scale : (mon && mon.scale > 0 ? mon.scale : 1)
    var w = ipc && ipc.width > 0 ? ipc.width / scale : (mon && mon.width > 0 ? mon.width / scale : panel.width)
    var h = ipc && ipc.height > 0 ? ipc.height / scale : (mon && mon.height > 0 ? mon.height / scale : panel.height)
    var transform = ipc && typeof ipc.transform === "number" ? ipc.transform : 0
    if (transform % 2 === 1) { var t = w; w = h; h = t }
    var x = mon && typeof mon.x === "number" ? mon.x : 0
    var y = mon && typeof mon.y === "number" ? mon.y : 0
    return { x: x, y: y, w: Math.max(1, Math.round(w)), h: Math.max(1, Math.round(h)) }
  }

  // A window's rectangle relative to its monitor; unknown geometry fills the monitor.
  function windowRect(toplevel, monRect) {
    var ipc = root.ipcOf(toplevel)
    if (!ipc || !ipc.at || !ipc.size || ipc.size[0] <= 0 || ipc.size[1] <= 0)
      return { x: 0, y: 0, w: monRect.w, h: monRect.h }
    return { x: ipc.at[0] - monRect.x, y: ipc.at[1] - monRect.y, w: ipc.size[0], h: ipc.size[1] }
  }

  // Rows layout: more than three workspaces wrap into two columns, filled top to bottom.
  readonly property int rowColumns: root.layoutRows && groupCount > 3 ? 2 : 1
  readonly property int rowsPerColumn: groupCount === 0 ? 0 : Math.ceil(groupCount / rowColumns)
  readonly property real rowWidth: (availWidth - columnGap * (rowColumns - 1)) / rowColumns
  readonly property real rowHeight: groupCount === 0 ? 0
    : Math.max(minRowHeight, Math.min(maxRowHeight, (availHeight - rowGap * (rowsPerColumn - 1)) / rowsPerColumn))

  // ---- host contract -----------------------------------------------------

  function open(payloadJson) {
    root.targetScreen = root.screenForFocusedMonitor()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.rebuild()
    root.flyPhase = root.animate ? 1 : 2
    root.opened = true
    if (root.animate) flyTimer.restart()
    // IPC data (window positions) arrives a moment later; re-sort once it does.
    settleTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.flyPhase = 0
    root.flying = false
    flyTimer.stop()
    flyEndTimer.stop()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- data --------------------------------------------------------------

  function screenForFocusedMonitor() {
    var screens = Quickshell.screens
    var mon = Hyprland.focusedMonitor
    if (mon) {
      for (var i = 0; i < screens.length; i++)
        if (screens[i].name === mon.name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function ipcOf(toplevel) {
    var ipc = toplevel ? toplevel.lastIpcObject : null
    return (ipc && typeof ipc === "object") ? ipc : null
  }

  function byPosition(a, b) {
    var ia = root.ipcOf(a), ib = root.ipcOf(b)
    if (!ia || !ib || !ia.at || !ib.at) return 0
    if (ia.at[1] !== ib.at[1]) return ia.at[1] - ib.at[1]
    return ia.at[0] - ib.at[0]
  }

  function rebuild() {
    var selectedAddress = root.selectedToplevel() ? root.selectedToplevel().address : ""
    var numbered = [], named = []
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      var ws = all[i]
      if (!ws || !ws.toplevels || ws.toplevels.values.length === 0) continue
      if (ws.id > 0) numbered.push(ws)
      else named.push(ws)
    }
    numbered.sort(function(a, b) { return a.id - b.id })
    named.sort(function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0 })

    var multiMonitor = Hyprland.monitors.values.length > 1
    var groups = [], flat = []
    var ordered = numbered.concat(named)
    for (var g = 0; g < ordered.length; g++) {
      var w = ordered[g]
      var tls = w.toplevels.values.slice()
      tls.sort(root.byPosition)
      var entry = {
        workspace: w,
        label: w.id > 0 ? String(w.id) : String(w.name).replace(/^special:/, ""),
        sub: multiMonitor && w.monitor ? w.monitor.name : "",
        toplevels: tls,
        firstIndex: flat.length
      }
      for (var r = 0; r < tls.length; r++)
        flat.push({ group: g, item: r, toplevel: tls[r] })
      groups.push(entry)
    }
    var signature = groups.map(function(c) {
      return c.label + ":" + c.toplevels.map(function(t) { return t.address }).join(",")
    }).join("|")
    if (signature !== root.groupSignature) {
      root.groupSignature = signature
      root.groups = groups
      root.flat = flat
    }

    var sel = -1
    for (var k = 0; k < flat.length; k++) {
      if (selectedAddress && flat[k].toplevel.address === selectedAddress) { sel = k; break }
    }
    if (sel < 0) {
      for (var a = 0; a < flat.length; a++)
        if (root.isActive(flat[a].toplevel)) { sel = a; break }
    }
    if (sel < 0 && flat.length > 0) sel = 0
    root.selectedIndex = sel
  }

  function scheduleRebuild() {
    if (root.opened) rebuildTimer.restart()
    else refreshTimer.restart()   // keep window geometry fresh for the fly-in
  }

  // Where a window sits on the overlay's monitor right now, in overlay
  // coordinates, or null when it is not visible there (other workspace or
  // monitor, hidden, unmapped).
  function flySource(toplevel) {
    var ipc = root.ipcOf(toplevel)
    if (!ipc || !ipc.at || !ipc.size || ipc.hidden || ipc.mapped === false) return null
    var ws = toplevel.workspace
    var mon = toplevel.monitor
    var focused = Hyprland.focusedMonitor
    if (!ws || !mon || !focused || mon.name !== focused.name) return null
    if (!(ws.active || (ipc.pinned === true))) return null
    var mx = typeof mon.x === "number" ? mon.x : 0
    var my = typeof mon.y === "number" ? mon.y : 0
    if (ipc.size[0] <= 0 || ipc.size[1] <= 0) return null
    return { x: ipc.at[0] - mx, y: ipc.at[1] - my, w: ipc.size[0], h: ipc.size[1] }
  }

  function selectedToplevel() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.flat.length) return null
    return root.flat[root.selectedIndex].toplevel
  }

  // ---- actions -----------------------------------------------------------

  // Hyprland ignores foreign-toplevel activate requests unless
  // misc:focus_on_activate is set, so focus through the dispatcher instead.
  function activate(toplevel) {
    if (!toplevel) return
    var addr = String(toplevel.address || "")
    if (addr.length > 0) {
      if (addr.indexOf("0x") !== 0) addr = "0x" + addr
      Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + addr + "\" })"])
    } else if (toplevel.wayland) {
      toplevel.wayland.activate()
    } else if (toplevel.workspace) {
      root.focusWorkspace(toplevel.workspace, false)
    }
    root.dismiss()
  }

  // `activated` goes false for every window once the overlay takes keyboard
  // focus; hyprctl's focusHistoryID (0 = most recently focused) survives that.
  function isActive(toplevel) {
    var ipc = root.ipcOf(toplevel)
    if (ipc && ipc.focusHistoryID !== undefined) return ipc.focusHistoryID === 0
    return toplevel ? toplevel.activated === true : false
  }

  function focusWorkspace(workspace, dismissAfter) {
    if (!workspace) return
    var target = workspace.id > 0 ? String(workspace.id) : String(workspace.name)
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + target + "\" })"])
    if (dismissAfter !== false) root.dismiss()
  }

  function focusWorkspaceById(id) {
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++)
      if (all[i].id === id) { root.focusWorkspace(all[i]); return }
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + id + "\" })"])
    root.dismiss()
  }

  function iconFor(toplevel) {
    var appId = toplevel && toplevel.wayland ? String(toplevel.wayland.appId || "") : ""
    var entry = appId ? DesktopEntries.heuristicLookup(appId) : null
    var icon = entry && entry.icon ? String(entry.icon) : appId
    if (icon) {
      if (icon.charAt(0) === "/") return Util.fileUrl(icon)
      var themed = Quickshell.iconPath(icon, true)
      if (themed && themed.length > 0) return themed
      themed = Quickshell.iconPath(icon.toLowerCase(), true)
      if (themed && themed.length > 0) return themed
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  // ---- keyboard ----------------------------------------------------------

  // dGroup moves to the neighbouring workspace group, dItem within the group.
  // Both axes wrap around.
  function moveSelection(dGroup, dItem) {
    if (root.flat.length === 0) return
    if (root.selectedIndex < 0) { root.selectedIndex = 0; return }
    var cur = root.flat[root.selectedIndex]
    var g = cur.group, i = cur.item
    var n = root.groups.length
    if (dGroup !== 0) {
      g = ((g + dGroup) % n + n) % n
      i = Math.min(i, root.groups[g].toplevels.length - 1)
    }
    if (dItem !== 0) {
      var m = root.groups[g].toplevels.length
      i = ((i + dItem) % m + m) % m
    }
    root.selectedIndex = root.groups[g].firstIndex + i
  }

  // ---- spatial navigation (grid layout): nearest thumbnail in a direction ----
  property var thumbItems: []

  function registerThumb(item) { root.thumbItems.push(item) }
  function unregisterThumb(item) {
    var i = root.thumbItems.indexOf(item)
    if (i >= 0) root.thumbItems.splice(i, 1)
  }

  // Candidates are ranked in tiers: ahead on the same line, then wrap on the
  // same line (farthest behind), then ahead on another line, then wrap there.
  // "Same line" means the frames overlap on the axis perpendicular to the move.
  function spatialMove(dx, dy) {
    if (root.flat.length === 0) return
    var items = root.thumbItems.filter(function(t) { return t && t.flatIndex >= 0 && t.flatIndex < root.flat.length })
    var cur = null
    for (var i = 0; i < items.length; i++)
      if (items[i].flatIndex === root.selectedIndex) { cur = items[i]; break }
    if (!cur) { root.selectedIndex = items.length ? items[0].flatIndex : 0; return }
    var c = cur.frameGeometry()
    var best = [null, null, null, null], bestScore = [Infinity, Infinity, Infinity, Infinity]
    for (var k = 0; k < items.length; k++) {
      var t = items[k]
      if (t === cur) continue
      var g = t.frameGeometry()
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
      if (score < bestScore[tier]) { bestScore[tier] = score; best[tier] = t }
    }
    for (var tr = 0; tr < 4; tr++)
      if (best[tr]) { root.selectedIndex = best[tr].flatIndex; return }
  }

  function stepSelection(delta) {
    if (root.flat.length === 0) return
    var n = root.flat.length
    root.selectedIndex = ((root.selectedIndex + delta) % n + n) % n
  }

  function handleKey(event) {
    var k = event.key
    if (k === Qt.Key_Escape) { root.dismiss(); return true }
    // Grid: spatial, by on-screen position. Columns: left/right = other
    // workspace, up/down = within it. Rows: transposed.
    if (root.layoutGrid) {
      if (k === Qt.Key_Left) { root.spatialMove(-1, 0); return true }
      if (k === Qt.Key_Right) { root.spatialMove(1, 0); return true }
      if (k === Qt.Key_Up) { root.spatialMove(0, -1); return true }
      if (k === Qt.Key_Down) { root.spatialMove(0, 1); return true }
    }
    var r = root.layoutRows
    if (k === Qt.Key_Left) { r ? root.moveSelection(0, -1) : root.moveSelection(-1, 0); return true }
    if (k === Qt.Key_Right) { r ? root.moveSelection(0, 1) : root.moveSelection(1, 0); return true }
    if (k === Qt.Key_Up) { r ? root.moveSelection(-1, 0) : root.moveSelection(0, -1); return true }
    if (k === Qt.Key_Down) { r ? root.moveSelection(1, 0) : root.moveSelection(0, 1); return true }
    if (k === Qt.Key_Tab) { root.stepSelection(1); return true }
    if (k === Qt.Key_Backtab) { root.stepSelection(-1); return true }
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
      root.activate(root.selectedToplevel()); return true
    }
    if (k >= Qt.Key_0 && k <= Qt.Key_9 && event.modifiers === Qt.NoModifier) {
      var id = k === Qt.Key_0 ? 10 : (k - Qt.Key_0)
      root.focusWorkspaceById(id); return true
    }
    return false
  }

  // ---- IPC helpers: `omarchy-shell shell call git-spren.overview press down` ----

  readonly property var keyNames: ({
    escape: Qt.Key_Escape, left: Qt.Key_Left, right: Qt.Key_Right, up: Qt.Key_Up, down: Qt.Key_Down,
    tab: Qt.Key_Tab, backtab: Qt.Key_Backtab, "return": Qt.Key_Return, enter: Qt.Key_Enter, space: Qt.Key_Space,
    "0": Qt.Key_0, "1": Qt.Key_1, "2": Qt.Key_2, "3": Qt.Key_3, "4": Qt.Key_4,
    "5": Qt.Key_5, "6": Qt.Key_6, "7": Qt.Key_7, "8": Qt.Key_8, "9": Qt.Key_9
  })

  // Drive the overlay as if a key were pressed (for scripts and testing).
  function press(name) {
    var key = root.keyNames[String(name || "").toLowerCase()]
    if (key === undefined) return "unknown key: " + name
    return root.handleKey({ key: key, modifiers: Qt.NoModifier }) ? "ok" : "ignored"
  }

  // Current model as JSON (for debugging; "state" is taken by Item).
  function dump(arg) {
    var groups = root.groups.map(function(c) {
      return {
        workspace: c.label, monitor: c.sub,
        windows: c.toplevels.map(function(t) {
          return { title: t.title, address: t.address, active: root.isActive(t),
                   fly: root.flySource(t),
                   appId: t.wayland ? t.wayland.appId : null }
        })
      }
    })
    return JSON.stringify({ opened: root.opened, selectedIndex: root.selectedIndex,
                            zoom: root.selectedZoom, selectedBorder: String(root.selectedBorderColor),
                            layout: root.layoutMode,
                            animate: root.animate, animationDuration: root.animationMs,
                            flyPhase: root.flyPhase, groups: groups })
  }

  // ---- plumbing ----------------------------------------------------------

  Timer { id: settleTimer; interval: 180; onTriggered: root.rebuild() }
  Timer { id: flyTimer; interval: 45; onTriggered: if (root.opened) { root.flying = true; root.flyPhase = 2; flyEndTimer.restart() } }
  Timer { id: flyEndTimer; interval: root.animationMs + 80; onTriggered: root.flying = false }
  Timer { id: refreshTimer; interval: 120; onTriggered: Hyprland.refreshToplevels() }
  Timer { id: rebuildTimer; interval: 60; onTriggered: { Hyprland.refreshToplevels(); root.rebuild() } }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      if (/^(openwindow|closewindow|movewindow(v2)?|workspace(v2)?|createworkspace(v2)?|destroyworkspace(v2)?|focusedmon(v2)?|activewindow(v2)?|changefloatingmode|fullscreen)$/.test(name))
        root.scheduleRebuild()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "git-spren-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    // Extra dimming so thumbnails read against a busy desktop.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.55)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { event.accepted = root.handleKey(event) }

      Item {
        id: content
        anchors.fill: parent
        opacity: root.opened ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Text {
          visible: root.groupCount === 0
          anchors.centerIn: parent
          text: "No windows open"
          color: root.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Grid {
          id: groupsGrid
          anchors.centerIn: parent
          columns: root.layoutGrid ? root.gridMetrics.cols
                 : root.layoutRows ? root.rowColumns : Math.max(1, root.groupCount)
          rows: root.layoutRows ? Math.max(1, root.rowsPerColumn)
              : root.layoutGrid ? Math.max(1, Math.ceil(root.groupCount / root.gridMetrics.cols)) : 1
          flow: root.layoutRows ? Grid.TopToBottom : Grid.LeftToRight
          columnSpacing: root.columnGap
          rowSpacing: root.rowGap
          verticalItemAlignment: root.layoutRows || root.layoutGrid ? Grid.AlignVCenter : Grid.AlignTop
          horizontalItemAlignment: root.layoutRows ? Grid.AlignLeft : Grid.AlignHCenter

          Repeater {
            model: root.groups

            WorkspaceGroup {
              required property var modelData
              required property int index
              overview: root
              entry: modelData
              groupIndex: index
              mode: root.layoutMode
              groupWidth: root.layoutGrid ? root.gridMetrics.boxW : root.layoutRows ? root.rowWidth : root.columnWidth
              groupHeight: root.layoutRows ? root.rowHeight : root.availHeight
            }
          }
        }
      }
    }
  }
}
