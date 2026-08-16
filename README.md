# Downloads — an aria2 queue for the Omarchy bar

Live download speed in the bar, with the queue, pause/resume, and add-from-clipboard
one keystroke away. Optionally runs the aria2 daemon **on demand**, so nothing sits
resident when you have nothing downloading.

Built for [Omarchy](https://omarchy.org/) 4 (Quickshell shell).

## Why aria2

aria2 already does the hard parts — multi-connection transfers, queueing, and
resume across restarts. This plugin does not reimplement any of that. It gives you
a glance at what the daemon is doing and the two or three actions you actually
want in the moment; anything heavier is better done in [AriaNg](https://ariang.mayswind.net/).

## Install

```bash
omarchy plugin add https://github.com/rawritude/omarchy-aria2.git --enable
omarchy bar move aria2 --section right
```

Plugins land disabled unless you pass `--enable`, so you can read the code first.

**Requirements:** `aria2` with RPC enabled, and `wl-copy`/`wl-paste`
(`wl-clipboard`) for add-from-clipboard.

Minimum aria2 config (`~/.config/aria2/aria2.conf`):

```ini
enable-rpc=true
rpc-listen-port=6800
rpc-listen-all=false      # loopback only; no secret needed
continue=true
save-session=/home/YOU/.config/aria2/aria2.session
save-session-interval=30
input-file=/home/YOU/.config/aria2/aria2.session
```

If you expose the RPC beyond loopback, set an `rpc-secret` and put the same value
in the plugin's `rpcSecret` setting.

## Usage

**Bar:** left-click opens the panel · right-click adds the clipboard URL ·
middle-click opens AriaNg (when `manageDaemon` is on).

**In the panel:** `a` add from clipboard · `p` pause/resume all · `r` refresh ·
`u` open AriaNg · `s` stop the daemon now · `esc` close.

**IPC**, for keybinds:

```bash
omarchy-shell aria2 toggle
omarchy-shell aria2 add      # queue the clipboard URL
omarchy-shell aria2 pause
```

## Settings

| Key | Default | Meaning |
|---|---|---|
| `rpcHost` | `127.0.0.1` | aria2 RPC host |
| `rpcPort` | `6800` | aria2 RPC port |
| `rpcSecret` | `""` | Value of aria2's `rpc-secret`, if set |
| `manageDaemon` | `false` | Start/stop the daemon on demand (needs the helper, below) |
| `activePollMs` | `1000` | Poll cadence while transferring |
| `idlePollMs` | `5000` | Poll cadence while the daemon is up but idle |
| `downPollMs` | `60000` | Heartbeat while the daemon is unreachable |

Set them with `omarchy bar set`. **Pass `--json` for booleans and numbers**,
otherwise they are stored as strings:

```bash
omarchy bar set aria2 manageDaemon true --json
omarchy bar set aria2 rpcSecret hunter2
```

## Optional: on-demand daemon

By default the plugin only reads and commands an aria2 that something else is
running. It never starts or stops anything.

If you would rather nothing be resident, `contrib/` has a helper and two systemd
user units that start aria2 when a download is queued and stop it once the queue
drains:

```bash
./contrib/install.sh
omarchy bar set aria2 manageDaemon true --json
```

That installs `~/.local/bin/aria2ctl` plus `aria2.service` and `aria2-idle.timer`
(the helper additionally needs `curl` and `python3`). The service is deliberately
**not** enabled at boot. The timer is `PartOf=` the service, so it is torn down
with it, and `idle-check` stops the timer itself if the daemon is not answering —
`PartOf=` alone would leak it when a start *fails*, since nothing stops a unit
that never ran.

The widget passes its own `rpcHost`/`rpcPort`/`rpcSecret` to the helper through
the environment, so the two cannot end up managing different daemons. Run by
hand, `aria2ctl` falls back to `ARIA2_RPC_*` env vars, then to `rpc-listen-port`
and `rpc-secret` read from your `aria2.conf`, then to `127.0.0.1:6800`.

It also assumes the single-file [AriaNg all-in-one build](https://github.com/mayswind/AriaNg/releases)
at `~/.local/share/ariang/index.html`, opened over `file://`. No web server is
started for the UI.

Uninstall with `./contrib/install.sh --uninstall`.

## Design notes

**Polling costs no processes.** State is read over JSON-RPC with
`XMLHttpRequest`, not by shelling out. Subprocesses are spawned only for things
you actually asked for. A fork+exec every second to read a transfer rate is a
real cost on a laptop.

**The poll interval follows what is happening.** Unreachable daemon → slow
heartbeat. Idle daemon → slow poll. Only an active transfer, or an open panel,
polls at full rate. With `manageDaemon` on, the steady state is "daemon stopped",
which costs one refused loopback connect per minute.

**Per-transfer detail is fetched only while the panel is open.** A closed panel
issues a single small `getGlobalStat` call — enough to render the bar and nothing
more.

**Booleans are parsed defensively.** `omarchy bar set` without `--json` stores
`"true"` as a string, and a naive truthiness test would read the string `"false"`
as true. Settings are compared stringwise instead.

## License

MIT
