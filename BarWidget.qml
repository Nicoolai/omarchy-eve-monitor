import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.nicoolai.eve-monitor"

  property var snapshot: ({ ok: false, characters: [] })
  property string lastError: ""
  property int clockTick: 0
  property bool authRunning: false
  property string authResultMessage: ""
  property bool authCanceled: false

  readonly property string script: String(Qt.resolvedUrl("bin/omarchy-eve-monitor")).replace(/^file:\/\//, "")
  readonly property int refreshIntervalSec: Math.max(60, Math.min(1800, parseInt(setting("refreshIntervalSec", 120), 10) || 120))
  readonly property string barMode: {
    var configured = String(setting("barMode", "Selected character")).trim().toLowerCase()
    if (configured === "auto" || configured === "automatic") return "auto"
    if (configured === "soonest" || configured === "soonest active") return "soonest"
    return "selected"
  }
  readonly property string barIcon: "\uF135"
  readonly property var selectedCharacter: Model.barCharacter(root.snapshot, root.barMode)
  readonly property bool hasCharacters: root.snapshot && root.snapshot.characters && root.snapshot.characters.length > 0
  readonly property string barCountdown: root.selectedCharacter
    ? (Model.liveQueueRemaining(root.selectedCharacter) > 0
      ? Model.shortDuration(Model.liveRemaining(root.selectedCharacter))
      : "READY")
    : "SETUP"
  readonly property string barText: {
    clockTick
    if (!hasCharacters) return root.barIcon + " EVE " + barCountdown
    var label = String(setting("showCharacterName", false)) === "true" ? root.selectedCharacter.name + " " : ""
    return root.barIcon + " " + label + barCountdown
  }
  readonly property string barTooltip: {
    clockTick
    return Model.tooltip(root.snapshot)
  }

  function refresh(force) {
    if (snapshotProcess.running) return
    snapshotProcess.command = ["python3", root.script, "snapshot"].concat(force ? ["--force"] : [])
    snapshotProcess.running = true
  }

  function applySnapshot(text) {
    var parsed = Model.parseSnapshot(text)
    if (parsed.ok) {
      root.snapshot = parsed
      root.lastError = ""
    } else {
      root.lastError = parsed.error
      if (!root.snapshot.characters) root.snapshot = { ok: false, characters: [] }
    }
  }

  function setSelectedCharacter(characterId) {
    var next = {}
    for (var key in root.snapshot) next[key] = root.snapshot[key]
    next.selectedCharacterId = String(characterId)
    root.snapshot = next
  }

  function authAdd() {
    if (authProcess.running) {
      cancelAuth()
      return
    }
    authResultMessage = ""
    authCanceled = false
    authRunning = true
    if (panelLoader.item) panelLoader.item.authMessage = "Waiting for EVE authorization..."
    authTimeout.restart()
    authProcess.running = true
  }

  function cancelAuth() {
    if (!authProcess.running) {
      authRunning = false
      return
    }
    authCanceled = true
    authProcess.running = false
    authRunning = false
    authTimeout.stop()
    if (panelLoader.item) panelLoader.item.authMessage = "Authorization canceled"
  }

  function applyAuthOutput(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      if (!parsed.ok) authResultMessage = parsed.error || "Authorization failed"
    } catch (error) {
      authResultMessage = "Authorization failed"
    }
  }

  function demo(enabled) {
    demoProcess.command = ["python3", root.script, "demo", enabled ? "on" : "off"]
    demoProcess.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      item.bar = root.bar
      item.hostWidget = root
      item.anchorItem = button
      item.snapshot = root.snapshot
      Qt.callLater(function() {
        if (item) item.snapshot = root.snapshot
      })
    }
  }

  onSnapshotChanged: if (panelLoader.item) panelLoader.item.snapshot = root.snapshot
  onBarChanged: if (panelLoader.item) panelLoader.item.bar = root.bar

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.clockTick++
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Process {
    id: snapshotProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySnapshot(text)
    }
  }

  Process {
    id: authProcess
    command: ["python3", root.script, "auth-add"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAuthOutput(text)
    }
    onExited: function(exitCode, exitStatus) {
      root.authRunning = false
      root.authTimeout.stop()
      root.refresh(true)
      if (panelLoader.item && !root.authCanceled) {
        panelLoader.item.authMessage = exitCode === 0 ? "Character added" : (root.authResultMessage || "Authorization failed")
      }
      root.authCanceled = false
      root.authResultMessage = ""
    }
  }

  Timer {
    id: authTimeout
    interval: 125000
    repeat: false
    onTriggered: {
      if (root.authRunning) root.cancelAuth()
    }
  }

  Process {
    id: demoProcess
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) { root.refresh(true) }
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): string { root.refresh(true); return "ok" }
    function status(): string { return root.barText }
    function auth(): string { root.authAdd(); return "started" }
    function demo(): string { root.demo(true); return "started" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(150)
    text: root.barText
    tooltipText: root.barTooltip
    foreground: root.lastError !== "" ? (root.bar && root.bar.urgent ? root.bar.urgent : Color.urgent) : (root.bar ? root.bar.barForeground : Color.foreground)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh(true)
      else if (buttonCode === Qt.RightButton) root.authAdd()
      else root.togglePanel()
    }
  }
}
