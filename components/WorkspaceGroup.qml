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
  // The selected window lives in this group (grid: its header gets the underline).
  readonly property bool selectedGroup: entry !== null && count > 0
    && overview.selectedIndex >= entry.firstIndex && overview.selectedIndex < entry.firstIndex + count
  // A numbered workspace renamed by the user ("8" -> "Git Tools") shows both.
  readonly property string customName: workspace && workspace.id > 0 && workspace.name
    && workspace.name !== String(workspace.id) ? workspace.name : ""
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

  // Columns/rows: very faint zebra band on every other group; it drops when the
  // close starts so the zoom lands on the windows. Grid boxes get no fill or outline.
  Rectangle {
    visible: !group.grid && group.groupIndex % 2 === 1
    x: -overview.columnGap / 2
    y: -overview.rowGap / 2
    width: parent.width + overview.columnGap
    height: parent.height + overview.rowGap
    radius: overview.cornerRadius
    opacity: overview.chromeOpacity
    color: overview.closing ? "transparent" : overview.zebraColor
  }

  Item {
    id: header
    x: 0
    y: 0
    width: group.rows ? overview.headerWidth - group.gap : group.groupWidth
    height: group.rows ? group.contentHeight : group.headerH
    opacity: overview.chromeOpacity
    visible: !overview.closing
    readonly property real textPad: Style.space(4)

    Rectangle {
      anchors.fill: parent
      radius: overview.cornerRadius
      color: group.focusedWorkspace && !group.grid ? Util.alpha(overview.accent, 0.18) : "transparent"
    }

    // Wallpaper backdrop: a pill in the menu surface colour behind the header
    // text (and the grid underline), so it reads on a busy image.
    Rectangle {
      visible: overview.backdropWallpaper
      readonly property real padX: Style.space(group.grid ? 8 : 12)
      readonly property real padY: Style.space(group.grid ? 2 : 6)
      x: Math.max(0, headerText.x - padX)
      y: Math.max(0, headerText.y - padY)
      width: Math.min(header.width - x, headerText.width + padX * 2)
      height: group.grid ? header.height - y - Style.space(3)
            : Math.min(header.height - y, headerText.height + padY * 2)
      radius: Math.min(height / 2, overview.cornerRadius + Style.space(4))
      color: Util.alpha(overview.surface, 0.82)
      border.width: 1
      border.color: overview.subtleBorderColor
    }

    Grid {
      id: headerText
      anchors.centerIn: parent
      columns: group.rows ? 1 : 3
      columnSpacing: Style.space(10)
      rowSpacing: Style.space(2)
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      Text {
        id: nameText
        // Long custom names elide so the header (and its underline) stay inside the box.
        readonly property real room: header.width - header.textPad * 2
          - (subText.visible ? subText.implicitWidth + headerText.columnSpacing : 0)
          - (group.rows ? 0 : countText.implicitWidth + headerText.columnSpacing)
        width: Math.min(implicitWidth, Math.max(0, room))
        elide: Text.ElideRight
        text: !group.entry ? "" : group.customName ? group.entry.label + " · " + group.customName : group.entry.label
        textFormat: Text.PlainText
        color: group.focusedWorkspace ? overview.accent : overview.text
        font.family: overview.fontFamily
        font.pixelSize: group.rows ? Style.font.display : (group.grid ? Style.font.title : Style.font.heading)
        font.bold: true
      }

      Text {
        id: subText
        visible: text.length > 0
        text: group.entry ? group.entry.sub : ""
        textFormat: Text.PlainText
        color: overview.muted
        font.family: overview.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: countText
        text: group.count === 1 ? "1 window" : group.count + " windows"
        color: overview.muted
        font.family: overview.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Grid: the header of the box holding the selection is underlined in the
    // selection colour; the workspace you came from keeps a faint one (columns/rows
    // tint the focused workspace's header instead).
    Rectangle {
      visible: group.grid && (group.selectedGroup || group.focusedWorkspace)
      x: headerText.x - header.textPad
      y: headerText.y + headerText.height + Style.space(1)
      width: headerText.width + header.textPad * 2
      height: overview.underlineHeight
      radius: height / 2
      color: group.selectedGroup ? overview.selectedBorderColor : Util.alpha(overview.selectedBorderColor, 0.3)
    }

    // Only the text is a target in grid: the rest of the strip looks like backdrop.
    MouseArea {
      x: group.grid ? headerText.x - header.textPad : 0
      y: 0
      width: group.grid ? headerText.width + header.textPad * 2 : parent.width
      height: parent.height
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

    // No box is drawn, so empty replica space reads as backdrop and closes like it.
    MouseArea {
      anchors.fill: parent
      onClicked: overview.dismiss()
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
