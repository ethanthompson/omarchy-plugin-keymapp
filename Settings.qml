import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Settings modal for the Keymapp panel — currently just the polling
// interval. Summoned by the shell as a separate "overlay" plugin surface
// (see manifest.json + Panel.qml's gear button), the same pattern the Home
// Assistant plugin uses for its own settings screen, rather than shown
// inline in the popup panel.
//
//   omarchy-shell shell summon ethan.keymapp
Item {
  id: root

  // Injected by the shell's panel loader (see shell.qml's Instantiator).
  property var shell: null
  property var manifest: null

  property bool opened: false
  readonly property string pluginId: (manifest && manifest.id) || "ethan.keymapp"

  // Snapshotted from Panel.qml's `settings` on open(). Keeping every key
  // here, not just refreshIntervalSec, means save() never clobbers settings
  // this screen doesn't show (layerCount, layerNames).
  property var baseSettings: ({})
  // The value on disk, as of open() or the last Save. The slider only ever
  // edits intervalDraft — nothing is written back until the user hits Save,
  // so dragging around and then hitting Escape/clicking outside leaves the
  // saved interval untouched.
  property int savedIntervalSec: 5
  property int intervalDraft: 5
  readonly property bool dirty: intervalDraft !== savedIntervalSec

  function open(payloadJson) {
    var payload = {}
    try {
      payload = payloadJson ? JSON.parse(payloadJson) : {}
    } catch (e) {
      payload = {}
    }
    root.baseSettings = payload || {}
    var interval = Number(payload.refreshIntervalSec)
    var normalized = isFinite(interval) && interval > 0 ? Math.round(interval) : 5
    root.savedIntervalSec = normalized
    root.intervalDraft = normalized
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  // Discards intervalDraft — nothing was written to disk, so there's
  // nothing to undo.
  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function save() {
    if (root.dirty) {
      var entry = { id: root.pluginId }
      for (var k in root.baseSettings) if (k !== "id") entry[k] = root.baseSettings[k]
      entry.refreshIntervalSec = root.intervalDraft
      root.baseSettings = entry
      if (root.shell && typeof root.shell.updateEntryInline === "function")
        root.shell.updateEntryInline(root.pluginId, entry)
      root.savedIntervalSec = root.intervalDraft
    }
    root.dismiss()
  }

  readonly property string family: Style.font.menuFamily
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property var borderSpec: Border.surfaceSpec(
    "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "ethan.keymapp-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(420), window.width - Style.gapsOut * 2)
      height: Math.min(Style.space(290), window.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      // Swallows clicks on the card itself so they don't fall through to
      // the scrim's dismiss-on-click-outside MouseArea behind it.
      MouseArea { anchors.fill: parent }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        onCloseRequested: root.dismiss()
        onActivateRequested: root.save()

        Item {
          id: header
          anchors { top: parent.top; left: parent.left; right: parent.right }
          implicitHeight: heading.implicitHeight

          Text {
            id: heading
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Keymapp settings"
            color: root.foreground
            font.family: root.family
            font.pixelSize: Style.font.title
            font.weight: Font.Medium
          }

          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Close"
            foreground: root.foreground
            fontFamily: root.family
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.dismiss()
          }
        }

        PanelSeparator {
          id: rule
          anchors { top: header.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: Style.space(12)
          foreground: root.foreground
        }

        Row {
          id: footer
          anchors { bottom: parent.bottom; right: parent.right }
          spacing: Style.spacing.lg

          Button {
            text: "Cancel"
            foreground: root.foreground
            fontFamily: root.family
            bordered: true
            onClicked: root.dismiss()
          }

          Button {
            text: "Save"
            foreground: root.foreground
            fontFamily: root.family
            bordered: true
            enabled: root.dirty
            opacity: enabled ? 1.0 : 0.5
            onClicked: root.save()
          }
        }

        Column {
          anchors {
            top: rule.bottom; bottom: footer.top
            left: parent.left; right: parent.right
          }
          anchors.topMargin: Style.space(16)
          anchors.bottomMargin: Style.space(16)
          spacing: Style.spacing.sm

          Item {
            width: parent.width
            implicitHeight: Math.max(intervalLabel.implicitHeight, intervalValue.implicitHeight)

            Text {
              id: intervalLabel
              textFormat: Text.PlainText
              text: "Polling interval"
              color: root.foreground
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: intervalValue
              text: (intervalSlider.dragging ? intervalSlider.liveValue : root.intervalDraft) + "s"
              color: Color.muted
              font.family: root.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: intervalSlider
            width: parent.width
            minimum: 2
            maximum: 60
            step: 1
            integer: true
            value: root.intervalDraft
            onMoved: function(v) { root.intervalDraft = Math.round(v) }
            onReleased: function(v) { root.intervalDraft = Math.round(v) }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "How often Keymapp is polled for the connected keyboard's status and active layer."
            wrapMode: Text.WordWrap
            color: Color.muted
            font.family: root.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
