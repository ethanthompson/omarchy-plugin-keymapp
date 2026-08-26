import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for the ZSA Keymapp API. Shows whether Keymapp is running, the
// connected keyboard's active layer, and a click-to-switch layer picker.
//
// Talks to Keymapp through the `kontroll` CLI (https://github.com/zsa/kontroll,
// AUR: zsa-kontroll-bin), which speaks Keymapp's local gRPC API over its Unix
// socket. There's no long-lived Quickshell service for Keymapp, so status is
// polled on a timer that keeps running whether or not the popup is open, the
// same way the bar icon needs to.
//
// The live API only ever reports the *active* layer as a bare index — it
// doesn't expose how many layers exist or what they're named. Keymapp's own
// UI gets that from its local cache instead: a compiled copy of your keymap
// that it keeps in ~/.config/.keymapp/keymapp.sqlite3 (table `revision`,
// one JSON blob per synced layout) so it can render offline. We read that
// same file with the `sqlite3` CLI to recover real layer names and count.
// If that file or CLI isn't available, layer names fall back to the manual
// `layerCount`/`layerNames` settings.
Panel {
  id: root
  moduleName: "ethan.keymapp"
  ipcTarget: "ethan.keymapp"

  property bool keymappRunning: false
  property bool keyboardConnected: false
  property string keyboardName: ""
  property string firmwareVersion: ""
  property int currentLayer: -1
  property string lastError: ""
  property int cursorLayer: 0
  property bool cursorActive: false
  property var discoveredLayerNames: []
  property bool autoConnectAttempted: false

  readonly property int refreshIntervalSec: setting("refreshIntervalSec", 5)
  readonly property int manualLayerCount: Math.max(1, setting("layerCount", 6))
  readonly property string layerNamesRaw: setting("layerNames", "")
  readonly property string keymappConfigDir: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    var base = xdg && xdg.length > 0 ? xdg : (Quickshell.env("HOME") + "/.config")
    return base + "/.keymapp"
  }
  readonly property string keymappDbPath: keymappConfigDir + "/keymapp.sqlite3"

  // Guards against a runaway or malicious `kontroll status` response and
  // against keymapp.sqlite3 holding an oversized/adversarial cache (it's
  // just a local file, but nothing stops another process — or a corrupted
  // sync — from bloating it). StdioCollector keeps appending to its internal
  // buffer for as long as the process keeps writing, regardless of
  // waitForEnd — waitForEnd only controls when `text`/`data` are exposed to
  // QML, not how much gets buffered internally. So every collector below is
  // waitForEnd: false, and these caps are enforced live from onDataChanged
  // by killing the offending process the moment its combined output crosses
  // the limit (see boundedAppend below), rather than only checking the
  // length of whatever StdioCollector eventually hands back once the
  // stream ends — by which point the damage is already done.
  //
  // These are JS string length (UTF-16 code unit) caps, not a count of the
  // process's original output bytes — but since Qt/JS strings are always
  // stored as UTF-16 internally, that's exactly what bounds the actual
  // in-memory footprint we're trying to cap, regardless of how the source
  // text was encoded on the wire.
  readonly property int maxStatusOutputBytes: 262144
  readonly property int maxKeymapCacheBytes: 8 * 1024 * 1024
  readonly property int maxLayersParsed: 64
  readonly property int maxFieldLength: 200

  function clampField(s, max) {
    s = String(s || "")
    var limit = max || root.maxFieldLength
    return s.length > limit ? s.slice(0, limit) : s
  }

  // The panel's own Text elements pin textFormat to Text.PlainText, but the
  // bar's shared tooltip label doesn't — it defaults to Text.AutoText and
  // will render anything that looks like markup as rich text. Strip the
  // characters that make Qt consider a string "rich text" before an
  // untrusted field (e.g. keyboardName, sourced from `kontroll status`)
  // reaches tooltipText.
  function plainTooltip(s) {
    return String(s || "").replace(/[<>]/g, "")
  }

  // Called from a StdioCollector's onDataChanged as `text` grows. Kills
  // `proc` the instant accumulated output crosses `maxBytes` so the
  // collector stops appending to its buffer, then returns the (possibly
  // truncated) text to store. Truncation makes the JSON invalid, which
  // parseStatus()/parseLayerNames() already reject via their own try/catch —
  // and killing the process also gives it a non-zero exit code, so a
  // truncated `kontroll status` read is treated as a status failure rather
  // than silently parsed.
  //
  // running = false only sends SIGTERM (Process::terminate()), which a
  // hostile process — the exact threat this guards against — can trap or
  // ignore and keep writing. Follow up with signal(9) (SIGKILL) directly so
  // the process actually stops regardless of its own signal handling.
  function boundedAppend(proc, text, maxBytes) {
    if (text.length <= maxBytes) return text
    if (proc.running) {
      proc.running = false
      proc.signal(9)
    }
    return text.slice(0, maxBytes)
  }

  readonly property var manualLayerNames: layerNamesRaw.split(",").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })

  // Manual names (if set) win outright; otherwise prefer whatever we read
  // out of Keymapp's local keymap cache; otherwise fall back to bare numbers
  // using the manual layer count.
  readonly property var layerLabels: {
    if (manualLayerNames.length > 0) {
      var labels = []
      for (var i = 0; i < manualLayerCount; i++) labels.push(manualLayerNames[i] || String(i))
      return labels
    }
    if (discoveredLayerNames.length > 0) return discoveredLayerNames
    var fallback = []
    for (var j = 0; j < manualLayerCount; j++) fallback.push(String(j))
    return fallback
  }
  readonly property int layerCount: layerLabels.length

  readonly property string statusIcon: "⌨"
  readonly property string barText: keyboardConnected && currentLayer >= 0
    ? statusIcon + " " + currentLayer
    : statusIcon

  // configure.zsa.io URLs are keyed by model slug, not the "friendly_name"
  // Keymapp reports (e.g. "Moonlander MK1"), so map known ZSA models to
  // their slug. Unrecognized keyboards just don't get a configure link.
  readonly property var keyboardSlugByMatch: ({
    "moonlander": "moonlander",
    "ergodox": "ergodox-ez",
    "planck": "planck-ez",
    "voyager": "voyager"
  })
  readonly property string keyboardSlug: {
    var name = keyboardName.toLowerCase()
    for (var key in keyboardSlugByMatch) {
      if (name.indexOf(key) !== -1) return keyboardSlugByMatch[key]
    }
    return ""
  }
  // firmware_version from kontroll (e.g. "GL9jw/DzYVWZ") is already the
  // exact <layoutId>/<revisionId> path segment configure.zsa.io expects.
  readonly property string configureUrl: keyboardSlug !== "" && firmwareVersion !== ""
    ? "https://configure.zsa.io/" + keyboardSlug + "/layouts/" + firmwareVersion + "/0"
    : ""

  function openConfigureUrl() {
    if (configureUrl !== "") Qt.openUrlExternally(configureUrl)
  }

  // Settings (currently just the polling interval) live in a separate
  // overlay plugin surface — Settings.qml — summoned through the shell the
  // same way the Home Assistant plugin's settings screen is, rather than
  // shown inline in this popup. The current settings ride along as the
  // payload so the overlay can edit a full copy without needing a live
  // reference back to this widget instance.
  function openSettings() {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    close()
    bar.shell.summon(root.moduleName, JSON.stringify(root.settings || {}))
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshLayerNames() {
    if (!layerNamesProc.running) layerNamesProc.running = true
  }

  // `revision` can hold more than one synced revision for the same keyboard —
  // e.g. right after flashing new firmware, Keymapp syncs the new compiled
  // layout down but leaves the previous revision's row in place. Best-effort
  // match the connected keyboard's friendly name against each layout's
  // geometry/title, and among matches (or among all rows if nothing matches)
  // prefer the one with the newest revision.createdAt, since row order isn't
  // guaranteed to reflect sync recency.
  function parseLayerNames(raw) {
    // Bail before JSON.parse ever sees it: a bloated cache (LIMIT above
    // still caps row count, but a single row's compiled keymap could still
    // be huge) shouldn't get parsed or held onto.
    if (String(raw || "").length > root.maxKeymapCacheBytes) return
    var rows
    try {
      rows = JSON.parse(raw)
    } catch (e) {
      return
    }
    if (!Array.isArray(rows) || rows.length === 0) return

    var wanted = root.keyboardName.toLowerCase()
    var best = null
    var bestMatched = false
    var bestCreatedAt = -1

    for (var i = 0; i < rows.length; i++) {
      var layout
      try {
        layout = JSON.parse(rows[i].data).layout
      } catch (e) {
        continue
      }
      if (!layout || !layout.revision || !Array.isArray(layout.revision.layers)) continue

      var geometry = String(layout.geometry || "").toLowerCase()
      var title = String(layout.title || "").toLowerCase()
      var matched = wanted !== "" && geometry !== "" && (wanted.indexOf(geometry) !== -1 || geometry.indexOf(wanted) !== -1 || wanted.indexOf(title) !== -1)

      var createdAt = Date.parse(layout.revision.createdAt || "")
      if (isNaN(createdAt)) createdAt = 0

      if (best === null || (matched && !bestMatched) || (matched === bestMatched && createdAt > bestCreatedAt)) {
        best = layout
        bestMatched = matched
        bestCreatedAt = createdAt
      }
    }
    if (!best) return

    var layers = best.revision.layers.slice()
      .sort(function(a, b) { return (a.position || 0) - (b.position || 0) })
      .slice(0, root.maxLayersParsed)
    root.discoveredLayerNames = layers.map(function(l, idx) {
      return (l.title && String(l.title).length > 0) ? root.clampField(l.title) : String(idx)
    })
  }

  function parseStatus(raw) {
    if (String(raw || "").length > root.maxStatusOutputBytes) return false
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      return false
    }
    keymappRunning = true
    lastError = ""
    if (data && data.keyboard) {
      keyboardConnected = true
      keyboardName = root.clampField(data.keyboard.friendly_name)
      firmwareVersion = root.clampField(data.keyboard.firmware_version)
      currentLayer = typeof data.keyboard.current_layer === "number" ? data.keyboard.current_layer : -1
      // A keyboard is connected now, so a future disconnect deserves its
      // own fresh nudge.
      autoConnectAttempted = false
    } else {
      keyboardConnected = false
      keyboardName = ""
      firmwareVersion = ""
      currentLayer = -1
      // `kontroll status` only reports whatever keyboard Keymapp already
      // has connected — it doesn't establish a connection itself. A fresh
      // Keymapp process (e.g. relaunched on login, kept hidden in a special
      // workspace) starts with no keyboard connected until something asks
      // it to, so nudge it here rather than leaving the widget stuck on
      // "no keyboard" until someone opens Keymapp's window by hand.
      //
      // Only do this once per "no keyboard" streak: connectAnyProc's
      // onExited re-triggers a status refresh immediately (not on the
      // timer), and with no keyboard actually plugged in — a common,
      // long-lived state — re-nudging on every poll turned this into an
      // unthrottled loop that kept spawning kontroll processes back-to-back
      // forever.
      if (!autoConnectAttempted) {
        autoConnectAttempted = true
        attemptAutoConnect()
      }
    }
    return true
  }

  function attemptAutoConnect() {
    if (!connectAnyProc.running) connectAnyProc.running = true
  }

  function handleStatusFailure(stderrText) {
    keymappRunning = false
    keyboardConnected = false
    keyboardName = ""
    firmwareVersion = ""
    currentLayer = -1
    lastError = stderrText && stderrText.length > 0
      ? stderrText
      : "kontroll not found. Install it with: omarchy pkg aur add zsa-kontroll-bin"
    // Keymapp itself isn't running (or kontroll can't reach it); reset so
    // it gets a fresh auto-connect nudge once it comes back up.
    autoConnectAttempted = false
  }

  function setLayer(index) {
    if (setLayerProc.running || index < 0 || index >= layerCount) return
    // Update optimistically so the bar/panel reflect the switch the instant
    // it's clicked, rather than waiting on set-layer's process to exit and
    // a full status re-poll to come back. onExited below still runs a real
    // refresh() regardless of outcome, so a failed/rejected set-layer
    // self-corrects back to the true layer within that one status poll.
    currentLayer = index
    setLayerProc.command = ["kontroll", "set-layer", "-i", String(index)]
    setLayerProc.running = true
  }

  function moveCursor(delta) {
    if (layerCount <= 0) return
    cursorActive = true
    cursorLayer = (cursorLayer + delta + layerCount) % layerCount
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      refreshLayerNames()
      cursorLayer = currentLayer >= 0 ? currentLayer : 0
      cursorActive = false
    }
  }

  onKeyboardConnectedChanged: if (keyboardConnected) refreshLayerNames()

  Component.onCompleted: refreshLayerNames()

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property string statusOut: ""
  property string statusErr: ""
  property string layerNamesOut: ""

  // Fails harmlessly (non-zero exit) if a keyboard's already connected or
  // none is plugged in, so it's safe to fire opportunistically whenever a
  // status poll comes back with no keyboard.
  Process {
    id: connectAnyProc
    command: ["kontroll", "connect-any"]
    onExited: root.refresh()
  }

  Process {
    id: statusProc
    command: ["kontroll", "status", "--json"]
    stdout: StdioCollector { waitForEnd: false; onDataChanged: root.statusOut = root.boundedAppend(statusProc, text, root.maxStatusOutputBytes) }
    stderr: StdioCollector { waitForEnd: false; onDataChanged: root.statusErr = root.boundedAppend(statusProc, text, 500) }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.parseStatus(root.statusOut)) return
      root.handleStatusFailure(root.statusErr.trim())
    }
  }

  Process {
    id: setLayerProc
    // `kontroll set-layer` exits as soon as its request lands, which can
    // beat Keymapp's own state update — a status refresh fired immediately
    // on exit can still read back the *previous* layer, briefly clobbering
    // the optimistic update in setLayer() with stale data before the next
    // poll corrects it again. Give Keymapp a moment to actually commit the
    // switch before confirming it.
    onExited: postSetLayerRefreshTimer.restart()
  }

  Timer {
    id: postSetLayerRefreshTimer
    interval: 300
    onTriggered: root.refresh()
  }

  // Reads Keymapp's local compiled-keymap cache for layer names/count. Runs
  // independently of the kontroll status poll: it's a large-ish read (a
  // full compiled keymap per row) that only needs to happen when something
  // might actually have changed, not every refresh tick.
  Process {
    id: layerNamesProc
    command: ["sqlite3", "-readonly", "-json", root.keymappDbPath, "SELECT revisionId, data FROM revision ORDER BY revisionId DESC LIMIT 25;"]
    stdout: StdioCollector { waitForEnd: false; onDataChanged: root.layerNamesOut = root.boundedAppend(layerNamesProc, text, root.maxKeymapCacheBytes) }
    onExited: function(exitCode) {
      if (exitCode === 0) root.parseLayerNames(root.layerNamesOut)
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Slow safety-net re-read in case the keymap gets recompiled/re-synced
  // mid-session without the keyboard ever disconnecting.
  Timer {
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refreshLayerNames()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    dimmed: !root.keymappRunning
    tooltipText: root.keymappRunning
      ? (root.keyboardConnected
        ? "Keymapp — " + root.plainTooltip(root.keyboardName) + " — layer " + root.currentLayer
        : "Keymapp running, no keyboard connected")
      : "Keymapp not running"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.moveCursor(dx)
        else if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.setLayer(root.cursorLayer)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "s" || t === "S") root.openSettings() }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · title/status · layer · settings ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroRight.implicitHeight)

          Text {
            id: heroIcon
            text: root.statusIcon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroRight.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Keymapp"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: !root.keymappRunning
                ? "NOT RUNNING"
                : (root.keyboardConnected ? root.keyboardName.toUpperCase() : "NO KEYBOARD")
              textFormat: Text.PlainText
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: heroRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              id: heroLayer
              text: root.keyboardConnected && root.currentLayer >= 0
                ? String(root.currentLayer)
                : "—"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: settingsButton
              iconText: "󰒓"
              tooltipText: "Settings"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.openSettings()
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // ---------- Layer picker ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.keymappRunning && root.keyboardConnected

          Item {
            width: parent.width
            implicitHeight: Math.max(layerHeader.implicitHeight, refreshLayersButton.implicitHeight)

            PanelSectionHeader {
              id: layerHeader
              text: "LAYER"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: refreshLayersButton
              iconText: "⟳"
              tooltipText: "Re-read layer names from Keymapp (e.g. after flashing new firmware)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: {
                root.refresh()
                root.refreshLayerNames()
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.layerLabels
              Button {
                required property var modelData
                required property int index
                text: modelData
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.currentLayer === index
                hasCursor: root.cursorActive && root.cursorLayer === index
                onClicked: root.setLayer(index)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.cursorLayer = index
                  }
                }
              }
            }
          }
        }

        // ---------- Not-connected / error messaging ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.keymappRunning || !root.keyboardConnected

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: !root.keymappRunning
              ? root.lastError
              : "No keyboard connected in Keymapp. Plug in your keyboard and make sure Keymapp sees it."
            textFormat: Text.PlainText
            color: root.bar.foreground
            opacity: 0.7
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Firmware footer ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(fwLabel.implicitHeight, fwValue.implicitHeight, fwLink.implicitHeight)
          visible: root.keymappRunning && root.keyboardConnected && root.firmwareVersion !== ""

          Text {
            id: fwLabel
            text: "Firmware"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: fwValue
            text: root.firmwareVersion
            textFormat: Text.PlainText
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.left: fwLabel.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
          }

          PanelActionButton {
            id: fwLink
            visible: root.configureUrl !== ""
            iconText: "↗"
            tooltipText: "Open this layout in ZSA Configure"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            anchors.left: fwValue.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.openConfigureUrl()
          }
        }
      }
    }
  }
}
