import QtQuick
import qs.Commons

// One occupied workspace: header (number/name, click to focus the workspace)
// above a vertical stack of window thumbnails.
Item {
  id: col

  property var overview: null
  property var column: null   // { workspace, label, sub, toplevels, firstIndex }
  property real columnWidth: 300
  property real availHeight: 600

  readonly property var workspace: column ? column.workspace : null
  readonly property int count: column ? column.toplevels.length : 0
  readonly property bool focusedWorkspace: workspace !== null && workspace.focused

  // Shrink thumbnails so the whole column always fits the screen height.
  readonly property real thumbBoxHeight: count === 0 ? 0 : Math.max(
    overview.captionHeight * 2,
    Math.min(overview.maxThumbHeight,
      (availHeight - overview.headerHeight - overview.thumbGap * (count - 1)) / count - overview.captionHeight))

  width: columnWidth
  implicitHeight: stack.implicitHeight
  height: implicitHeight

  Column {
    id: stack
    width: parent.width
    spacing: overview.thumbGap

    Item {
      id: header
      width: parent.width
      height: overview.headerHeight

      Rectangle {
        anchors.fill: parent
        radius: overview.cornerRadius
        color: col.focusedWorkspace ? Util.alpha(overview.accent, 0.18) : "transparent"
      }

      Row {
        anchors.centerIn: parent
        spacing: Style.space(10)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: col.column ? col.column.label : ""
          color: col.focusedWorkspace ? overview.accent : overview.text
          font.family: overview.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: text.length > 0
          text: col.column ? col.column.sub : ""
          color: overview.muted
          font.family: overview.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: col.count === 1 ? "1 window" : col.count + " windows"
          color: overview.muted
          font.family: overview.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: overview.focusWorkspace(col.workspace)
      }
    }

    Repeater {
      model: col.column ? col.column.toplevels : []

      WindowThumb {
        required property var modelData
        required property int index
        overview: col.overview
        toplevel: modelData
        flatIndex: col.column.firstIndex + index
        boxWidth: col.columnWidth
        boxHeight: col.thumbBoxHeight
      }
    }
  }
}
