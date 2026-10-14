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

  // columns: [{ workspace, label, sub, toplevels: [HyprlandToplevel], firstIndex }]
  // flat:    [{ col, row, toplevel }] in column-major order, for keyboard navigation
  property var columns: []
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

  // ---- user settings (~/.config/omarchy/git-spren.overview.json, hot-reloaded) ----
  //   zoom:           "small" | "medium" | "large" | number 1.0–2.0   (default medium)
  //   selectedBorder: "accent" | "selected" | "foreground" | "urgent" | "#rrggbb"  (default accent)
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

  function applySettings(raw) {
    var text = String(raw || "").trim()
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

  readonly property real availWidth: Math.max(0, panel.width - outerMargin * 2)
  readonly property real availHeight: Math.max(0, panel.height - outerMargin * 2)
  readonly property int columnCount: root.columns.length
  readonly property real columnWidth: columnCount === 0 ? 0
    : Math.max(minColumnWidth, Math.min(maxColumnWidth, (availWidth - columnGap * (columnCount - 1)) / columnCount))

  // ---- host contract -----------------------------------------------------

  function open(payloadJson) {
    root.targetScreen = root.screenForFocusedMonitor()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.rebuild()
    root.opened = true
    // IPC data (window positions) arrives a moment later; re-sort once it does.
    settleTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
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
    var cols = [], flat = []
    var ordered = numbered.concat(named)
    for (var c = 0; c < ordered.length; c++) {
      var w = ordered[c]
      var tls = w.toplevels.values.slice()
      tls.sort(root.byPosition)
      var col = {
        workspace: w,
        label: w.id > 0 ? String(w.id) : String(w.name).replace(/^special:/, ""),
        sub: multiMonitor && w.monitor ? w.monitor.name : "",
        toplevels: tls,
        firstIndex: flat.length
      }
      for (var r = 0; r < tls.length; r++)
        flat.push({ col: c, row: r, toplevel: tls[r] })
      cols.push(col)
    }
    root.columns = cols
    root.flat = flat

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

  function moveSelection(dCol, dRow) {
    if (root.flat.length === 0) return
    if (root.selectedIndex < 0) { root.selectedIndex = 0; return }
    var cur = root.flat[root.selectedIndex]
    var col = cur.col, row = cur.row
    if (dCol !== 0) {
      col = Math.max(0, Math.min(root.columns.length - 1, col + dCol))
      row = Math.min(row, root.columns[col].toplevels.length - 1)
    }
    if (dRow !== 0) {
      row = Math.max(0, Math.min(root.columns[col].toplevels.length - 1, row + dRow))
    }
    root.selectedIndex = root.columns[col].firstIndex + row
  }

  function stepSelection(delta) {
    if (root.flat.length === 0) return
    var n = root.flat.length
    root.selectedIndex = ((root.selectedIndex + delta) % n + n) % n
  }

  function handleKey(event) {
    var k = event.key
    if (k === Qt.Key_Escape) { root.dismiss(); return true }
    if (k === Qt.Key_Left) { root.moveSelection(-1, 0); return true }
    if (k === Qt.Key_Right) { root.moveSelection(1, 0); return true }
    if (k === Qt.Key_Up) { root.moveSelection(0, -1); return true }
    if (k === Qt.Key_Down) { root.moveSelection(0, 1); return true }
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
    var cols = root.columns.map(function(c) {
      return {
        workspace: c.label, monitor: c.sub,
        windows: c.toplevels.map(function(t) {
          return { title: t.title, address: t.address, active: root.isActive(t),
                   appId: t.wayland ? t.wayland.appId : null }
        })
      }
    })
    return JSON.stringify({ opened: root.opened, selectedIndex: root.selectedIndex,
                            zoom: root.selectedZoom, selectedBorder: String(root.selectedBorderColor),
                            columns: cols })
  }

  // ---- plumbing ----------------------------------------------------------

  Timer { id: settleTimer; interval: 180; onTriggered: root.rebuild() }
  Timer { id: rebuildTimer; interval: 60; onTriggered: { Hyprland.refreshToplevels(); root.rebuild() } }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.opened) return
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
          visible: root.columnCount === 0
          anchors.centerIn: parent
          text: "No windows open"
          color: root.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Row {
          id: columnsRow
          anchors.centerIn: parent
          spacing: root.columnGap

          Repeater {
            model: root.columns

            WorkspaceColumn {
              required property var modelData
              overview: root
              column: modelData
              columnWidth: root.columnWidth
              availHeight: root.availHeight
            }
          }
        }
      }
    }
  }
}
