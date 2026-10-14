import QtQuick
import Quickshell.Wayland
import qs.Commons

// A single window: live toplevel capture fitted into a box, with an icon +
// title caption. Hover selects, click activates (focus + workspace switch).
Item {
  id: thumb

  property var overview: null
  property var toplevel: null        // HyprlandToplevel
  property int flatIndex: -1
  property real boxWidth: 300
  property real boxHeight: 200
  // exact: the frame fills the box precisely (grid replica); the caption becomes an
  // overlay that only shows for the selected window.
  property bool exact: false

  readonly property bool selected: overview !== null && overview.selectedIndex === flatIndex
  readonly property bool active: overview !== null && overview.isActive(toplevel)
  readonly property bool urgent: toplevel !== null && toplevel.urgent
  readonly property string title: toplevel ? String(toplevel.title || (toplevel.wayland ? toplevel.wayland.appId : "") || "") : ""
  readonly property string iconSource: overview ? overview.iconFor(toplevel) : ""
  readonly property bool hasContent: view.hasContent

  readonly property real borderWidth: Math.max(2, Style.space(2))
  readonly property real selectedBorderWidth: Math.max(3, Style.space(3))
  readonly property real selectedZoom: overview ? overview.selectedZoom : 1.1
  readonly property color selectedColor: overview ? overview.selectedBorderColor : "white"

  // Aspect: real frame once captured, else Hyprland's reported size, else 16:9.
  readonly property real fallbackAspect: {
    var ipc = overview ? overview.ipcOf(toplevel) : null
    if (ipc && ipc.size && ipc.size[1] > 0) return ipc.size[0] / ipc.size[1]
    return 16 / 9
  }
  readonly property real aspect: view.hasContent && view.sourceSize.height > 0
    ? view.sourceSize.width / view.sourceSize.height : fallbackAspect
  readonly property real innerW: Math.max(0, boxWidth - borderWidth * 2)
  readonly property real innerH: Math.max(0, boxHeight - borderWidth * 2)
  readonly property real fitW: Math.max(1, Math.min(innerW, innerH * aspect))
  readonly property real fitH: Math.max(1, fitW / aspect)

  width: boxWidth
  z: selected ? 1 : 0

  // ---- fly-in: start at the window's real geometry, settle into the slot ----
  property real flyDX: 0
  property real flyDY: 0
  property real flySX: 1
  property real flySY: 1
  property real captionOpacity: 1
  // Where the fly-back ends (set by startFlyBack, read by flyBackAnim).
  property real backDX: 0
  property real backDY: 0
  property real backSX: 1
  property real backSY: 1
  readonly property int phase: overview ? overview.flyPhase : 2
  opacity: 1

  function stopAnimations() { flyAnim.stop(); fadeAnim.stop(); flyBackAnim.stop(); fadeOutAnim.stop() }

  onPhaseChanged: {
    if (thumb.phase === 1) { thumb.stopAnimations(); thumb.opacity = 0; return }
    if (thumb.phase === 2) thumb.startFly()
    if (thumb.phase === 3) thumb.startFlyBack()
  }

  // Registered with the overview so spatial (grid) navigation can compare
  // on-screen positions.
  Component.onCompleted: if (overview) overview.registerThumb(thumb)
  Component.onDestruction: if (overview) overview.unregisterThumb(thumb)

  // Frame rectangle in scene coordinates, including the selection zoom.
  function frameGeometry() {
    var p = frame.mapToItem(null, 0, 0)
    var q = frame.mapToItem(null, frame.width, frame.height)
    var w = q.x - p.x, h = q.y - p.y
    return { x: p.x, y: p.y, w: w, h: h, cx: p.x + w / 2, cy: p.y + h / 2 }
  }

  // "current": fly from the real window. "all" / "none": just show (the "all"
  // zoom is applied to the whole overview by Overview.qml).
  function startFly() {
    thumb.stopAnimations()
    thumb.flyDX = 0; thumb.flyDY = 0; thumb.flySX = 1; thumb.flySY = 1
    var src = overview && overview.animateCurrent ? overview.flySource(thumb.toplevel) : null
    if (src && frame.width > 0 && frame.height > 0) {
      // Frame starts exactly over the real window, then settles into its slot.
      var g = frame.mapToItem(null, 0, 0)
      thumb.flyDX = src.x - g.x
      thumb.flyDY = src.y - g.y
      thumb.flySX = src.w / frame.width
      thumb.flySY = src.h / frame.height
      thumb.captionOpacity = 0
      thumb.opacity = 1
      flyAnim.start()
    } else {
      thumb.captionOpacity = 1
      if (overview && overview.animateCurrent) fadeAnim.start()
      else thumb.opacity = 1
    }
  }

  // Reverse of startFly, from wherever the frame is right now (closing can
  // interrupt the fly-in): measure the slot at identity, then restore the
  // in-flight values and animate to the real window. No source: fade out.
  function startFlyBack() {
    thumb.stopAnimations()
    var src = overview && overview.animateCurrent ? overview.flyBackRect(thumb.toplevel) : null
    if (src && frame.width > 0 && frame.height > 0 && thumb.opacity > 0) {
      var cur = { dx: thumb.flyDX, dy: thumb.flyDY, sx: thumb.flySX, sy: thumb.flySY }
      thumb.flyDX = 0; thumb.flyDY = 0; thumb.flySX = 1; thumb.flySY = 1
      var g = frame.mapToItem(null, 0, 0)
      thumb.flyDX = cur.dx; thumb.flyDY = cur.dy; thumb.flySX = cur.sx; thumb.flySY = cur.sy
      thumb.backDX = src.x - g.x
      thumb.backDY = src.y - g.y
      thumb.backSX = src.w / frame.width
      thumb.backSY = src.h / frame.height
      flyBackAnim.start()
    } else {
      fadeOutAnim.start()
    }
  }

  ParallelAnimation {
    id: flyBackAnim
    NumberAnimation { target: thumb; property: "flyDX"; to: thumb.backDX; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "flyDY"; to: thumb.backDY; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "flySX"; to: thumb.backSX; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "flySY"; to: thumb.backSY; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "captionOpacity"; to: 0; duration: overview ? Math.min(120, overview.animationMs) : 120; easing.type: Easing.OutCubic }
  }

  NumberAnimation {
    id: fadeOutAnim
    target: thumb; property: "opacity"; to: 0
    duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic
  }

  ParallelAnimation {
    id: flyAnim
    NumberAnimation { target: thumb; property: "flyDX"; to: 0; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "flyDY"; to: 0; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "flySX"; to: 1; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "flySY"; to: 1; duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic }
    NumberAnimation { target: thumb; property: "captionOpacity"; to: 1; duration: overview ? overview.animationMs : 240; easing.type: Easing.InCubic }
  }

  NumberAnimation {
    id: fadeAnim
    target: thumb; property: "opacity"; from: 0; to: 1
    duration: overview ? overview.animationMs : 240; easing.type: Easing.OutCubic
  }
  height: boxHeight + overview.captionHeight

  Rectangle {
    id: frame
    width: thumb.fitW + thumb.borderWidth * 2
    height: thumb.fitH + thumb.borderWidth * 2
    anchors.horizontalCenter: parent.horizontalCenter
    y: (thumb.boxHeight - height) / 2
    radius: overview.cornerRadius
    color: overview.surface
    // Selected: zoomed, raised above its neighbours, theme accent border.
    // Active (the window you came from) keeps a dimmer accent so it stays findable.
    border.width: thumb.selected ? thumb.selectedBorderWidth : thumb.borderWidth
    border.color: thumb.selected ? thumb.selectedColor
      : thumb.urgent ? overview.urgent
      : thumb.active ? Util.alpha(thumb.selectedColor, 0.55)
      : overview.borderColor
    Behavior on border.color { ColorAnimation { duration: 120 } }
    // No zoom in the exact (grid) mode: the box clips it and the border + overlay
    // caption already mark the selection.
    scale: thumb.selected && !thumb.exact ? thumb.selectedZoom : 1
    z: thumb.selected ? 1 : 0
    transform: [
      Scale { origin.x: 0; origin.y: 0; xScale: thumb.flySX; yScale: thumb.flySY },
      Translate { x: thumb.flyDX; y: thumb.flyDY }
    ]
    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    ScreencopyView {
      id: view
      anchors.centerIn: parent
      width: thumb.fitW
      height: thumb.fitH
      captureSource: thumb.toplevel ? thumb.toplevel.wayland : null
      live: overview !== null && overview.opened
      paintCursor: false
      visible: hasContent
    }

    Image {
      anchors.centerIn: parent
      visible: !view.hasContent
      width: Math.min(Style.space(64), thumb.fitH * 0.5)
      height: width
      sourceSize: Qt.size(width, height)
      source: thumb.iconSource
      asynchronous: true
    }
  }

  // Overlay caption for the exact (grid) mode: shown on the selected window only.
  Rectangle {
    visible: thumb.exact && thumb.selected
    anchors.bottom: frame.bottom
    anchors.horizontalCenter: frame.horizontalCenter
    anchors.bottomMargin: thumb.borderWidth + Style.space(4)
    width: Math.min(frame.width - Style.space(12), overlayRow.implicitWidth + Style.space(16))
    height: overlayRow.implicitHeight + Style.space(8)
    radius: overview.cornerRadius
    color: Util.alpha(overview.surface, 0.9)
    opacity: thumb.captionOpacity * overview.zoomScrim   // fades with the zoom / close
    z: 5

    Row {
      id: overlayRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Image {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16); height: width
        sourceSize: Qt.size(width, height)
        source: thumb.iconSource
        asynchronous: true
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, frame.width - Style.space(50))
        text: thumb.title
        elide: Text.ElideRight
        color: overview.text
        font.family: overview.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Row {
    visible: !thumb.exact
    anchors.top: frame.bottom
    anchors.topMargin: Style.space(6)
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.min(parent.width, implicitWidth)
    spacing: Style.space(6)
    opacity: thumb.captionOpacity

    Image {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      height: width
      sourceSize: Qt.size(width, height)
      source: thumb.iconSource
      asynchronous: true
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, thumb.width - Style.space(16) - Style.space(6))
      text: thumb.title
      elide: Text.ElideRight
      color: thumb.selected ? overview.text : overview.muted
      font.family: overview.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: frame
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: function(mouse) {
      if (!overview) return
      var p = mapToItem(null, mouse.x, mouse.y)
      overview.pointerMoved(thumb.flatIndex, p.x, p.y)
    }
    onClicked: if (overview) overview.activate(thumb.toplevel)
  }
}
