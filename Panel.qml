import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget + popup for an aria2 download queue.
//
// The bar stays deliberately cheap: a glyph, plus a speed readout only while
// something is actually moving. Per-transfer detail is fetched only while the
// popup is open, so a closed panel costs one small RPC call at the idle
// cadence — and only a slow heartbeat once the daemon is gone.
Panel {
  id: root
  moduleName: "io.github.rawritude.aria2"
  ipcTarget: "io.github.rawritude.aria2"
  manageIpc: false

  // Required. The bar does not size the slot for us: without these the root has
  // no implicit size, the button's `anchors.fill: parent` collapses to zero, and
  // the widget vanishes entirely. This is not circular — BarIconButton's
  // implicitWidth comes from `fixedWidth: slotSize`, a constant that does not
  // depend on the parent's actual width.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Booleans can arrive as real JSON booleans or as strings, depending on how
  // they were written (`omarchy bar set ... --json` vs. without, or a
  // hand-edited shell.json). A bare truthiness test would read the string
  // "false" as true, so compare the stringified form instead.
  function boolSetting(name, fallback) {
    var v = root.setting(name, fallback)
    return typeof v === "string" ? v.toLowerCase() === "true" : !!v
  }

  function fmtSpeed(bytesPerSec) {
    var v = Number(bytesPerSec) || 0
    if (v <= 0) return ""
    if (v < 1048576) return (v / 1024).toFixed(0) + " kB/s"
    return (v / 1048576).toFixed(1) + " MB/s"
  }

  function fmtSize(bytes) {
    var v = Number(bytes) || 0
    if (v <= 0) return "?"
    if (v < 1048576) return (v / 1024).toFixed(0) + " kB"
    if (v < 1073741824) return (v / 1048576).toFixed(1) + " MB"
    return (v / 1073741824).toFixed(2) + " GB"
  }

  function nameOf(d) {
    if (!d) return "(unknown)"
    var files = d.files || []
    if (files.length > 0 && files[0].path) {
      var p = String(files[0].path)
      var slash = p.lastIndexOf("/")
      if (slash >= 0 && slash < p.length - 1) return p.substring(slash + 1)
      if (p.length > 0) return p
    }
    if (files.length > 0 && files[0].uris && files[0].uris.length > 0)
      return String(files[0].uris[0].uri || "").split("/").pop() || "(download)"
    return "(download)"
  }

  function pctOf(d) {
    var tot = Number(d.totalLength) || 0
    var done = Number(d.completedLength) || 0
    return tot > 0 ? Math.min(100, done / tot * 100) : 0
  }

  Aria2Service {
    id: aria2
    rpcHost: root.setting("rpcHost", "127.0.0.1")
    rpcPort: root.setting("rpcPort", 6800)
    rpcSecret: root.setting("rpcSecret", "")
    manageDaemon: root.boolSetting("manageDaemon", false)
    activePollMs: root.setting("activePollMs", 1000)
    idlePollMs: root.setting("idlePollMs", 5000)
    downPollMs: root.setting("downPollMs", 60000)
    detailWanted: root.opened
  }

  IpcHandler {
    target: "io.github.rawritude.aria2"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function add(): void { aria2.addFromClipboard() }
    function pause(): void { aria2.pauseAll() }
    function resume(): void { aria2.unpauseAll() }
    function ui(): void { aria2.openUi() }
  }

  // BarIconButton draws `text` through OpticalGlyph into a fixed square canvas
  // (Style.bar.iconCanvas, 16px by default) inside a slot of Style.bar.iconSlot
  // (27px). It is built for one centered glyph. An iconComponent holding a Row
  // of glyph + speed + count has nowhere to render and the slot never grows to
  // fit it. omarchy.power has the same problem with its battery percentage and
  // solves it by putting everything in `text` and widening slotSize, so do that.
  // nf-md-download. Built from its codepoint rather than pasted as a literal:
  // a literal sits outside the BMP and does not survive every editor or
  // pipeline, and when it is silently lost the label becomes "", which makes
  // BarIconButton.hasVisualContent false and the widget renders as an empty
  // gap in the bar with no error anywhere.
  readonly property string downloadGlyph: String.fromCodePoint(0xF01DA)

  // Action glyphs, all built from codepoints for the same reason. These happen
  // to be in the BMP, so a literal would survive — the rule is applied without
  // exception so there is nothing to remember.
  readonly property string addGlyph: String.fromCodePoint(0xF067)      // plus
  readonly property string pauseGlyph: String.fromCodePoint(0xF04C)    // pause
  readonly property string playGlyph: String.fromCodePoint(0xF04B)     // play
  readonly property string refreshGlyph: String.fromCodePoint(0xF021)  // refresh
  readonly property string webGlyph: String.fromCodePoint(0xF0AC)      // globe
  readonly property string powerGlyph: String.fromCodePoint(0xF011)    // power
  readonly property string removeGlyph: String.fromCodePoint(0xF00D)   // times

  readonly property bool verticalBar: bar ? bar.vertical : false

  readonly property string barLabel: {
    var glyph = root.downloadGlyph
    // In a left/right bar the slot is a narrow column and nothing clips the
    // label, so a horizontal "1.2 MB/s" would paint straight over the
    // neighbouring widgets. omarchy.power gates its percentage the same way.
    if (root.verticalBar) return glyph
    if (aria2.numActive > 0) {
      var s = root.fmtSpeed(aria2.downloadSpeed)
      return s !== "" ? s + " " + glyph : glyph
    }
    if (aria2.numWaiting > 0) return "+" + aria2.numWaiting + " " + glyph
    return glyph
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    // Only widen when there is more than the glyph to show, and never in a
    // vertical bar, where the slot is height-constrained instead.
    //
    // Compare against the glyph rather than testing barLabel.length: U+F01DA is
    // outside the BMP, so JS stores it as a surrogate pair and `.length` is 2
    // for the bare glyph. A `length > 1` test is therefore always true and the
    // slot sits permanently at 2.4x, padding the icon with dead space.
    slotSize: Style.bar.iconSlot * (root.barLabel !== root.downloadGlyph && !vertical ? 2.4 : 1)
    // Highlight while transferring; the glyph colour is otherwise the bar's.
    active: aria2.numActive > 0
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) aria2.addFromClipboard()
      else if (buttonCode === Qt.MiddleButton && aria2.manageDaemon) aria2.openUi()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "a") aria2.addFromClipboard()
        else if (k === "p") aria2.paused ? aria2.unpauseAll() : aria2.pauseAll()
        else if (k === "u" && aria2.manageDaemon) aria2.openUi()
        else if (k === "s" && aria2.manageDaemon) aria2.stopDaemon()
        else if (k === "r") aria2.refresh()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "Downloads"
              font.family: root.fontFamily
              font.pixelSize: Style.space(13)
              font.bold: true
              color: Color.foreground
            }

            Item { width: Math.max(0, column.width - Style.space(220)); height: 1 }

            Text {
              text: root.fmtSpeed(aria2.downloadSpeed)
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
              color: Color.accent
              visible: text !== ""
            }
          }

          // Wrong/missing rpc-secret otherwise looks identical to "no
          // downloads", which is a miserable thing to debug.
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: aria2.lastError !== ""
            text: "RPC error: " + aria2.lastError
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            color: Color.urgent
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: !aria2.up && aria2.lastError === ""
            text: aria2.manageDaemon
              ? "Nothing queued, so aria2 is not running. Adding a download starts it; it stops again once the queue drains."
              : "No aria2 RPC at " + aria2.rpcHost + ":" + aria2.rpcPort + "."
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            color: root.dim
          }

          Text {
            visible: aria2.up && aria2.lastError === ""
                     && aria2.active.length === 0 && aria2.waiting.length === 0
            text: "Queue is empty."
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            color: root.dim
          }

          PanelSeparator { width: parent.width; visible: aria2.active.length > 0 }

          Repeater {
            model: aria2.active
            delegate: Column {
              required property var modelData
              width: column.width
              spacing: Style.space(2)

              Row {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: parent.width - Style.space(150)   // leaves room for %, speed and the remove button
                  elide: Text.ElideMiddle
                  text: root.nameOf(modelData)
                  // Daemon-supplied: whoever named the remote file chose this.
                  // Text defaults to AutoText, which sniffs for markup, so a
                  // file named "<b><font color=red>" would render as styled
                  // markup inside the shell process.
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  color: Color.foreground
                }
                Text {
                  text: root.pctOf(modelData).toFixed(0) + "%"
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  color: root.dim
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.fmtSpeed(modelData.downloadSpeed)
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  color: Color.accent
                }
                // Per-transfer control. aria2.remove(gid) already existed in the
                // service but nothing called it, so an individual download could
                // not be touched from the panel at all.
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.removeGlyph
                  tooltipText: "Remove this download"
                  foreground: root.dim
                  hoverColor: Color.urgent
                  onClicked: aria2.remove(String(modelData.gid))
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: Qt.darker(Color.foreground, 3.0)
                Rectangle {
                  width: parent.width * root.pctOf(modelData) / 100
                  height: parent.height
                  radius: height / 2
                  color: Color.accent
                }
              }

              Text {
                text: root.fmtSize(modelData.completedLength) + " of " + root.fmtSize(modelData.totalLength)
                font.family: root.fontFamily
                font.pixelSize: Style.space(10)
                color: root.dim
              }
            }
          }

          Text {
            visible: aria2.waiting.length > 0
            text: aria2.waiting.length + " waiting" + (aria2.paused ? " (paused)" : "")
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            color: root.dim
          }

          PanelSeparator { width: parent.width }

          // Typed/pasted URL entry. The Ubuntu tray this replaces had an
          // "Add download..." box; clipboard-only was a regression.
          TextField {
            id: urlField
            width: parent.width
            placeholderText: "Paste or type a URL, then press Enter"
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            foreground: Color.foreground
            accent: Color.accent
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: {
              aria2.addUrl(text)
              text = ""
            }
          }

          // Clickable equivalents of the keys below. The panel was previously
          // keyboard-only, which made every action invisible unless you read
          // the hint line — and the bar button's right/middle-click actions
          // were undiscoverable entirely.
          Row {
            width: parent.width
            spacing: Style.space(6)

            PanelActionButton {
              iconText: root.addGlyph
              tooltipText: "Add the clipboard URL"
              foreground: root.dim
              hoverColor: Color.foreground
              onClicked: aria2.addFromClipboard()
            }
            PanelActionButton {
              iconText: aria2.paused ? root.playGlyph : root.pauseGlyph
              tooltipText: aria2.paused ? "Resume all" : "Pause all"
              foreground: root.dim
              hoverColor: Color.foreground
              onClicked: aria2.paused ? aria2.unpauseAll() : aria2.pauseAll()
            }
            PanelActionButton {
              iconText: root.refreshGlyph
              tooltipText: "Refresh"
              foreground: root.dim
              hoverColor: Color.foreground
              onClicked: aria2.refresh()
            }
            // Both of these only mean anything when this plugin owns the
            // daemon's lifecycle; shown conditionally for the same reason the
            // key hints are, so they can never appear and silently do nothing.
            PanelActionButton {
              visible: aria2.manageDaemon
              iconText: root.webGlyph
              tooltipText: "Open AriaNg"
              foreground: root.dim
              hoverColor: Color.foreground
              onClicked: aria2.openUi()
            }
            PanelActionButton {
              visible: aria2.manageDaemon
              iconText: root.powerGlyph
              tooltipText: "Stop the daemon now"
              foreground: root.dim
              hoverColor: Color.foreground
              onClicked: aria2.stopDaemon()
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "a  add from clipboard    p  " + (aria2.paused ? "resume all" : "pause all")
                  + "    r  refresh"
                  + (aria2.manageDaemon ? "\nu  open AriaNg          s  stop daemon now" : "")
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: root.dim
          }
        }
      }
    }
  }
}
