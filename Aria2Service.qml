import QtQuick
import Quickshell.Io

// Talks JSON-RPC to an aria2 daemon.
//
// Three deliberate properties:
//
//  1. Polling uses XMLHttpRequest, not a subprocess. A fork+exec per tick to
//     read a transfer rate is a real cost on a laptop; this way an idle widget
//     costs one small loopback request and no processes at all.
//
//  2. The poll interval is derived from state, never fixed. Unreachable daemon
//     falls back to a slow heartbeat, an idle one to a slow poll, and only an
//     active transfer (or an open panel) polls at full rate.
//
//  3. Daemon lifecycle management is OPTIONAL. With `manageDaemon` off — the
//     default — this component only ever reads and commands an aria2 that
//     someone else is running. Nothing is started or stopped behind your back.
Item {
  id: svc

  // ---- connection ----------------------------------------------------
  property string rpcHost: "127.0.0.1"
  property int rpcPort: 6800
  property string rpcSecret: ""
  readonly property string rpcUrl: "http://" + rpcHost + ":" + rpcPort + "/jsonrpc"

  // Opt-in on-demand daemon control, via the aria2ctl helper shipped alongside
  // this plugin. Off by default so the plugin is safe against an aria2 that is
  // managed by something else entirely.
  property bool manageDaemon: false

  property int activePollMs: 1000
  property int idlePollMs: 5000
  property int downPollMs: 60000

  // Set by the panel while visible; switches us from the cheap summary call to
  // the full per-transfer fetch.
  property bool detailWanted: false

  // ---- observed state -------------------------------------------------
  property bool up: false
  property int numActive: 0
  property int numWaiting: 0
  property int numStopped: 0
  property int downloadSpeed: 0
  property var active: []
  property var waiting: []
  property bool paused: false
  property string lastError: ""

  // Guards against piling up requests when the daemon accepts connections but
  // stops answering: at a 250ms cadence with a 4s timeout, ~16 could otherwise
  // be in flight, and a slow old reply could overwrite a newer one.
  property bool _inFlight: false

  readonly property bool busy: up && (numActive > 0 || numWaiting > 0)

  readonly property int pollInterval: !up
    ? downPollMs
    : (detailWanted || numActive > 0 ? activePollMs : idlePollMs)

  signal refreshed()

  // aria2 takes the shared secret as a synthetic leading parameter on every
  // call. Absent a secret the list is passed through untouched.
  function withToken(params) {
    var p = params || []
    if (svc.rpcSecret === "") return p
    return ["token:" + svc.rpcSecret].concat(p)
  }

  // POSIX single-quote escaping, so a secret containing shell metacharacters
  // cannot break out of the command we hand to sh.
  function shq(value) {
    return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
  }

  function helperCmd(argv) {
    // The helper is told which daemon to talk to, rather than defaulting to
    // 127.0.0.1:6800 independently. Without this a user who moves aria2 to
    // another port gets a split brain: the widget polls one daemon while the
    // helper starts, queues into, and idle-stops a different one.
    var env = "ARIA2_RPC_HOST=" + shq(rpcHost) +
              " ARIA2_RPC_PORT=" + shq(rpcPort) +
              (rpcSecret !== "" ? " ARIA2_RPC_SECRET=" + shq(rpcSecret) : "")
    // $HOME quoted: an unquoted expansion word-splits on a home path with a space.
    return ["sh", "-c", env + " \"$HOME\"/.local/bin/aria2ctl " + argv]
  }

  function rpc(method, params, onOk) {
    var req = new XMLHttpRequest()
    req.open("POST", svc.rpcUrl, true)
    req.setRequestHeader("Content-Type", "application/json")
    req.timeout = 4000
    req.onreadystatechange = function() {
      if (req.readyState !== XMLHttpRequest.DONE) return
      svc._inFlight = false

      if (req.status !== 200) {
        // aria2 answers a rejected call (bad or missing rpc-secret) with an
        // HTTP 4xx *and* a JSON-RPC error body. Treating every non-200 as "not
        // running" would report "No aria2 RPC at host:port" for a daemon that
        // is up and reachable — the exact confusion this plugin claims to
        // avoid. Status 0 is the genuine cannot-connect case.
        var errMsg = ""
        if (req.status !== 0) {
          try {
            var errBody = JSON.parse(req.responseText)
            if (errBody && errBody.error) errMsg = String(errBody.error.message || "rpc error")
          } catch (parseErr) {
            errMsg = "HTTP " + req.status
          }
        }
        if (errMsg !== "") {
          svc.lastError = errMsg
          svc.up = true          // reachable, just refusing us
        } else {
          svc.lastError = ""     // a down daemon is not an error to report
          svc.up = false
        }
        svc.numActive = 0; svc.numWaiting = 0; svc.numStopped = 0
        svc.downloadSpeed = 0
        svc.active = []; svc.waiting = []
        svc.refreshed()
        return
      }
      try {
        var body = JSON.parse(req.responseText)
        if (body.error) {
          // Most commonly a wrong or missing rpc-secret; worth surfacing,
          // because it is otherwise indistinguishable from "no downloads".
          svc.lastError = String(body.error.message || "rpc error")
          svc.up = true
          svc.refreshed()
          return
        }
        svc.up = true
        svc.lastError = ""
        if (onOk) onOk(body.result)
      } catch (e) {
        svc.lastError = String(e)
        svc.refreshed()
      }
    }
    req.ontimeout = function() { svc._inFlight = false }
    req.onerror = function() { svc._inFlight = false }
    svc._inFlight = true
    req.send(JSON.stringify({
      jsonrpc: "2.0", id: "omarchy", method: method, params: params || []
    }))
  }

  function refresh() {
    if (!detailWanted) {
      rpc("aria2.getGlobalStat", withToken([]), function(r) {
        svc.numActive = parseInt(r.numActive || 0)
        svc.numWaiting = parseInt(r.numWaiting || 0)
        svc.numStopped = parseInt(r.numStopped || 0)
        svc.downloadSpeed = parseInt(r.downloadSpeed || 0)
        svc.refreshed()
      })
      return
    }

    var keys = ["gid", "status", "totalLength", "completedLength",
                "downloadSpeed", "files", "errorMessage"]
    // One round trip for summary + both lists. Each inner call carries its own
    // token; multicall does not inherit the outer one.
    rpc("system.multicall", [[
      { methodName: "aria2.getGlobalStat", params: svc.withToken([]) },
      { methodName: "aria2.tellActive", params: svc.withToken([keys]) },
      { methodName: "aria2.tellWaiting", params: svc.withToken([0, 32, keys]) }
    ]], function(r) {
      if (!r || r.length < 3) return

      // system.multicall is exempt from the token, so the outer call still
      // returns 200 when the secret is wrong; the inner calls come back as
      // fault objects {code, message} rather than [result]. Mapping those to
      // {}/[] would render a wrong secret as a cheerful "Queue is empty."
      for (var f = 0; f < r.length; f++) {
        if (r[f] && !Array.isArray(r[f])) {
          svc.lastError = String(r[f].message || "rpc error")
          svc.active = []; svc.waiting = []
          svc.refreshed()
          return
        }
      }

      var stat = (r[0] && r[0][0]) || {}
      svc.numActive = parseInt(stat.numActive || 0)
      svc.numWaiting = parseInt(stat.numWaiting || 0)
      svc.numStopped = parseInt(stat.numStopped || 0)
      svc.downloadSpeed = parseInt(stat.downloadSpeed || 0)
      svc.active = (r[1] && r[1][0]) || []
      svc.waiting = (r[2] && r[2][0]) || []
      var w = svc.waiting
      var allPaused = w.length > 0
      for (var i = 0; i < w.length; i++) if (w[i].status !== "paused") allPaused = false
      svc.paused = allPaused
      svc.refreshed()
    })
  }

  // ---- user actions ---------------------------------------------------
  function pauseAll()   { rpc("aria2.pauseAll",   withToken([]),    function() { refresh() }) }
  function unpauseAll() { rpc("aria2.unpauseAll", withToken([]),    function() { refresh() }) }
  function remove(gid)  { rpc("aria2.remove",     withToken([gid]), function() { refresh() }) }

  function addUri(uri) {
    var u = String(uri || "").trim()
    if (u === "") return
    rpc("aria2.addUri", withToken([[u]]), function() { refresh() })
  }

  function addFromClipboard() {
    if (svc.manageDaemon) {
      // Helper path: brings the daemon up first if it is not running.
      addProc.command = helperCmd("add \"$(wl-paste -n)\"")
      addProc.running = true
      return
    }
    // Plain path: read the clipboard, hand the URI straight to whatever aria2
    // is already listening. No daemon management, no helper required.
    clipProc.running = true
  }

  function openUi()      { if (manageDaemon) { uiProc.command  = helperCmd("ui");   uiProc.running = true } }
  function startDaemon() { if (manageDaemon) { lifeProc.command = helperCmd("up");   lifeProc.running = true } }
  function stopDaemon()  { if (manageDaemon) { lifeProc.command = helperCmd("down"); lifeProc.running = true } }

  Process { id: addProc;  onExited: Qt.callLater(svc.refresh) }
  Process { id: uiProc }
  Process { id: lifeProc; onExited: Qt.callLater(svc.refresh) }

  Process {
    id: clipProc
    command: ["wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: svc.addUri(text)
    }
  }

  // Opening the panel switches us to detail mode, but without this the first
  // detailed result waits out the current interval — up to downPollMs (60s by
  // default, and configurable to 600s), so a freshly started daemon would keep
  // showing "No aria2 RPC at ..." long after it came up.
  onDetailWantedChanged: if (detailWanted) refresh()

  Timer {
    interval: svc.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!svc._inFlight) svc.refresh()
  }
}
