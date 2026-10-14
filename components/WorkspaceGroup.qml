import QtQuick
import qs.Commons

// One occupied workspace. Columns layout: header on top, thumbnails stacked
// vertically. Rows layout: header on the left, thumbnails side by side.
Item {
  id: group

  property var overview: null
  property var entry: null          // { workspace, label, sub, toplevels, firstIndex }
  property bool rows: false
  property int groupIndex: 0
  property real groupWidth: 300     // columns: column width; rows: full available width
  property real groupHeight: 600    // columns: available height; rows: row height

  readonly property var workspace: entry ? entry.workspace : null
  readonly property int count: entry ? entry.toplevels.length : 0
  readonly property bool focusedWorkspace: workspace !== null && workspace.focused
  readonly property real gap: overview.thumbGap

  // Thumbnail box: shrink along the stacking axis so the group always fits.
  readonly property real thumbBoxHeight: count === 0 ? 0 : (rows
    ? Math.max(overview.captionHeight * 2, Math.min(overview.maxThumbHeight, groupHeight - overview.captionHeight))
    : Math.max(overview.captionHeight * 2, Math.min(overview.maxThumbHeight,
        (groupHeight - overview.headerHeight - gap * (count - 1)) / count - overview.captionHeight)))
  readonly property real thumbBoxWidth: count === 0 ? 0 : (rows
    ? Math.max(overview.minThumbWidth, Math.min(overview.maxThumbWidth,
        (groupWidth - overview.headerWidth - gap * (count - 1)) / count))
    : groupWidth)

  // Rows: header pinned left, thumbnails left-aligned after it.
  // Columns: header on top, thumbnails stacked below.
  readonly property real contentHeight: rows ? thumbBoxHeight + overview.captionHeight : 0
  width: groupWidth
  // Columns take the full available height so the zebra bands are uniform.
  height: rows ? contentHeight : groupHeight
  implicitWidth: width
  implicitHeight: height

  // Very faint zebra band on every other group; extends half a gap on each
  // side so neighbouring bands meet.
  Rectangle {
    visible: group.groupIndex % 2 === 1
    x: group.rows ? -overview.columnGap / 2 : -overview.columnGap / 2
    y: group.rows ? -overview.rowGap / 2 : -overview.rowGap / 2
    width: parent.width + overview.columnGap
    height: parent.height + overview.rowGap
    radius: overview.cornerRadius
    color: overview.zebraColor
  }

  Item {
    id: header
    x: 0
    y: 0
    width: group.rows ? overview.headerWidth - group.gap : group.groupWidth
    height: group.rows ? group.contentHeight : overview.headerHeight

    Rectangle {
      anchors.fill: parent
      radius: overview.cornerRadius
      color: group.focusedWorkspace ? Util.alpha(overview.accent, 0.18) : "transparent"
    }

    Grid {
      anchors.centerIn: parent
      columns: group.rows ? 1 : 3
      columnSpacing: Style.space(10)
      rowSpacing: Style.space(2)
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      Text {
        text: group.entry ? group.entry.label : ""
        color: group.focusedWorkspace ? overview.accent : overview.text
        font.family: overview.fontFamily
        font.pixelSize: group.rows ? Style.font.display : Style.font.heading
        font.bold: true
      }

      Text {
        visible: text.length > 0
        text: group.entry ? group.entry.sub : ""
        color: overview.muted
        font.family: overview.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        text: group.count === 1 ? "1 window" : group.count + " windows"
        color: overview.muted
        font.family: overview.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: overview.focusWorkspace(group.workspace)
    }
  }

  Grid {
    id: thumbs
    columns: group.rows ? Math.max(1, group.count) : 1
    rowSpacing: group.gap
    columnSpacing: group.gap
    verticalItemAlignment: Grid.AlignVCenter
    horizontalItemAlignment: Grid.AlignHCenter
    x: group.rows ? overview.headerWidth : 0
    y: group.rows ? 0 : overview.headerHeight + group.gap

    Repeater {
      model: group.entry ? group.entry.toplevels : []

      WindowThumb {
        required property var modelData
        required property int index
        overview: group.overview
        toplevel: modelData
        flatIndex: group.entry.firstIndex + index
        boxWidth: group.thumbBoxWidth
        boxHeight: group.thumbBoxHeight
      }
    }
  }
}
