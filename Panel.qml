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
  moduleName: "aria2"
  ipcTarget: "aria2"
  manageIpc: false

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

  readonly property bool hideWhenIdle: root.boolSetting("hideWhenIdle", false)

  // Opt-in, and off by default: a widget that hides itself the moment you
  // install it just looks broken. It is worth having for OLED panels, where a
  // permanent static glyph is exactly the sort of unchanging bar furniture that
  // burns in — but note that while hidden there is nothing to click, so the
  // panel is only reachable over IPC (`omarchy-shell aria2 toggle`). Bind a key
  // to that before turning this on.
  visible: !hideWhenIdle || aria2.busy || root.opened

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
    target: "aria2"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function add(): void { aria2.addFromClipboard() }
    function pause(): void { aria2.pauseAll() }
    function resume(): void { aria2.unpauseAll() }
    function ui(): void { aria2.openUi() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(4)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: ""   // download glyph
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            color: aria2.numActive > 0 ? Color.accent
                 : (aria2.up ? root.barForeground : root.dim)
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: aria2.numActive > 0 && text !== ""
            text: root.fmtSpeed(aria2.downloadSpeed)
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: root.barForeground
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: aria2.numWaiting > 0
            text: "+" + aria2.numWaiting
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            color: root.dim
          }
        }
      }
    }
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
                  width: parent.width - Style.space(120)
                  elide: Text.ElideMiddle
                  text: root.nameOf(modelData)
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
                  text: root.fmtSpeed(modelData.downloadSpeed)
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  color: Color.accent
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
