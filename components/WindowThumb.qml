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
