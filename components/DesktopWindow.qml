import QtQuick
import Quickshell.Wayland
import qs.Commons

// Desktop peek: one window drawn where the real one is, sliding toward its
// screen edge with overview.peekProgress until only a strip of it is left.
// Same privacy rules as WindowThumb: redacted and not-yet-answered windows are
// never captured.
Item {
  id: win

  property var overview: null
  property var toplevel: null        // HyprlandToplevel
  // { rect: { x, y, w, h }, edge, dx, dy } in overlay coordinates (overview.peekGeom).
  readonly property var geom: overview && toplevel ? overview.peekGeom[toplevel.address] || null : null
  readonly property bool redacted: overview !== null && overview.isRedacted(toplevel)
  readonly property bool pending: overview !== null && overview.privacyPending(toplevel)
  // Counted as ready for the reveal wait, like a thumbnail.
  readonly property bool hasContent: redacted || pending || view.hasContent

  visible: geom !== null
  x: geom ? geom.rect.x - overview.peekArea.x + geom.dx * overview.peekProgress : 0
  y: geom ? geom.rect.y - overview.peekArea.y + geom.dy * overview.peekProgress : 0
  width: geom ? geom.rect.w : 0
  height: geom ? geom.rect.h : 0
  // The opacity Hyprland draws the real window with, so nothing snaps when the
  // peek starts over the real windows or ends on them.
  opacity: overview ? overview.landingOpacity(toplevel) : 1

  Component.onCompleted: if (overview) overview.registerPeek(win)
  Component.onDestruction: if (overview) overview.unregisterPeek(win)

  ScreencopyView {
    id: view
    anchors.fill: parent
    captureSource: win.toplevel && !win.redacted && !win.pending ? win.toplevel.wayland : null
    live: overview !== null && overview.refreshLive && !win.redacted && !win.pending
    paintCursor: false
    visible: hasContent && !win.redacted
  }

  Connections {
    target: win.overview
    // A view without content is still on its automatic first capture.
    function onCaptureTickChanged() { if (view.hasContent && !win.redacted && !win.pending) view.captureFrame() }
  }

  Rectangle {
    anchors.fill: parent
    visible: !view.hasContent || win.redacted
    color: win.redacted ? "black" : overview.surface
  }

  Image {
    anchors.centerIn: parent
    visible: !view.hasContent || win.redacted
    width: Math.min(Style.space(64), Math.min(win.width, win.height) * 0.5)
    height: width
    sourceSize: Qt.size(width, height)
    source: overview ? overview.iconFor(win.toplevel) : ""
    asynchronous: true
  }
}
