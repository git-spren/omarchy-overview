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

  readonly property bool selected: overview !== null && overview.selectedIndex === flatIndex
  readonly property bool active: overview !== null && overview.isActive(toplevel)
  readonly property bool urgent: toplevel !== null && toplevel.urgent
  readonly property string title: toplevel ? String(toplevel.title || (toplevel.wayland ? toplevel.wayland.appId : "") || "") : ""
  readonly property string iconSource: overview ? overview.iconFor(toplevel) : ""

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
  readonly property int phase: overview ? overview.flyPhase : 2
  opacity: 1

  onPhaseChanged: {
    if (thumb.phase === 1) { flyAnim.stop(); fadeAnim.stop(); thumb.opacity = 0; return }
    if (thumb.phase === 2) thumb.startFly()
  }

  function startFly() {
    flyAnim.stop(); fadeAnim.stop()
    var src = overview && overview.animate ? overview.flySource(thumb.toplevel) : null
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
      thumb.flyDX = 0; thumb.flyDY = 0; thumb.flySX = 1; thumb.flySY = 1
      thumb.captionOpacity = 1
      if (overview && overview.animate) fadeAnim.start()
      else thumb.opacity = 1
    }
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
    scale: thumb.selected ? thumb.selectedZoom : 1
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

  Row {
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
    onEntered: if (overview) overview.selectedIndex = thumb.flatIndex
    onClicked: if (overview) overview.activate(thumb.toplevel)
  }
}
