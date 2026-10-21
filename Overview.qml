import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "components"
import "OverviewModel.js" as Model

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
  readonly property color scrim: Util.alpha(Commons.Color.menu.scrim, Math.max(Commons.Color.menu.scrim.a, 0.82))
  readonly property color surface: Commons.Color.menu.background
  readonly property color text: Commons.Color.menu.text
  readonly property color borderColor: Commons.Color.menu.border
  // Faint light-grey edge for plain windows and workspace boxes.
  readonly property color subtleBorderColor: Util.alpha(Commons.Color.menu.border, 0.3)
  readonly property color selectedBorder: Commons.Color.menu.selectedBorder
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color muted: Commons.Color.muted
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property color zebraColor: Util.alpha(Commons.Color.foreground, 0.045)

  // ---- user settings ------------------------------------------------------
  // Settings live inline on this plugin's entry in ~/.config/omarchy/shell.json,
  // as the shell's storage rules ask: { "id": "git-spren.overview", "layout": "rows", ... }.
  // The host gives overlays no way to read that entry, so we read the file ourselves
  // (read-only, watched); writes go through shell.updateEntryInline() via set()/reset().
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
  //   animationDuration: milliseconds for that animation (default 350, 60-1000)
  //   closeFadeStart / closeFadeEnd: when the close fades the overlay out, in percent
  //                   of animationDuration (default 80 / 95, 0-100); the overlay is
  //                   gone at closeFadeEnd
  //   refreshRate:    thumbnail refreshes per second for windows on visible workspaces
  //                   (default 4, 0.5-60), 0 = one snapshot at open, "live" = every frame
  //                   (costly: Hyprland re-renders each window at full size per frame).
  //                   Windows on hidden workspaces are captured once at open.
  //   redactNoScreenShare: true (default) - windows with Hyprland's no_screen_share
  //                   window-rule property are redacted like overview-redact | false
  //   backdrop:       "wallpaper" (default) - the desktop background behind the
  //                   thumbnails, lightly dimmed | "dim" - the dark menu scrim
  readonly property string shellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  // Our entry's fields (without "id"); {} = all defaults.
  property var settings: ({})
  readonly property var settingDefaults: Model.settingDefaults

  // Normalised value of one setting, or undefined when `raw` is not valid for
  // `key` (OverviewModel.js); selectedBorder palette roles become theme colours.
  function parseSetting(key, raw) {
    var v = Model.parseSetting(key, raw)
    if (key !== "selectedBorder" || v === undefined) return v
    if (v === "accent") return root.accent
    if (v === "selected") return Commons.Color.menu.selectedBorder
    if (v === "foreground") return Commons.Color.foreground
    if (v === "urgent") return root.urgent
    return v
  }

  // Effective value: the stored one if valid, else the default (with a warning).
  function setting(key) {
    var raw = root.settings[key]
    if (raw !== undefined && raw !== null) {
      var v = root.parseSetting(key, raw)
      if (v !== undefined) return v
      console.warn("git-spren.overview: unknown " + key + " value", JSON.stringify(raw),
                   "- using", JSON.stringify(root.settingDefaults[key]))
    }
    return root.parseSetting(key, root.settingDefaults[key])
  }

  readonly property real selectedZoom: root.setting("zoom")
  readonly property color selectedBorderColor: root.setting("selectedBorder")
  readonly property string layoutMode: root.setting("layout")
  readonly property bool layoutRows: root.layoutMode === "rows"
  readonly property bool layoutGrid: root.layoutMode === "grid"
  readonly property string animateMode: root.setting("animate")
  readonly property bool animate: root.animateMode !== "none"
  readonly property bool animateCurrent: root.animateMode === "current"
  readonly property bool animateAll: root.animateMode === "all"
  readonly property int animationMs: root.setting("animationDuration")
  // "live", or refreshes per second (0 = snapshot only).
  readonly property var refreshRate: root.setting("refreshRate")
  readonly property bool refreshLive: root.refreshRate === "live"
  readonly property int refreshIntervalMs: root.refreshLive || root.refreshRate === 0 ? 0
    : Math.round(1000 / root.refreshRate)
  property int captureTick: 0
  readonly property bool redactNoScreenShare: root.setting("redactNoScreenShare")
  readonly property bool backdropWallpaper: root.setting("backdrop") === "wallpaper"
  // Omarchy's current background (the link omarchy-theme-bg-set points); resolved
  // so the Image shares the pixmap cache with the shell's own background layer.
  readonly property string wallpaperLink: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property string wallpaperPath: ""
  function refreshWallpaper() { if (!wallpaperProc.running) wallpaperProc.running = true }
  readonly property real closeFadeEndPct: root.setting("closeFadeEnd")
  readonly property real closeFadeStartPct: Math.min(root.setting("closeFadeStart"), root.closeFadeEndPct)

  // Fly-in phases: 0 closed, 1 opened but thumbnails still hidden (waiting for
  // fresh window geometry), 2 thumbnails flying / shown, 3 flying back (closing).
  property int flyPhase: 0
  property bool flying: false
  // True while the reverse animation plays; `opened` stays true until it ends so
  // the host keeps treating the overlay as open.
  property bool closing: false
  // Headers / zebra bands fade out with the "current" reverse animation.
  property real chromeOpacity: 1
  // Whole-overlay fade near the end of the close (closeFadeStart..closeFadeEnd),
  // so the thumbnails vanish while still settling instead of sitting still and
  // then snapping; the overlay really closes at closeFadeEnd.
  property real closeOpacity: 1
  readonly property int closeFadeStartMs: Math.round(root.animationMs * root.closeFadeStartPct / 100)
  readonly property int closeMs: Math.round(root.animationMs * root.closeFadeEndPct / 100)
  // Set when closing because a window / workspace was chosen: the reverse
  // animation then lands on that workspace instead of the one we came from.
  // { workspace: HyprlandWorkspace, toplevel: HyprlandToplevel | null }
  property var closeTarget: null
  // Window focus dispatch to repeat once the layer is unmapped (see activate()).
  property var pendingFocus: null
  // Address (no 0x) the pendingFocus command targets, and how many times the
  // close has put focus back on it (see onRawEvent).
  property string pendingFocusAddress: ""
  property int refocusCount: 0
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

  function applyShellConfig(text) {
    var config
    try { config = JSON.parse(String(text || "")) } catch (e) {
      console.warn("git-spren.overview: cannot parse " + root.shellConfigPath + ":", e)
      return   // keep the last good settings
    }
    var entry = Model.findOwnEntry(config, root.pluginId)
    var next = ({})
    if (entry) for (var k in entry) if (k !== "id") next[k] = entry[k]
    if (JSON.stringify(next) !== JSON.stringify(root.settings)) root.settings = next
  }

  FileView {
    path: root.shellConfigPath
    watchChanges: true
    onLoaded: root.applyShellConfig(text())
    onFileChanged: reload()
    onLoadFailed: function(error) { root.settings = ({}) }   // no shell.json = defaults
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
  // Grid header: the title line plus the selection underline, never less than 24.
  readonly property int underlineHeight: Math.max(2, Style.space(2))
  // The wallpaper backdrop puts a pill behind the header; give it some air.
  readonly property int gridHeaderHeight: Math.max(Style.space(24),
    Math.ceil(gridTitleMetrics.height) + underlineHeight + Style.space(root.backdropWallpaper ? 10 : 5))
  FontMetrics {
    id: gridTitleMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
  }
  readonly property var gridMetrics: {
    var mon = root.monitorLogicalRect(Hyprland.focusedMonitor)
    return Model.gridMetrics(root.groupCount, root.availWidth, root.availHeight, root.columnGap,
                             root.rowGap, root.gridHeaderHeight, mon.h > 0 ? mon.w / mon.h : 16 / 9)
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
    root.queryNoScreenShare()
    root.refreshWallpaper()
    root.selectionTouched = false
    root.hoverArmed = false
    root.hoverOrigin = null
    root.selectedIndex = -1
    root.query = ""
    root.pendingFocus = null
    refocusTimer.stop()
    root.rebuild()
    // Payload options: {"query": "..."} opens with the search filled in.
    var payload = null
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { console.warn("overview: bad payload", payloadJson) }
    if (payload && typeof payload.query === "string")
      root.setQuery(payload.query.replace(/[\x00-\x1f\x7f]/g, ""))
    root.flyPhase = root.animate ? 1 : 2
    // "all" fades the backdrop in with the zoom; without this the capture wait
    // (phase 1, up to 300 ms) shows it at full strength over the live desktop.
    root.zoomScrim = root.animateAll ? 0 : 1
    root.flyWaited = 0
    flyTimer.interval = 45   // a close during the capture wait leaves it at 30
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
    root.landingWindow = root.resolveLandingWindow()
    root.closing = true
    // The layer lets go of the keyboard now (keyboardFocus), and Hyprland hands
    // it back to the window focused before the overlay: focus the chosen one again
    // so it turns active (opaque, with inactive_opacity / opacity rules) under the
    // overlay instead of snapping opaque after the fade. finishClose() repeats it.
    if (root.pendingFocus) refocusTimer.restart()
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
    // Clear the search while `closing` still disables the pill's fade: left for
    // open() to clear, the empty pill faded out over the opening frames.
    root.query = ""
    root.closing = false
    root.flyPhase = 0
    root.flying = false
    root.zoomScale = 1; root.zoomTX = 0; root.zoomTY = 0; root.zoomScrim = 1
    root.chromeOpacity = 1
    root.closeOpacity = 1
    root.closeTarget = null
    root.landingWindow = null
    if (root.pendingFocus) refocusTimer.restart()
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

  // Hyprland tags for privacy (e.g. screen sharing): hideTag leaves a window out
  // of the overview; redactTag keeps its slot but shows a black box, never
  // captures it, and keeps its title out of the caption and the search.
  // Dynamic tags (from window rules) carry a trailing "*".
  readonly property string hideTag: "overview-hide"
  readonly property string redactTag: "overview-redact"

  function hasTag(toplevel, tag) {
    var ipc = root.ipcOf(toplevel)
    return Model.hasTag(ipc ? ipc.tags : null, tag)
  }

  function isHidden(toplevel) { return root.hasTag(toplevel, root.hideTag) }
  function isRedacted(toplevel) {
    return root.hasTag(toplevel, root.redactTag)
      || (root.redactNoScreenShare && root.noScreenShare[toplevel ? toplevel.address : ""] === true)
  }
  // no_screen_share is not in the clients JSON, so it is asked per window with
  // getprop. Until a window's answer is in, it is not captured (icon only).
  function privacyPending(toplevel) {
    return root.redactNoScreenShare && !!toplevel && root.noScreenShare[toplevel.address] === undefined
  }

  // address (no 0x) -> bool, refreshed while closed on window events.
  property var noScreenShare: ({})
  // address (no 0x) -> { active, inactive, fullscreen }: the opacity Hyprland
  // draws the window with (rules × decoration options), for landingOpacity().
  property var windowOpacity: ({})
  property var noScreenShareQuery: []
  // One getprop batch for no_screen_share and the opacity props
  // (Model.windowPropsBatch). With redactNoScreenShare off, only startup and
  // open() ask (for the opacity), not window events.
  function queryNoScreenShare() {
    if (noShareProc.running) { noShareTimer.restart(); return }
    var addrs = Hyprland.toplevels.values.map(function(t) { return String(t.address) })
      .filter(function(a) { return /^[0-9a-f]+$/i.test(a) })
    if (addrs.length === 0) { root.noScreenShare = ({}); root.windowOpacity = ({}); return }
    root.noScreenShareQuery = addrs
    noShareProc.command = ["hyprctl", "-j", "--batch", Model.windowPropsBatch(addrs)]
    noShareProc.running = true
  }
  // no_screen_share fails closed (OverviewModel.js): windows without a clear
  // answer stay unknown, and unknown windows stay uncaptured (privacyPending).
  // Opacity fails open (1).
  function applyNoScreenShare(text) {
    var r = Model.parseWindowProps(text, root.noScreenShareQuery)
    r.warnings.forEach(function(w) { console.warn("git-spren.overview: " + w) })
    root.noScreenShare = r.map
    root.windowOpacity = r.opacity
  }

  // The opacity `toplevel` has once the overlay is gone: the window being
  // landed on (closeTarget, else the one active before) is active, the rest
  // inactive. Thumbnails fade to it on close and from it on open, so nothing
  // snaps when the real windows show again.
  function landingOpacity(toplevel) {
    var o = toplevel ? root.windowOpacity[toplevel.address] : null
    if (!o) return 1
    var ipc = root.ipcOf(toplevel)
    if (ipc && ipc.fullscreen) return o.fullscreen
    var active = root.landingWindow ? root.landingWindow === toplevel : root.isActive(toplevel)
    return active ? o.active : o.inactive
  }
  // The window that ends up active, resolved once per close (close() sets it
  // before `closing`, which makes every thumb ask landingOpacity()).
  property var landingWindow: null
  function resolveLandingWindow() {
    var t = root.closeTarget
    if (t && t.toplevel) return t.toplevel
    if (t && t.workspace) return root.lastFocusedOn(t.workspace)
    return null
  }
  // The window Hyprland focuses when switching to `workspace`.
  function lastFocusedOn(workspace) {
    var best = null, bestId = Infinity
    var list = workspace && workspace.toplevels ? workspace.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var ipc = root.ipcOf(list[i])
      var id = ipc && ipc.focusHistoryID !== undefined ? ipc.focusHistoryID : Infinity
      if (!best || id < bestId) { best = list[i]; bestId = id }
    }
    return best
  }

  // Caption for a redacted window: the app's name, never its title.
  function redactedLabel(toplevel) {
    var appId = toplevel && toplevel.wayland ? String(toplevel.wayland.appId || "") : ""
    var entry = appId ? DesktopEntries.heuristicLookup(appId) : null
    if (entry && entry.name) return String(entry.name)
    var ipc = root.ipcOf(toplevel)
    return appId || (ipc && ipc["class"] ? String(ipc["class"]) : "")
  }

  function byPosition(a, b) {
    var ia = root.ipcOf(a), ib = root.ipcOf(b)
    if (!ia || !ib || !ia.at || !ib.at) return 0
    if (ia.at[1] !== ib.at[1]) return ia.at[1] - ib.at[1]
    return ia.at[0] - ib.at[0]
  }

  // Workspaces with at least one shown window, in overview order (numbered by
  // id, then named ones by name), each with its windows sorted by position.
  function orderedWorkspaces() {
    var numbered = [], named = []
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      var ws = all[i]
      if (!ws || !ws.toplevels) continue
      var visible = ws.toplevels.values.filter(function(t) { return !root.isHidden(t) })
      if (visible.length === 0) continue
      if (ws.id > 0) numbered.push({ ws: ws, toplevels: visible })
      else named.push({ ws: ws, toplevels: visible })
    }
    numbered.sort(function(a, b) { return a.ws.id - b.ws.id })
    named.sort(function(a, b) { return a.ws.name < b.ws.name ? -1 : a.ws.name > b.ws.name ? 1 : 0 })
    var ordered = numbered.concat(named)
    for (var g = 0; g < ordered.length; g++) ordered[g].toplevels.sort(root.byPosition)
    return ordered
  }

  function workspaceLabel(ws) {
    return ws.id > 0 ? String(ws.id) : String(ws.name).replace(/^special:/, "")
  }

  function rebuild() {
    var selectedAddress = root.selectionTouched && root.selectedToplevel() ? root.selectedToplevel().address : ""
    var multiMonitor = Hyprland.monitors.values.length > 1
    var groups = [], flat = []
    var ordered = root.orderedWorkspaces()
    for (var g = 0; g < ordered.length; g++) {
      var w = ordered[g].ws
      var tls = ordered[g].toplevels
      var entry = {
        workspace: w,
        label: root.workspaceLabel(w),
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

  // Hyprland ignores foreign-toplevel activate requests unless
  // misc:focus_on_activate is set, so focus through the dispatcher instead.
  function focusCommand(toplevel) {
    var addr = String(toplevel && toplevel.address || "")
    if (addr.length === 0) return null
    if (addr.indexOf("0x") !== 0) addr = "0x" + addr
    return ["hyprctl", "dispatch", "hl.dsp.focus({ window = " + Model.luaString("address:" + addr) + " })"]
  }

  function activate(toplevel) {
    if (!toplevel) return
    var cmd = root.focusCommand(toplevel)
    if (cmd) {
      Quickshell.execDetached(cmd)
      // While our exclusive layer holds the keyboard, Hyprland only records
      // the focus; unmapping the layer hands it back to the window it had
      // before. A workspace switch hides that, a window on the current
      // workspace does not, so focus again once the layer is gone.
      root.pendingFocus = cmd
      root.pendingFocusAddress = String(toplevel.address).replace(/^0x/, "")
      root.refocusCount = 0
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
    // A bare name is a selector ("r+1", "prev", "empty", ...): named workspaces
    // need "name:", special ones already carry "special:".
    var name = String(workspace.name)
    var target = workspace.id > 0 ? String(workspace.id)
      : name.indexOf("special:") === 0 ? name : "name:" + name
    var last = root.lastFocusedOn(workspace)
    root.dispatchWorkspaceFocus(target, last ? String(last.address) : "")
    if (dismissAfter !== false) root.closeToward({ workspace: workspace, toplevel: null })
  }

  // Like activate(): while our layer holds the keyboard the switch only sticks
  // until the layer lets go, then Hyprland focuses the window from before the
  // overlay again and switches back to its workspace. So the command is kept
  // as pendingFocus and re-run while closing (whenever another window than
  // `address`, the one the workspace focuses, turns active) and after close.
  function dispatchWorkspaceFocus(target, address) {
    var cmd = ["hyprctl", "dispatch", "hl.dsp.focus({ workspace = " + Model.luaString(target) + " })"]
    Quickshell.execDetached(cmd)
    root.pendingFocus = cmd
    root.pendingFocusAddress = address.replace(/^0x/, "")
    root.refocusCount = 0
  }

  // False when there is no such workspace and it cannot be created: only
  // positive ids can (a negative number would be a relative selector).
  function focusWorkspaceById(id) {
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++)
      if (all[i].id === id) { root.focusWorkspace(all[i]); return true }
    if (!(id > 0)) return false
    root.dispatchWorkspaceFocus(String(id), "")
    root.dismissNow()
    return true
  }

  function iconFor(toplevel) {
    var appId = toplevel && toplevel.wayland ? String(toplevel.wayland.appId || "") : ""
    var entry = appId ? DesktopEntries.heuristicLookup(appId) : null
    var fromEntry = !!(entry && entry.icon)
    var icon = fromEntry ? String(entry.icon) : appId
    // The app id is chosen by the client (a sandboxed one too), so only a
    // desktop entry may name an icon file by path.
    if (icon && !fromEntry && icon.indexOf("/") >= 0) icon = ""
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

  // Nearest match in a direction by on-screen frame (OverviewModel.pickSpatial).
  function spatialMove(dx, dy) {
    root.selectionTouched = true
    if (root.flat.length === 0) return
    var items = root.thumbItems.filter(function(t) {
      return t && t.flatIndex >= 0 && t.flatIndex < root.flat.length
        && (root.isMatch(t.flatIndex) || t.flatIndex === root.selectedIndex)
    })
    var frames = items.map(function(t) { return t.frameGeometry() })
    var cur = -1
    for (var i = 0; i < items.length; i++)
      if (items[i].flatIndex === root.selectedIndex) { cur = i; break }
    if (cur < 0) { root.selectedIndex = items.length ? items[0].flatIndex : 0; return }
    var pick = Model.pickSpatial(frames, frames[cur], dx, dy)
    if (pick >= 0) root.selectedIndex = items[pick].flatIndex
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
    // Redacted (and hidden) windows match on app identity only, so typing
    // cannot probe their titles.
    var redacted = root.isRedacted(toplevel) || root.isHidden(toplevel)
    var f = redacted ? [root.redactedLabel(toplevel)] : [String(toplevel.title || "")]
    if (toplevel.wayland && toplevel.wayland.appId) f.push(String(toplevel.wayland.appId))
    var ipc = root.ipcOf(toplevel)
    if (ipc) {
      if (ipc["class"]) f.push(String(ipc["class"]))
      if (ipc.initialClass) f.push(String(ipc.initialClass))
      if (ipc.initialTitle && !redacted) f.push(String(ipc.initialTitle))
    }
    return f
  }

  // Fuzzy scoring lives in OverviewModel.js; -1 = no match, 0 = empty query.
  function matchScore(toplevel, query) {
    if (String(query).trim() === "") return 0
    return Model.matchScore(root.searchFields(toplevel), query)
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
    // Backspace / Ctrl+Backspace / Ctrl+U, shared with the shell's own search
    // overlays; Backspace on an empty query is swallowed.
    if (Util.editsFilter(event, root.query)) { root.setQuery(Util.editedFilter(event, root.query)); return true }
    if (k === Qt.Key_Backspace) return true
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
    // Keypad digits carry KeypadModifier.
    if (k >= Qt.Key_0 && k <= Qt.Key_9 && (event.modifiers & ~Qt.KeypadModifier) === Qt.NoModifier && root.query === "") {
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
    root.setQuery(root.query + String(text || "").replace(/[\x00-\x1f\x7f]/g, ""))
    return "ok"
  }

  // Every window (works while closed): the shown ones in overview order, then
  // the hidden ones (`hidden: true`), optionally only those matching a search
  // query. Redacted and hidden windows report their app name as the title.
  // `call git-spren.overview list "fire"`
  function list(query) {
    var q = String(query || "")
    var out = []
    function add(t, ws, hidden) {
      if (!root.matches(t, q)) return
      var ipc = root.ipcOf(t)
      out.push({ address: root.addressOf(t), title: root.windowLabel(t),
                 appId: t.wayland ? String(t.wayland.appId || "") : "",
                 "class": ipc && ipc["class"] ? String(ipc["class"]) : "",
                 workspace: ws ? root.workspaceLabel(ws) : "",
                 monitor: ws && ws.monitor ? ws.monitor.name : "",
                 active: root.isActive(t), redacted: root.isRedacted(t), hidden: hidden })
    }
    root.orderedWorkspaces().forEach(function(g) {
      g.toplevels.forEach(function(t) { add(t, g.ws, false) })
    })
    Hyprland.toplevels.values.forEach(function(t) {
      if (root.isHidden(t)) add(t, t.workspace, true)
    })
    return JSON.stringify(out)
  }

  function addressOf(toplevel) { return "0x" + String(toplevel.address).replace(/^0x/i, "") }
  // Title for scripting output; private windows give their app name instead.
  function windowLabel(toplevel) {
    return root.isRedacted(toplevel) || root.isHidden(toplevel)
      ? root.redactedLabel(toplevel) : String(toplevel.title || "")
  }

  // Focus the best match for a search query, like typing it and pressing
  // Enter, without showing the overview. `call git-spren.overview jump "fire"`
  // (not "focus": that is Item.focus, like "state" below)
  function jump(query) {
    var q = String(query || "")
    if (q.trim() === "" || root.closing) return "ignored"
    var best = null, bestScore = -1
    root.orderedWorkspaces().forEach(function(g) {
      g.toplevels.forEach(function(t) {
        var sc = root.matchScore(t, q)
        if (sc > bestScore) { bestScore = sc; best = t }
      })
    })
    if (!best) return "no match"
    if (root.opened) { root.activate(best); return "ok" }
    var cmd = root.focusCommand(best)
    if (!cmd) return "no match"
    Quickshell.execDetached(cmd)
    return "ok"
  }

  // While open: go to a workspace by id or name, like its digit key.
  function workspace(name) {
    if (!root.opened || root.closing) return "ignored"
    var s = String(name || "").trim()
    if (/^-?\d+$/.test(s)) return root.focusWorkspaceById(parseInt(s, 10)) ? "ok" : "unknown workspace: " + s
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      var n = String(all[i].name)
      if (n === s || n === "special:" + s) { root.focusWorkspace(all[i]); return "ok" }
    }
    return "unknown workspace: " + s
  }

  // While open: select a window by address (with or without 0x).
  function select(address) {
    if (!root.opened || root.closing) return "ignored"
    var a = String(address || "").trim().replace(/^0x/i, "").toLowerCase()
    for (var i = 0; i < root.flat.length; i++) {
      if (String(root.flat[i].toplevel.address).replace(/^0x/i, "").toLowerCase() !== a) continue
      if (!root.isMatch(i)) return "filtered"
      root.selectionTouched = true
      root.selectedIndex = i
      return "ok"
    }
    return "unknown window: " + address
  }

  // Tag a window from the shell: `call git-spren.overview hide ""` (the focused
  // window), `redact 0x…` (an address) or `clear "keepass"` (best search match,
  // hidden windows included). The tags are manual ones and last until the window
  // closes; tags from window rules (trailing "*") cannot be cleared this way.
  function hide(target) { return root.tagWindow(target, [root.hideTag], "+") }
  function redact(target) { return root.tagWindow(target, [root.redactTag], "+") }
  function clear(target) { return root.tagWindow(target, [root.hideTag, root.redactTag], "-") }

  // "" = focused window, "0x…" = that address, anything else = a search over
  // every toplevel (hidden ones too) that must match exactly one window: tagging
  // the wrong one of two Firefox windows is worse than asking for an address.
  // Returns { toplevel } or { error }.
  function resolveWindow(target) {
    var s = String(target || "").trim()
    var all = Hyprland.toplevels.values
    if (s === "") {
      for (var i = 0; i < all.length; i++) if (root.isActive(all[i])) return { toplevel: all[i] }
      return { error: "no focused window" }
    }
    if (/^0x[0-9a-f]+$/i.test(s)) {
      var a = s.slice(2).toLowerCase()
      for (var j = 0; j < all.length; j++)
        if (String(all[j].address).replace(/^0x/i, "").toLowerCase() === a) return { toplevel: all[j] }
      return { error: "no window: " + s }
    }
    var hits = all.filter(function(t) { return root.matchScore(t, s) >= 0 })
    if (hits.length === 1) return { toplevel: hits[0] }
    if (hits.length === 0) return { error: "no window matches: " + s }
    return { error: hits.length + " windows match \"" + s + "\": " + hits.map(function(t) {
      return root.addressOf(t) + " (" + root.windowLabel(t) + ")"
    }).join(", ") + "; use an address" }
  }

  function tagWindow(target, tags, sign) {
    if (root.closing) return "ignored"
    var r = root.resolveWindow(target)
    if (r.error) return r.error
    var t = r.toplevel
    var addr = root.addressOf(t)
    var ruleTags = []
    tags.forEach(function(tag) {
      var ipcTags = (root.ipcOf(t) || {}).tags || []
      if (sign === "-" && ipcTags.indexOf(tag + "*") !== -1) { ruleTags.push(tag); return }
      if (sign === "-" && !root.hasTag(t, tag)) return
      if (sign === "+" && root.hasTag(t, tag)) return
      Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.window.tag({ tag = "
        + Model.luaString(sign + tag) + ", window = " + Model.luaString("address:" + addr) + " })"])
    })
    // Tag changes raise no Hyprland event, so refresh the IPC data ourselves.
    tagTimer.restart()
    if (ruleTags.length) return addr + ": " + ruleTags.join(", ") + " set by a window rule"
    return "ok " + addr
  }

  // Current model as JSON (for debugging; "state" is taken by Item).
  function dump(arg) {
    var groups = root.groups.map(function(c) {
      return {
        workspace: c.label, monitor: c.sub,
        windows: c.toplevels.map(function(t) {
          return { title: t.title, address: t.address, active: root.isActive(t),
                   redacted: root.isRedacted(t),
                   landingOpacity: root.landingOpacity(t),
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
                            closeFadeStart: root.closeFadeStartPct, closeFadeEnd: root.closeFadeEndPct,
                            refreshRate: root.refreshRate, redactNoScreenShare: root.redactNoScreenShare,
                            backdrop: root.setting("backdrop"), wallpaper: root.wallpaperPath,
                            flyPhase: root.flyPhase, selectionTouched: root.selectionTouched, groups: groups })
  }

  // ---- settings over IPC --------------------------------------------------
  // `omarchy-shell shell call git-spren.overview config ""` / `set "layout=rows"` /
  // `set '{"zoom":1.3}'` / `reset "zoom"` / `reset ""`. ("settings" is the property.)

  // Stored entry fields plus the values in effect.
  function config(arg) {
    var effective = ({})
    for (var key in root.settingDefaults) {
      var v = root.setting(key)
      effective[key] = key === "selectedBorder" ? String(v) : v
    }
    return JSON.stringify({ stored: root.settings, effective: effective })
  }

  // "key=value" (value parsed as JSON, else taken as a string) or a JSON object.
  function set(arg) {
    var parsed = Model.parseSetArgument(arg)
    if (parsed.error) return parsed.error
    var changes = parsed.changes
    var next = JSON.parse(JSON.stringify(root.settings))
    for (var key in changes) {
      if (!root.hasOwn(root.settingDefaults, key))
        return "unknown setting: " + key + " (known: " + Object.keys(root.settingDefaults).join(", ") + ")"
      if (root.parseSetting(key, changes[key]) === undefined)
        return "invalid value for " + key + ": " + JSON.stringify(changes[key])
      next[key] = changes[key]
    }
    return root.writeSettings(next)
  }

  function hasOwn(obj, key) { return Model.hasOwn(obj, key) }

  // Drop one stored key (back to its default), or all of them with "".
  function reset(arg) {
    var key = String(arg || "").trim()
    var next = ({})
    if (key) {
      if (!root.hasOwn(root.settings, key)) return root.hasOwn(root.settingDefaults, key) ? "ok" : "unknown setting: " + key
      next = JSON.parse(JSON.stringify(root.settings))
      delete next[key]
    }
    return root.writeSettings(next)
  }

  function writeSettings(next) {
    // A shell.json write makes the host rebuild its plugin loaders, which would
    // tear the overlay down mid-use.
    if (root.opened) return "close the overview first"
    if (JSON.stringify(next) === JSON.stringify(root.settings)) return "ok"
    if (!root.shell || typeof root.shell.updateEntryInline !== "function")
      return "the host does not allow saving settings"
    if (!root.shell.updateEntryInline(root.pluginId, next))
      return "not saved: is " + root.pluginId + " enabled (an entry in shell.json)?"
    root.settings = next
    return "ok"
  }

  // ---- plumbing ----------------------------------------------------------

  // Thumbnail refresh: every visible-workspace thumb recaptures on the same tick,
  // so the overlay redraws once per tick instead of once per window.
  Timer {
    interval: root.refreshIntervalMs; repeat: true
    running: root.opened && root.refreshIntervalMs > 0
    onTriggered: root.captureTick++
  }
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
  Timer {
    id: refocusTimer; interval: 60
    onTriggered: {
      var cmd = root.pendingFocus
      if (root.closing) { if (cmd) Quickshell.execDetached(cmd); return }
      root.pendingFocus = null
      if (cmd && !root.opened) Quickshell.execDetached(cmd)
    }
  }

  SequentialAnimation {
    id: closeFadeAnim
    PauseAnimation { duration: root.closeFadeStartMs }
    NumberAnimation { target: root; property: "closeOpacity"; to: 0; duration: Math.max(1, root.closeMs - root.closeFadeStartMs); easing.type: Easing.InOutQuad }
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
      // The close released the keyboard and Hyprland moved focus back to the
      // window from before the overlay (which can switch workspace): put it on
      // the chosen window again while the overlay still covers the screen.
      if (name === "activewindowv2" && root.closing && root.pendingFocus
          && String(event.data).replace(/^0x/, "") !== root.pendingFocusAddress
          && root.refocusCount < 3) {
        root.refocusCount += 1
        Quickshell.execDetached(root.pendingFocus)
      }
      // Window rules can match on title. Only no_screen_share has to be current
      // while closed; opacity is only read at open(), which queries anyway.
      if (root.redactNoScreenShare && /^(openwindow|closewindow|windowtitle(v2)?)$/.test(name))
        noShareTimer.restart()
    }
  }

  Timer { id: noShareTimer; interval: 150; onTriggered: root.queryNoScreenShare() }
  // After a tag dispatch: refresh the IPC data, then rebuild once it has landed
  // (hidden windows drop out of the model; redaction follows lastIpcObject).
  Timer { id: tagTimer; interval: 80; onTriggered: { Hyprland.refreshToplevels(); tagSettleTimer.restart() } }
  Timer { id: tagSettleTimer; interval: 150; onTriggered: if (root.opened && !root.closing) root.rebuild() }
  Process {
    id: noShareProc
    stdout: StdioCollector { onStreamFinished: root.applyNoScreenShare(text) }
  }
  // Fetch IPC data (focus history, positions, tags) up front, so `list` and
  // `jump` are right even before the first window event or open.
  Component.onCompleted: { noShareTimer.restart(); refreshTimer.restart(); root.refreshWallpaper() }

  Process {
    id: wallpaperProc
    command: ["readlink", "-f", root.wallpaperLink]
    stdout: StdioCollector { onStreamFinished: root.wallpaperPath = String(text || "").trim() }
  }
  onRedactNoScreenShareChanged: if (root.redactNoScreenShare) root.queryNoScreenShare()

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "git-spren-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    // Released as soon as the close starts, so the chosen window gets focus (and
    // its active opacity) while still hidden under the overlay; see close().
    WlrLayershell.keyboardFocus: root.closing ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Everything fades out as one layer at the end of the close: faded item by
    // item, the backdrop would show through every half-transparent thumbnail.
    Item {
      anchors.fill: parent
      opacity: root.closeOpacity
      layer.enabled: root.closing

      // Backdrop "wallpaper": the desktop background, dimmed a little so headers
      // and thumbnail edges stay readable on a bright image. It is the same image
      // the desktop shows (same crop), so it appears at once with the content and
      // only the dim follows the zoom: the close then lands on exactly what the
      // desktop shows, and the overlay's final fade has nothing to cross over.
      Item {
        anchors.fill: parent
        visible: root.backdropWallpaper && wallpaper.status === Image.Ready
        opacity: root.opened && root.flyPhase >= 2 ? 1 : 0

        Image {
          id: wallpaper
          anchors.fill: parent
          source: root.backdropWallpaper ? Util.fileUrl(root.wallpaperPath) : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
        }
        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Commons.Color.background, 0.35)
          opacity: root.zoomScrim
        }
      }

      // Backdrop "dim" (and the wallpaper's fallback until it has loaded).
      Rectangle {
        anchors.fill: parent
        visible: !root.backdropWallpaper || wallpaper.status !== Image.Ready
        color: root.scrim
        opacity: root.zoomScrim
      }

      // Extra dimming so thumbnails read against a busy desktop.
      Rectangle {
        anchors.fill: parent
        visible: !root.backdropWallpaper || wallpaper.status !== Image.Ready
        color: Util.alpha(Commons.Color.background, 0.55)
        opacity: root.zoomScrim
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
          opacity: root.opened && !(root.animateAll && root.flyPhase < 2) ? 1 : 0
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
          opacity: (shown ? 1 : 0) * root.chromeOpacity
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
}
