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
  // False until the user moves the selection after open; while false every
  // rebuild re-selects the active window (fresh focus data can arrive late),
  // so SUPER+E then Enter always returns to the window you came from.
  property bool selectionTouched: false
  // Hover only selects after the pointer has really moved since open (Qt sends
  // synthetic hover events when a surface appears under a still cursor), so a
  // thumbnail that happens to sit under the pointer does not steal the selection.
  property bool hoverArmed: false
  property var hoverOrigin: null

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
  //   layout:         "grid" (default; a box per workspace replicating the monitor, windows at
  //                   their real position and size) | "columns" (one column per workspace) |
  //                   "rows" (one row per workspace,
  //                   left-aligned; more than three workspaces wrap into two columns)
  //   animate:        "all" (default) - the whole overview is drawn around the live
  //                   desktop at 1:1 (grid: the current workspace's box over the real
  //                   screen; columns/rows: the active window's thumbnail over the real
  //                   window) and zooms into view | "current" (true) - windows of the
  //                   current workspace fly from their real place on screen into their
  //                   thumbnail slot | "none" (false)
  //   animationDuration: milliseconds for that animation (default 250, 60-1000)
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
    var v = String(root.settings.layout || "grid").toLowerCase()
    return v === "rows" || v === "columns" ? v : "grid"
  }
  readonly property bool layoutRows: root.layoutMode === "rows"
  readonly property bool layoutGrid: root.layoutMode === "grid"
  readonly property string animateMode: {
    var v = root.settings.animate
    if (v === undefined || v === null) return "all"
    if (v === true) return "current"
    if (v === false) return "none"
    var s = String(v).trim().toLowerCase()
    if (s === "current" || s === "all" || s === "none") return s
    if (s === "true" || s === "on") return "current"
    if (s === "false" || s === "off") return "none"
    console.warn("git-spren.overview: unknown animate value", v, "- using all")
    return "all"
  }
  readonly property bool animate: root.animateMode !== "none"
  readonly property bool animateCurrent: root.animateMode === "current"
  readonly property bool animateAll: root.animateMode === "all"
  readonly property int animationMs: {
    var v = Number(root.settings.animationDuration)
    return isFinite(v) && v > 0 ? Math.max(60, Math.min(1000, Math.round(v))) : 250
  }

  // Fly-in phases: 0 closed, 1 opened but thumbnails still hidden (waiting for
  // fresh window geometry), 2 thumbnails flying / shown, 3 flying back (closing).
  property int flyPhase: 0
  property bool flying: false
  // True while the reverse animation plays; `opened` stays true until it ends so
  // the host keeps treating the overlay as open.
  property bool closing: false
  // Headers / zebra bands fade out with the "current" reverse animation.
  property real chromeOpacity: 1
  // Whole-overlay fade over the second half of the close, so the thumbnails
  // vanish while still settling instead of sitting still and then snapping.
  property real closeOpacity: 1
  readonly property int closeMs: Math.round(root.animationMs * 0.9)
  // Set when closing because a window / workspace was chosen: the reverse
  // animation then lands on that workspace instead of the one we came from.
  // { workspace: HyprlandWorkspace, toplevel: HyprlandToplevel | null }
  property var closeTarget: null
  // "all" animation: Scale+Translate on the whole content, scrim fading in alongside.
  property real zoomScale: 1
  property real zoomTX: 0
  property real zoomTY: 0
  property real zoomScrim: 1
  property real zoomToScale: 1
  property real zoomToTX: 0
  property real zoomToTY: 0
  // ms spent waiting (after the 45 ms geometry wait) for the current
  // workspace's captures, so the 1:1 start frame shows real content.
  property int flyWaited: 0

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
    if (root.closing) root.finishClose()
    root.closeTarget = null
    root.targetScreen = root.screenForFocusedMonitor()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.selectionTouched = false
    root.hoverArmed = false
    root.hoverOrigin = null
    root.selectedIndex = -1
    root.query = ""
    root.rebuild()
    root.flyPhase = root.animate ? 1 : 2
    root.flyWaited = 0
    root.opened = true
    if (root.animate) flyTimer.restart()
    // IPC data (window positions) arrives a moment later; re-sort once it does.
    settleTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Host hide / toggle, Escape, backdrop click: play the opening animation in
  // reverse, then really close. A second close while that runs snaps shut.
  function close() {
    if (!root.opened) return
    if (root.closing || !root.animate || root.flyPhase < 2) { root.finishClose(); return }
    root.closing = true
    flyTimer.stop(); flyEndTimer.stop(); settleTimer.stop(); rebuildTimer.stop()
    if (root.animateAll) {
      root.startZoomBack()
    } else {
      root.flying = true
      root.flyPhase = 3
      chromeOutAnim.start()
    }
    closeFadeAnim.start()
    closeTimer.restart()
  }

  function finishClose() {
    closeTimer.stop(); zoomAnim.stop(); zoomOutAnim.stop(); chromeOutAnim.stop(); closeFadeAnim.stop()
    flyTimer.stop(); flyEndTimer.stop()
    root.opened = false
    root.closing = false
    root.flyPhase = 0
    root.flying = false
    root.zoomScale = 1; root.zoomTX = 0; root.zoomTY = 0; root.zoomScrim = 1
    root.chromeOpacity = 1
    root.closeOpacity = 1
    root.closeTarget = null
  }

  // Close with the reverse animation landing on `target` (see closeTarget);
  // falls back to an instant close when there is nothing to land on.
  function closeToward(target) {
    var ok = target && target.workspace && root.animate && !root.closing && root.flyPhase >= 2
      && root.groupIndexOfWorkspace(target.workspace) >= 0
      && target.workspace.monitor && target.workspace.monitor.name === root.overlayMonitorName()
    if (!ok) { root.dismissNow(); return }
    root.closeTarget = target
    root.dismiss()
  }

  // Ask the host to hide us; it calls close() back, so this animates.
  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else root.close()
  }

  // Close at once (the desktop is about to change under us).
  function dismissNow() {
    root.finishClose()
    root.dismiss()
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
    var selectedAddress = root.selectionTouched && root.selectedToplevel() ? root.selectedToplevel().address : ""
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
    if (root.query !== "") root.selectBestMatch()
  }

  function scheduleRebuild() {
    if (root.closing) return   // keep the model still while we animate out
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

  // Name of the monitor the overlay is shown on.
  function overlayMonitorName() {
    if (root.targetScreen && root.targetScreen.name) return root.targetScreen.name
    return Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  }

  function sameWorkspace(a, b) {
    return !!a && !!b && (a === b || (typeof a.id === "number" && a.id === b.id))
  }

  function groupIndexOfWorkspace(ws) {
    for (var g = 0; g < root.groups.length; g++)
      if (root.sameWorkspace(root.groups[g].workspace, ws)) return g
    return -1
  }

  // Where a window will sit on the overlay's monitor once its workspace is
  // shown (Hyprland keeps real positions for windows on hidden workspaces).
  function landingRect(toplevel) {
    var ipc = root.ipcOf(toplevel)
    if (!ipc || !ipc.at || !ipc.size || ipc.mapped === false) return null
    if (ipc.size[0] <= 0 || ipc.size[1] <= 0) return null
    var mon = toplevel.monitor
    if (!mon || mon.name !== root.overlayMonitorName()) return null
    var mx = typeof mon.x === "number" ? mon.x : 0
    var my = typeof mon.y === "number" ? mon.y : 0
    return { x: ipc.at[0] - mx, y: ipc.at[1] - my, w: ipc.size[0], h: ipc.size[1] }
  }

  // Where a thumbnail flies to when closing: its window's real place on the
  // chosen workspace (closeTarget), otherwise the current one.
  function flyBackRect(toplevel) {
    if (!root.closeTarget) return root.flySource(toplevel)
    if (!toplevel || !root.sameWorkspace(toplevel.workspace, root.closeTarget.workspace)) return null
    return root.landingRect(toplevel)
  }

  // ---- "all" animation: the overview starts drawn around the live desktop ----

  // Index of the group for the workspace shown on the overlay's monitor.
  function homeGroupIndex() {
    var mon = Hyprland.focusedMonitor
    for (var g = 0; g < root.groups.length; g++) {
      var ws = root.groups[g].workspace
      if (ws && ws.focused) return g
    }
    for (var h = 0; h < root.groups.length; h++) {
      var w = root.groups[h].workspace
      if (w && w.active && w.monitor && mon && w.monitor.name === mon.name) return h
    }
    return -1
  }

  // Which on-screen rectangle (`from`, scene coords, identity transform) should
  // start out covering which real rectangle (`to`): the current workspace's box
  // over the whole monitor in the grid layout, otherwise the active window's
  // thumbnail over the real window, otherwise the current group filling the screen.
  function zoomAnchor() {
    var target = root.closeTarget
    var gi = target ? root.groupIndexOfWorkspace(target.workspace) : root.homeGroupIndex()
    var item = gi >= 0 ? groupRepeater.itemAt(gi) : null
    if (!item) return null
    if (root.layoutGrid) {
      var r = item.replicaRegion()
      return r && r.w > 0 ? { from: r, to: { x: 0, y: 0, w: panel.width, h: panel.height } } : null
    }
    // Columns / rows: the chosen window's thumbnail (else any window of the
    // chosen workspace, else the active window) over its real place.
    for (var i = 0; i < root.thumbItems.length; i++) {
      var t = root.thumbItems[i]
      if (!t || t.flatIndex < 0 || t.flatIndex >= root.flat.length) continue
      var tl = root.flat[t.flatIndex].toplevel
      if (target) {
        if (target.toplevel ? tl !== target.toplevel : !root.sameWorkspace(tl.workspace, target.workspace)) continue
      } else if (!root.isActive(tl)) {
        continue
      }
      var dst = root.flyBackRect(tl)
      var fg = t.frameGeometry()
      if (dst && fg.w > 0) return { from: fg, to: dst }
      if (!target || target.toplevel) break
    }
    var gr = item.sceneRect()
    if (gr.w <= 0 || gr.h <= 0) return null
    var s = Math.min(panel.width / gr.w, panel.height / gr.h)
    return { from: gr, to: { x: (panel.width - gr.w * s) / 2, y: (panel.height - gr.h * s) / 2, w: gr.w * s, h: gr.h * s } }
  }

  function homeThumbsReady() {
    var gi = root.homeGroupIndex()
    if (gi < 0) return true
    for (var i = 0; i < root.thumbItems.length; i++) {
      var t = root.thumbItems[i]
      if (!t || t.flatIndex < 0 || t.flatIndex >= root.flat.length) continue
      if (root.flat[t.flatIndex].group === gi && !t.hasContent) return false
    }
    return true
  }

  // Scale + translation that puts the anchor over the real desktop. Measured
  // with the identity transform, so callers must have reset zoomScale/TX/TY.
  function zoomTarget() {
    var a = root.zoomAnchor()
    if (a) {
      var s = a.to.w / a.from.w
      return { s: s,
               x: a.to.x + a.to.w / 2 - (a.from.x + a.from.w / 2) * s,
               y: a.to.y + a.to.h / 2 - (a.from.y + a.from.h / 2) * s }
    }
    // Nothing to anchor on (empty current workspace): a gentle zoom from the centre.
    return { s: 1.08, x: (1 - 1.08) * panel.width / 2, y: (1 - 1.08) * panel.height / 2 }
  }

  function startZoomAll() {
    zoomAnim.stop(); zoomOutAnim.stop()
    root.zoomScale = 1; root.zoomTX = 0; root.zoomTY = 0
    var t = root.zoomTarget()
    root.zoomScale = t.s
    root.zoomTX = t.x
    root.zoomTY = t.y
    root.zoomScrim = 0
    zoomAnim.start()
  }

  // Reverse: from wherever the zoom is right now back onto the desktop. The
  // anchor is measured at identity and the in-flight values restored before
  // the animation starts, so nothing jumps even when closing mid-open.
  function startZoomBack() {
    zoomAnim.stop()
    var cur = { s: root.zoomScale, x: root.zoomTX, y: root.zoomTY }
    root.zoomScale = 1; root.zoomTX = 0; root.zoomTY = 0
    var t = root.zoomTarget()
    root.zoomScale = cur.s; root.zoomTX = cur.x; root.zoomTY = cur.y
    root.zoomToScale = t.s
    root.zoomToTX = t.x
    root.zoomToTY = t.y
    zoomOutAnim.start()
  }

  // Called with scene coordinates on every pointer move over a thumbnail.
  function pointerMoved(index, sx, sy) {
    if (root.closing) return
    if (!root.hoverArmed) {
      if (!root.hoverOrigin) { root.hoverOrigin = { x: sx, y: sy }; return }
      if (Math.abs(sx - root.hoverOrigin.x) < 8 && Math.abs(sy - root.hoverOrigin.y) < 8) return
      root.hoverArmed = true
    }
    if (!root.isMatch(index)) return
    root.selectionTouched = true
    root.selectedIndex = index
  }

  function selectedToplevel() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.flat.length) return null
    return root.flat[root.selectedIndex].toplevel
  }

  // ---- actions -----------------------------------------------------------

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

  // Hyprland ignores foreign-toplevel activate requests unless
  // misc:focus_on_activate is set, so focus through the dispatcher instead.
  function activate(toplevel) {
    if (!toplevel) return
    var addr = String(toplevel.address || "")
    if (addr.length > 0) {
      if (addr.indexOf("0x") !== 0) addr = "0x" + addr
      Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = " + root.luaString("address:" + addr) + " })"])
    } else if (toplevel.wayland) {
      toplevel.wayland.activate()
    } else if (toplevel.workspace) {
      root.focusWorkspace(toplevel.workspace, false)
    }
    root.closeToward({ workspace: toplevel.workspace, toplevel: toplevel })
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
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = " + root.luaString(target) + " })"])
    if (dismissAfter !== false) root.closeToward({ workspace: workspace, toplevel: null })
  }

  function focusWorkspaceById(id) {
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++)
      if (all[i].id === id) { root.focusWorkspace(all[i]); return }
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = " + root.luaString(id) + " })"])
    root.dismissNow()
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
    root.selectionTouched = true
    if (root.flat.length === 0) return
    if (root.selectedIndex < 0) { root.selectedIndex = 0; return }
    var cur = root.flat[root.selectedIndex]
    var g = cur.group, i = cur.item
    var n = root.groups.length
    if (dGroup !== 0) {
      // Next group with a match; land on the match closest to the current row.
      for (var step = 0; step < n; step++) {
        g = ((g + dGroup) % n + n) % n
        var best = -1
        for (var j = 0; j < root.groups[g].toplevels.length; j++)
          if (root.isMatch(root.groups[g].firstIndex + j) && (best < 0 || Math.abs(j - i) < Math.abs(best - i))) best = j
        if (best >= 0) { i = best; break }
      }
      if (best < 0) return
    }
    if (dItem !== 0) {
      var m = root.groups[g].toplevels.length
      for (var s = 0; s < m; s++) {
        i = ((i + dItem) % m + m) % m
        if (root.isMatch(root.groups[g].firstIndex + i)) break
      }
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
    root.selectionTouched = true
    if (root.flat.length === 0) return
    var items = root.thumbItems.filter(function(t) {
      return t && t.flatIndex >= 0 && t.flatIndex < root.flat.length
        && (root.isMatch(t.flatIndex) || t.flatIndex === root.selectedIndex)
    })
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
    root.selectionTouched = true
    if (root.flat.length === 0) return
    var n = root.flat.length
    var i = root.selectedIndex
    for (var s = 0; s < n; s++) {
      i = ((i + delta) % n + n) % n
      if (root.isMatch(i)) { root.selectedIndex = i; return }
    }
  }

  // ---- search: typing filters, windows that do not match are dimmed ----------
  // Every whitespace-separated token must fuzzy-match one of the window's title,
  // app id, Hyprland class / initialClass or initialTitle.
  property string query: ""
  readonly property int matchCount: {
    var q = root.query, n = 0
    for (var i = 0; i < root.flat.length; i++)
      if (root.matches(root.flat[i].toplevel, q)) n++
    return n
  }

  function searchFields(toplevel) {
    if (!toplevel) return []
    var f = [String(toplevel.title || "")]
    if (toplevel.wayland && toplevel.wayland.appId) f.push(String(toplevel.wayland.appId))
    var ipc = root.ipcOf(toplevel)
    if (ipc) {
      if (ipc["class"]) f.push(String(ipc["class"]))
      if (ipc.initialClass) f.push(String(ipc.initialClass))
      if (ipc.initialTitle) f.push(String(ipc.initialTitle))
    }
    return f
  }

  function wordStart(h, i) { return i === 0 || /[^a-z0-9]/.test(h.charAt(i - 1)) }

  // Score of `needle` (lower case) in `hay`, or -1. Substrings beat scattered
  // subsequences; word starts and consecutive runs score higher.
  function fuzzyScore(needle, hay) {
    var h = hay.toLowerCase()
    var at = h.indexOf(needle)
    if (at >= 0) return 1000 + (root.wordStart(h, at) ? 200 : 0) - Math.min(at, 100)
    var score = 0, j = 0, prev = -2
    for (var i = 0; i < h.length && j < needle.length; i++) {
      if (h.charAt(i) !== needle.charAt(j)) continue
      score += i === prev + 1 ? 10 : root.wordStart(h, i) ? 8 : 1
      prev = i; j++
    }
    return j === needle.length ? score : -1
  }

  function matchScore(toplevel, query) {
    var tokens = String(query).toLowerCase().split(/\s+/).filter(function(t) { return t.length > 0 })
    if (tokens.length === 0) return 0
    var fields = root.searchFields(toplevel)
    var total = 0
    for (var t = 0; t < tokens.length; t++) {
      var best = -1
      for (var f = 0; f < fields.length; f++) best = Math.max(best, root.fuzzyScore(tokens[t], fields[f]))
      if (best < 0) return -1
      total += best
    }
    return total
  }

  function matches(toplevel, query) { return query === "" || root.matchScore(toplevel, query) >= 0 }
  function isMatch(index) {
    return index >= 0 && index < root.flat.length && root.matches(root.flat[index].toplevel, root.query)
  }

  // Keep a selection the user moved to while it still matches, otherwise jump
  // to the best match (ties: earlier in the overview).
  function selectBestMatch() {
    if (root.query === "") return
    if (root.selectionTouched && root.isMatch(root.selectedIndex)) return
    var best = -1, bestScore = -1
    for (var i = 0; i < root.flat.length; i++) {
      var sc = root.matchScore(root.flat[i].toplevel, root.query)
      if (sc > bestScore) { bestScore = sc; best = i }
    }
    if (best >= 0) root.selectedIndex = best
  }

  function setQuery(q) {
    if (q === root.query) return
    var narrowing = q.length > root.query.length
    root.query = q
    if (!narrowing) root.selectionTouched = root.selectionTouched && root.isMatch(root.selectedIndex)
    root.selectBestMatch()
  }

  function handleKey(event) {
    var k = event.key
    if (root.closing) { if (k === Qt.Key_Escape) root.finishClose(); return true }
    var mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)
    if (k === Qt.Key_Escape) { if (root.query !== "") root.setQuery(""); else root.dismiss(); return true }
    if (k === Qt.Key_Backspace) {
      if (mods & Qt.ControlModifier) root.setQuery(root.query.replace(/\S*\s*$/, ""))
      else root.setQuery(root.query.slice(0, -1))
      return true
    }
    if (k === Qt.Key_U && mods === Qt.ControlModifier) { root.setQuery(""); return true }
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
    if (k === Qt.Key_Return || k === Qt.Key_Enter || (k === Qt.Key_Space && root.query === "")) {
      if (root.isMatch(root.selectedIndex)) root.activate(root.selectedToplevel())
      return true
    }
    // Digits jump to a workspace until a search is under way, then they are text.
    if (k >= Qt.Key_0 && k <= Qt.Key_9 && event.modifiers === Qt.NoModifier && root.query === "") {
      var id = k === Qt.Key_0 ? 10 : (k - Qt.Key_0)
      root.focusWorkspaceById(id); return true
    }
    var text = String(event.text || "")
    if (mods === 0 && text.length > 0 && !/[\x00-\x1f\x7f]/.test(text)) {
      if (root.query === "" && /^\s+$/.test(text)) return true
      root.setQuery(root.query + text); return true
    }
    return false
  }

  // ---- IPC helpers: `omarchy-shell shell call git-spren.overview press down` ----

  readonly property var keyNames: ({
    escape: Qt.Key_Escape, left: Qt.Key_Left, right: Qt.Key_Right, up: Qt.Key_Up, down: Qt.Key_Down,
    tab: Qt.Key_Tab, backtab: Qt.Key_Backtab, backspace: Qt.Key_Backspace, "return": Qt.Key_Return, enter: Qt.Key_Enter, space: Qt.Key_Space,
    "0": Qt.Key_0, "1": Qt.Key_1, "2": Qt.Key_2, "3": Qt.Key_3, "4": Qt.Key_4,
    "5": Qt.Key_5, "6": Qt.Key_6, "7": Qt.Key_7, "8": Qt.Key_8, "9": Qt.Key_9
  })

  // Drive the overlay as if a key were pressed (for scripts and testing).
  function press(name) {
    var key = root.keyNames[String(name || "").toLowerCase()]
    if (key === undefined) return "unknown key: " + name
    return root.handleKey({ key: key, modifiers: Qt.NoModifier, text: "" }) ? "ok" : "ignored"
  }

  // Type text into the search as if it were typed (`call git-spren.overview type "fire"`).
  function type(text) {
    if (!root.opened || root.closing) return "ignored"
    root.setQuery(root.query + String(text || ""))
    return "ok"
  }

  // Current model as JSON (for debugging; "state" is taken by Item).
  function dump(arg) {
    var groups = root.groups.map(function(c) {
      return {
        workspace: c.label, monitor: c.sub,
        windows: c.toplevels.map(function(t) {
          return { title: t.title, address: t.address, active: root.isActive(t),
                   matched: root.matches(t, root.query),
                   fly: root.flySource(t),
                   appId: t.wayland ? t.wayland.appId : null }
        })
      }
    })
    return JSON.stringify({ opened: root.opened, closing: root.closing,
                            closeTarget: root.closeTarget ? (root.closeTarget.workspace.id + ":" + (root.closeTarget.toplevel ? root.closeTarget.toplevel.title : "")) : null,
                            selectedIndex: root.selectedIndex,
                            query: root.query, matchCount: root.matchCount,
                            zoom: root.selectedZoom, selectedBorder: String(root.selectedBorderColor),
                            layout: root.layoutMode,
                            animate: root.animateMode, animationDuration: root.animationMs,
                            flyPhase: root.flyPhase, selectionTouched: root.selectionTouched, groups: groups })
  }

  // ---- plumbing ----------------------------------------------------------

  Timer { id: settleTimer; interval: 180; onTriggered: root.rebuild() }
  Timer {
    id: flyTimer; interval: 45
    onTriggered: if (root.opened) {
      if (root.animateAll && root.flyWaited < 300 && !root.homeThumbsReady()) {
        root.flyWaited += 30
        flyTimer.interval = 30
        flyTimer.restart()
        return
      }
      flyTimer.interval = 45
      root.flying = root.animateCurrent
      root.flyPhase = 2
      if (root.animateAll) root.startZoomAll()
      flyEndTimer.restart()
    }
  }
  Timer { id: flyEndTimer; interval: root.animationMs + 80; onTriggered: root.flying = false }

  Timer { id: closeTimer; interval: root.closeMs + 10; onTriggered: root.finishClose() }

  SequentialAnimation {
    id: closeFadeAnim
    PauseAnimation { duration: Math.round(root.animationMs * 0.35) }
    NumberAnimation { target: root; property: "closeOpacity"; to: 0; duration: root.closeMs - Math.round(root.animationMs * 0.35); easing.type: Easing.InOutQuad }
  }

  ParallelAnimation {
    id: zoomOutAnim
    NumberAnimation { target: root; property: "zoomScale"; to: root.zoomToScale; duration: root.animationMs; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "zoomTX"; to: root.zoomToTX; duration: root.animationMs; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "zoomTY"; to: root.zoomToTY; duration: root.animationMs; easing.type: Easing.OutCubic }
    // Landing on another workspace: keep the dim up while Hyprland switches underneath.
    NumberAnimation { target: root; property: "zoomScrim"; to: 0; duration: root.animationMs; easing.type: root.closeTarget ? Easing.InCubic : Easing.OutCubic }
  }

  // "current" reverse: the chrome and the scrim fade while the thumbnails fly back.
  ParallelAnimation {
    id: chromeOutAnim
    NumberAnimation { target: root; property: "chromeOpacity"; to: 0; duration: root.animationMs; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "zoomScrim"; to: 0; duration: root.animationMs; easing.type: root.closeTarget ? Easing.InCubic : Easing.OutCubic }
  }

  ParallelAnimation {
    id: zoomAnim
    NumberAnimation { target: root; property: "zoomScale"; to: 1; duration: root.animationMs; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "zoomTX"; to: 0; duration: root.animationMs; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "zoomTY"; to: 0; duration: root.animationMs; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "zoomScrim"; to: 1; duration: root.animationMs; easing.type: Easing.OutCubic }
  }
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
      opacity: root.zoomScrim * root.closeOpacity
    }

    // Extra dimming so thumbnails read against a busy desktop.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.55)
      opacity: root.zoomScrim * root.closeOpacity
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
        // "all": stay hidden until the zoom starts (phase 2), then appear at once.
        opacity: (root.opened && !(root.animateAll && root.flyPhase < 2) ? 1 : 0) * root.closeOpacity
        Behavior on opacity { enabled: !root.animateAll && !root.closing; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        transform: [
          Scale { origin.x: 0; origin.y: 0; xScale: root.zoomScale; yScale: root.zoomScale },
          Translate { x: root.zoomTX; y: root.zoomTY }
        ]

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
          // Only the rows layout needs an explicit row count (it flows top to
          // bottom); elsewhere Grid derives rows from columns, which avoids a
          // transient "more items than rows*columns" warning on layout changes.
          rows: root.layoutRows ? Math.max(1, root.rowsPerColumn) : -1
          flow: root.layoutRows ? Grid.TopToBottom : Grid.LeftToRight
          columnSpacing: root.columnGap
          rowSpacing: root.rowGap
          verticalItemAlignment: root.layoutRows || root.layoutGrid ? Grid.AlignVCenter : Grid.AlignTop
          horizontalItemAlignment: root.layoutRows ? Grid.AlignLeft : Grid.AlignHCenter

          Repeater {
            id: groupRepeater
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

      // Search field: appears once you type, centred in the top margin.
      Rectangle {
        id: searchPill
        readonly property bool shown: root.query !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(Style.space(8), (root.outerMargin - height) / 2)
        width: Math.min(parent.width - Style.space(32), Math.max(Style.space(280), searchRow.implicitWidth + Style.space(32)))
        height: searchRow.implicitHeight + Style.space(14)
        radius: height / 2
        color: Util.alpha(root.surface, 0.92)
        border.width: Math.max(1, Style.space(1))
        border.color: root.matchCount === 0 ? root.urgent : root.selectedBorderColor
        opacity: (shown ? 1 : 0) * root.closeOpacity * root.chromeOpacity
        visible: opacity > 0
        Behavior on opacity { enabled: !root.closing; NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

        Row {
          id: searchRow
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(16)
          spacing: Style.space(10)

          Text {
            id: queryText
            width: Math.min(implicitWidth + caret.width + Style.space(2), searchRow.width - countText.implicitWidth - searchRow.spacing * 2)
            rightPadding: caret.width + Style.space(2)
            text: root.query
            textFormat: Text.PlainText
            elide: Text.ElideLeft
            color: root.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.title

            // Caret right after the last glyph (a Row sibling would get the row spacing).
            Rectangle {
              id: caret
              x: Math.min(queryText.contentWidth, queryText.width - queryText.rightPadding) + Style.space(1)
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(2, Style.space(2)); height: queryText.implicitHeight * 0.8
              color: root.text
            }
          }
          Item {
            width: Math.max(0, searchRow.width - queryText.width - countText.implicitWidth - searchRow.spacing * 2)
            height: 1
          }
          Text {
            id: countText
            anchors.verticalCenter: parent.verticalCenter
            text: root.matchCount === 0 ? "no match" : root.matchCount + " / " + root.flat.length
            color: root.matchCount === 0 ? root.urgent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
