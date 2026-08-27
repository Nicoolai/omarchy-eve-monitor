.pragma library

function plain(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/[<>]/g, "")
    .trim()
}

function formatNumber(value, decimals) {
  var numeric = Number(value)
  var places = decimals === undefined ? 0 : Math.max(0, Number(decimals) || 0)
  if (!isFinite(numeric)) return "0"
  var parts = numeric.toFixed(places).split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return parts.join(".")
}

function formatIsk(value) {
  return formatNumber(value, 2) + " ISK"
}

function formatDuration(seconds) {
  var value = Math.max(0, Math.floor(Number(seconds) || 0))
  var days = Math.floor(value / 86400)
  value %= 86400
  var hours = Math.floor(value / 3600)
  value %= 3600
  var minutes = Math.floor(value / 60)
  var secs = value % 60

  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  if (minutes > 0) return minutes + "m " + secs + "s"
  return secs + "s"
}

function shortDuration(seconds) {
  var value = Math.max(0, Math.floor(Number(seconds) || 0))
  var days = Math.floor(value / 86400)
  value %= 86400
  var hours = Math.floor(value / 3600)
  value %= 3600
  var minutes = Math.floor(value / 60)

  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return minutes + "m"
}

function dateSeconds(value) {
  var parsed = Date.parse(String(value || ""))
  return isNaN(parsed) ? 0 : parsed / 1000
}

function liveRemaining(character) {
  if (!character) return 0
  var now = Date.now() / 1000
  var queue = character.queue || []
  for (var i = 0; i < queue.length; i++) {
    var finish = dateSeconds(queue[i].finishDate)
    if (finish > now) return finish - now
  }
  return 0
}

function liveQueueRemaining(character) {
  if (!character) return 0
  var queue = character.queue || []
  var latest = 0
  for (var i = 0; i < queue.length; i++) latest = Math.max(latest, dateSeconds(queue[i].finishDate))
  if (latest <= 0) latest = dateSeconds(character.queueFinishDate)
  return Math.max(0, latest - Date.now() / 1000)
}

function normalizeCharacter(character) {
  var copy = {}
  for (var key in (character || {})) copy[key] = character[key]
  copy.name = plain(copy.name || "Unknown character")
  copy.currentSkillName = plain(copy.currentSkillName || "")
  copy.error = plain(copy.error || "")
  copy.remainingSeconds = Math.max(0, Number(copy.remainingSeconds) || 0)
  copy.queueRemainingSeconds = Math.max(0, Number(copy.queueRemainingSeconds) || 0)
  copy.online = copy.online === true
  copy.queue = copy.queue instanceof Array ? copy.queue : []
  return copy
}

function parseSnapshot(raw) {
  try {
    var payload = JSON.parse(String(raw || ""))
    if (!payload || payload.ok !== true) return { ok: false, error: plain(payload && payload.error) || "EVE monitor is not configured" }
    payload.characters = (payload.characters || []).map(normalizeCharacter)
    return payload
  } catch (error) {
    return { ok: false, error: "Unexpected response from EVE monitor" }
  }
}

function barCharacter(payload, mode) {
  var characters = payload && payload.characters ? payload.characters : []
  var active = characters.filter(function(character) { return liveQueueRemaining(character) > 0 })
  if (characters.length === 0) return null

  var selectedId = String(payload.selectedCharacterId || "")
  var selected = characters.filter(function(character) { return String(character.characterId) === selectedId })[0]
  if (!selected) selected = characters[0]

  if (mode === "soonest" || (mode === "auto" && characters.length > 1)) {
    if (active.length > 0) {
      active.sort(function(a, b) { return a.queueRemainingSeconds - b.queueRemainingSeconds })
      return active[0]
    }
  }
  return selected
}

function tooltip(payload) {
  var characters = payload && payload.characters ? payload.characters : []
  if (characters.length === 0) return "Add an EVE Online character"
  return characters.map(function(character) {
    var state = liveQueueRemaining(character) > 0
      ? (plain(character.currentSkillName) || "Training") + " - " + shortDuration(liveRemaining(character))
      : "Queue ready"
    return character.name + ": " + state
  }).join("\n")
}

function planSummary(plans) {
  return (plans || []).map(function(plan) {
    return plain(plan.name || "Unnamed plan") + " (" + ((plan.skills || []).length) + " skills)"
  }).join("\n")
}
