import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.nicoolai.eve-monitor"
  ipcTarget: "io.github.nicoolai.eve-monitor"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var snapshot: ({ ok: false, characters: [] })
  property string authMessage: ""
  property int selectedIndex: 0
  property int clockTick: 0
  property string pendingCharacterId: ""
  property string writingCharacterId: ""
  property string displayedCharacterId: ""
  property string activeView: "overview"
  property var detailPayload: ({ ok: false, data: {}, errors: [] })
  property bool detailLoading: false
  property string detailCharacterId: ""
  property string pendingDetailView: ""
  property var pendingDetailTarget: null
  property string settingsMessage: ""
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var characters: snapshot && snapshot.characters ? snapshot.characters : []
  readonly property var plans: snapshot && snapshot.plans ? snapshot.plans : []
  readonly property var character: {
    if (characters.length === 0) return null
    if (displayedCharacterId) {
      for (var i = 0; i < characters.length; i++) {
        if (String(characters[i].characterId) === displayedCharacterId) return characters[i]
      }
    }
    return characters[Math.min(selectedIndex, characters.length - 1)]
  }

  function syncSelection() {
    if (characters.length === 0) {
      selectedIndex = 0
      displayedCharacterId = ""
      return
    }
    var wanted = displayedCharacterId || String(snapshot.selectedCharacterId || "")
    for (var i = 0; i < characters.length; i++) {
      if (String(characters[i].characterId) === wanted) {
        displayedCharacterId = wanted
        selectedIndex = i
        return
      }
    }
    displayedCharacterId = String(characters[0].characterId)
    selectedIndex = 0
  }

  onSnapshotChanged: {
    syncSelection()
    if (activeView !== "overview" && activeView !== "settings" && root.character
        && root.detailCharacterId !== String(root.character.characterId)) {
      Qt.callLater(function() { root.loadDetails(root.activeView, root.character) })
    }
  }

  function open() {
    controller.show()
    if (hostWidget && hostWidget.refresh) hostWidget.refresh(false)
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { popoutSwitchClosing = true; close(); Qt.callLater(function() { popoutSwitchClosing = false }) }

  function selectCharacter(index) {
    var nextCharacter = index >= 0 && index < characters.length ? characters[index] : null
    if (!nextCharacter || !hostWidget) return
    selectedIndex = index
    displayedCharacterId = String(nextCharacter.characterId)
    pendingCharacterId = String(nextCharacter.characterId)
    if (hostWidget.setSelectedCharacter) hostWidget.setSelectedCharacter(nextCharacter.characterId)
    selectionTimer.restart()
    if (activeView !== "overview") loadDetails(activeView, nextCharacter)
  }

  function authAdd() { if (hostWidget && hostWidget.authAdd) hostWidget.authAdd() }
  function cancelAuth() { if (hostWidget && hostWidget.cancelAuth) hostWidget.cancelAuth() }

  function selectView(view) {
    root.activeView = view
    if (view !== "overview" && view !== "settings") root.loadDetails(view)
  }

  function viewLabel(view) {
    var labels = { overview: "OVERVIEW", training: "TRAINING", wealth: "WEALTH", industry_market: "INDUSTRY", activity: "ACTIVITY", character: "CHARACTER", settings: "SETTINGS" }
    return labels[view] || String(view).toUpperCase()
  }

  function detailRows(view) {
    var data = root.detailPayload.data || {}
    if (view === "wealth") return []
    if (view === "industry_market") {
      var rows = (data.jobs || []).slice()
      ;(data.orders || []).forEach(function(order) {
        var copy = {}
        for (var key in order) copy[key] = order[key]
        copy._rowKind = "order"
        rows.push(copy)
      })
      return rows
    }
    if (view === "activity") return data.notifications || []
    return data.implants || []
  }

  function walletFlowDays() {
    var data = root.detailPayload.data || {}
    return data.cashflow && data.cashflow.days ? data.cashflow.days : []
  }

  function walletFlowMax() {
    var days = walletFlowDays()
    var maximum = 0
    for (var i = 0; i < days.length; i++) {
      maximum = Math.max(maximum, Number(days[i].income) || 0, Number(days[i].expenses) || 0)
    }
    return maximum || 1
  }

  function walletDateLabel(value) {
    var text = String(value || "")
    return text.length >= 10 ? text.substring(5, 10) : text
  }

  function walletTimestampLabel(value) {
    var text = String(value || "")
    return text.length >= 16 ? text.substring(0, 16).replace("T", " ") : text
  }

  function walletAmount(value) {
    var amount = Number(value) || 0
    return (amount >= 0 ? "+" : "-") + Model.formatIsk(Math.abs(amount))
  }

  function walletTransactionTotal(transaction) {
    return (Number(transaction.quantity) || 0) * (Number(transaction.unit_price) || 0)
  }

  function implantLabel(value) {
    if (value && typeof value === "object") {
      return value.name || ("Implant type " + (value.typeId || value.type_id || "Unknown"))
    }
    return "Implant type " + String(value || "Unknown")
  }

  function compactTotal(value) {
    var numeric = Number(value) || 0
    var absolute = Math.abs(numeric)
    if (absolute >= 1000000000000) return (numeric / 1000000000000).toFixed(1) + "T"
    if (absolute >= 1000000000) return (numeric / 1000000000).toFixed(1) + "B"
    if (absolute >= 1000000) return (numeric / 1000000).toFixed(1) + "M"
    if (absolute >= 1000) return (numeric / 1000).toFixed(1) + "K"
    return Model.formatNumber(numeric)
  }

  function headerMeta() {
    if (root.characters.length === 0) return "No characters connected"
    var totalSkillPoints = 0
    var totalIsk = 0
    for (var i = 0; i < root.characters.length; i++) {
      totalSkillPoints += Number(root.characters[i].totalSp) || 0
      totalIsk += Number(root.characters[i].wallet) || 0
    }
    return root.characters.length + " character" + (root.characters.length === 1 ? "" : "s")
      + "  |  " + compactTotal(totalSkillPoints) + " SP"
      + "  |  " + compactTotal(totalIsk) + " ISK"
  }

  function trainingRows() {
    var skills = root.detailPayload.data && root.detailPayload.data.skills
      ? root.detailPayload.data.skills.slice()
      : []
    skills.sort(function(a, b) {
      var categoryA = String(a.category || "Uncategorized").toLowerCase()
      var categoryB = String(b.category || "Uncategorized").toLowerCase()
      if (categoryA !== categoryB) return categoryA < categoryB ? -1 : 1
      var nameA = String(a.name || "Unknown skill").toLowerCase()
      var nameB = String(b.name || "Unknown skill").toLowerCase()
      return nameA === nameB ? 0 : (nameA < nameB ? -1 : 1)
    })

    var rows = []
    var lastCategory = ""
    for (var i = 0; i < skills.length; i++) {
      var skill = skills[i]
      var category = String(skill.category || "Uncategorized")
      if (category !== lastCategory) {
        rows.push({ kind: "category", label: category })
        lastCategory = category
      }
      rows.push({
        kind: "skill",
        name: skill.name || "Unknown skill",
        level: skill.trained_skill_level || 0,
        skillPoints: skill.skillpoints_in_skill || 0,
      })
    }
    return rows
  }

  function loadDetails(view, targetCharacter) {
    var target = targetCharacter || root.character
    if (!target || !root.hostWidget) return
    if (detailProcess.running) {
      root.pendingDetailView = view
      root.pendingDetailTarget = target
      return
    }
    root.detailCharacterId = String(target.characterId)
    root.detailLoading = true
    root.detailPayload = { ok: false, data: {}, errors: [] }
    detailProcess.command = ["python3", root.hostWidget.script, "details", String(target.characterId), view]
    detailProcess.running = true
  }

  function applyDetails(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      root.detailPayload = parsed.ok === true ? parsed : { ok: false, data: {}, errors: [parsed.error || "Could not load EVE data"] }
    } catch (error) {
      root.detailPayload = { ok: false, data: {}, errors: ["Unexpected response from EVE monitor"] }
    }
    root.detailLoading = false
  }

  function settingValue(name, fallback) {
    return root.hostWidget && root.hostWidget.setting ? root.hostWidget.setting(name, fallback) : fallback
  }

  function barModeLabel() {
    var mode = root.hostWidget ? String(root.hostWidget.barMode || "selected") : "selected"
    if (mode === "auto") return "Automatic"
    if (mode === "soonest") return "Soonest active"
    return "Selected character"
  }

  function showCharacterName() {
    var value = settingValue("showCharacterName", false)
    return value === true || ["true", "on", "yes", "1"].indexOf(String(value).toLowerCase()) >= 0
  }

  function refreshSeconds() {
    return Math.max(60, Math.min(1800, parseInt(settingValue("refreshIntervalSec", 120), 10) || 120))
  }

  function saveSetting(key, value) {
    if (!root.hostWidget || !root.hostWidget.moduleName) return
    root.settingsMessage = "Saving..."
    settingsProcess.command = ["omarchy", "bar", "set", root.hostWidget.moduleName, key, String(value)]
    settingsProcess.running = false
    settingsProcess.running = true
  }

  function cycleBarMode() {
    var modes = ["Selected character", "Soonest active", "Automatic"]
    var current = barModeLabel()
    saveSetting("barMode", modes[(modes.indexOf(current) + 1) % modes.length])
  }

  function adjustRefresh(delta) {
    saveSetting("refreshIntervalSec", Math.max(60, Math.min(1800, refreshSeconds() + delta)))
  }

  function toggleCharacterName() {
    saveSetting("showCharacterName", showCharacterName() ? "false" : "true")
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.clockTick++
  }

  Timer {
    id: selectionTimer
    interval: 180
    repeat: false
    onTriggered: {
      if (!root.pendingCharacterId || !root.hostWidget) return
      if (setSelectedProcess.running) return
      root.writingCharacterId = root.pendingCharacterId
      setSelectedProcess.command = ["python3", root.hostWidget.script, "select", root.writingCharacterId]
      setSelectedProcess.running = true
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        var maxY = Math.max(0, contentFlick.contentHeight - contentFlick.height)
        if (dy !== 0 && root.activeView !== "overview" && maxY > 0) {
          contentFlick.contentY = Math.max(0, Math.min(maxY, contentFlick.contentY + dy * Style.space(56)))
          return
        }
        if (dy === 0 || root.characters.length === 0) return
        var nextIndex = Math.max(0, Math.min(root.characters.length - 1, root.selectedIndex + dy))
        if (nextIndex !== root.selectedIndex) root.selectCharacter(nextIndex)
      }
      onTextKey: function(text) {
        if (text === "a") root.authAdd()
        else if (text === "r" && root.hostWidget) root.hostWidget.refresh(true)
      }

      Flickable {
        id: contentFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: content
          width: contentFlick.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "EVE Online Monitor"
          meta: root.headerMeta()
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "\uF135"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          PanelActionButton {
            iconText: root.hostWidget && root.hostWidget.authRunning ? "\uF00D" : "\uF067"
            tooltipText: root.hostWidget && root.hostWidget.authRunning ? "Cancel EVE authorization" : "Add EVE character"
            foreground: root.foreground
            hoverColor: root.accent
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.authAdd()
          }
          PanelActionButton {
            iconText: "\uF021"
            tooltipText: "Refresh EVE data"
            foreground: root.foreground
            hoverColor: root.accent
            fontFamily: root.fontFamily
            onClicked: if (root.hostWidget) root.hostWidget.refresh(true)
          }
          Text {
            width: parent.width - Style.space(60)
            text: root.authMessage
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSeparator { width: parent.width }

        Row {
          width: parent.width
          spacing: Style.space(2)
          visible: true
          Repeater {
            model: ["overview", "training", "wealth", "industry_market", "activity", "character", "settings"]
            Rectangle {
              required property string modelData
              width: (parent.width - Style.space(12)) / 7
              height: Style.space(28)
              radius: Style.cornerRadius
              clip: true
              color: modelData === root.activeView ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
              Text {
                anchors.fill: parent
                anchors.leftMargin: Style.space(2)
                anchors.rightMargin: Style.space(2)
                text: root.viewLabel(parent.modelData)
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                color: parent.modelData === root.activeView ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.selectView(parent.modelData)
              }
            }
          }
        }

        ListView {
          id: characterList
          width: parent.width
          height: Math.min(contentHeight, Style.space(180))
          visible: root.characters.length > 0
          model: root.characters
          clip: true
          spacing: Style.space(2)
          delegate: Rectangle {
            required property var modelData
            required property int index
            width: characterList.width
            height: Style.space(42)
            radius: Style.cornerRadius
            color: index === root.selectedIndex
              ? Style.hoverFillFor(root.foreground, root.accent)
              : "transparent"

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                width: Style.space(18)
                text: modelData.online ? "\uF111" : "\uF10C"
                color: modelData.online ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              Column {
                width: parent.width - Style.space(150)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width
                  text: modelData.name
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: modelData.currentSkillName || "Queue ready"
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Text {
                width: Style.space(120)
                text: root.clockTick >= 0 && Model.liveQueueRemaining(modelData) > 0 ? Model.shortDuration(Model.liveRemaining(modelData)) : "READY"
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
                color: root.clockTick >= 0 && Model.liveQueueRemaining(modelData) > 0 ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            MouseArea {
              anchors.fill: parent
              onClicked: root.selectCharacter(parent.index)
            }
          }
        }

        Text {
          width: parent.width
          visible: root.activeView === "overview" && root.character !== null
          text: root.character ? root.character.name : "Add a character to begin"
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Grid {
          width: parent.width
          columns: 2
          rowSpacing: Style.space(8)
          columnSpacing: Style.space(24)
          visible: root.activeView === "overview" && root.character !== null

          Text { text: "TRAINING"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: root.character ? (root.character.currentSkillName || "Queue ready") : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
          Text { text: "CURRENT ETA"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: root.clockTick >= 0 && root.character && Model.liveQueueRemaining(root.character) > 0 ? Model.formatDuration(Model.liveRemaining(root.character)) : "Ready"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.body }
          Text { text: "QUEUE ETA"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: root.clockTick >= 0 && root.character && Model.liveQueueRemaining(root.character) > 0 ? Model.formatDuration(Model.liveQueueRemaining(root.character)) : "No queued training"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
           Text { text: "SKILL POINTS"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
           Text { text: root.character ? Model.formatNumber(root.character.totalSp || 0) : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
           Text { text: "WALLET"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
           Text { text: root.character ? Model.formatIsk(root.character.wallet || 0) : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
          Text { text: "STATUS"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: root.character ? (root.character.online ? "Online" : "Offline") : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
          Text { text: "CORPORATION"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: root.character ? (root.character.corporationName || "Unknown") : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight }
          Text { text: "LOCATION"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: root.character ? (root.character.solarSystemName || "Unknown") : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight }
          Text { text: "SHIP"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: root.character ? (root.character.shipName || "Unknown") : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight }
        }

        Column {
          id: planColumn
          width: parent.width
          spacing: Style.space(5)
          visible: root.activeView === "overview" && root.plans.length > 0

          PanelSeparator { width: parent.width }
          Text {
            text: "SKILL PLANS"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: root.plans
            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width - Style.space(120)
                text: modelData.name + " (" + (modelData.skills || []).length + " skills)"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                width: Style.space(112)
                text: root.character && root.character.planEtaSeconds !== null && root.character.planEtaSeconds !== undefined
                  ? (root.character.planEtaSeconds > 0 ? Model.formatDuration(root.character.planEtaSeconds) : "Complete")
                  : "Catalog needed"
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
          Text {
            width: parent.width
            visible: root.character && root.character.planError
            text: root.character ? root.character.planError : ""
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          width: parent.width
          visible: root.activeView === "overview" && (root.characters.length === 0 || root.snapshot.error !== undefined)
          text: root.characters.length === 0
            ? "Press + or the right mouse button on the bar to authorize a character."
            : (root.snapshot.error || "")
          textFormat: Text.PlainText
          color: root.characters.length === 0 ? root.dim : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Column {
          id: settingsOptionsColumn
          width: parent.width
          spacing: Style.space(10)
          visible: root.activeView === "settings"
          readonly property int settingsControlWidth: Style.space(180)

          Text {
            width: parent.width
            text: "SETTINGS"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Text {
            width: parent.width
            text: "Changes are saved to Omarchy's bar configuration."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Item {
            width: parent.width - Style.space(8)
            implicitHeight: Math.max(modeLabel.implicitHeight, modeControl.implicitHeight)
            Text {
              id: modeLabel
              anchors.left: parent.left
              anchors.right: modeControl.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "BAR COUNTDOWN"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item {
              id: modeControl
              width: settingsOptionsColumn.settingsControlWidth
              height: modeButton.implicitHeight
              implicitHeight: height
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              Button {
                id: modeButton
                width: Style.space(150)
                anchors.right: parent.right
                text: root.barModeLabel()
                tooltipText: "Cycle countdown mode"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.cycleBarMode()
              }
            }
          }
          Item {
            width: parent.width - Style.space(8)
            implicitHeight: Math.max(refreshLabel.implicitHeight, refreshControl.implicitHeight)
            Text {
              id: refreshLabel
              anchors.left: parent.left
              anchors.right: refreshControl.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "REFRESH INTERVAL"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item {
              id: refreshControl
              width: settingsOptionsColumn.settingsControlWidth
              height: refreshPlus.implicitHeight
              implicitHeight: height
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              Row {
                anchors.right: parent.right
                spacing: Style.space(8)
                PanelActionButton {
                  id: refreshMinus
                  iconText: "\uF068"
                  tooltipText: "Decrease refresh interval"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.adjustRefresh(-30)
                }
                Text {
                  id: refreshValue
                  text: root.refreshSeconds() + "s"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  horizontalAlignment: Text.AlignHCenter
                  width: Style.space(46)
                  anchors.verticalCenter: parent.verticalCenter
                }
                PanelActionButton {
                  id: refreshPlus
                  iconText: "\uF067"
                  tooltipText: "Increase refresh interval"
                  foreground: root.foreground
                  hoverColor: root.accent
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.adjustRefresh(30)
                }
              }
            }
          }
          Item {
            width: parent.width - Style.space(8)
            implicitHeight: Math.max(nameLabel.implicitHeight, nameControl.implicitHeight)
            Text {
              id: nameLabel
              anchors.left: parent.left
              anchors.right: nameControl.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "SHOW CHARACTER NAME"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item {
              id: nameControl
              width: settingsOptionsColumn.settingsControlWidth
              height: nameButton.implicitHeight
              implicitHeight: height
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              Button {
                id: nameButton
                anchors.right: parent.right
                text: root.showCharacterName() ? "On" : "Off"
                tooltipText: "Toggle the character name in the top bar"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.toggleCharacterName()
              }
            }
          }
          Text {
            width: parent.width
            text: root.settingsMessage
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          id: detailContent
          width: parent.width
          spacing: Style.space(8)
          visible: root.activeView !== "overview" && root.activeView !== "settings"

          Text {
            width: parent.width
            text: root.detailLoading ? "Loading " + root.activeView + "..." : root.viewLabel(root.activeView)
            textFormat: Text.PlainText
            color: root.detailLoading ? root.dim : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Text {
            width: parent.width
            visible: !root.detailLoading && root.detailPayload.errors && root.detailPayload.errors.length > 0
            text: root.detailPayload.errors ? root.detailPayload.errors.join("; ") : ""
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.activeView === "training" && !root.detailLoading
            text: "CURRENT TRAINING QUEUE"
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ListView {
            id: trainingQueueList
            width: parent.width
            height: Math.min(contentHeight, Style.space(180))
            visible: root.activeView === "training" && !root.detailLoading && root.character !== null && root.character.queue && root.character.queue.length > 0
            model: root.character ? root.character.queue : []
            clip: true
            spacing: Style.space(2)
            delegate: Item {
              required property var modelData
              width: trainingQueueList.width
              height: Style.space(30)
              Text {
                anchors.left: parent.left
                anchors.right: queueLevel.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: (modelData.queuePosition === 0 ? "NOW  " : "#" + (modelData.queuePosition + 1) + "  ") + (modelData.skillName || "Unknown skill")
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                id: queueLevel
                anchors.right: queueEta.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(55)
                text: "to L" + (modelData.finishedLevel || 0)
                textFormat: Text.PlainText
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                id: queueEta
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(80)
                text: modelData.queuePosition === 0
                  ? Model.formatDuration(Model.liveRemaining(root.character))
                  : Model.formatDuration(Math.max(0, Model.dateSeconds(modelData.finishDate) - Date.now() / 1000))
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            width: parent.width
            visible: root.activeView === "training" && !root.detailLoading && (!root.character || !root.character.queue || root.character.queue.length === 0)
            text: "No queued training"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            visible: root.activeView === "training" && !root.detailLoading
            text: root.detailPayload.data
              ? "TRAINED SKILLS  " + Model.formatNumber(root.detailPayload.data.totalSp || 0) + " SP" + ((root.detailPayload.data.unallocatedSp || 0) > 0 ? "  |  " + Model.formatNumber(root.detailPayload.data.unallocatedSp) + " unallocated" : "")
              : "TRAINED SKILLS"
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ListView {
            id: trainingSkillList
            width: parent.width
            height: Math.min(contentHeight, Style.space(400))
            visible: root.activeView === "training" && !root.detailLoading
            model: root.trainingRows()
            clip: true
            spacing: Style.space(2)
            delegate: Item {
              required property var modelData
              width: trainingSkillList.width
              height: modelData.kind === "category" ? Style.space(26) : Style.space(28)
              Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: modelData.kind === "category"
                text: modelData.label
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                anchors.left: parent.left
                anchors.right: skillLevel.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: modelData.kind === "skill"
                text: modelData.name || ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                id: skillLevel
                anchors.right: skillPoints.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(45)
                visible: modelData.kind === "skill"
                text: "L" + (modelData.level || 0)
                textFormat: Text.PlainText
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                id: skillPoints
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(100)
                visible: modelData.kind === "skill"
                text: Model.formatNumber(modelData.skillPoints || 0) + " SP"
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Grid {
            width: parent.width
            columns: 2
            rowSpacing: Style.space(8)
            columnSpacing: Style.space(20)
            visible: root.activeView === "wealth" && !root.detailLoading
            Text { text: "BALANCE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Text { text: root.detailPayload.data ? Model.formatIsk(root.detailPayload.data.wallet || 0) : ""; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.body }
            Text { text: "IN"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Text { text: root.detailPayload.data && root.detailPayload.data.cashflow ? Model.formatIsk(root.detailPayload.data.cashflow.income || 0) : ""; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.body }
            Text { text: "OUT"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Text { text: root.detailPayload.data && root.detailPayload.data.cashflow ? Model.formatIsk(root.detailPayload.data.cashflow.expenses || 0) : ""; color: Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.body }
            Text { text: "NET"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Text {
              text: root.detailPayload.data && root.detailPayload.data.cashflow ? walletAmount(root.detailPayload.data.cashflow.net || 0) : ""
              color: root.detailPayload.data && root.detailPayload.data.cashflow && Number(root.detailPayload.data.cashflow.net || 0) < 0 ? Color.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            width: parent.width
            visible: root.activeView === "wealth" && !root.detailLoading
            text: "CASH FLOW  |  LAST 30 DAYS"
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item {
            id: walletChart
            width: parent.width
            height: Style.space(130)
            visible: root.activeView === "wealth" && !root.detailLoading && root.walletFlowDays().length > 0

            Rectangle {
              id: cashflowZero
              anchors.left: parent.left
              anchors.right: parent.right
              y: Style.space(51)
              height: 1
              color: root.dim
              opacity: 0.7
            }
            Row {
              id: cashflowBars
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(24)
              spacing: Style.space(2)
              Repeater {
                model: root.walletFlowDays()
                Item {
                  required property var modelData
                  width: Math.max(Style.space(4), (cashflowBars.width - Style.space(2) * Math.max(0, root.walletFlowDays().length - 1)) / Math.max(1, root.walletFlowDays().length))
                  height: parent.height
                  Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: cashflowZero.top
                    width: Math.max(1, parent.width - Style.space(4))
                    height: Math.min(Style.space(43), Style.space(43) * (Number(modelData.income) || 0) / root.walletFlowMax())
                    color: root.accent
                    visible: height > 0
                  }
                  Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: cashflowZero.bottom
                    width: Math.max(1, parent.width - Style.space(4))
                    height: Math.min(Style.space(43), Style.space(43) * (Number(modelData.expenses) || 0) / root.walletFlowMax())
                    color: Color.urgent
                    visible: height > 0
                  }
                }
              }
            }
            Text {
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              text: root.walletFlowDays().length > 0 ? walletDateLabel(root.walletFlowDays()[0].date) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              text: root.walletFlowDays().length > 0 ? walletDateLabel(root.walletFlowDays()[root.walletFlowDays().length - 1].date) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: root.activeView === "wealth" && !root.detailLoading
            text: "WALLET JOURNAL"
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ListView {
            id: walletJournalList
            width: parent.width
            height: Math.min(contentHeight, Style.space(240))
            visible: root.activeView === "wealth" && !root.detailLoading && root.detailPayload.data && root.detailPayload.data.journal && root.detailPayload.data.journal.length > 0
            model: root.detailPayload.data && root.detailPayload.data.journal ? root.detailPayload.data.journal : []
            clip: true
            spacing: Style.space(2)
            delegate: Item {
              required property var modelData
              width: walletJournalList.width
              height: Style.space(42)
              Text {
                anchors.left: parent.left
                anchors.right: journalAmount.left
                anchors.top: parent.top
                text: modelData.description || modelData.ref_type || "Wallet entry"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                anchors.left: parent.left
                anchors.right: journalAmount.left
                anchors.bottom: parent.bottom
                text: root.walletTimestampLabel(modelData.date) + "  |  " + (modelData.ref_type || "")
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              Text {
                id: journalAmount
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(150)
                text: root.walletAmount(modelData.amount)
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
                color: Number(modelData.amount) >= 0 ? root.accent : Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            width: parent.width
            visible: root.activeView === "wealth" && !root.detailLoading
            text: "TRANSACTIONS"
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ListView {
            id: walletTransactionList
            width: parent.width
            height: Math.min(contentHeight, Style.space(200))
            visible: root.activeView === "wealth" && !root.detailLoading && root.detailPayload.data && root.detailPayload.data.transactions && root.detailPayload.data.transactions.length > 0
            model: root.detailPayload.data && root.detailPayload.data.transactions ? root.detailPayload.data.transactions : []
            clip: true
            spacing: Style.space(2)
            delegate: Item {
              required property var modelData
              width: walletTransactionList.width
              height: Style.space(42)
              Text {
                anchors.left: parent.left
                anchors.right: transactionTotal.left
                anchors.top: parent.top
                text: (modelData.is_buy ? "BUY  " : "SELL  ") + (modelData.typeName || ("Type " + (modelData.type_id || "Unknown")))
                textFormat: Text.PlainText
                color: modelData.is_buy ? Color.urgent : root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                anchors.left: parent.left
                anchors.right: transactionTotal.left
                anchors.bottom: parent.bottom
                text: Model.formatNumber(modelData.quantity || 0) + " units  |  " + root.walletTimestampLabel(modelData.date)
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              Text {
                id: transactionTotal
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(150)
                text: Model.formatIsk(root.walletTransactionTotal(modelData))
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
                color: modelData.is_buy ? Color.urgent : root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          ListView {
            width: parent.width
            height: Math.min(contentHeight, Style.space(400))
            visible: ["industry_market", "activity", "character"].indexOf(root.activeView) >= 0 && !root.detailLoading
            model: root.detailRows(root.activeView)
            clip: true
            spacing: Style.space(2)
            delegate: Rectangle {
              required property var modelData
              width: parent.width
              height: Style.space(42)
              color: "transparent"
              Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.activeView === "assets"
                  ? (modelData.typeName || "Unknown type") + "  x" + Model.formatNumber(modelData.quantity || 0) + "  -  " + (modelData.locationName || "Unknown location")
                  : root.activeView === "industry_market"
                    ? (modelData._rowKind === "order"
                      ? (modelData.is_buy_order ? "BUY " : "SELL ") + (modelData.typeName || ("Type " + (modelData.type_id || ""))) + "  -  " + Model.formatIsk(modelData.price || 0)
                      : "Job " + (modelData.job_id || "") + "  -  " + (modelData.status || "unknown") + "  -  " + (modelData.end_date || ""))
                    : root.activeView === "activity"
                      ? (modelData.type || "Notification") + "  -  " + (modelData.timestamp || "")
                       : root.implantLabel(modelData)
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.activeView === "overview"
          text: "a add character - r refresh - esc close"
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          color: Qt.darker(root.dim, 1.15)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
          }
      }
    }
  }

  Process {
    id: setSelectedProcess
    onExited: function(exitCode, exitStatus) {
      var completedCharacterId = root.writingCharacterId
      root.writingCharacterId = ""
      if (root.pendingCharacterId === completedCharacterId) root.pendingCharacterId = ""
      if (root.hostWidget) root.hostWidget.refresh(exitCode !== 0)
      if (root.pendingCharacterId) root.selectionTimer.restart()
    }
  }

  Process {
    id: detailProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDetails(text)
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 && root.detailLoading) root.detailLoading = false
      if (root.pendingDetailView !== "") {
        var nextView = root.pendingDetailView
        var nextTarget = root.pendingDetailTarget
        root.pendingDetailView = ""
        root.pendingDetailTarget = null
        Qt.callLater(function() { root.loadDetails(nextView, nextTarget) })
      }
    }
  }

  Process {
    id: settingsProcess
    onExited: function(exitCode, exitStatus) {
      root.settingsMessage = exitCode === 0 ? "Saved" : "Could not save setting"
    }
  }
}
