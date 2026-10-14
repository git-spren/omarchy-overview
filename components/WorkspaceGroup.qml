import QtQuick
import qs.Commons

// One occupied workspace, in one of three modes:
//   columns: header on top, thumbnails stacked vertically
//   rows:    header on the left, thumbnails side by side
//   grid:    a scaled replica of the workspace's monitor with every window at
//            its real position and size
Item {
  id: group

  property var overview: null
  property var entry: null          // { workspace, label, sub, toplevels, firstIndex }
  property string mode: "columns"
  property int groupIndex: 0
  property real groupWidth: 300     // columns: column width; rows: row width; grid: box width
  property real groupHeight: 600    // columns: available height; rows: row height; grid: unused

  readonly property bool rows: mode === "rows"
  readonly property bool grid: mode === "grid"
  readonly property var workspace: entry ? entry.workspace : null
  readonly property int count: entry ? entry.toplevels.length : 0
  readonly property bool focusedWorkspace: workspace !== null && workspace.focused
  // The selected window lives in this group (grid: the box gets the accent outline).
  readonly property bool selectedGroup: entry !== null && count > 0
    && overview.selectedIndex >= entry.firstIndex && overview.selectedIndex < entry.firstIndex + count
  readonly property real gap: overview.thumbGap

  // ---- grid: monitor replica geometry ----
  readonly property var monitorRect: overview.monitorLogicalRect(workspace ? workspace.monitor : null)
  readonly property real replicaScale: monitorRect.w > 0 ? groupWidth / monitorRect.w : 0
  readonly property real replicaHeight: monitorRect.h * replicaScale

  // ---- columns / rows: thumbnail box ----
  readonly property real thumbBoxHeight: count === 0 ? 0 : (rows
    ? Math.max(overview.captionHeight * 2, Math.min(overview.maxThumbHeight, groupHeight - overview.captionHeight))
    : Math.max(overview.captionHeight * 2, Math.min(overview.maxThumbHeight,
        (groupHeight - overview.headerHeight - gap * (count - 1)) / count - overview.captionHeight)))
  readonly property real thumbBoxWidth: count === 0 ? 0 : (rows
    ? Math.max(overview.minThumbWidth, Math.min(overview.maxThumbWidth,
        (groupWidth - overview.headerWidth - gap * (count - 1)) / count))
    : groupWidth)

  readonly property real contentHeight: rows ? thumbBoxHeight + overview.captionHeight : 0
  readonly property real headerH: grid ? overview.gridHeaderHeight : overview.headerHeight

  // Scene rectangles for the "all" animation (measured with the identity transform).
  function replicaRegion() {
    var p = replica.mapToItem(null, 0, 0)
    return { x: p.x, y: p.y, w: replica.width, h: replica.height }
  }
  function sceneRect() {
    var p = group.mapToItem(null, 0, 0)
    return { x: p.x, y: p.y, w: group.width, h: group.height }
  }

  width: groupWidth
  height: grid ? headerH + replicaHeight
        : rows ? contentHeight
        : overview.headerHeight + gap + thumbs.height
  implicitWidth: width
  implicitHeight: height

  // Very faint zebra band on every other group (columns/rows) or box tint (grid).
  Rectangle {
    visible: group.grid || group.groupIndex % 2 === 1
    x: group.grid ? 0 : -overview.columnGap / 2
    y: group.grid ? 0 : -overview.rowGap / 2
    width: group.grid ? parent.width : parent.width + overview.columnGap
    height: group.grid ? parent.height : parent.height + overview.rowGap
    radius: overview.cornerRadius
    opacity: overview.chromeOpacity
    color: group.grid && group.groupIndex % 2 === 0 ? Util.alpha(overview.zebraColor, 0.5) : overview.zebraColor
    border.width: group.grid ? (group.selectedGroup ? Math.max(2, Style.space(2)) : 1) : 0
    border.color: group.grid && group.selectedGroup ? overview.selectedBorderColor
      : group.focusedWorkspace ? Util.alpha(overview.accent, 0.6) : overview.borderColor
    Behavior on border.color { ColorAnimation { duration: 120 } }
  }

  Item {
    id: header
    x: 0
    y: 0
    width: group.rows ? overview.headerWidth - group.gap : group.groupWidth
    height: group.rows ? group.contentHeight : group.headerH
    opacity: overview.chromeOpacity

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
        font.pixelSize: group.rows ? Style.font.display : (group.grid ? Style.font.title : Style.font.heading)
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

  // columns / rows: thumbnails in a Grid
  Grid {
    id: thumbs
    visible: !group.grid
    columns: group.rows ? Math.max(1, group.count) : 1
    rowSpacing: group.gap
    columnSpacing: group.gap
    verticalItemAlignment: Grid.AlignVCenter
    horizontalItemAlignment: Grid.AlignHCenter
    x: group.rows ? overview.headerWidth : 0
    y: group.rows ? 0 : overview.headerHeight + group.gap

    Repeater {
      model: group.grid || !group.entry ? [] : group.entry.toplevels

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

  // grid: monitor replica with windows at their real geometry
  Item {
    id: replica
    visible: group.grid
    x: 0
    y: group.headerH
    width: group.groupWidth
    height: group.replicaHeight
    // Keep windows inside the box, except while they fly in from the real screen.
    clip: !overview.flying

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: overview.focusWorkspace(group.workspace)
    }

    Repeater {
      model: group.grid && group.entry ? group.entry.toplevels : []

      WindowThumb {
        id: gridThumb
        required property var modelData
        required property int index
        readonly property var rect: overview.windowRect(modelData, group.monitorRect)
        readonly property var ipc: overview.ipcOf(modelData)
        overview: group.overview
        toplevel: modelData
        flatIndex: group.entry.firstIndex + index
        exact: true
        x: rect.x * group.replicaScale
        y: rect.y * group.replicaScale
        boxWidth: Math.max(4, rect.w * group.replicaScale)
        boxHeight: Math.max(4, rect.h * group.replicaScale)
        // Most recently focused on top, selected above all.
        z: (selected ? 1000 : 0) + (ipc && typeof ipc.focusHistoryID === "number" ? 100 - ipc.focusHistoryID : 0)
      }
    }
  }
}
