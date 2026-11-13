-- Copyright (C) 2026 Kijbev
-- This file is part of FS25_ToPastureAndBack_RL (To Pasture And Back, RL edition).
-- Licensed under the GNU General Public License v3.0 or later.
-- See the LICENSE file shipped with this mod, or https://www.gnu.org/licenses/gpl-3.0.html
--[[
    To Pasture and Back - RL Edition for Farming Simulator 25
    Realistic Livestock compatible version.
    Moves livestock from barns to owned pasture fields for timed grazing.
    Reads RL's individual animal data (breed, age, gender, ear tags).
    All species supported (cows, sheep, goats, pigs, horses), chickens and fish excluded.
    Visual-only: barn feeding, breeding, and production continue normally.

    Requires: FS25_RealisticLivestockRM
    Do NOT use alongside base game "To Pasture and Back".

    Author: Kijbev
    Version: 0.1.0.0 (initial RL port)
]]

ToPastureAndBack_RL = {}

ToPastureAndBack_RL.DEBUG = false  -- GitHub release build 2026-11-13; true again when development resumes
local dbgLog  -- forward declaration; defined below, gated by DEBUG

-- PCALL-FREE CALLS (TestRunner PublicLuaCheck fails any pcall/xpcall, 2026-09-09). fcall checks that
-- the function exists and calls it; an error inside it now reaches the log, as the cert wants.
-- fcallNode also checks the node id still exists, so a stale node is skipped instead of making the
-- engine log an "Unknown entity id" line. Both return false plus a reason when they do not call.
--- Singular or plural text by count (2026-10-13, "why (s) when it is only ever
--- shown for more than one?"). The plural keeps the base key, the singular is key.."_one".
--- hasText first (the base game's own test); getText on an absent key returns a placeholder.
function ToPastureAndBack_RL.textN(key, n, fbMany, fbOne)
    local k = (n == 1) and (key .. "_one") or key
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(k) then
        return g_i18n:getText(k)
    end
    return (n == 1) and fbOne or fbMany
end

--- Localized text with an English fallback for a key the locale does not carry (2026-10-22).
function ToPastureAndBack_RL.locText(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return fallback
end

--- Localized place tail for herd messages, with its leading space (2026-10-22): kind is
--- "at_farmland" (pasture name, farmland id), "at" (pasture name) or "farmland" (farmland id).
ToPastureAndBack_RL.PLACE_FALLBACK = { at_farmland = "at %s on {farmland} %d", at = "at %s", farmland = "on {farmland} %d" }
function ToPastureAndBack_RL.placeFmt(kind)
    return " " .. ToPastureAndBack_RL.farmText(ToPastureAndBack_RL.locText("tpab_place_" .. kind, ToPastureAndBack_RL.PLACE_FALLBACK[kind]))
end

--- The game's own word for a farmland, in the player's language (our ruling 2026-10-25): the
--- on-foot info box labels the number with the base-game text fieldInfo_farmland ("Farmland" in
--- English, read from the running game), so every herd message that names a farmland uses that
--- same word and always matches the box. Our texts carry the token {farmland} where it goes
--- ({la_farmland} in French, see frArticleWord).
--- French puts an article before the noun mid-sentence ("sur la parcelle 13"), and its form
--- follows the noun: la (feminine), le (masculine), l' (before a vowel or h), les (plural). The
--- French texts carry the token {la_farmland}; the article is chosen from the game's own word.
--- A word not in either list keeps the game's label form with no article ("sur Parcelle 13").
ToPastureAndBack_RL.FR_FEMININE = { parcelle = true, terre = true, zone = true, surface = true, exploitation = true, ["propriété"] = true }
ToPastureAndBack_RL.FR_MASCULINE = { terrain = true, champ = true, lot = true, domaine = true, secteur = true }
ToPastureAndBack_RL.FR_VOWEL_START = { a = true, e = true, i = true, o = true, u = true, y = true, h = true,
    ["\195\169"] = true, ["\195\168"] = true, ["\195\170"] = true, ["\195\174"] = true,
    ["\195\180"] = true, ["\195\162"] = true }
function ToPastureAndBack_RL.frArticleWord(word)
    local lw = string.lower(word)
    local first = string.match(lw, "^(%S+)") or lw
    local plural = false
    local stem = first
    if not ToPastureAndBack_RL.FR_FEMININE[first] and not ToPastureAndBack_RL.FR_MASCULINE[first] then
        local last = string.sub(first, -1)
        if last == "s" or last == "x" then
            stem = string.sub(first, 1, -2)
            plural = true
        end
    end
    local fem = ToPastureAndBack_RL.FR_FEMININE[stem] == true
    local masc = ToPastureAndBack_RL.FR_MASCULINE[stem] == true
    if not fem and not masc then
        return word
    end
    if plural then
        return "les " .. lw
    end
    local c1 = string.sub(lw, 1, 1)
    local c2 = string.sub(lw, 1, 2)
    if ToPastureAndBack_RL.FR_VOWEL_START[c1] or ToPastureAndBack_RL.FR_VOWEL_START[c2] then
        return "l'" .. lw
    end
    if fem then
        return "la " .. lw
    end
    return "le " .. lw
end

--- German says where a herd is, or that it is out, never both (2026-10-25: "auf der Weide"
--- already means out on pasture). The German texts carry {draußen} right before the place tail:
--- it becomes " draußen" when no place follows and nothing when one does. Other languages do not
--- use the token, so their texts pass through unchanged.
function ToPastureAndBack_RL.outText(text, tail)
    if type(text) ~= "string" or string.find(text, "{draußen}", 1, true) == nil then
        return text
    end
    local word = (type(tail) == "string" and tail ~= "") and "" or " draußen"
    local out = string.gsub(text, "{draußen}", function() return word end)
    return out
end

function ToPastureAndBack_RL.farmText(text)
    if type(text) ~= "string" or string.find(text, "_farmland}", 1, true) == nil
            and string.find(text, "{farmland}", 1, true) == nil then
        return text
    end
    local word = ToPastureAndBack_RL.locText("fieldInfo_farmland", "Farmland")
    if type(word) ~= "string" or word == "" then
        word = "Farmland"
    end
    local frWord = ToPastureAndBack_RL.frArticleWord(word)
    -- The words are spliced into a format string, so a literal percent sign must stay literal.
    word = string.gsub(word, "%%", "%%%%")
    frWord = string.gsub(frWord, "%%", "%%%%")
    local out = string.gsub(text, "{la_farmland}", function() return frWord end)
    out = string.gsub(out, "{farmland}", function() return word end)
    return out
end

function ToPastureAndBack_RL.fcall(fn, ...)
    if type(fn) ~= "function" then return false, "not a function" end
    return true, fn(...)
end
--- RL's createVisual reads the birthday and the age model without nil checks (VisualAnimal
--- setRightEarTag and VisualAnimal:load). Our calls go through fcall, which does not catch errors,
--- so an animal that would make it throw is skipped (review 2026-10-27).
function ToPastureAndBack_RL.canCreateRLVisual(animal)
    if type(animal) ~= "table" or animal.birthday == nil then return false end
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if animalSystem == nil or animalSystem.getVisualByAge == nil then return false end
    local ok, visual = ToPastureAndBack_RL.fcall(animalSystem.getVisualByAge, animalSystem, animal.subTypeIndex, animal.age)
    return ok and visual ~= nil
end
function ToPastureAndBack_RL.fcallNode(fn, node, ...)
    if type(fn) ~= "function" then return false, "not a function" end
    if type(node) ~= "number" or node == 0 or not entityExists(node) then return false, "node gone" end
    return true, fn(node, ...)
end

-- Capture mod directory at file scope (g_currentModDirectory is only valid during script loading)
ToPastureAndBack_RL.modDirectory = g_currentModDirectory

-- 2026-05-25 (fix v2): capture g_currentModSettingsDirectory at file scope too.
-- First attempt (earlier today) read this global inline in getSettingsPath() at
-- runtime, but the engine resets it as other mods are loaded; in our MP
-- log it resolved to '/modSettings/FS25_zzLazydistribution/' (some other mod's
-- directory). Saves landed there, loads couldn't find them, settings effectively
-- lost. Mirror the modDirectory capture above: snapshot at script-load time when
-- the global is guaranteed to point at THIS mod.
ToPastureAndBack_RL.modSettingsDirectory = g_currentModSettingsDirectory
ToPastureAndBack_RL.initialized = false
ToPastureAndBack_RL.rlMissing = false
ToPastureAndBack_RL.rlWarningShown = false

-- Pasture points: list of placed markers
ToPastureAndBack_RL.pasturePoints = {}
ToPastureAndBack_RL.nextPastureId = 1

-- Grazing sessions: active herds on pasture
ToPastureAndBack_RL.grazingSessions = {}

-- Barn data: cached nav mesh sources per animal type (populated on first use)
ToPastureAndBack_RL.barnCache = {}         -- keyed by animal type, value = list of all candidates
ToPastureAndBack_RL.barnCacheReady = false
ToPastureAndBack_RL.initComplete = false           -- gates keybinds during boot/sync (false until reconstructSavedSessions or client sync grace expires)
ToPastureAndBack_RL.clientSyncDeadline = nil       -- frame number after which a client gives up waiting for sync replies
ToPastureAndBack_RL.BARN_SCAN_DELAY = 350  -- frames to wait before scanning (placeables load by ~300)
ToPastureAndBack_RL.BARN_SCAN_RETRY_INTERVAL = 60  -- frames between retries if client finds no placeables
ToPastureAndBack_RL.BARN_SCAN_MAX_RETRIES = 20     -- give up after this many retries (~20 seconds at 60fps)
ToPastureAndBack_RL.BARN_SCAN_MIN_CLIENT_RETRIES = 5  -- minimum retries on client even after finding some barns
ToPastureAndBack_RL.barnScanRetries = 0
ToPastureAndBack_RL.prevBarnCount = 0               -- track previous scan result to detect when new barns stop appearing
ToPastureAndBack_RL.BARN_PROXIMITY = 50    -- meters, max distance to detect "nearest barn"
-- cert 2026-07-07 (M8): a POCKETABLE barn within this distance wins over a nearer
-- grazing-herd centroid (adjacent barns on one field), see initiateGrazing override.
local TPAB_BARN_POCKET_OVERRIDE_RADIUS = 15

-- Density map data (cached after loadMap)
ToPastureAndBack_RL.densityMapId = nil
ToPastureAndBack_RL.densityFirstChannel = nil
ToPastureAndBack_RL.densityNumChannels = nil
ToPastureAndBack_RL.grassValue = nil

-- Forage-type foliage layers (for growth state detection, separate from ground type)
-- Multiple fruit types can represent grazeable/forageable vegetation
ToPastureAndBack_RL.forageLayers = {}  -- list of {name, planeId, startCh, numCh, cutState, groundType}
ToPastureAndBack_RL.forageReady = false
-- All crop layers (non-forage fruit types with foliage data, for pig stubble detection)
ToPastureAndBack_RL.cropLayers = {}  -- list of {name, planeId, startCh, numCh, cutState}
ToPastureAndBack_RL.cropLayersReady = false

-- Forage type names: detected at runtime, unknown names silently ignored.
-- Covers base game (GRASS, MEADOW) and popular map additions (alfalfa, clover, etc.)
ToPastureAndBack_RL.KNOWN_FORAGE_NAMES = {
    "GRASS", "MEADOW", "FIELDGRASS",
    "ALFALFA", "CLOVER",
    "GREENRYE", "FLOWERINGCATCHCROP",
}
-- Lookup set built at init from resolved forage names (for fast "is this forage?" checks)
ToPastureAndBack_RL.forageNameSet = {}

-- Temporary pasture fences: visual net fence around grazing contour
ToPastureAndBack_RL.FENCE_I3D_PATH = "data/placeables/brandless/fences/husbandries/chickenNetFence/chickenNetFence.i3d"
ToPastureAndBack_RL.FENCE_POST_SPACING = 2.0    -- meters between fence posts
ToPastureAndBack_RL.FENCE_PANEL_LENGTH = 2.0    -- base panel mesh length along local +Z (from I3D)
ToPastureAndBack_RL.FENCE_MAX_SCALE = 1.3       -- max panel stretch factor
ToPastureAndBack_RL.FENCE_Y_SCALE = 0.6         -- panel height scale (waist-height temporary fence)
ToPastureAndBack_RL.FENCE_POLE_Y_SCALE = 0.5    -- pole height scale (shorter so tip aligns with netting top)
ToPastureAndBack_RL.fenceTemplateRoot = nil      -- cached I3D root node
ToPastureAndBack_RL.fenceTemplateLoaded = false

-- Fence detection: skip temp fences on fields already fenced by the map or player
ToPastureAndBack_RL.FENCE_DETECT_SEARCH_RADIUS = 10  -- meters, max distance from contour center to consider a fence segment
-- meters, max perpendicular distance from contour edge to count a fence segment as "covering" it (contour is
-- ~8m inside field boundary where fences sit)
ToPastureAndBack_RL.FENCE_DETECT_PROXIMITY = 12
ToPastureAndBack_RL.FENCE_DETECT_ANGLE_TOLERANCE = 30 -- degrees, max angle between fence segment and contour edge to count as parallel
-- fraction of perimeter that must be covered to skip temp fence (was 0.70 until 2026-05-08; F2 on Pichonniere
-- measures 76% from borrowed E+W fences and was being incorrectly skipped, leaving N+S sides open for cows to
-- escape)
ToPastureAndBack_RL.FENCE_DETECT_COVERAGE_THRESHOLD = 0.95
ToPastureAndBack_RL.FENCE_RAYCAST_SPACING = 5        -- meters, spacing between raycast sample points along a contour edge
ToPastureAndBack_RL.FENCE_RAYCAST_MAX_DIST = 12      -- meters, max perpendicular distance for raycast probe (contour is ~8m inside field boundary)
ToPastureAndBack_RL.FENCE_RAYCAST_HEIGHT = 1.0       -- meters above terrain, ray origin height (fence post height)
ToPastureAndBack_RL.FENCE_RAYCAST_HIT_RATIO = 0.5    -- fraction of sample points that must hit to consider edge covered
ToPastureAndBack_RL.fenceRaycastHit = false           -- temp state for synchronous raycast callback

-- Settings
ToPastureAndBack_RL.DEFAULT_RADIUS = 30       -- meters, default pasture radius
ToPastureAndBack_RL.DENSITY_CHECK_DELAY = 300 -- frames to wait before density map is reliable

-- Action messages toggle: 1 = On, 2 = Off
ToPastureAndBack_RL.ACTION_MSGS_OPTIONS = {true, false}
ToPastureAndBack_RL.ACTION_MSGS_KEYS = {"tpab_settings_action_msgs_on", "tpab_settings_action_msgs_off"}

-- Dusk reminder toggle: 1 = On, 2 = Off
ToPastureAndBack_RL.DUSK_REMINDER_OPTIONS = {true, false}
ToPastureAndBack_RL.DUSK_REMINDER_KEYS = {"tpab_settings_dusk_reminder_on", "tpab_settings_dusk_reminder_off"}

-- MESSAGE STANDARD (2026-10-11): the same choices and values as every Kijbev mod (TT, UBW, LPR,
-- MCA). Sizes are multiplied by the game's HUD scale at draw time; colors are the shared Kijbev
-- palette (red is reserved for warnings); the background plate values are MCA's label plates.
-- MESSAGE SIZES = THE GAME'S OWN (2026-10-17): Small is the base game's warning text, 16 px at 1080 lines
-- (WarningDisplay.lua 56, scalePixelToScreenHeight(16)), the same size as TT's weather panel text; Medium and
-- Large keep the ratios 1.22 and 1.56. Rendered as getCorrectTextSize(size x HUD scale) like the game's.
ToPastureAndBack_RL.MSG_SIZE_OPTIONS = { 16 / 1080, 16 / 1080 * 1.22, 16 / 1080 * 1.56 }
ToPastureAndBack_RL.MSG_SIZE_KEYS = {"tpab_settings_msg_size_small", "tpab_settings_msg_size_medium", "tpab_settings_msg_size_large"}

ToPastureAndBack_RL.MSG_COLOR_IDS = {"white", "yellow", "orange", "green", "cyan", "blue", "purple", "pink"}
ToPastureAndBack_RL.MSG_COLOR_VALUES = {
    {1.000, 1.000, 1.000, 1},  -- white (default)
    {1.000, 0.870, 0.200, 1},  -- yellow
    {1.000, 0.600, 0.150, 1},  -- orange
    {0.400, 0.900, 0.350, 1},  -- green
    {0.360, 0.750, 1.000, 1},  -- cyan
    {0.350, 0.550, 1.000, 1},  -- blue
    {0.720, 0.500, 1.000, 1},  -- purple
    {1.000, 0.520, 0.800, 1},  -- pink
}
ToPastureAndBack_RL.MSG_COLOR_KEYS = {"tpab_settings_msg_color_white", "tpab_settings_msg_color_yellow", "tpab_settings_msg_color_orange",
    "tpab_settings_msg_color_green", "tpab_settings_msg_color_cyan", "tpab_settings_msg_color_blue",
    "tpab_settings_msg_color_purple", "tpab_settings_msg_color_pink"}

-- Message position presets (Y coordinate in normalized screen space, 0=bottom 1=top)
ToPastureAndBack_RL.MSG_POSITION_IDS = {"lower", "middle", "top"}
ToPastureAndBack_RL.MSG_POSITION_OPTIONS = {0.30, 0.58, 0.92}
ToPastureAndBack_RL.MSG_POSITION_KEYS = {"tpab_settings_msg_position_lower", "tpab_settings_msg_position_middle", "tpab_settings_msg_position_top"}

-- Background plate behind the messages; index 1 is off.
ToPastureAndBack_RL.MSG_BG_IDS = {"off", "dark", "opaque", "rose", "purple", "blue", "teal"}
ToPastureAndBack_RL.MSG_BG_VALUES = {
    false,
    {0.00, 0.00, 0.00, 0.55},
    {0.00, 0.00, 0.00, 1.00},
    {0.55, 0.07, 0.30, 0.82},
    {0.33, 0.10, 0.52, 0.82},
    {0.10, 0.18, 0.50, 0.82},
    {0.05, 0.34, 0.34, 0.82},
}
ToPastureAndBack_RL.MSG_BG_KEYS = {"tpab_settings_msg_bg_off", "tpab_settings_msg_bg_dark", "tpab_settings_msg_bg_opaque",
    "tpab_settings_msg_bg_rose", "tpab_settings_msg_bg_purple", "tpab_settings_msg_bg_blue", "tpab_settings_msg_bg_teal"}

-- Warning style for refusals: our message style, or the game's own blinking warning.
ToPastureAndBack_RL.WARN_STYLE_IDS = {"same", "game"}
ToPastureAndBack_RL.WARN_STYLE_KEYS = {"tpab_settings_warn_style_same", "tpab_settings_warn_style_game"}

-- Settings saved by v1.0.0.0 stored list INDICES. The old color list was orange, red, white, yellow,
-- green and the old positions middle, top; these map them to the new ids (red becomes orange).
ToPastureAndBack_RL.MSG_COLOR_LEGACY = {"orange", "orange", "white", "yellow", "green"}
ToPastureAndBack_RL.MSG_POSITION_LEGACY = {"middle", "top"}

-- Reading time for a message (the Kijbev rule: 67 ms per character, floor and cap).
function ToPastureAndBack_RL.readDurationMs(text, minMs)
    local n = type(text) == "string" and #text or 0
    return math.min(8000, math.max(minMs or 2500, n * 67))
end

-- Curfew recall toggle: 1 = Off, 2 = On (recalls all animals at 10 PM game time)
ToPastureAndBack_RL.CURFEW_HOUR = 22  -- 10 PM game time
ToPastureAndBack_RL.CURFEW_OPTIONS = {false, true}
ToPastureAndBack_RL.CURFEW_KEYS = {"tpab_settings_curfew_off", "tpab_settings_curfew_on"}

-- Confirm before recalling (2026-10-13: "destructive, like UBW's RCtrl+U"): 1 = Off, 2 = On.
-- On by default. The first recall press says what would be recalled; a second press inside
-- RECALL_CONFIRM_MS recalls.
ToPastureAndBack_RL.CONFIRM_RECALL_OPTIONS = {false, true}
ToPastureAndBack_RL.CONFIRM_RECALL_KEYS = {"tpab_settings_confirm_off", "tpab_settings_confirm_on"}
ToPastureAndBack_RL.RECALL_CONFIRM_MS = 5000

-- POULTRY LIMIT (2026-10-20, docs/TPAB_RL_PoultryCap_Blueprint.md): how many birds a coop shows, on top of
-- Realistic Livestock's one visible-animals slider. "same" leaves RL's number; a number only LOWERS it for coops.
-- Client-local, like RL's own slider. Words and values from Livestock Visibility.
ToPastureAndBack_RL.POULTRY_CAP_IDS = { "same", "25", "50", "100", "200", "500" }
ToPastureAndBack_RL.POULTRY_WORDS = { "CHICKEN", "HEN", "DUCK", "GOOSE", "GEESE", "TURKEY", "QUAIL", "POULTRY", "FOWL" }
ToPastureAndBack_RL.POULTRY_SKIP = { DUCKWILD = true }   -- wild ducks are not a coop (LV leaves them alone too)

-- Show fences toggle: 1 = On, 2 = Off
ToPastureAndBack_RL.SHOW_FENCES_OPTIONS = {true, false}
ToPastureAndBack_RL.SHOW_FENCES_KEYS = {"tpab_settings_fences_on", "tpab_settings_fences_off"}

ToPastureAndBack_RL.settings = {
    msgSizeIndex = 1,     -- default: Small (index into MSG_SIZE_OPTIONS)
    msgColorIndex = 1,    -- default: White (index into MSG_COLOR_VALUES)
    msgPositionIndex = 2, -- default: Middle (index into MSG_POSITION_OPTIONS)
    msgBackgroundIndex = 1, -- default: Off (index into MSG_BG_IDS), so the update does not change the look
    warnStyleIndex = 1,     -- default: Same as messages (index into WARN_STYLE_IDS)
    actionMessagesIndex = 1,  -- default: On (index into ACTION_MSGS_OPTIONS)
    duskReminderIndex = 1,    -- default: On (index into DUSK_REMINDER_OPTIONS)
    curfewIndex = 2,      -- default: On (index into CURFEW_OPTIONS)
    confirmRecallIndex = 2, -- default: On (index into CONFIRM_RECALL_OPTIONS), 2026-10-13
    showFencesIndex = 1,  -- default: On (index into SHOW_FENCES_OPTIONS)
    poultryCapIndex = 1,  -- default: same as herd animals (index into POULTRY_CAP_IDS), so the update changes nothing
}

-- Multi-herd collection (2026-04-29): list of pending herds awaiting field destination.
-- All entries share the same class (GRAZER = cow/buffalo/horse/sheep/goat, FORAGER = pig).
-- Player presses RCtrl+J at multiple barns to queue, then RCtrl+G at a field to send all at once.
ToPastureAndBack_RL.pendingGrazings = {}  -- list of { barnData, barnName, animalCount, animalType, animalAge, youngKept, rlAnimals }
ToPastureAndBack_RL.pendingClass = nil    -- "GRAZER" or "FORAGER"; locked when first entry added; cleared when list empties
-- cert 2026-07-07 symptom A (M1): farmlandIds where THIS peer dropped a herd during
-- the current pasture run (set of [farmlandId]=true). Covers the MP round-trip race
-- where our own first drop's session has not yet arrived back when the second drop
-- on the same farmland is confirmed. Cleared when the pocket empties (end of run)
-- and in deleteMap.
ToPastureAndBack_RL.recentDropFarmlands = {}

function ToPastureAndBack_RL.getPendingClass(animalType)
    if animalType == "PIG" then return "FORAGER" end
    return "GRAZER"
end

function ToPastureAndBack_RL.hasPendingGrazings()
    return ToPastureAndBack_RL.pendingGrazings ~= nil and #ToPastureAndBack_RL.pendingGrazings > 0
end

function ToPastureAndBack_RL.clearPendingGrazings()
    -- 2026-05-11: broadcast unlock for each pending barn before clearing so
    -- other players can re-select. The lock was established when the player
    -- added the pending; cancel releases it.
    if ToPastureAndBack_RL.pendingGrazings ~= nil then
        for _, pending in ipairs(ToPastureAndBack_RL.pendingGrazings) do
            local placeable = pending.barnData and pending.barnData.placeable
            if placeable ~= nil then
                local bx, bz = ToPastureAndBack_RL.getBarnLockPos(placeable)
                if bx ~= nil then
                    local myName = ToPastureAndBack_RL.getLocalPlayerName()
                    ToPastureAndBack_RL.sendEvent(PendingBarnLockEvent.new(
                        bx, bz, pending.barnName or "", myName, false))
                end
            end
        end
    end
    ToPastureAndBack_RL.pendingGrazings = {}
    ToPastureAndBack_RL.pendingClass = nil
    ToPastureAndBack_RL.runWasMultiHerd = false
end

-- ============================================================================
-- MP barn-pending lock (2026-05-11)
-- Synced via PendingBarnLockEvent so the SECOND player's pickup is rejected
-- at the source. See TPAB main script doc for full design.
-- ============================================================================

ToPastureAndBack_RL.remotePendingLocks = {}

function ToPastureAndBack_RL.barnLockKey(x, z)
    return string.format("%.0f,%.0f", x, z)
end

function ToPastureAndBack_RL.getLocalPlayerName()
    -- FS25's per-user nickname lives on User objects in userManager, keyed by
    -- userId. Pattern lifted from Enterable.lua:1554-1568 (gameSource).
    -- g_localPlayer.userId is the local player's userId (EnterablePassenger.lua:791).
    if g_localPlayer ~= nil and g_localPlayer.userId ~= nil
            and g_currentMission ~= nil and g_currentMission.userManager ~= nil
            and g_currentMission.userManager.getUserByUserId ~= nil then
        local ok, user = ToPastureAndBack_RL.fcall(g_currentMission.userManager.getUserByUserId,
            g_currentMission.userManager, g_localPlayer.userId)
        if ok and user ~= nil and user.getNickname ~= nil then
            local okN, nick = ToPastureAndBack_RL.fcall(user.getNickname, user)
            if okN and type(nick) == "string" and nick ~= "" then
                return nick
            end
        end
    end
    -- Legacy fallbacks
    if g_currentMission ~= nil and g_currentMission.player ~= nil
            and g_currentMission.player.userName ~= nil
            and g_currentMission.player.userName ~= "" then
        return g_currentMission.player.userName
    end
    if g_localPlayer ~= nil and g_localPlayer.userName ~= nil
            and g_localPlayer.userName ~= "" then
        return g_localPlayer.userName
    end
    return "another player"
end

function ToPastureAndBack_RL.getBarnWorldPos(placeable)
    if placeable == nil then return nil, nil end
    local spec = placeable.spec_husbandryAnimals
    if spec == nil or spec.clusterHusbandry == nil or spec.clusterHusbandry.navigationNode == nil then
        return nil, nil
    end
    local node = spec.clusterHusbandry.navigationNode
    local okE, exists = ToPastureAndBack_RL.fcallNode(entityExists, node)
    if okE and exists then
        local ok, x, _, z = ToPastureAndBack_RL.fcallNode(getWorldTranslation, node)
        if ok and x ~= nil then
            return x, z
        end
    end
    return nil, nil
end

--- Barn position for the pending-LOCK key: same source as the SendToPastureEvent
-- barnWorldX/Z (getBarnCachePos on the cache entry) so apply and auto-clear compute the
-- same key. getBarnWorldPos (nav-node only) vs getBarnCachePos leaked a stale lock on a
-- freshly placed barn and stranded a relocated herd (Riverbend 197-cow loss, 2026-07-01).
function ToPastureAndBack_RL.getBarnLockPos(placeable)
    if placeable == nil then return nil, nil end
    if ToPastureAndBack_RL.barnCache ~= nil then
        for _, list in pairs(ToPastureAndBack_RL.barnCache) do
            for _, entry in ipairs(list) do
                if entry.placeable == placeable then
                    local x, z = ToPastureAndBack_RL.getBarnCachePos(entry)
                    if x ~= nil then return x, z end
                end
            end
        end
    end
    return ToPastureAndBack_RL.getBarnWorldPos(placeable)
end

function ToPastureAndBack_RL.isBarnLockedByOther(placeable)
    local bx, bz = ToPastureAndBack_RL.getBarnLockPos(placeable)
    if bx == nil then return false, nil end
    local key = ToPastureAndBack_RL.barnLockKey(bx, bz)
    local entry = ToPastureAndBack_RL.remotePendingLocks[key]
    if entry == nil then return false, nil end
    -- 2026-05-11 v2: name-based identity unreliable in FS25 MP (both peers
    -- can resolve userName to nil and fall back to "Player", making remote
    -- locks look like own locks). Instead, check whether the barn is in our
    -- LOCAL pending list; if yes, the lock entry was generated by our own
    -- broadcast and represents our own pending. If not, it's another player.
    if ToPastureAndBack_RL.pendingGrazings ~= nil then
        for _, pe in ipairs(ToPastureAndBack_RL.pendingGrazings) do
            if pe.barnData and pe.barnData.placeable == placeable then
                return false, nil  -- our own lock
            end
        end
    end
    return true, entry
end

function ToPastureAndBack_RL.applyPendingBarnLock(x, z, barnName, playerName, isLock, fieldOrigin)
    local key = ToPastureAndBack_RL.barnLockKey(x, z)
    if isLock then
        ToPastureAndBack_RL.remotePendingLocks[key] = {
            playerName = playerName,
            barnName = barnName,
            x = x,
            z = z,
            fieldOrigin = fieldOrigin,  -- nil for barn pickups; set for field relocates (disconnect re-deploy)
        }
        if ToPastureAndBack_RL.DEBUG then
            dbgLog("TPAB-RL: Pending lock APPLIED at %s for barn %s by %s", key, barnName, playerName)
        end
    else
        ToPastureAndBack_RL.remotePendingLocks[key] = nil
        if ToPastureAndBack_RL.DEBUG then
            dbgLog("TPAB-RL: Pending lock RELEASED at %s for barn %s by %s", key, barnName, playerName)
        end
    end

    -- In-pocket visual sync: hide/show the barn herd on THIS peer too.
    ToPastureAndBack_RL.applyBarnPocketVisual(x, z, isLock)
end

--- cert 2026-07-07 (M6): nearest cached barn placeable (any type) to a world
-- position, scanning the same barn cache findBarnDataByPosition uses. Returns
-- nil when no cached barn is within maxDist. Used to protect an adjacent
-- barn's live pending lock from the 15m proximity auto-clear.
function ToPastureAndBack_RL.findNearestCachedBarnPlaceable(x, z, maxDist)
    if ToPastureAndBack_RL.barnCache == nil then return nil, nil end
    local best, bestDist = nil, nil
    for _, candidates in pairs(ToPastureAndBack_RL.barnCache) do
        for _, barn in ipairs(candidates) do
            if barn.placeable ~= nil then
                local bx, bz = ToPastureAndBack_RL.getBarnCachePos(barn)
                if bx ~= nil then
                    local dx = bx - x
                    local dz = bz - z
                    local d = math.sqrt(dx * dx + dz * dz)
                    if bestDist == nil or d < bestDist then
                        best, bestDist = barn.placeable, d
                    end
                end
            end
        end
    end
    if best ~= nil and maxDist ~= nil and bestDist > maxDist then
        return nil, nil
    end
    return best, bestDist
end

--- Resolve a cached barn placeable from a lock (x,z), type-agnostic
-- (scans the whole barn cache). Used by the in-pocket visual sync.
function ToPastureAndBack_RL.findCachedBarnPlaceableByPos(x, z)
    if ToPastureAndBack_RL.barnCache == nil then return nil end
    local wantKey = ToPastureAndBack_RL.barnLockKey(x, z)
    for _, candidates in pairs(ToPastureAndBack_RL.barnCache) do
        for _, barn in ipairs(candidates) do
            if barn.placeable ~= nil then
                local bx, bz = ToPastureAndBack_RL.getBarnLockPos(barn.placeable)
                if bx ~= nil and ToPastureAndBack_RL.barnLockKey(bx, bz) == wantKey then
                    return barn.placeable
                end
            end
        end
    end
    return nil
end

--- In-pocket visual sync (runs on every peer via applyPendingBarnLock):
-- hide a barn's herd when a pending pickup is locked (RCtrl+J / T), show
-- it again on unlock (RCtrl+N cancel). A co-op partner sees the
-- herd vanish the instant it is claimed. Idempotent; no-op if uncached.
function ToPastureAndBack_RL.applyBarnPocketVisual(x, z, isLock)
    local placeable = ToPastureAndBack_RL.findCachedBarnPlaceableByPos(x, z)
    if placeable == nil then return end
    if isLock then
        -- Suppress only grazing-eligible adults (species minimum age) so young
        -- animals stay visible in the barn, matching what is sent.
        local _all = ToPastureAndBack_RL.getRLAnimalsFromBarn(placeable)
        local _minAge = ToPastureAndBack_RL.getMinGrazingAgeForPlaceable(placeable)
        local rlAnimals = {}
        for _, animal in ipairs(_all) do
            if animal:getAge() >= _minAge then table.insert(rlAnimals, animal) end
        end
        ToPastureAndBack_RL.suppressBarnVisuals(placeable, rlAnimals)
    else
        ToPastureAndBack_RL.restoreBarnVisuals(placeable)
    end
end

-- ============================================================================
-- Disconnect cleanup (2026-06-23): a player who leaves mid-pocket would otherwise
-- leave a permanent ghost lock on the barn (nobody can pick it up) plus the barn
-- visually suppressed. On the SERVER, whenever a user is removed we re-validate
-- every pending barn lock against the still-connected players and release any whose
-- owner is gone. Releasing restores the barn, and the pocketed herd (which never
-- left it) reappears, via the normal unlock path. MessageType.USER_REMOVED triggers it.
-- ============================================================================

function ToPastureAndBack_RL.collectConnectedNicknames()
    local set = {}
    local um = g_currentMission ~= nil and g_currentMission.userManager or nil
    if um == nil then return set end
    local okU, users = ToPastureAndBack_RL.fcall(function() return um.getUsers ~= nil and um:getUsers() or nil end)
    if okU and type(users) == "table" then
        for _, u in pairs(users) do
            if type(u) == "table" and u.getNickname ~= nil then
                local okN, nick = ToPastureAndBack_RL.fcall(u.getNickname, u)
                if okN and type(nick) == "string" and nick ~= "" then set[nick] = true end
            end
        end
    end
    if next(set) ~= nil then return set end
    local okC, n = ToPastureAndBack_RL.fcall(function() return um.getNumberOfUsers ~= nil and um:getNumberOfUsers() or nil end)
    if okC and type(n) == "number" then
        for i = 0, n - 1 do
            local okI, u = ToPastureAndBack_RL.fcall(function() return um:getUserByIndex(i) end)
            if okI and type(u) == "table" and u.getNickname ~= nil then
                local okN, nick = ToPastureAndBack_RL.fcall(u.getNickname, u)
                if okN and type(nick) == "string" and nick ~= "" then set[nick] = true end
            end
        end
    end
    return set
end

-- Re-deploy a disconnected player's field-relocate pocket back to the pasture it was
-- grabbed from. Rebuilds the canonical SendToPastureEvent from the lock's stashed
-- fieldOrigin + the barn position. The session creation auto-clears the barn lock.
-- RL re-fetches the actual Animal objects from the barn, so the same individuals respawn.
function ToPastureAndBack_RL.redeployLockToFieldOrigin(lock)
    local o = lock.fieldOrigin
    if o == nil or o.x == nil or o.animalType == nil then return false end
    local newPointId = ToPastureAndBack_RL.nextPastureId
    ToPastureAndBack_RL.nextPastureId = newPointId + 1
    local sessionId = string.format("%s_%d_%d", o.animalType, newPointId, math.random(10000, 99999))
    local eventData = {
        barnWorldX = lock.x,
        barnWorldZ = lock.z,
        barnName = lock.barnName,
        destX = o.x,
        destZ = o.z,
        destY = o.y,
        fieldContour = o.fieldContour,
        fieldRadius = o.radius,
        animalType = o.animalType,
        animalCount = o.animalCount,
        animalAge = o.animalAge or 36,
        durationHours = 0,
        farmlandId = o.farmlandId or 0,
        sessionId = sessionId,
        pasturePointId = newPointId,
        pasturePointName = string.format("Pasture %d", newPointId),
        isPastureDestination = o.isPastureDestination or false,
        pastureDestName = o.pastureDestName,
        suppressYoungKept = true,
        batchInfo = { size = 1, index = 1, isMixed = false, isLast = true },
    }
    dbgLog("TPAB-RL: Disconnect: re-deploying %s field pocket from %s back to (%.1f,%.1f) point %d",
        tostring(o.animalType), tostring(lock.barnName), o.x, o.z, newPointId)
    ToPastureAndBack_RL.sendEvent(SendToPastureEvent.new(eventData))
    return true
end

function ToPastureAndBack_RL.onUserRemovedCleanup()
    if g_currentMission == nil or g_currentMission.getIsServer == nil
            or not g_currentMission:getIsServer() then
        return
    end
    if ToPastureAndBack_RL.remotePendingLocks == nil then return end

    local connected = ToPastureAndBack_RL.collectConnectedNicknames()
    -- Guard: empty set means we could NOT read the user list (the host is always
    -- present), not that nobody is connected. Releasing on empty would nuke valid locks.
    if next(connected) == nil then
        dbgLog("TPAB-RL: Disconnect cleanup: could not enumerate users, skipping")
        return
    end

    -- Collect first; the unlock event mutates remotePendingLocks via applyPendingBarnLock.
    local stuck = {}
    for _, lock in pairs(ToPastureAndBack_RL.remotePendingLocks) do
        if type(lock) == "table" and lock.playerName ~= nil and not connected[lock.playerName] then
            stuck[#stuck + 1] = lock
        end
    end
    if #stuck == 0 then return end

    local myName = ToPastureAndBack_RL.getLocalPlayerName()
    for _, lock in ipairs(stuck) do
        if lock.fieldOrigin ~= nil and ToPastureAndBack_RL.redeployLockToFieldOrigin(lock) then
            -- Field-relocate pocket: herd returns to the field it was grabbed from.
            -- The re-deploy's session creation auto-clears this barn's lock.
        else
            -- Barn pickup (or no usable field origin): restore the herd to the barn.
            dbgLog("TPAB-RL: Disconnect cleanup: releasing stuck lock on %s (owner %s gone), restoring barn",
                tostring(lock.barnName), tostring(lock.playerName))
            ToPastureAndBack_RL.sendEvent(PendingBarnLockEvent.new(
                lock.x, lock.z, lock.barnName or "", myName, false))
        end
    end
end

-- Barn visual suppression: tracks which barns have had their visuals hidden
-- Key = barn placeable, value = { hidden=true, originalVisualCount=number }
ToPastureAndBack_RL.suppressedBarns = {}

-- Pending session reconstructions from save file (processed after barn scan)
ToPastureAndBack_RL.pendingReconstructions = nil

-- Queued events received before barn cache is ready (client-side only).
-- When a client joins and receives SendToPastureEvent broadcasts from the server
-- before the client's own barn scan has completed (~frame 350), those events
-- are queued here and replayed once barnCacheReady becomes true.
ToPastureAndBack_RL.pendingEventQueue = {}

-- HUD lookup: maps pasture husbandryId -> { [animalId] = RL Animal object }
-- Populated in addAnimalsToHusbandries, cleared in cleanupSession.
-- Used by our PlayerHUDUpdater hook to show RL data when hovering over pasture animals.
ToPastureAndBack_RL.pastureAnimalLookup = {}

-- State tracking
ToPastureAndBack_RL.frameCount = 0
ToPastureAndBack_RL.densityReady = false

-- Dusk reminder: fires once per game day at hour 18 when auto-recall is Off and herds are out
ToPastureAndBack_RL.DUSK_REMINDER_HOUR = 18  -- 6 PM game time
ToPastureAndBack_RL.lastDuskReminderDay = -1
-- Curfew recall: fires once per game day at CURFEW_HOUR when enabled.
-- lastCurfewDay tracks the actual recall (server-only); lastCurfewMessageDay
-- tracks the notification message (fires on every peer independently so
-- both host and clients see it).
ToPastureAndBack_RL.lastCurfewDay = -1
ToPastureAndBack_RL.lastCurfewMessageDay = -1

-- Debug log helper
dbgLog = function(fmt, ...)
    if ToPastureAndBack_RL.DEBUG then
        Logging.info(fmt, ...)
    end
end
ToPastureAndBack_RL.dbgLog = dbgLog  -- expose the DEBUG-gated logger to event scripts


-- Custom on-screen message queue (rendered via draw callback, center screen, red, non-blinking)
ToPastureAndBack_RL._messageQueue = {}

--- MESSAGES OF A FARM GO TO THAT FARM'S PLAYERS ONLY (2026-10-10/11). Herds sent out, recalled,
--- returned at curfew or by the timer are farm-wide decisions, so every player of the barn's farm sees
--- them, and no player of another farm does. A message with no farm attached is the local player's own
--- (a refusal, a confirmation of a key they pressed) and is always shown. Single player: always true.
function ToPastureAndBack_RL.isLocalFarm(farmId)
    if farmId == nil then return true end
    local m = g_currentMission
    if m == nil or m.missionDynamicInfo == nil or m.missionDynamicInfo.isMultiplayer ~= true then return true end
    if type(m.getFarmId) ~= "function" then return true end
    local mine = m:getFarmId()
    if mine == nil then return true end
    return mine == farmId
end

function ToPastureAndBack_RL.farmOfPlaceable(placeable)
    if placeable ~= nil and type(placeable.getOwnerFarmId) == "function" then
        return placeable:getOwnerFarmId()
    end
    return nil
end

function ToPastureAndBack_RL.farmOfSession(session)
    if session == nil then return nil end
    return ToPastureAndBack_RL.farmOfPlaceable(session.barnPlaceable)
end

--- A PLAYER ACTS ONLY ON HIS OWN FARM'S HERDS (2026-10-11). Recall, call back and pick-up choose
--- among the sessions of the local player's farm; another farm's herds are never touched.
function ToPastureAndBack_RL.isOwnSession(session)
    return ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfSession(session))
end

--- The farm of the player behind a network connection (the lookup the base game's WashingStationEvent uses).
function ToPastureAndBack_RL.farmIdForConnection(connection)
    local m = g_currentMission
    if connection == nil or m == nil or m.userManager == nil or g_farmManager == nil then return nil end
    local userId = m.userManager:getUserIdByConnection(connection)
    if userId == nil then return nil end
    local farm = g_farmManager:getFarmByUserId(userId)
    return farm ~= nil and farm.farmId or nil
end

--- SERVER SIDE of the own-farm rule: a client's recall may only touch its own farm's herds, whatever
--- the client's view was when it sent. Returns the id list to execute ("" when none), or the input
--- unchanged when the sender's farm cannot be read (never stricter than before then).
function ToPastureAndBack_RL.filterIdsForConnection(sessionIds, connection)
    local farmId = ToPastureAndBack_RL.farmIdForConnection(connection)
    if farmId == nil then return sessionIds end
    local want = nil
    if sessionIds ~= "ALL" then
        want = {}
        for id in string.gmatch(sessionIds or "", "[^,]+") do want[id] = true end
    end
    local out, all = {}, true
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions or {}) do
        if want == nil or want[session.id] then
            if ToPastureAndBack_RL.farmOfSession(session) == farmId then
                table.insert(out, session.id)
            else
                all = false
            end
        end
    end
    if sessionIds == "ALL" and all then return "ALL" end
    return table.concat(out, ",")
end

--- The local player's sessions, plus whether that is every session (then "ALL" means the same).
function ToPastureAndBack_RL.ownSessionIds()
    local ids, all = {}, true
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions or {}) do
        if ToPastureAndBack_RL.isOwnSession(session) then
            table.insert(ids, session.id)
        else
            all = false
        end
    end
    return ids, all
end

--- The game's HUD scale (Settings > Display > HUD size), so message sizes follow it like every
--- Kijbev mod's messages do.
function ToPastureAndBack_RL.hudScale()
    local gs = g_gameSettings
    if gs == nil or type(gs.getValue) ~= "function" then return 1 end
    local key = (GameSettings ~= nil and GameSettings.SETTING ~= nil and GameSettings.SETTING.UI_SCALE) or "uiScale"
    local v = gs:getValue(key)
    if type(v) ~= "number" or v ~= v then return 1 end
    if v < 0.5 then v = 0.5 elseif v > 2 then v = 2 end
    return v
end

--- The plain-color overlay behind messages, created once (the slice MCA uses for its label plates).
function ToPastureAndBack_RL.getMessagePlate()
    if ToPastureAndBack_RL._msgPlate == nil and ToPastureAndBack_RL._msgPlateFailed ~= true then
        if g_overlayManager ~= nil and g_overlayManager.createOverlay ~= nil and g_plainColorSliceId ~= nil then
            ToPastureAndBack_RL._msgPlate = g_overlayManager:createOverlay(g_plainColorSliceId, 0, 0, 0.1, 0.02)
        end
        if ToPastureAndBack_RL._msgPlate == nil then
            ToPastureAndBack_RL._msgPlateFailed = true
            dbgLog("TPAB-RL: message background unavailable (no plain color slice), messages draw without it")
        end
    end
    return ToPastureAndBack_RL._msgPlate
end

--- v3 STACK (2026-10-14): TPAB's messages stack among themselves like every Kijbev mod's.
--- A message with the same TOPIC replaces the older one (default topic: the text), at most three
--- at once, each with its own reading time (KijbevMessages.push). Without the module: newest only.
function ToPastureAndBack_RL.pushMessage(entry)
    local KM = KijbevMessages
    if KM ~= nil and KM.push ~= nil then
        KM.push(ToPastureAndBack_RL._messageQueue, entry)
    else
        ToPastureAndBack_RL._messageQueue = { entry }
    end
end

--- A refusal ("no can do") from the local player's own action. Follows the warning style: our
--- message style, or the game's own blinking warning (which then owns look and place).
function ToPastureAndBack_RL.showRefusal(text, duration)
    if type(text) == "string" then text = text:gsub("\\n", "\n") end
    local style = ToPastureAndBack_RL.WARN_STYLE_IDS[ToPastureAndBack_RL.settings.warnStyleIndex] or "same"
    dbgLog("TPAB-RL: refusal '%s' (style=%s)", tostring(text), style)
    if style == "game" then
        local m = g_currentMission
        if m ~= nil and type(m.showBlinkingWarning) == "function" then
            m:showBlinkingWarning(text, ToPastureAndBack_RL.readDurationMs(text, 2000))
            return
        end
        if not ToPastureAndBack_RL._warnedNoBlink then
            ToPastureAndBack_RL._warnedNoBlink = true
            Logging.warning("TPAB-RL: the game's warning display is unavailable, refusals use the message style.")
        end
    end
    ToPastureAndBack_RL.showModInitiatedMessage(text, duration)
end

--- Show a non-blinking notification centered on screen.
-- Respects the player's Show Messages setting; does nothing when messages are off.
-- @param text string The message to display
-- @param duration number|nil Duration in ms (defaults to the reading time of the text)
function ToPastureAndBack_RL.showMessage(text, duration, farmId)
    if not ToPastureAndBack_RL.isLocalFarm(farmId) then
        dbgLog("TPAB-RL: message for farm %s withheld on this farm", tostring(farmId))
        return
    end
    -- Respect action messages setting
    if not ToPastureAndBack_RL.ACTION_MSGS_OPTIONS[ToPastureAndBack_RL.settings.actionMessagesIndex] then
        return
    end
    duration = duration or ToPastureAndBack_RL.readDurationMs(text, 2500)
    ToPastureAndBack_RL.pushMessage({ text = text, remaining = duration, posted = g_time or 0 })
end

--- Show a mod-initiated message that always displays, bypassing the action messages toggle.
-- Used for curfew firing, recall completion, and errors.
-- @param text string The message to display
-- @param duration number|nil Duration in ms (defaults to the reading time of the text)
function ToPastureAndBack_RL.showModInitiatedMessage(text, duration, farmId)
    if not ToPastureAndBack_RL.isLocalFarm(farmId) then
        dbgLog("TPAB-RL: message for farm %s withheld on this farm", tostring(farmId))
        return
    end
    if type(text) == "string" then text = text:gsub("\\n", "\n") end  -- let locale line-break sequences render as real newlines
    duration = duration or ToPastureAndBack_RL.readDurationMs(text, 2500)
    ToPastureAndBack_RL.pushMessage({ text = text, remaining = duration, posted = g_time or 0 })
end

--- Human-readable text for the CURRENT binding of one of our actions,
-- cert 2026-07-07 (K4). Queried at message-build time, never cached, so a
-- mid-session rebind is picked up immediately. Falls back to the localized
-- action label when the action is bound to a gamepad (.keys empty) or the
-- display manager is unavailable, and to the raw action name as a last resort.
-- @param actionName string action name, e.g. "TPABRL_CONFIRM_PASTURE"
-- @return string current binding, e.g. "Right Ctrl + G"
function ToPastureAndBack_RL.getBindingText(actionName)
    if g_inputDisplayManager ~= nil then
        local ok, help = ToPastureAndBack_RL.fcall(g_inputDisplayManager.getControllerSymbolOverlays, g_inputDisplayManager, actionName, nil, "", false)
        if ok and help ~= nil and help.keys ~= nil and #help.keys > 0 then
            return table.concat(help.keys, " + ")
        end
    end
    local ok2, label = ToPastureAndBack_RL.fcall(g_i18n.getText, g_i18n, "input_" .. actionName)
    if ok2 and label ~= nil and label ~= "" then return label end
    return actionName
end

--- Show a dusk reminder message, gated by the dusk reminder setting.
-- @param text string The message to display
-- @param duration number|nil Duration in ms (defaults to the reading time of the text)
function ToPastureAndBack_RL.showDuskReminder(text, duration, farmId)
    if not ToPastureAndBack_RL.isLocalFarm(farmId) then return end
    if not ToPastureAndBack_RL.DUSK_REMINDER_OPTIONS[ToPastureAndBack_RL.settings.duskReminderIndex] then
        return
    end
    duration = duration or ToPastureAndBack_RL.readDurationMs(text, 2500)
    ToPastureAndBack_RL.pushMessage({ text = text, remaining = duration, posted = g_time or 0 })
end

--- Format a game-time hour for display, locale-aware.
-- English locales render 12-hour with AM/PM (e.g. "10 PM"). French uses
-- "22h" notation. All other locales use 24-hour "22:00" form.
-- @param hour24 number Hour in 24-hour form (0-23)
-- @return string Formatted time string
function ToPastureAndBack_RL.formatGameTime(hour24)
    local lang = (g_languageShort or "en")
    if type(lang) == "string" then lang = lang:lower() end
    if lang == "fr" then
        return string.format("%dh", hour24)
    elseif lang == "en" then
        if hour24 == 0 then return "12 AM" end
        if hour24 < 12 then return string.format("%d AM", hour24) end
        if hour24 == 12 then return "12 PM" end
        return string.format("%d PM", hour24 - 12)
    end
    return string.format("%02d:00", hour24)
end

--- Draw callback, called every frame by the engine via addModEventListener.
-- Renders any active TPAB messages centered on screen using player-chosen color and size.
function ToPastureAndBack_RL:draw()
    -- The shared help panel draws itself only when this mod owns it and it is open.
    if KijbevHelp ~= nil and KijbevHelp.draw ~= nil then
        KijbevHelp.draw("TPABRL")
    end
    if KijbevHelp ~= nil and KijbevHelp.isOpen == true then return end   -- help panel open: screen is the panel's (v21)
    if #ToPastureAndBack_RL._messageQueue == 0 then return end

    -- Look up player settings for color and size
    local colorIdx = ToPastureAndBack_RL.settings.msgColorIndex or 1
    local color = ToPastureAndBack_RL.MSG_COLOR_VALUES[colorIdx] or ToPastureAndBack_RL.MSG_COLOR_VALUES[1]
    local sizeIdx = ToPastureAndBack_RL.settings.msgSizeIndex or 1
    local sizeVal = ToPastureAndBack_RL.MSG_SIZE_OPTIONS[sizeIdx] or ToPastureAndBack_RL.MSG_SIZE_OPTIONS[1]

    -- Text style: centered, bold, player-chosen color, slightly above screen center
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    setTextColor(color[1], color[2], color[3], color[4])

    local fontSize = getCorrectTextSize(sizeVal * ToPastureAndBack_RL.hudScale())
    local posIdx = ToPastureAndBack_RL.settings.msgPositionIndex or 2
    local baseY = ToPastureAndBack_RL.MSG_POSITION_OPTIONS[posIdx] or 0.58

    -- v3 STACK: every message is its own block (tag TPABRL#<seq>) in the shared stack.
    -- Multi-line messages (containing \n) render each line separately with proper spacing.
    local queue = ToPastureAndBack_RL._messageQueue
    local KM = KijbevMessages
    local stacked = KM ~= nil and KM.place ~= nil and KM.extent ~= nil
    local anchorY = baseY
    -- newest first, so a message posted this frame is registered before the older ones are placed
    for qi = #queue, (stacked and 1 or #queue), -1 do
        local msg = queue[qi]
        local baseY = anchorY
        local msgText = msg.text
        if type(msg.textFn) == "function" then
            -- Live countdown (recall confirm): whole seconds left, never below 1 while shown.
            local secs = math.max(1, math.ceil((msg.remaining or 0) / 1000))
            local live = msg.textFn(secs)
            if type(live) == "string" then msgText = live:gsub("\\n", "\n") end
        end
        -- Standard 1.8 (2026-10-24): timed messages wrap at the game's warning measure (KijbevMessages.wrapLines).
        -- The game's warning display sets a global wrap width and never clears it (WarningDisplay.lua 86):
        -- clear it so renderText and getTextWidth do not wrap our lines a second time.
        if setTextWrapWidth ~= nil then setTextWrapWidth(0) end
        -- Hand-set breaks stay; the wrap width follows the font size (about 60 to 70 characters a line).
        local lines = (KM ~= nil and KM.wrapLines ~= nil) and KM.wrapLines(msgText, fontSize) or nil
        if lines == nil then
            -- Fallback without the shared module: the old wrap at 0.9 of the screen.
            local maxWidth = 0.9
            lines = {}
            for srcLine in string.gmatch(msgText .. "\n", "(.-)\n") do
                if srcLine ~= "" then
                    local cur = nil
                    for word in string.gmatch(srcLine, "%S+") do
                        local trial = (cur == nil) and word or (cur .. " " .. word)
                        if cur ~= nil and getTextWidth(fontSize, trial) > maxWidth then
                            table.insert(lines, cur)
                            cur = word
                        else
                            cur = trial
                        end
                    end
                    if cur ~= nil then table.insert(lines, cur) end
                end
            end
        end
        local lineSpacing = fontSize * 1.4
        -- SHARED MESSAGE STACK (2026-10-11): the newest message of any Kijbev mod takes the chosen spot
        -- and older ones move aside (lib/KijbevMessages.lua). Without the module, the old spot.
        if stacked and #lines > 0 then
            local above, below = KM.extent(fontSize, #lines, lineSpacing)
            local tag = (KM.blockTag ~= nil) and KM.blockTag("TPABRL", msg) or ("TPABRL#" .. tostring(msg.seq or 0))
            baseY = KM.place(tag, ToPastureAndBack_RL.MSG_POSITION_IDS[posIdx] or "middle", baseY, above, below,
                msg.stackAt or msg.posted or 0)
        end
        -- Optional background plate behind the whole block, measured with the bold state set above.
        local bg = ToPastureAndBack_RL.MSG_BG_VALUES[ToPastureAndBack_RL.settings.msgBackgroundIndex or 1]
        if bg and #lines > 0 then
            local plate = ToPastureAndBack_RL.getMessagePlate()
            if plate ~= nil then
                local w = 0
                for _, ln in ipairs(lines) do w = math.max(w, getTextWidth(fontSize, ln)) end
                w = w + fontSize * 0.8
                local h = (#lines - 1) * lineSpacing + fontSize * 1.35
                plate:setColor(bg[1], bg[2], bg[3], bg[4])
                plate:setDimension(w, h)
                plate:setPosition(0.5 - w * 0.5, baseY - (#lines - 1) * lineSpacing - fontSize * 0.28)
                plate:render()
                setTextColor(color[1], color[2], color[3], color[4])
            end
        end
        -- Anchor first line at baseY and grow downward. Earlier code centered the block
        -- around baseY which pushed the first line above the chosen Y position; with
        -- Top at 0.92 a 5-line block lost its top lines off the edge of the screen.
        for i, line in ipairs(lines) do
            renderText(0.5, baseY - (i - 1) * lineSpacing, fontSize, line)
        end
    end   -- one block per message

    -- Reset text state so we don't affect other HUD elements
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

--- Tick down message timers. Called from the existing update function.
function ToPastureAndBack_RL.updateMessages(dt)
    local queue = ToPastureAndBack_RL._messageQueue
    if KijbevMessages ~= nil and KijbevMessages.tick ~= nil then
        KijbevMessages.tick(queue, dt)      -- also frees each expired message's stack slot at once
        return
    end
    local i = 1
    while i <= #queue do
        queue[i].remaining = queue[i].remaining - dt
        if queue[i].remaining <= 0 then
            table.remove(queue, i)
        else
            i = i + 1
        end
    end
end


-- ============================================================================
-- PasturePoint data structure
-- ============================================================================

--- Create a new pasture point
-- @param id number Unique ID
-- @param x number World X coordinate
-- @param y number World Y coordinate (terrain height)
-- @param z number World Z coordinate
-- @param radius number Pasture radius in meters
-- @param name string Display name
-- @return table PasturePoint
function ToPastureAndBack_RL.createPasturePoint(id, x, y, z, radius, name)
    return {
        id = id,
        x = x,
        y = y,
        z = z,
        radius = radius or ToPastureAndBack_RL.DEFAULT_RADIUS,
        name = name or string.format("Pasture %d", id),
    }
end


-- ============================================================================
-- Field extent detection
-- ============================================================================

--- Get the farmland ID at a world position.
-- Uses g_farmlandManager to look up which farmland parcel a position belongs to.
-- Returns the farmland ID (1, 2, 3...) or 0/nil if not on any farmland.
-- This distinguishes adjacent fields that share the same ground type.
-- @param x number World X
-- @param z number World Z
-- @return number Farmland ID, or 0 if not on farmland or API unavailable
function ToPastureAndBack_RL.getFarmlandIdAtPosition(x, z)
    -- Try g_farmlandManager API (most likely FS25 approach)
    if g_farmlandManager ~= nil then
        -- Try getFarmlandIdAtWorldPosition (common FS API naming)
        if g_farmlandManager.getFarmlandIdAtWorldPosition ~= nil then
            local ok, id = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandIdAtWorldPosition, g_farmlandManager, x, z)
            if ok and id ~= nil then return id end
        end
        -- Try getOwnerIdAtWorldPosition (alternate naming)
        if g_farmlandManager.getOwnerIdAtWorldPosition ~= nil then
            local ok, id = ToPastureAndBack_RL.fcall(g_farmlandManager.getOwnerIdAtWorldPosition, g_farmlandManager, x, z)
            if ok and id ~= nil then return id end
        end
        -- Try getting farmland object then reading its id
        if g_farmlandManager.getFarmlandAtWorldPosition ~= nil then
            local ok, fl = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandAtWorldPosition, g_farmlandManager, x, z)
            if ok and fl ~= nil then
                if type(fl) == "table" and fl.id ~= nil then return fl.id end
                if type(fl) == "number" then return fl end
            end
        end
    end
    return 0
end

--- Check if the player owns the farmland at a world position.
-- Returns true if the farmland is owned by the player's farm, false otherwise.
-- Also returns the farmland ID and owner farm ID for messaging.
-- @param x number World X
-- @param z number World Z
-- @return boolean isOwned, number farmlandId, number ownerFarmId
function ToPastureAndBack_RL.isPlayerOwnedFarmland(x, z)
    local farmlandId = ToPastureAndBack_RL.getFarmlandIdAtPosition(x, z)
    if farmlandId == nil or farmlandId == 0 then
        return false, 0, 0
    end

    -- Get the player's farm ID
    local playerFarmId = nil
    if g_currentMission ~= nil then
        -- Try g_currentMission:getFarmId() (common FS25 API)
        if g_currentMission.getFarmId ~= nil then
            local ok, fid = ToPastureAndBack_RL.fcall(g_currentMission.getFarmId, g_currentMission)
            if ok and fid ~= nil then playerFarmId = fid end
        end
        -- Fallback: player.farmId
        if playerFarmId == nil and g_currentMission.player ~= nil then
            playerFarmId = g_currentMission.player.farmId
        end
    end

    if playerFarmId == nil then
        dbgLog("TPAB-RL: isPlayerOwnedFarmland: could not determine player farm ID")
        return true, farmlandId, 0  -- fail open if we can't check
    end

    -- Get the farmland's owner farm ID
    local ownerFarmId = nil

    if g_farmlandManager ~= nil then
        -- Method 1: getFarmlandById then check owner
        if g_farmlandManager.getFarmlandById ~= nil then
            local ok, farmland = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandById, g_farmlandManager, farmlandId)
            if ok and farmland ~= nil and type(farmland) == "table" then
                ownerFarmId = farmland.farmId or farmland.ownerId or farmland.ownerFarmId
            end
        end

        -- Method 2: getOwner or getFarmlandOwner
        if ownerFarmId == nil and g_farmlandManager.getFarmlandOwner ~= nil then
            local ok, owner = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandOwner, g_farmlandManager, farmlandId)
            if ok and owner ~= nil then ownerFarmId = owner end
        end

        -- Method 3: farmlands table lookup
        if ownerFarmId == nil and g_farmlandManager.farmlands ~= nil then
            local fl = g_farmlandManager.farmlands[farmlandId]
            if fl ~= nil and type(fl) == "table" then
                ownerFarmId = fl.farmId or fl.ownerId or fl.ownerFarmId
            end
        end

        -- Method 4: getFarmlandAtWorldPosition and read owner
        if ownerFarmId == nil and g_farmlandManager.getFarmlandAtWorldPosition ~= nil then
            local ok, fl = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandAtWorldPosition, g_farmlandManager, x, z)
            if ok and fl ~= nil and type(fl) == "table" then
                ownerFarmId = fl.farmId or fl.ownerId or fl.ownerFarmId
            end
        end
    end

    if ownerFarmId == nil then
        -- Could not determine owner, log it for diagnostics and fail open
        dbgLog("TPAB-RL: isPlayerOwnedFarmland: could not determine owner of farmland %d (playerFarm=%d)",
            farmlandId, playerFarmId)
        -- Dump farmland object keys for discovery
        if ToPastureAndBack_RL.DEBUG and g_farmlandManager ~= nil and g_farmlandManager.getFarmlandById ~= nil then
            local ok, fl = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandById, g_farmlandManager, farmlandId)
            if ok and fl ~= nil and type(fl) == "table" then
                local keys = {}
                for k, v in pairs(fl) do
                    local vt = type(v)
                    if vt == "number" or vt == "string" or vt == "boolean" then
                        table.insert(keys, string.format("%s=%s", tostring(k), tostring(v)))
                    else
                        table.insert(keys, string.format("%s=(%s)", tostring(k), vt))
                    end
                end
                table.sort(keys)
                dbgLog("TPAB-RL: Farmland %d keys: %s", farmlandId, table.concat(keys, ", "))
            end
        end
        return true, farmlandId, 0  -- fail open
    end

    local isOwned = (ownerFarmId == playerFarmId)
    dbgLog("TPAB-RL: Farmland %d: owner=%d, player=%d, owned=%s",
        farmlandId, ownerFarmId, playerFarmId, tostring(isOwned))
    return isOwned, farmlandId, ownerFarmId
end

--- One-time diagnostic: probe g_farmlandManager availability.
-- Called once at init to verify the farmland API is accessible.
function ToPastureAndBack_RL.probeFarmlandManager()
    if g_farmlandManager == nil then
        Logging.warning("TPAB-RL: g_farmlandManager is nil, farmland boundary detection unavailable")
        return
    end
    -- Quick check with player position to confirm API works
    local px, _, pz = ToPastureAndBack_RL.getPlayerPosition()
    if px ~= nil then
        local farmId = ToPastureAndBack_RL.getFarmlandIdAtPosition(px, pz)
        dbgLog("TPAB-RL: Farmland ID at player (%.1f, %.1f) = %s", px, pz, tostring(farmId))
    end
end

--- Scan outward from a position to find the field boundary and center.
-- Uses farmland ID to detect field boundaries between adjacent fields.
-- Falls back to ground type if farmland API is unavailable.
-- @param startX number World X (player position)
-- @param startZ number World Z (player position)
-- @return table {centerX, centerZ, avgRadius, minEdgeDist, farmlandId, contourPoints} or nil
function ToPastureAndBack_RL.scanFieldExtent(startX, startZ, skipGroundCheck)
    if not ToPastureAndBack_RL.densityReady then
        return nil
    end

    -- First check we're on a field at all (skip for pasture destinations where groundType=0)
    if not skipGroundCheck then
        local onField, _ = ToPastureAndBack_RL.isOnFieldGround(startX, startZ)
        if not onField then
            return nil
        end
    end

    -- Get the farmland ID at the starting position for boundary detection
    local startFarmlandId = ToPastureAndBack_RL.getFarmlandIdAtPosition(startX, startZ)
    local useFarmlandBoundary = (startFarmlandId ~= nil and startFarmlandId > 0)
    if useFarmlandBoundary then
        dbgLog("TPAB-RL: scanFieldExtent: using farmland boundary (id=%d)", startFarmlandId)
    else
        dbgLog("TPAB-RL: scanFieldExtent: farmland ID unavailable, falling back to ground type only")
    end

    -- Helper: cast numRays radial rays from (cx, cz), return edge points on same field/farmland
    local numRays = 32
    local stepSize = 0.5     -- meters per sample step
    local maxDist = 200      -- max scan distance

    local function castRadialRays(cx, cz)
        local pts = {}
        for i = 0, numRays - 1 do
            local angle = (i / numRays) * 2 * math.pi
            local dirX = math.cos(angle)
            local dirZ = math.sin(angle)
            local edgeDist = 0
            for d = stepSize, maxDist, stepSize do
                local sampleX = cx + dirX * d
                local sampleZ = cz + dirZ * d
                if not skipGroundCheck then
                    local fieldOk, _ = ToPastureAndBack_RL.isOnFieldGround(sampleX, sampleZ)
                    if not fieldOk then
                        edgeDist = d - stepSize
                        break
                    end
                end
                if useFarmlandBoundary then
                    local sampleFarmId = ToPastureAndBack_RL.getFarmlandIdAtPosition(sampleX, sampleZ)
                    if sampleFarmId ~= startFarmlandId then
                        edgeDist = d - stepSize
                        break
                    end
                end
                edgeDist = d
            end
            if edgeDist > 0 then
                table.insert(pts, { x = cx + dirX * edgeDist, z = cz + dirZ * edgeDist, dist = edgeDist })
            end
        end
        return pts
    end

    -- Helper: compute centroid of edge points
    local function computeCentroid(pts)
        local sx, sz = 0, 0
        for _, pt in ipairs(pts) do sx = sx + pt.x; sz = sz + pt.z end
        return sx / #pts, sz / #pts
    end

    -- Helper: validate a point is on-field and same farmland
    local function isValidCenter(cx, cz)
        if not skipGroundCheck then
            local onField, _ = ToPastureAndBack_RL.isOnFieldGround(cx, cz)
            if not onField then return false end
        end
        if useFarmlandBoundary then
            local fid = ToPastureAndBack_RL.getFarmlandIdAtPosition(cx, cz)
            if fid ~= startFarmlandId then return false end
        end
        return true
    end

    -- Iterative centroid refinement: cast rays from current center, compute new
    -- centroid, repeat until it converges. This walks from the player position to
    -- the true field center regardless of where the player is standing.
    local centerX, centerZ = startX, startZ
    local maxIterations = 10
    local convergeThreshold = 2.0  -- stop when centroid moves less than 2m

    for iter = 1, maxIterations do
        local edgePoints = castRadialRays(centerX, centerZ)
        if #edgePoints < 4 then
            dbgLog("TPAB-RL: scanFieldExtent: too few edge points (%d) on iteration %d", #edgePoints, iter)
            if iter == 1 then return nil end
            break  -- keep the last good center
        end

        local newCX, newCZ = computeCentroid(edgePoints)

        -- Verify the new center is still on our field
        if not isValidCenter(newCX, newCZ) then
            dbgLog("TPAB-RL: scanFieldExtent: centroid left field on iteration %d, keeping previous", iter)
            break
        end

        local dx = newCX - centerX
        local dz = newCZ - centerZ
        local shift = math.sqrt(dx * dx + dz * dz)
        dbgLog("TPAB-RL: scanFieldExtent iter %d: center=(%.1f, %.1f) -> (%.1f, %.1f), shift=%.1fm",
            iter, centerX, centerZ, newCX, newCZ, shift)

        centerX, centerZ = newCX, newCZ

        if shift < convergeThreshold then
            dbgLog("TPAB-RL: scanFieldExtent: converged after %d iterations (shift=%.1fm)", iter, shift)
            break
        end
    end

    -- Final edge points from converged center for statistics
    local edgePoints = castRadialRays(centerX, centerZ)
    if #edgePoints < 4 then
        dbgLog("TPAB-RL: scanFieldExtent: too few final edge points (%d)", #edgePoints)
        return nil
    end

    -- Compute distances from final center to each edge point
    local minDist = math.huge
    local maxDistFound = 0
    local totalDist = 0
    for _, pt in ipairs(edgePoints) do
        local dx = pt.x - centerX
        local dz = pt.z - centerZ
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist < minDist then minDist = dist end
        if dist > maxDistFound then maxDistFound = dist end
        totalDist = totalDist + dist
    end
    local avgRadius = totalDist / #edgePoints

    -- Build polygonal contour from edge points, pulled inward by 8m buffer.
    -- Each edge point is moved toward the center so the nav mesh boundary stays
    -- safely inside the farmland. This replaces the old rectangular approach
    -- and properly handles irregular field shapes.
    local CONTOUR_BUFFER = 8  -- meters inward from detected boundary
    local contourPoints = {}
    for _, pt in ipairs(edgePoints) do
        local dx = pt.x - centerX
        local dz = pt.z - centerZ
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist > CONTOUR_BUFFER + 2 then
            -- Pull the point inward by CONTOUR_BUFFER meters along the ray from center
            local scale = (dist - CONTOUR_BUFFER) / dist
            table.insert(contourPoints, {
                x = centerX + dx * scale,
                z = centerZ + dz * scale,
            })
        end
        -- Skip points too close to center (field edge very near center, can't buffer)
    end

    if #contourPoints < 4 then
        dbgLog("TPAB-RL: scanFieldExtent: too few contour points after buffer (%d)", #contourPoints)
        return nil
    end

    -- Subdivide long contour edges so the nav mesh builder has accurate elevation
    -- data along the boundary. On steep terrain, two contour points 25m apart can
    -- cause the nav mesh boundary to interpolate linearly over a terrain dip,
    -- creating a floating walkway. Splitting edges > MAX_EDGE into segments with
    -- proper terrain-sampled midpoints fixes this.
    local MAX_EDGE = 10  -- meters, max distance between consecutive contour points
    local subdivided = {}
    for i = 1, #contourPoints do
        local cur = contourPoints[i]
        table.insert(subdivided, cur)
        local nxt = contourPoints[(i % #contourPoints) + 1]
        local edgeDx = nxt.x - cur.x
        local edgeDz = nxt.z - cur.z
        local edgeLen = math.sqrt(edgeDx * edgeDx + edgeDz * edgeDz)
        if edgeLen > MAX_EDGE then
            local segments = math.ceil(edgeLen / MAX_EDGE)
            for s = 1, segments - 1 do
                local t = s / segments
                table.insert(subdivided, {
                    x = cur.x + edgeDx * t,
                    z = cur.z + edgeDz * t,
                })
            end
        end
    end
    contourPoints = subdivided
    dbgLog("TPAB-RL: scanFieldExtent: contour subdivided from 32 rays to %d points (maxEdge=%dm)", #contourPoints, MAX_EDGE)

    dbgLog("TPAB-RL: scanFieldExtent: farmlandId=%d, center=(%.1f, %.1f), avgRadius=%.1f, minEdgeDist=%.1f, contourPoints=%d",
        startFarmlandId, centerX, centerZ, avgRadius, minDist, #contourPoints)

    return {
        centerX = centerX,
        centerZ = centerZ,
        avgRadius = avgRadius,
        minEdgeDist = minDist,
        farmlandId = startFarmlandId,
        contourPoints = contourPoints,  -- list of {x, z} pairs forming the polygon
    }
end



-- ============================================================================
-- Density map validation
-- ============================================================================

--- Initialize density map data for ground type checking.
-- Must be called after loadMap, with a frame delay for reliability.
function ToPastureAndBack_RL.initDensityMap()
    if g_currentMission == nil or g_currentMission.fieldGroundSystem == nil then
        dbgLog("TPAB-RL: fieldGroundSystem not available yet")
        return false
    end

    local ok, mapId, firstCh, numCh = ToPastureAndBack_RL.fcall(function()
        return g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    end)

    if not ok or mapId == nil or mapId == 0 then
        dbgLog("TPAB-RL: getDensityMapData failed or returned nil")
        return false
    end

    ToPastureAndBack_RL.densityMapId = mapId
    ToPastureAndBack_RL.densityFirstChannel = firstCh
    ToPastureAndBack_RL.densityNumChannels = numCh

    -- Cache the grass value for quick comparison
    local gv = g_currentMission.grassValue
    if gv == nil and g_currentMission.fieldGroundSystem ~= nil then
        local ok2, val = ToPastureAndBack_RL.fcall(function() return g_currentMission.fieldGroundSystem.grassValue end)
        if ok2 and val ~= nil then gv = val end
    end
    if gv ~= nil then
        ToPastureAndBack_RL.grassValue = gv
    end

    dbgLog("TPAB-RL: Density map initialized (mapId=%s, firstCh=%s, numCh=%s, grassValue=%s)",
        tostring(mapId), tostring(firstCh), tostring(numCh), tostring(ToPastureAndBack_RL.grassValue))

    -- Probe forage foliage layers for growth state detection
    ToPastureAndBack_RL.initForageLayers()
    ToPastureAndBack_RL.initAllCropLayers()

    return true
end

--- Initialize forage-type foliage layers for growth state checking.
-- Covers base game grass/meadow plus map-added forage crops (alfalfa, clover, etc.).
-- Each has its own foliage plane with independent growth states.
-- Growth states (confirmed for GRASS 2026-04-06, assumed similar for others):
--   0 = no foliage, 1 = just planted, 2-4 = growing, 5 = cut/mowed, 6 = rolled cut, 7 = destroyed
function ToPastureAndBack_RL.initForageLayers()
    local ftm = g_fruitTypeManager
    if ftm == nil then
        dbgLog("TPAB-RL: g_fruitTypeManager is nil, forage layer checking disabled")
        return
    end

    ToPastureAndBack_RL.forageLayers = {}
    ToPastureAndBack_RL.forageNameSet = {}

    for _, name in ipairs(ToPastureAndBack_RL.KNOWN_FORAGE_NAMES) do
        local ok, fruit = ToPastureAndBack_RL.fcall(function() return ftm:getFruitTypeByName(name) end)
        if ok and fruit ~= nil and
           fruit.terrainDataPlaneId ~= nil and
           fruit.startStateChannel ~= nil and
           fruit.numStateChannels ~= nil then
            local layer = {
                name = name,
                planeId = fruit.terrainDataPlaneId,
                startCh = fruit.startStateChannel,
                numCh = fruit.numStateChannels,
                cutState = fruit.cutState or 5,
                groundType = fruit.groundTypeChangeType,
            }
            table.insert(ToPastureAndBack_RL.forageLayers, layer)
            ToPastureAndBack_RL.forageNameSet[name] = true
            dbgLog("TPAB-RL: Forage layer %s: planeId=%d, channels=%d+%d, cutState=%s, groundType=%s",
                name, layer.planeId, layer.startCh, layer.numCh,
                tostring(layer.cutState), tostring(layer.groundType))
        else
            dbgLog("TPAB-RL: Forage type %s not available on this map", name)
        end
    end

    ToPastureAndBack_RL.forageReady = (#ToPastureAndBack_RL.forageLayers > 0)
    dbgLog("TPAB-RL: Forage layers ready=%s, %d layer(s) cached",
        tostring(ToPastureAndBack_RL.forageReady), #ToPastureAndBack_RL.forageLayers)
end

--- Initialize all non-forage crop layers for pig stubble detection.
-- Iterates every registered fruit type, caches those with valid foliage data
-- that are NOT already in the forage list.
function ToPastureAndBack_RL.initAllCropLayers()
    local ftm = g_fruitTypeManager
    if ftm == nil then return end

    ToPastureAndBack_RL.cropLayers = {}

    -- getFruitTypes returns the list of all FruitTypeDesc objects
    local ok, allFruits = ToPastureAndBack_RL.fcall(function() return ftm:getFruitTypes() end)
    if not ok or allFruits == nil then
        dbgLog("TPAB-RL: Could not iterate fruit types for crop layer init")
        return
    end

    for _, fruit in ipairs(allFruits) do
        local name = fruit.name and string.upper(fruit.name) or nil
        if name ~= nil
           and not ToPastureAndBack_RL.forageNameSet[name]
           and fruit.terrainDataPlaneId ~= nil
           and fruit.startStateChannel ~= nil
           and fruit.numStateChannels ~= nil
           and (fruit.cutState or 0) > 0
           and (fruit.minHarvestingGrowthState or 0) > 0 then
            local layer = {
                name = name,
                planeId = fruit.terrainDataPlaneId,
                startCh = fruit.startStateChannel,
                numCh = fruit.numStateChannels,
                cutState = fruit.cutState or 5,
            }
            -- Editor-accurate type id (2026-06-04): the multilayer plane keys
            -- each cell by type index; resolve THIS fruit's type id so point
            -- queries can match the painted type instead of probing planes.
            local okT, _did, _tid = ToPastureAndBack_RL.fcall(getTerrainDataPlaneByName,
                g_currentMission.terrainRootNode, fruit.layerName or fruit.name)
            if okT and _tid ~= nil then
                layer.typeId = _tid
            end
            table.insert(ToPastureAndBack_RL.cropLayers, layer)
        end
    end

    ToPastureAndBack_RL.cropLayersReady = (#ToPastureAndBack_RL.cropLayers > 0)
    if ToPastureAndBack_RL.DEBUG then
        local _cnames = {}
        for _, _l in ipairs(ToPastureAndBack_RL.cropLayers) do table.insert(_cnames, string.format("%s(t=%s)", _l.name, tostring(_l.typeId))) end
        dbgLog("TPAB-RL: Crop layers cached: %s", table.concat(_cnames, ", "))
    end
    dbgLog("TPAB-RL: Crop layers ready=%s, %d non-forage crop(s) cached",
        tostring(ToPastureAndBack_RL.cropLayersReady), #ToPastureAndBack_RL.cropLayers)
end

--- Determine the field validation tier for an animal type.
-- @param animalType string e.g. "COW", "PIG", "SHEEP", "GOAT", "HORSE"
-- @return string "selective" (cows/horses), "rough" (sheep/goats), or "forager" (pigs)
function ToPastureAndBack_RL.getAnimalFieldTier(animalType)
    local t = animalType and string.upper(animalType) or ""
    if t == "PIG" then
        return "forager"
    elseif t == "SHEEP" or t == "GOAT" then
        return "rough"
    else
        return "selective"  -- COW, HORSE, and anything else
    end
end

--- Return the localized plural species noun for an animalType.
-- Used to replace the generic "herd" in user-facing messages (e.g. "The horses
-- from X are grazing"). Falls back to the generic "herd" locale if the animal
-- type is unknown.
--
-- FS25 treats sheep and goats as the same engine animalType ("SHEEP") with
-- different subTypes. When a barnPlaceable is provided and the animalType is
-- SHEEP, we scan the barn's clusters and inspect each subType's fillType name
-- to decide whether to use "sheep", "goats", or the mixed "flock" label.
-- Sheep fillTypes in base game are SHEEP_LANDRACE, SHEEP_SWISS_MOUNTAIN,
-- SHEEP_STEINSCHAF, SHEEP_BLACK_WELSH; the goat fillType is GOAT. Realistic
-- Livestock adds male variants to the same SHEEP animalType: RAM_LANDRACE,
-- RAM_STEINSCHAF, RAM_SWISS_MOUNTAIN, RAM_BLACK_WELSH (all sheep), and
-- RAM_GOAT (goat). Since we are already inside the SHEEP engine type when
-- this runs, every subtype here is either a sheep or a goat, so the matcher
-- simply treats "GOAT" in the fillType name as the goat discriminator and
-- everything else as a sheep. This correctly handles RAM_* male sheep that
-- do not contain "SHEEP" as a substring.
-- Result is cached on the barn to avoid rescans.
-- @param animalType string e.g. "COW", "PIG", "SHEEP", "GOAT", "HORSE", "BUFFALO"
-- @param barnPlaceable table|nil Optional barn for sheep/goat disambiguation
-- @return string Localized plural noun, e.g. "cows", "Kühe", "vaches"
function ToPastureAndBack_RL.getSpeciesNoun(animalType, ctx)
    local class = ToPastureAndBack_RL.classifySpecies(animalType, ctx)
    local key = "tpab_species_herd"
    if class == "COW" then key = "tpab_species_cow"
    elseif class == "BUFFALO" then key = "tpab_species_buffalo"
    elseif class == "SHEEP" then key = "tpab_species_sheep"
    elseif class == "GOAT" then key = "tpab_species_goat"
    elseif class == "MIXED_SHEEP_GOAT" then key = "tpab_species_flock"
    elseif class == "PIG" then key = "tpab_species_pig"
    elseif class == "HORSE" then key = "tpab_species_horse"
    elseif class == "ALPACA" then key = "tpab_species_alpaca"
    end
    return g_i18n:getText(key) or "herd"
end

--- Classify the species precisely by inspecting subType data.
-- Returns one of: "COW", "BUFFALO", "SHEEP", "GOAT", "MIXED_SHEEP_GOAT",
-- "PIG", "HORSE", or the uppercase animalType if unknown.
-- Caches the result on the session if a session-shaped ctx is passed,
-- so subsequent calls during the session lifetime hit the cache.
-- @param animalType string Engine animalType ("COW", "SHEEP", etc.)
-- @param ctx table|nil Session, barn placeable, or nil
-- @return string Classification token
function ToPastureAndBack_RL.classifySpecies(animalType, ctx)
    if type(ctx) == "table" and ctx.classifiedSpecies ~= nil then
        return ctx.classifiedSpecies
    end

    local t = animalType and string.upper(animalType) or ""
    if t == "BUFFALO" or t == "WATERBUFFALO" or t == "WATER_BUFFALO" then
        return "BUFFALO"
    end
    if t ~= "SHEEP" and t ~= "COW" then
        return t  -- PIG / HORSE / etc unchanged
    end

    -- Resolve animal source: session.rlAnimals, session.barnPlaceable, or direct barn
    local animals = nil
    if type(ctx) == "table" then
        if type(ctx.rlAnimals) == "table" and #ctx.rlAnimals > 0 then
            animals = ctx.rlAnimals
        elseif ctx.barnPlaceable ~= nil then
            animals = ToPastureAndBack_RL.getRLAnimalsFromBarn(ctx.barnPlaceable)
        elseif ctx.spec_husbandryAnimals ~= nil then
            animals = ToPastureAndBack_RL.getRLAnimalsFromBarn(ctx)
        end
    end

    local animalSystem = g_currentMission and g_currentMission.animalSystem
    if animals == nil or #animals == 0 or animalSystem == nil then
        return t
    end

    -- 2026-06-22: case-insensitive substring match so buffalo/goat detection survives
    -- casing/delimiter differences and modded subtypes (mirrors vanilla TPAB fix).
    local hasMain, hasSubset = false, false
    local seenNames = {}
    for _, anim in ipairs(animals) do
        local sti = anim.subTypeIndex
        if sti ~= nil then
            local subType = animalSystem:getSubTypeByIndex(sti)
            if subType ~= nil and subType.name ~= nil then
                local name = string.upper(subType.name)
                seenNames[name] = true
                if t == "SHEEP" then
                    if name:find("GOAT") then hasSubset = true else hasMain = true end
                else  -- COW
                    if name:find("BUFFALO") then hasSubset = true else hasMain = true end
                end
            end
        end
    end
    do
        local names = {}
        for n in pairs(seenNames) do names[#names + 1] = n end
        dbgLog("TPAB-RL: classifySpecies(%s): subtypes seen = [%s] (hasMain=%s hasSubset=%s)",
            t, table.concat(names, ","), tostring(hasMain), tostring(hasSubset))
    end

    local result
    if t == "SHEEP" then
        if hasMain and hasSubset then result = "MIXED_SHEEP_GOAT"
        elseif hasSubset then result = "GOAT"
        else result = "SHEEP" end
    else  -- COW
        if hasSubset and not hasMain then result = "BUFFALO"
        else result = "COW" end
    end

    -- Cache on session if ctx looks like a session
    if type(ctx) == "table" and ctx.id ~= nil and ctx.spawnState ~= nil then
        ctx.classifiedSpecies = result
    end

    return result
end

--- Get the locale-correct "to be" or "to have" form for the species noun.
-- For SHEEP/GOAT (singular collective "herd"/"Herde"/"troupeau"), returns the
-- third-person singular form. Otherwise returns the plural form.
function ToPastureAndBack_RL.getSpeciesVerb(animalType, form, ctx)
    local class = ToPastureAndBack_RL.classifySpecies(animalType, ctx)
    local isSingular = (class == "MIXED_SHEEP_GOAT")
    local lang = (g_languageShort or "en")
    if type(lang) == "string" then lang = lang:lower() end
    if form == "be" then
        if lang == "fr" then return isSingular and "est" or "sont" end
        if lang == "de" then return isSingular and "ist" or "sind" end
        return isSingular and "is" or "are"
    end
    if form == "have" then
        if lang == "fr" then return isSingular and "a" or "ont" end
        if lang == "de" then return isSingular and "hat" or "haben" end
        return isSingular and "has" or "have"
    end
    if form == "return_present" then
        -- Direct present-tense form of "to return". DE uses "kehrt"/"kehren"
        -- and pairs with a "zum X zurück" template; FR uses "rentre"/"rentrent";
        -- EN uses the compound "is heading"/"are heading" so the template can
        -- read "are heading back to ...".
        if lang == "fr" then return isSingular and "rentre" or "rentrent" end
        if lang == "de" then return isSingular and "kehrt" or "kehren" end
        return isSingular and "is heading" or "are heading"
    end
    return ""
end

--- Get the locale-correct second-person possessive determiner for the species
-- noun. Capitalized for sentence-start use. EN and DE possessives don't vary
-- with the noun number for our cases ("your"/"deine"); only FR distinguishes.
function ToPastureAndBack_RL.getSpeciesPossessive(animalType, ctx, lowercase)
    local class = ToPastureAndBack_RL.classifySpecies(animalType, ctx)
    local isSingular = (class == "MIXED_SHEEP_GOAT")
    local lang = (g_languageShort or "en")
    if type(lang) == "string" then lang = lang:lower() end
    if lang == "fr" then
        if lowercase then return isSingular and "votre" or "vos" end
        return isSingular and "Votre" or "Vos"
    end
    if lang == "de" then return lowercase and "deine" or "Deine" end
    return lowercase and "your" or "Your"
end

--- Check forage growth state at a single world position.
-- Reads the ground type first to determine which foliage layer owns this position,
-- then reads that layer's growth state.
-- @return number|nil The foliage state from the owning forage layer, or nil if not forage
-- @return number|nil The cutState of the matched layer
function ToPastureAndBack_RL.getForageState(x, z)
    if not ToPastureAndBack_RL.forageReady then
        return nil, nil
    end

    local terrainNode = g_currentMission.terrainRootNode
    local y = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)

    local groundType = 0
    if ToPastureAndBack_RL.densityReady then
        local density = getDensityAtWorldPos(ToPastureAndBack_RL.densityMapId, x, y, z)
        groundType = bitAND(
            bitShiftRight(density, ToPastureAndBack_RL.densityFirstChannel),
            2^ToPastureAndBack_RL.densityNumChannels - 1)
    end

    -- Find the forage layer that owns this ground type.
    -- Multiple forage types can share the same groundType (e.g. GRASS, FIELDGRASS,
    -- and CLOVER all use groundType=15 on Hof Bergmann). When that happens,
    -- getDensityStatesAtWorldPos on a non-owning layer returns stale/bleed data
    -- that can read as "mowed" (states >= cutState) even though the real crop is
    -- still growing. Fix: collect all matching layers, prefer the one where
    -- states > 0 AND states < cutState (growing forage = real owner).
    local bestStates, bestCutState, bestName = nil, nil, nil
    local fallbackStates, fallbackCutState, fallbackName = nil, nil, nil

    for _, layer in ipairs(ToPastureAndBack_RL.forageLayers) do
        if layer.groundType ~= nil and layer.groundType == groundType and layer.cutState > 0 then
            local ok, states = ToPastureAndBack_RL.fcall(getDensityStatesAtWorldPos, layer.planeId, x, y, z)
            if ok and states ~= nil and states > 0 then
                if states < layer.cutState then
                    -- Growing forage on this layer, this is the real owner
                    bestStates = states
                    bestCutState = layer.cutState
                    bestName = layer.name
                    break
                end
                if fallbackStates == nil then
                    -- Mowed/cut on this layer, keep as fallback in case no
                    -- other layer claims growing forage here
                    fallbackStates = states
                    fallbackCutState = layer.cutState
                    fallbackName = layer.name
                end
            end
        end
    end

    -- When "best" (growing) and "fallback" (mowed) layers return the same raw
    -- states value, the data is ambiguous, likely shared density plane data
    -- interpreted differently due to different cutStates (e.g. GRASS cutState=5
    -- vs FIELDGRASS cutState=9, both reading states=5). In this case, prefer
    -- the stricter interpretation (lower cutState), which is typically GRASS,
    -- the universal base grazing layer.
    if bestStates ~= nil and fallbackStates ~= nil and bestStates == fallbackStates and fallbackCutState < bestCutState then
        dbgLog("TPAB-RL: Forage ambiguous: %s and %s both read states=%d, preferring %s (lower cutState=%d) at (%.1f, %.1f)",
            bestName, fallbackName, bestStates, fallbackName, fallbackCutState, x, z)
        return fallbackStates, fallbackCutState
    end

    if bestStates ~= nil then
        dbgLog("TPAB-RL: Forage owner %s: states=%d, cutState=%d at (%.1f, %.1f)",
            bestName, bestStates, bestCutState, x, z)
        return bestStates, bestCutState
    end
    if fallbackStates ~= nil then
        dbgLog("TPAB-RL: Forage fallback %s: states=%d, cutState=%d at (%.1f, %.1f)",
            fallbackName, fallbackStates, fallbackCutState, x, z)
        return fallbackStates, fallbackCutState
    end

    -- 2026-05-09: ungated all-layer fallback. Originally gated on
    -- groundType==14 (natural grassland). But Helden field 6 surfaced a case
    -- where cultivated grass crops use groundType=12, which doesn't match
    -- any forage layer's groundType and isn't the natural-grass marker.
    -- The GRASS foliage plane DOES have valid growing-state data at that
    -- position (state=3 of cutState=5, "ready to harvest"), but the original
    -- groundType==14 gate prevented us from reading it.
    --
    -- New behavior: when no groundType-matched layer returned states, scan
    -- ALL forage layers for growing state regardless of groundType. This
    -- matches what the engine actually does: foliage planes are authoritative
    -- for fruit growth state; the terrain-detail groundType is just a paint
    -- coloration that hints at the layer mapping but isn't the only source.
    --
    -- Maps where this matters:
    --   * Helden: cultivated grass on groundType=12
    --   * Hof Bergmann: FIELDGRASS/CLOVER on natural groundType=14
    --   * Any future map with non-vanilla groundType assignments
    --
    -- Risk profile: stale bleed-through reads on non-owning layers typically
    -- show states >= cutState (mowed range) which we treat as "not growing"
    -- via `states < layer.cutState`. So the worst case for a wheat field
    -- (where GRASS plane bleeds through) is the fallback branch fires with
    -- states=cutState and the caller sees "mowed" rather than "not grass".
    -- Both are rejections; the new diagnostic is closer to truth.
    do
        local natBest, natBestCut, natBestName = nil, nil, nil
        local natFall, natFallCut, natFallName = nil, nil, nil

        for _, layer in ipairs(ToPastureAndBack_RL.forageLayers) do
            -- Skip layers with cutState=0, they can't be mowed and their
            -- non-zero states are stale bleed-through (e.g. FLOWERINGCATCHCROP)
            if layer.cutState > 0 then
                local ok, states = ToPastureAndBack_RL.fcall(getDensityStatesAtWorldPos, layer.planeId, x, y, z)
                if ok and states ~= nil and states > 0 then
                    if states < layer.cutState then
                        natBest = states
                        natBestCut = layer.cutState
                        natBestName = layer.name
                        break
                    end
                    if natFall == nil then
                        natFall = states
                        natFallCut = layer.cutState
                        natFallName = layer.name
                    end
                end
            end
        end

        if natBest ~= nil then
            dbgLog("TPAB-RL: Forage owner %s (ungated): states=%d, cutState=%d, gt=%d at (%.1f, %.1f)",
                natBestName, natBest, natBestCut, groundType, x, z)
            return natBest, natBestCut
        end
        if natFall ~= nil then
            dbgLog("TPAB-RL: Forage fallback %s (ungated): states=%d, cutState=%d, gt=%d at (%.1f, %.1f)",
                natFallName, natFall, natFallCut, groundType, x, z)
            return natFall, natFallCut
        end
    end

    return nil, nil
end

--- Check crop growth state at a single world position (non-forage fruit types).
-- Used for pig stubble detection. Iterates all cached crop layers.
-- @return number|nil The foliage state from a matching crop layer, or nil
-- @return number|nil The cutState of the matched crop layer
-- @return string|nil The crop name that matched
function ToPastureAndBack_RL.getCropState(x, z)
    if not ToPastureAndBack_RL.cropLayersReady then
        return nil, nil, nil
    end

    local terrainNode = g_currentMission.terrainRootNode
    local y = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)

    -- Editor-accurate read (2026-06-04): a multilayer data plane stores
    -- (typeIndex + states) per cell, so per-fruit plane probing bleeds between
    -- fruits that share a plane (Etruria: grass read as a growing crop and
    -- vice versa). Ask the plane WHICH type is painted at the cell
    -- (getDensityTypeIndexAtWorldPos), match it against the cached crop
    -- layers' typeId (resolved via getTerrainDataPlaneByName at init), and
    -- only then read the states. Grass/forage cells carry a different type,
    -- so they can never match a crop layer.
    local checkedPlanes = {}
    for _, layer in ipairs(ToPastureAndBack_RL.cropLayers) do
        if layer.typeId ~= nil and checkedPlanes[layer.planeId] == nil then
            checkedPlanes[layer.planeId] = true
            local okT, cellType = ToPastureAndBack_RL.fcall(getDensityTypeIndexAtWorldPos, layer.planeId, x, y, z)
            if okT and cellType ~= nil and cellType > 0 then
                for _, cand in ipairs(ToPastureAndBack_RL.cropLayers) do
                    if cand.planeId == layer.planeId and cand.typeId == cellType then
                        local okS, states = ToPastureAndBack_RL.fcall(getDensityStatesAtWorldPos, layer.planeId, x, y, z)
                        if okS and states ~= nil and states > 0 then
                            return states, cand.cutState, cand.name
                        end
                    end
                end
            end
        end
    end

    -- Fallback only for layers whose typeId could not be resolved at init:
    -- per-fruit channel read (imperfect on shared planes, better than nothing).
    for _, layer in ipairs(ToPastureAndBack_RL.cropLayers) do
        if layer.typeId == nil and layer.startCh ~= nil and layer.numCh ~= nil then
            local ok, density = ToPastureAndBack_RL.fcall(getDensityAtWorldPos, layer.planeId, x, y, z)
            if ok and density ~= nil then
                local s = bitAND(bitShiftRight(density, layer.startCh), 2^layer.numCh - 1)
                if s > 0 then
                    return s, layer.cutState, layer.name
                end
            end
        end
    end

    return nil, nil, nil
end
--- Check field suitability for a specific animal type at a world position.
-- Uses multi-point sampling. Branches logic based on species tier.
-- @param x number World X
-- @param z number World Z
-- @param animalType string e.g. "COW", "PIG", "SHEEP"
-- @param barnPlaceable table|nil Optional barn for species noun disambiguation
-- @return boolean True if field is suitable
-- @return string|nil Rejection reason if not suitable
function ToPastureAndBack_RL.checkFieldSuitability(x, z, animalType, barnPlaceable, speciesOverride)
    local tier = ToPastureAndBack_RL.getAnimalFieldTier(animalType)

    local sampleOffset = 5  -- meters
    local samplePoints = {
        {x, z},
        {x + sampleOffset, z},
        {x - sampleOffset, z},
        {x, z + sampleOffset},
        {x, z - sampleOffset},
    }

    if tier == "forager" then
        return ToPastureAndBack_RL.checkFieldForForager(samplePoints, x, z, animalType, barnPlaceable, speciesOverride)
    elseif tier == "rough" then
        return ToPastureAndBack_RL.checkFieldForRoughGrazer(samplePoints, x, z, animalType, barnPlaceable, speciesOverride)
    else
        return ToPastureAndBack_RL.checkFieldForSelectiveGrazer(samplePoints, x, z, animalType, barnPlaceable, speciesOverride)
    end
end

--- Field check for selective grazers (cows, horses).
-- Requires forage at growth states 2-4 (growing, not just planted, not mowed).
function ToPastureAndBack_RL.checkFieldForSelectiveGrazer(samplePoints, x, z, animalType, barnPlaceable, speciesOverride)
    local species = speciesOverride or ToPastureAndBack_RL.getSpeciesNoun(animalType, barnPlaceable)
    -- Growing-crop guard FIRST (2026-06-04): the crop planes are authoritative.
    -- On maps where crop fields share the grass ground type (Etruria), the
    -- forage ownership test below wrongly reports forage states on crop fields
    -- (groundType collision), so this must run before any forage acceptance.
    if ToPastureAndBack_RL.isGrowingCropAt(samplePoints) then
        return false, string.format(
            g_i18n:getText("tpab_growing_crop") or "There are crops growing here. Your %s would destroy them. Find a grass field or pasture.",
            species)
    end
    local forageCount = 0
    local cutCount = 0
    local justPlantedCount = 0

    for _, pt in ipairs(samplePoints) do
        local state, cutState = ToPastureAndBack_RL.getForageState(pt[1], pt[2])
        if state ~= nil then
            forageCount = forageCount + 1
            if state >= cutState then
                cutCount = cutCount + 1
            elseif state <= 1 then
                justPlantedCount = justPlantedCount + 1
            end
        end
    end

    if forageCount == 0 then
        -- No grass foliage anywhere. getForageState (incl. the ungated all-layer
        -- fallback) returns non-nil for ANY real grass, so reaching here means no
        -- grass to eat. Grazers need grass: accept ONLY explicit grass terrain
        -- (groundType 14=grass / 15=grassCut per maps_fieldGround.xml); reject
        -- everything else, plowed(4)/cultivated(2)/seedbed(3)/sown(7+)/stubble(1,
        -- 12,13)/bare(0) and a not-ready density. Cert fix 2026-06-22: sheep were
        -- accepted on plowed ground because the old reject fired only for
        -- groundType 1..13 AND only when density was ready, so accept-by-default
        -- let non-grass through.
        local isGrassGround = false
        if ToPastureAndBack_RL.densityReady then
            local terrainNode = g_currentMission.terrainRootNode
            local yCheck = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)
            local density = getDensityAtWorldPos(ToPastureAndBack_RL.densityMapId, x, yCheck, z)
            local groundType = bitAND(
                bitShiftRight(density, ToPastureAndBack_RL.densityFirstChannel),
                2^ToPastureAndBack_RL.densityNumChannels - 1)
            dbgLog("TPAB-RL: Selective grazer: no forage match, groundType=%d at (%.1f, %.1f)", groundType, x, z)
            isGrassGround = (groundType == 14 or groundType == 15)
        end
        if not isGrassGround then
            return false, string.format(
                g_i18n:getText("tpab_not_grass_field") or "This is not a grass field. Find a pasture with growing grass for your %s.",
                species)
        end
        return true, nil
    end

    dbgLog("TPAB-RL: Selective grazer check at (%.1f, %.1f): %d forage, %d cut, %d justPlanted",
        x, z, forageCount, cutCount, justPlantedCount)

    if cutCount >= math.ceil(forageCount / 2) then
        return false, string.format(
            g_i18n:getText("tpab_field_mowed") or "This field has been mowed. Find one with growing grass for your %s.",
            species)
    end

    if justPlantedCount >= math.ceil(forageCount / 2) then
        return false, string.format(
            g_i18n:getText("tpab_just_planted") or "This pasture was just planted. Let the grass grow before bringing your %s here.",
            species)
    end

    return true, nil
end

--- Field check for rough grazers (sheep, goats).
-- Accepts forage at any growth state (1 through cutState and beyond).
-- Only rejects non-forage fields (crops, fallow).
function ToPastureAndBack_RL.checkFieldForRoughGrazer(samplePoints, x, z, animalType, barnPlaceable, speciesOverride)
    local species = speciesOverride or ToPastureAndBack_RL.getSpeciesNoun(animalType, barnPlaceable)
    -- Growing-crop guard FIRST (2026-06-04): the crop planes are authoritative.
    -- On maps where crop fields share the grass ground type (Etruria), the
    -- forage ownership test below wrongly reports forage states on crop fields
    -- (groundType collision), so this must run before any forage acceptance.
    if ToPastureAndBack_RL.isGrowingCropAt(samplePoints) then
        return false, string.format(
            g_i18n:getText("tpab_growing_crop") or "There are crops growing here. Your %s would destroy them. Find a grass field or pasture.",
            species)
    end
    local forageCount = 0
    local emptyCount = 0  -- state 0 = no foliage at all

    for _, pt in ipairs(samplePoints) do
        local state, cutState = ToPastureAndBack_RL.getForageState(pt[1], pt[2])
        if state ~= nil then
            forageCount = forageCount + 1
            if state == 0 then
                emptyCount = emptyCount + 1
            end
        end
    end

    if forageCount == 0 then
        -- No grass foliage anywhere. getForageState (incl. the ungated all-layer
        -- fallback) returns non-nil for ANY real grass, so reaching here means no
        -- grass to eat. Grazers need grass: accept ONLY explicit grass terrain
        -- (groundType 14=grass / 15=grassCut per maps_fieldGround.xml); reject
        -- everything else, plowed(4)/cultivated(2)/seedbed(3)/sown(7+)/stubble(1,
        -- 12,13)/bare(0) and a not-ready density. Cert fix 2026-06-22: sheep were
        -- accepted on plowed ground because the old reject fired only for
        -- groundType 1..13 AND only when density was ready, so accept-by-default
        -- let non-grass through.
        local isGrassGround = false
        if ToPastureAndBack_RL.densityReady then
            local terrainNode = g_currentMission.terrainRootNode
            local yCheck = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)
            local density = getDensityAtWorldPos(ToPastureAndBack_RL.densityMapId, x, yCheck, z)
            local groundType = bitAND(
                bitShiftRight(density, ToPastureAndBack_RL.densityFirstChannel),
                2^ToPastureAndBack_RL.densityNumChannels - 1)
            dbgLog("TPAB-RL: Rough grazer: no forage match, groundType=%d at (%.1f, %.1f)", groundType, x, z)
            isGrassGround = (groundType == 14 or groundType == 15)
        end
        if not isGrassGround then
            return false, string.format(
                g_i18n:getText("tpab_not_grass_field") or "This is not a grass field. Find a pasture with growing grass for your %s.",
                species)
        end
        return true, nil
    end

    dbgLog("TPAB-RL: Rough grazer check at (%.1f, %.1f): %d forage, %d empty",
        x, z, forageCount, emptyCount)

    -- Only reject if everything is state 0 (no foliage at all)
    if emptyCount >= forageCount then
        return false, string.format(
            g_i18n:getText("tpab_nothing_growing") or "There's nothing growing here. Find a pasture for your %s.",
            species)
    end

    return true, nil
end

--- Field check for foragers (pigs).
-- Accepts mowed forage, harvested crop stubble, and fallow/bare farmland.
-- Rejects standing forage and growing crops.
function ToPastureAndBack_RL.checkFieldForForager(samplePoints, x, z, animalType, barnPlaceable, speciesOverride)
    -- Growing-crop guard FIRST (2026-06-07, mirrors the grazer checks):
    -- on maps where crop fields share the grass ground type (Etruria), the
    -- forage read below misreports growing-crop fields as cut forage and
    -- accepted pigs onto growing spinach. The crop planes are authoritative;
    -- this must run before any forage acceptance. Stubble (0 growing) passes.
    if ToPastureAndBack_RL.isGrowingCropAt(samplePoints) then
        return false, g_i18n:getText("tpab_pig_growing_crop") or "There are crops growing here. Find a harvested field or mowed pasture for the pigs."
    end
    -- First check if this is a forage field
    local forageCount = 0
    local forageCutCount = 0

    for _, pt in ipairs(samplePoints) do
        local state, cutState = ToPastureAndBack_RL.getForageState(pt[1], pt[2])
        if state ~= nil and state > 0 then
            forageCount = forageCount + 1
            if state >= cutState then
                forageCutCount = forageCutCount + 1
            end
        end
    end

    -- Same edge-bleed threshold as the crop check below: require 3+ of 5 samples
    -- to agree it's forage before judging mowed-vs-standing. Otherwise a single
    -- sample hitting a neighboring pasture's standing grass could falsely reject
    -- an otherwise clean harvested/fallow field the player is actually on.
    local FORAGE_MAJORITY_THRESHOLD = 3
    if forageCount >= FORAGE_MAJORITY_THRESHOLD then
        dbgLog("TPAB-RL: Forager check at (%.1f, %.1f): %d forage, %d cut",
            x, z, forageCount, forageCutCount)
        if forageCutCount >= math.ceil(forageCount / 2) then
            return true, nil  -- mowed forage, good for pigs
        else
            return false, g_i18n:getText("tpab_pig_no_suitable_field") or "Pigs need a mowed field, stubble, or bare ground (fallow, plowed or cultivated). Find one for them."
        end
    elseif forageCount > 0 then
        -- Minority forage samples, likely pasture-edge bleed. Fall through to
        -- the crop check and the fallow check so a mostly clean field still
        -- gets accepted.
        dbgLog("TPAB-RL: Forager check at (%.1f, %.1f): %d/%d samples hit forage (below threshold %d), treating as edge bleed, falling through",
            x, z, forageCount, #samplePoints, FORAGE_MAJORITY_THRESHOLD)
    end

    -- Not a forage field. Check for crop stubble.
    local cropCount = 0
    local cropCutCount = 0
    local cropGrowingCount = 0
    local perSample = {}  -- for diagnostic log: list of "name:state/cutState"

    for _, pt in ipairs(samplePoints) do
        local state, cutState, cropName = ToPastureAndBack_RL.getCropState(pt[1], pt[2])
        if state ~= nil then
            cropCount = cropCount + 1
            if state >= cutState then
                cropCutCount = cropCutCount + 1
            else
                cropGrowingCount = cropGrowingCount + 1
            end
            if ToPastureAndBack_RL.DEBUG then
                table.insert(perSample, string.format("%s:%d/%d",
                    tostring(cropName or "?"), state, cutState or -1))
            end
        end
    end

    -- Threshold: require a majority of samples (3+ of 5) to agree it's a crop field
    -- before trusting the harvested-vs-growing decision. Otherwise a single stray
    -- sample bleeding into a neighboring field's crop can veto an otherwise clean
    -- harvested/fallow field when the player stands near a field edge.
    local CROP_MAJORITY_THRESHOLD = 3
    if cropCount >= CROP_MAJORITY_THRESHOLD then
        dbgLog("TPAB-RL: Forager crop check at (%.1f, %.1f): %d crops, %d harvested, %d growing [%s]",
            x, z, cropCount, cropCutCount, cropGrowingCount, table.concat(perSample, ", "))
        if cropCutCount >= math.ceil(cropCount / 2) then
            return true, nil  -- harvested crop stubble, good for pigs
        else
            return false, g_i18n:getText("tpab_pig_growing_crop") or "There are crops growing here. Find a harvested field or mowed pasture for the pigs."
        end
    elseif cropCount > 0 then
        -- Only a minority of samples saw crops. Likely edge-of-field bleed into
        -- a neighboring crop strip. Log and fall through to the fallow check so
        -- owned farmland with incidental edge noise still gets accepted.
        dbgLog("TPAB-RL: Forager crop check at (%.1f, %.1f): %d/%d samples hit crop (below threshold %d), treating as edge bleed, falling through to fallow check [%s]",
            x, z, cropCount, #samplePoints, CROP_MAJORITY_THRESHOLD, table.concat(perSample, ", "))
    end

    -- No forage, no crops. Check if it's owned farmland (fallow/bare).
    if ToPastureAndBack_RL.densityReady then
        local terrainNode = g_currentMission.terrainRootNode
        local yCheck = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)
        local density = getDensityAtWorldPos(ToPastureAndBack_RL.densityMapId, x, yCheck, z)
        local groundType = bitAND(
            bitShiftRight(density, ToPastureAndBack_RL.densityFirstChannel),
            2^ToPastureAndBack_RL.densityNumChannels - 1)
        dbgLog("TPAB-RL: Forager fallow check at (%.1f, %.1f): groundType=%d", x, z, groundType)
        if groundType > 0 then
            return true, nil  -- fallow/cultivated farmland, good for pigs
        end
    end

    return false, g_i18n:getText("tpab_pig_no_suitable_field") or "Pigs need a mowed field, stubble, or bare ground (fallow, plowed or cultivated). Find one for them."
end

--- Check if a world position is on field ground (grass or cultivated).
-- @param x number World X
-- @param z number World Z
-- @return boolean True if on field ground, false if not (road, bare ground, etc.)
-- @return boolean True if specifically on grass (meadow/pasture)
function ToPastureAndBack_RL.isOnFieldGround(x, z)
    if not ToPastureAndBack_RL.densityReady then
        return false, false
    end

    local mapId = ToPastureAndBack_RL.densityMapId
    local firstCh = ToPastureAndBack_RL.densityFirstChannel
    local numCh = ToPastureAndBack_RL.densityNumChannels

    local terrainNode = g_currentMission.terrainRootNode
    local y = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)

    local density = getDensityAtWorldPos(mapId, x, y, z)
    local groundType = bitAND(bitShiftRight(density, firstCh), 2^numCh - 1)

    local isField = groundType > 0
    local isGrass = false
    if ToPastureAndBack_RL.grassValue ~= nil then
        isGrass = (groundType == ToPastureAndBack_RL.grassValue)
    end

    return isField, isGrass
end

--- Validate a position for pasture placement.
-- Checks density map in a small area around the position to confirm
-- it's actually on a grass field, not just at the edge.
-- @param x number World X
-- @param z number World Z
-- @return boolean True if valid for placement
-- @return string Reason if invalid
function ToPastureAndBack_RL.validatePasturePosition(x, z, animalType, barnPlaceable, speciesOverride)
    local species = speciesOverride or ToPastureAndBack_RL.getSpeciesNoun(animalType, barnPlaceable)
    if not ToPastureAndBack_RL.densityReady then
        return false, string.format(
            g_i18n:getText("tpab_pasture_invalid") or "Walk a few steps into the field before you drop off your %s.",
            species)
    end

    local isField, isGrass = ToPastureAndBack_RL.isOnFieldGround(x, z)
    if not isField then
        return false, string.format(
            g_i18n:getText("tpab_pasture_invalid") or "Walk a few steps into the field before you drop off your %s.",
            species)
    end

    -- Check surrounding points to make sure we're well inside a field
    local checkRadius = 3  -- meters
    local validCount = 0
    local totalChecks = 0
    local offsets = {
        {checkRadius, 0}, {-checkRadius, 0}, {0, checkRadius}, {0, -checkRadius},
        {checkRadius * 0.7, checkRadius * 0.7}, {-checkRadius * 0.7, checkRadius * 0.7},
    }
    for _, offset in ipairs(offsets) do
        totalChecks = totalChecks + 1
        local fieldOk, _ = ToPastureAndBack_RL.isOnFieldGround(x + offset[1], z + offset[2])
        if fieldOk then validCount = validCount + 1 end
    end

    if validCount < totalChecks / 2 then
        return false, string.format(
            g_i18n:getText("tpab_pasture_invalid") or "Walk a few steps into the field before you drop off your %s.",
            species)
    end

    -- Per-drop stacking (Option A, 2026-06-03): the "too close to another
    -- pasture" reject was removed so a compatible herd can be dropped onto a
    -- field that already has one. Incompatible drops are still blocked by
    -- checkFieldSuitability (wrong ground for the species).

    return true, nil
end


-- ============================================================================
-- Player position helper
-- ============================================================================

--- Get the current player's world position.
-- Uses camera position as fallback (player.rootNode can be nil in MP host).
-- @return number x, number y, number z, or nil if unavailable
function ToPastureAndBack_RL.getPlayerPosition()
    if g_currentMission.player ~= nil then
        local player = g_currentMission.player
        if player.rootNode ~= nil and player.rootNode ~= 0 then
            local ok, x, y, z = ToPastureAndBack_RL.fcallNode(getWorldTranslation, player.rootNode)
            if ok then return x, y, z end
        end
    end

    -- Fallback: camera position (confirmed working in MP host from Diagnostic 1)
    local cam = getCamera()
    if cam ~= nil and cam ~= 0 then
        local ok, x, y, z = ToPastureAndBack_RL.fcallNode(getWorldTranslation, cam)
        if ok then return x, y, z end
    end

    return nil, nil, nil
end


-- ============================================================================
-- Pasture point management
-- ============================================================================

--- Confirm grazing destination: place pasture marker and spawn the herd(s).
-- This is step 2 of the barn-first flow. The player pressed RCtrl+J at one or more barns
-- (which appended to pendingGrazings), then walked/drove to a grass field and presses RCtrl+G.
-- All pending herds in the queue share the same class (GRAZER vs FORAGER), so field validation
-- runs once for the batch. Either all herds spawn or none do (no partial dispatch on failure).
function ToPastureAndBack_RL.confirmGrazingDestination()
    -- Must have at least one pending grazing from step 1 (RCtrl+J at barn)
    if not ToPastureAndBack_RL.hasPendingGrazings() then
        dbgLog("TPAB-RL: No pending grazing, player needs to visit a barn first.")
        ToPastureAndBack_RL.showRefusal(string.format(
            g_i18n:getText("tpab_no_pending_grazing") or "Go to a barn and collect a herd first, either from the animal menu or with %s.",
            ToPastureAndBack_RL.getBindingText("TPABRL_COLLECT_HERD")))
        return
    end

    local pendings = ToPastureAndBack_RL.pendingGrazings
    local firstPending = pendings[1]  -- representative for class-level validation (all share pendingClass)

    local x, y, z = ToPastureAndBack_RL.getPlayerPosition()
    if x == nil then
        Logging.warning("TPAB-RL: Cannot determine player position")
        return
    end

    -- Use terrain height, not camera height
    local terrainNode = g_currentMission.terrainRootNode
    y = getTerrainHeightAtWorldPos(terrainNode, x, 0, z)

    -- Log density at placement position
    if ToPastureAndBack_RL.densityReady and ToPastureAndBack_RL.densityMapId ~= nil then
        local density = getDensityAtWorldPos(ToPastureAndBack_RL.densityMapId, x, y, z)
        local groundType = bitAND(
            bitShiftRight(density, ToPastureAndBack_RL.densityFirstChannel),
            2^ToPastureAndBack_RL.densityNumChannels - 1)
        dbgLog("TPAB-RL: Destination attempt at (%.1f, %.1f, %.1f): groundType=%d",
            x, y, z, groundType)
    end

    -- UX 2026-07-09 : ownership outranks field state in refusal priority. A
    -- field the player does not own must refuse as someone-else's-field even when
    -- it is also mowed or otherwise unsuitable. Skipped when the position is not
    -- on a farmland at all (farmlandId 0), so non-field ground keeps its more
    -- accurate field-state message; the original post-suitability ownership check
    -- below still covers that path (kept, never replaced).
    do
        local earlyOwned, earlyFarmlandId, earlyOwnerFarmId = ToPastureAndBack_RL.isPlayerOwnedFarmland(x, z)
        if not earlyOwned and earlyFarmlandId ~= nil and earlyFarmlandId ~= 0 then
            local msg = g_i18n:getText("tpab_someone_else_field") or "You can only take herds onto your own land. Buy the land or go to a field you already own."
            dbgLog("TPAB-RL: Cannot place herd here: Farmland %s owned by farm %s (ownership checked before field state)", tostring(earlyFarmlandId), tostring(earlyOwnerFarmId))
            ToPastureAndBack_RL.showRefusal(msg)
            return
        end
    end

    -- Check field suitability based on animal species (tier-based validation).
    -- All pendings share pendingClass, so one tier check covers the whole batch.
    local animalType = firstPending.animalType
    local pendingBarn = firstPending.barnData and firstPending.barnData.placeable or nil
    -- Mixed pocket (2+ herds queued): field-rejection messages name the herd "mixed
    -- herd" instead of just the representative species (firstPending). Same 2+ rule as
    -- the move-prompt and the grazing-started umbrella message.
    local speciesOverride = nil
    if #pendings > 1 then
        speciesOverride = g_i18n:getText("tpab_species_mixed") or "mixed herd"
    end
    local isPastureDestination = false
    local matchedPastureData = nil  -- barn cache entry for matched pasture placeable

    local fieldOk, fieldReason = ToPastureAndBack_RL.checkFieldSuitability(x, z, animalType, pendingBarn, speciesOverride)
    if not fieldOk then
        matchedPastureData = ToPastureAndBack_RL.findPastureAtPosition(x, z, animalType, pendingBarn)
        if matchedPastureData == nil then
            dbgLog("TPAB-RL: Cannot place herd here: %s", fieldReason)
            ToPastureAndBack_RL.showRefusal(fieldReason)
            return
        end
        isPastureDestination = true
        dbgLog("TPAB-RL: Field check failed but player is inside pasture placeable '%s', allowing as destination", matchedPastureData.name)
    end

    -- Check farmland ownership (player must own the field)
    local isOwned, farmlandId, ownerFarmId = ToPastureAndBack_RL.isPlayerOwnedFarmland(x, z)
    if not isOwned then
        local msg = g_i18n:getText("tpab_someone_else_field") or "You can only take herds onto your own land. Buy the land or go to a field you already own."
        dbgLog("TPAB-RL: Cannot place herd here: Farmland %d owned by farm %d", farmlandId, ownerFarmId)
        ToPastureAndBack_RL.showRefusal(msg)
        return
    end

    -- Validate position (must be on a field, not too close to other pastures).
    -- Skip field-ground check for pasture destinations (groundType=0 is expected there).
    if not isPastureDestination then
        local valid, reason = ToPastureAndBack_RL.validatePasturePosition(x, z, animalType, pendingBarn, speciesOverride)
        if not valid then
            matchedPastureData = ToPastureAndBack_RL.findPastureAtPosition(x, z, animalType, pendingBarn)
            if matchedPastureData == nil then
                dbgLog("TPAB-RL: Cannot place herd here: %s", reason)
                ToPastureAndBack_RL.showRefusal(reason)
                return
            end
            isPastureDestination = true
            dbgLog("TPAB-RL: Position validation failed but player is inside pasture placeable '%s', allowing as destination", matchedPastureData.name)
        end
    else
        -- Per-drop stacking (Option A): no proximity reject on the pasture path.
    end

    -- Promote to pasture destination if the player passed the field check but is actually
    -- inside a husbandry placeable's fenced area (e.g. a Cow Pasture wrapping the farmland).
    if not isPastureDestination then
        local enclosing = ToPastureAndBack_RL.findEnclosingFence(x, z)
        if enclosing ~= nil and enclosing.placeable ~= nil then
            local encP = enclosing.placeable
            local encSpec = encP.spec_husbandryAnimals
            if encSpec ~= nil and encSpec.animalType ~= nil then
                local placeableType = ""
                if encSpec.animalType.name ~= nil then
                    placeableType = string.upper(encSpec.animalType.name)
                elseif encSpec.animalType.type ~= nil then
                    placeableType = string.upper(tostring(encSpec.animalType.type))
                end
                if placeableType == animalType then
                    local matchedEntry = nil
                    if ToPastureAndBack_RL.barnCache ~= nil and ToPastureAndBack_RL.barnCache[animalType] ~= nil then
                        for _, b in ipairs(ToPastureAndBack_RL.barnCache[animalType]) do
                            if b.placeable == encP then
                                matchedEntry = b
                                break
                            end
                        end
                    end
                    if matchedEntry ~= nil and matchedEntry.navNode ~= nil then
                        matchedPastureData = matchedEntry
                        isPastureDestination = true
                        dbgLog("TPAB-RL: Promoted to pasture destination '%s' (inside its fence), borrowing nav mesh", enclosing.name)
                    end
                else
                    dbgLog("TPAB-RL: Inside fence of '%s' but it is for %s not %s, staying on field path",
                        enclosing.name, placeableType, animalType)
                end
            else
                dbgLog("TPAB-RL: Inside bare fence '%s' (no husbandry spec), staying on field path for now",
                    enclosing.name)
            end
        end
    end

    -- Scan field extent. For pasture destinations, skip fence scanning entirely
    -- and reuse the pasture's own nav mesh.
    local fieldData
    local fieldRadius = ToPastureAndBack_RL.DEFAULT_RADIUS
    local herdX, herdZ = x, z  -- fallback to player position
    local fieldContour = nil

    if isPastureDestination and matchedPastureData ~= nil then
        -- LANDLOCKED-BARN GUARD (predicate B, senior-reviewed 2026-06-29): a real
        -- grazing pasture -- attached to a barn (adjustable husbandry meadow) OR a
        -- standalone fenced pasture -- ALWAYS has an outdoor fenced area: a fence
        -- outline (fenceRadius, built only from >=3 fence segments) and/or the engine
        -- outdoorContourPolygon. A landlocked barn (bare indoor barn: calf shed,
        -- chicken coop, large pig barn, or Pichonniere's Heifer Barn) has NEITHER and
        -- could only match via the nav-circle fallback. Refuse it: you cannot graze
        -- where there is no pasture. GEOMETRY ONLY, never occupancy, so co-grazing is
        -- safe. Do NOT gate on spec_husbandryMeadow: a fenced pasture may omit the
        -- meadow block (real-terrain grass), and gating on meadow would wrongly block it.
        do
            local destP = matchedPastureData.placeable
            local destSpec = destP ~= nil and destP.spec_husbandryAnimals or nil
            local hasContour = destSpec ~= nil and destSpec.outdoorContourPolygon ~= nil
            local hasFence = matchedPastureData.fenceRadius ~= nil
            if not hasContour and not hasFence then
                local destP2 = matchedPastureData.placeable
                local destName = (destP2 ~= nil and destP2.getName and destP2:getName())
                    or matchedPastureData.name or "That barn"
                local forager = ToPastureAndBack_RL.getAnimalFieldTier(animalType) == "forager"
                dbgLog("TPAB-RL: Refusing landlocked barn destination '%s' (no fence/contour, no pasture); pocket kept", destName)
                ToPastureAndBack_RL.showRefusal(string.format(
                    g_i18n:getText(forager and "tpab_dest_no_pasture_forage" or "tpab_dest_no_pasture_graze")
                    or ("A barn is not a destination for a pasture run, and %s has no pasture of its own.\n"
                        .. "To drop them off, go to a field or a pasture and press %s there.\n"
                        .. "To return them to their barn, first cancel with %s, then press %s."),
                    destName,
                    ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"),
                    ToPastureAndBack_RL.getBindingText("TPABRL_CANCEL"),
                    ToPastureAndBack_RL.getBindingText("TPABRL_RECALL")))
                return
            end
        end
        -- KEY position, NOT getBarnAnchorPos: pasture-dest herd center is matched back to the pasture by
        -- findBarnDataByPosition (navNode-keyed) on spawn.
        local nx, nz = ToPastureAndBack_RL.getBarnCachePos(matchedPastureData)
        if nx ~= nil then
            herdX, herdZ = nx, nz
        end
        fieldContour = nil
        dbgLog("TPAB-RL: Pasture destination, skipping fence scan, herd center=(%.1f, %.1f)", herdX, herdZ)
    else
        fieldData = ToPastureAndBack_RL.scanFieldExtent(x, z)
        if fieldData ~= nil then
            fieldRadius = math.max(fieldData.minEdgeDist - 8, 10)
            herdX = fieldData.centerX
            herdZ = fieldData.centerZ
            fieldContour = fieldData.contourPoints
            dbgLog("TPAB-RL: Field detected: center=(%.1f, %.1f), contourPoints=%d, minEdge=%.1f, player was at (%.1f, %.1f)",
                herdX, herdZ, fieldContour and #fieldContour or 0, fieldData.minEdgeDist, x, z)

            -- 2026-05-05 morning v12: use scanFieldExtent's farmland contour
            -- directly. scanFieldExtent ALREADY applies an 8m inward buffer
            -- (HANDOFF 2026-04-08 session 9) so the polygon is well inside the
            -- farmland boundary. v10 added an extra 3m inset on top, total 11m,
            -- which halved the polygon area on Pichonniere (3700 sqm farmland
            -- shrunk to 1700 sqm spawn polygon, killing dispersal). The 8m
            -- existing buffer is the established calibrated solution; don't
            -- double-shrink.
            --
            -- 2026-05-08 fence-aligned contour upgrade: scanFieldExtent
            -- stops at farmland-internal ground-type changes (paths, gravel,
            -- internal roads) which can truncate the contour well inside the
            -- actual fenced area. First seen on Pichonniere F6 where it
            -- stopped at avgRadius=33.9m while the real fence sits at 49m.
            -- Result: animals stuck in a small inner area, temp fence drawn
            -- around the truncated contour instead of the real fence. Fix:
            -- when isAreaRadiallyEnclosed detects fences (or farmland
            -- boundary) at significantly greater distance, swap the small
            -- farmland-derived contour for a fence-aligned contour built
            -- from buildContourFromRadialHits. The helper's 3m default
            -- buffer keeps animals safely off the wire (no double-inset
            -- because we're ENLARGING, not shrinking on top of an existing
            -- inset, so the v10 "halved area" failure mode doesn't apply).
            if fieldContour ~= nil and #fieldContour >= 3 then
                local _, hitArr, realHits = ToPastureAndBack_RL.isAreaRadiallyEnclosed(
                    herdX, herdZ, 60, fieldData.farmlandId)
                if hitArr ~= nil then
                    -- Compute the longest real-fence/boundary distance
                    local maxFenceDist = 0
                    for _, h in ipairs(hitArr) do
                        if h.dist ~= nil and not h.miss then
                            if h.dist > maxFenceDist then maxFenceDist = h.dist end
                        end
                    end
                    -- 2026-05-09 Helden fix: also require evidence of REAL
                    -- fence/wall/hedge hits before swapping. When all hits are
                    -- boundary clamps (real=0), the radial scan is just
                    -- remapping the farmland edge at higher resolution, and
                    -- swapping replaces scanFieldExtent's safe 8m-buffered
                    -- contour with one that runs right to the farmland edge.
                    -- On maps where the farmland extends beyond the visible
                    -- field (Helden field 62 includes the adjacent dirt road),
                    -- this puts the temp fence on the road. Pichonniere F6
                    -- (the original repro) had real=30, so realHits >= 8 is a
                    -- comfortable threshold that catches partially-fenced
                    -- bocage parcels while rejecting unfenced fields.
                    local MIN_REAL_HITS_FOR_SWAP = 8
                    -- Threshold: only swap when fence is substantially farther
                    -- than scanFieldExtent saw (>= 5m beyond avgRadius). Avoids
                    -- swapping for normal fields where the two converge.
                    if maxFenceDist >= fieldData.avgRadius + 5
                            and (realHits or 0) >= MIN_REAL_HITS_FOR_SWAP then
                        local fenceContour = ToPastureAndBack_RL.buildContourFromRadialHits(
                            herdX, herdZ, hitArr)
                        if fenceContour ~= nil and #fenceContour >= 8 then
                            local function polyArea(pts)
                                local a = 0
                                local m = #pts
                                for i = 1, m do
                                    local j = (i % m) + 1
                                    a = a + (pts[i].x * pts[j].z) - (pts[j].x * pts[i].z)
                                end
                                return math.abs(a) / 2
                            end
                            local oldArea = polyArea(fieldContour)
                            local newArea = polyArea(fenceContour)
                            -- Only swap if the new contour is at least 30%
                            -- larger; otherwise it's not worth the change.
                            if newArea > oldArea * 1.30 then
                                fieldContour = fenceContour
                                dbgLog("TPAB-RL: Replaced farmland contour (avgRadius=%.1fm, area=%.0f sqm) with fence-aligned contour (maxDist=%.1fm, area=%.0f sqm, +%.0f%%)",
                                    fieldData.avgRadius, oldArea, maxFenceDist, newArea,
                                    (newArea / oldArea - 1) * 100)
                            else
                                dbgLog("TPAB-RL: Using farmland contour as-is (%d-point polygon, fence-aligned alt was %.0f sqm vs %.0f sqm, not enough to swap)",
                                    #fieldContour, newArea, oldArea)
                            end
                        else
                            dbgLog("TPAB-RL: Using farmland contour as-is (%d-point polygon, fence-aligned alt failed to build)",
                                #fieldContour)
                        end
                    else
                        dbgLog("TPAB-RL: Using farmland contour as-is (%d-point polygon, scanFieldExtent's 8m buffer applied; realHits=%d, maxFenceDist=%.1fm vs avgRadius=%.1fm)",
                            #fieldContour, realHits or 0, maxFenceDist, fieldData.avgRadius)
                    end
                else
                    dbgLog("TPAB-RL: Using farmland contour as-is (%d-point polygon, scanFieldExtent's 8m buffer applied; isAreaRadiallyEnclosed returned no hitArr)",
                        #fieldContour)
                end
            end

            -- cert 2026-07-07 symptom A (M1): when a second herd is dropped on a
            -- farmland that ALREADY hosts an active session (or one this peer just
            -- dropped this run, MP round-trip race), re-centering on the farmland
            -- centroid would stack both herds on the same spot and ignore where the
            -- player actually stands. Center on the player instead, but only if the
            -- player is inside the buffered farmland contour (8m inward buffer);
            -- otherwise keep the centroid fallback. fieldContour stays the
            -- whole-field contour, containment bounds are unchanged. Occupancy
            -- never rejects (co-grazing core rule), this only moves the center.
            if fieldData.farmlandId ~= nil and fieldData.farmlandId > 0
                    and fieldData.contourPoints ~= nil and #fieldData.contourPoints >= 3 then
                local farmlandBusy = false
                for _, s in ipairs(ToPastureAndBack_RL.grazingSessions) do
                    if s.farmlandId ~= nil and s.farmlandId == fieldData.farmlandId
                            and s.spawnState ~= "done" then
                        farmlandBusy = true
                        break
                    end
                end
                if not farmlandBusy and ToPastureAndBack_RL.recentDropFarmlands ~= nil
                        and ToPastureAndBack_RL.recentDropFarmlands[fieldData.farmlandId] then
                    farmlandBusy = true
                end
                if farmlandBusy then
                    if ToPastureAndBack_RL.isInsidePolygon(x, z, fieldData.contourPoints) then
                        herdX, herdZ = x, z
                        dbgLog("TPAB-RL: M1: farmland %d already hosts a herd, centering new herd at player (%.1f, %.1f) instead of centroid",
                            fieldData.farmlandId, x, z)
                    else
                        dbgLog("TPAB-RL: M1: farmland %d already hosts a herd but player is outside the buffered contour, keeping centroid center",
                            fieldData.farmlandId)
                    end
                end
            end
        else
            dbgLog("TPAB-RL: Field scan failed, using player position as herd center")
        end
    end

    -- Field-area validation: sum animal counts across the whole batch.
    -- All pending herds will graze on the same field, so size requirement is total animals.
    -- Grass-coverage backstop (2026-06-29, Riverbend cert bug; mirror of TPAB): the
    -- 5-point drop-spot check passes if ANY point has grass forage, but the herd then
    -- spreads across the WHOLE farmland contour, so a plowed crop field with one grass
    -- patch let grazers onto plowed ground. Backstop: sample the ACTUAL placement
    -- polygon and reject if it is mostly not grass. Selective + rough grazers only;
    -- pigs (forager) exempt. AND-composed with upstream guards. "Grass" = groundType
    -- 14/15 (primary) OR a real forage layer (secondary). Density-not-ready -> skip.
    if not isPastureDestination and fieldContour ~= nil and #fieldContour >= 3
            and ToPastureAndBack_RL.densityReady then
        local coverTier = ToPastureAndBack_RL.getAnimalFieldTier(animalType)
        if coverTier == "selective" or coverTier == "rough" then
            local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
            for _, cp in ipairs(fieldContour) do
                if cp.x < minX then minX = cp.x end
                if cp.x > maxX then maxX = cp.x end
                if cp.z < minZ then minZ = cp.z end
                if cp.z > maxZ then maxZ = cp.z end
            end
            local STEP = 8
            local terrainNode = g_currentMission.terrainRootNode
            local mask = 2 ^ ToPastureAndBack_RL.densityNumChannels - 1
            local inCount, grassCount = 0, 0
            local sx = minX
            while sx <= maxX do
                local sz = minZ
                while sz <= maxZ do
                    if ToPastureAndBack_RL.isInsidePolygon(sx, sz, fieldContour) then
                        inCount = inCount + 1
                        local yCheck = getTerrainHeightAtWorldPos(terrainNode, sx, 0, sz)
                        local density = getDensityAtWorldPos(ToPastureAndBack_RL.densityMapId, sx, yCheck, sz)
                        local groundType = bitAND(
                            bitShiftRight(density, ToPastureAndBack_RL.densityFirstChannel), mask)
                        local isGrass = (groundType == 14 or groundType == 15)
                        if not isGrass and ToPastureAndBack_RL.getForageState(sx, sz) ~= nil then
                            isGrass = true
                        end
                        if isGrass then grassCount = grassCount + 1 end
                    end
                    sz = sz + STEP
                end
                sx = sx + STEP
            end
            if inCount >= 4 then
                local frac = grassCount / inCount
                dbgLog("TPAB-RL: Grass coverage on placement polygon: %d/%d in-poly samples grass (%.0f%%)",
                    grassCount, inCount, frac * 100)
                if frac < 0.50 then
                    local species = speciesOverride or ToPastureAndBack_RL.getSpeciesNoun(animalType, pendingBarn)
                    ToPastureAndBack_RL.showRefusal(
                        string.format(g_i18n:getText("tpab_not_grass_field")
                            or "This is not a grass field. Find a pasture with growing grass for your %s.",
                            species))  -- unified with the drop-spot reject (one message for "not grazeable grass", regardless of which check tripped)
                    return
                end
            end
        end
    end

    -- Per-drop: only the first (oldest) pocketed herd is released this press,
    -- so size the field for that one herd, not the whole pocket.
    local totalAnimalCount = firstPending.animalCount

    local MIN_AREA_PER_ANIMAL = 25
    if not isPastureDestination and fieldContour ~= nil and #fieldContour >= 3 then
        local area = 0
        local n = #fieldContour
        for i = 1, n do
            local j = (i % n) + 1
            area = area + (fieldContour[i].x * fieldContour[j].z)
            area = area - (fieldContour[j].x * fieldContour[i].z)
        end
        area = math.abs(area) / 2
        local requiredArea = totalAnimalCount * MIN_AREA_PER_ANIMAL
        dbgLog("TPAB-RL: Field area=%.0f sqm, required=%.0f sqm (%d animals total across %d pending herd(s) x %d sqm)",
            area, requiredArea, totalAnimalCount, #pendings, MIN_AREA_PER_ANIMAL)
        if area < requiredArea then
            dbgLog("TPAB-RL: Field too small: %.0f sqm for %d animals (need %.0f sqm)",
                area, totalAnimalCount, requiredArea)
            ToPastureAndBack_RL.showRefusal(
                string.format(g_i18n:getText("tpab_field_too_small") or "This field is too small for %d animals. Find a larger pasture.", totalAnimalCount))
            return
        end
    end

    -- All validation passed. Reserve ONE pasture point for the whole batch.
    -- All sessions share pasturePointId; executeGrazingFromEvent dedupes so the point is created exactly once.
    local pasturePointId = ToPastureAndBack_RL.nextPastureId
    ToPastureAndBack_RL.nextPastureId = pasturePointId + 1
    local pasturePointName = string.format("Pasture %d", pasturePointId)

    local eventFarmlandId = 0
    if fieldData ~= nil and fieldData.farmlandId ~= nil and fieldData.farmlandId > 0 then
        eventFarmlandId = fieldData.farmlandId
    elseif farmlandId ~= nil and farmlandId > 0 then
        eventFarmlandId = farmlandId
    end

    local destY = getTerrainHeightAtWorldPos(terrainNode, herdX, 0, herdZ)
    local pastureDestName = isPastureDestination and matchedPastureData and matchedPastureData.name or nil

    dbgLog("TPAB-RL: Per-drop: releasing 1 of %d pocketed herd(s) at pasture point %d (%s)",
        #pendings, pasturePointId, pasturePointName)

    -- Mixed-batch detection: 2+ distinct animalTypes among pendings (always grazer-only since
    -- class_mismatch blocks pigs from mixing). Used by executeGrazingFromEvent to render one
    -- "mixed herd is now grazing" umbrella instead of N per-session messages.
    -- Mixed = any time 2+ herds are queued. Base game animalType is too coarse
    -- (cow + water buffalo both report "COW" so a per-animalType comparison
    -- never catches that case). Treat any multi-herd send as a "mixed herd"
    -- for messaging purposes.
    -- Per-drop: single herd this press, so no mixed/umbrella messaging.
    local batchIsMixed = false
    local batchSize = 1
    local droppedSessionId = nil  -- captured for the combined-message suppress

    -- Release only the NEXT (oldest) pocketed herd at this spot.
    do
        local batchIndex = 1
        local pending = pendings[1]
        local barnWorldX, barnWorldZ = 0, 0
        local bx, bz = ToPastureAndBack_RL.getBarnCachePos(pending.barnData)  -- wire/key position, NOT getBarnAnchorPos
        if bx ~= nil then
            barnWorldX, barnWorldZ = bx, bz
        end

        local barnName = pending.barnName or pending.barnData.name
        local sessionId = string.format("%s_%d_%d", pending.animalType, pasturePointId, math.random(10000, 99999))
        droppedSessionId = sessionId

        local eventData = {
            barnWorldX = barnWorldX,
            barnWorldZ = barnWorldZ,
            barnName = barnName,
            destX = herdX,
            destZ = herdZ,
            destY = destY,
            fieldContour = fieldContour,
            fieldRadius = fieldRadius,
            animalType = pending.animalType,
            animalCount = pending.animalCount,
            animalAge = pending.animalAge or 36,
            suppressYoungKept = (pending.fieldOrigin ~= nil) or nil,  -- relocate: young already left behind at the first barn send
            durationHours = 0,
            farmlandId = eventFarmlandId,
            sessionId = sessionId,
            pasturePointId = pasturePointId,
            pasturePointName = pasturePointName,
            isPastureDestination = isPastureDestination,
            pastureDestName = pastureDestName,
            batchInfo = {
                size = batchSize,
                index = batchIndex,
                isMixed = batchIsMixed,
                isLast = (batchIndex == batchSize),
            },
        }

        dbgLog("TPAB-RL: Sending SendToPastureEvent for session %s: %d %s from %s to (%.1f,%.1f)",
            sessionId, pending.animalCount, pending.animalType, barnName, herdX, herdZ)
        ToPastureAndBack_RL.sendEvent(SendToPastureEvent.new(eventData))
    end

    -- Per-drop: remove only the herd we just released; keep the rest pocketed.
    -- Do NOT call clearPendingGrazings (it broadcasts an unlock for every
    -- remaining barn). The released herd lock auto-clears in
    -- executeGrazingFromEvent when its session takes over.
    -- Capture the herd we just released (still pendings[1] until table.remove)
    -- so its drop confirmation can be rebuilt for the combined message below.
    local dropped = pendings[1]
    local runWasMulti = ToPastureAndBack_RL.runWasMultiHerd or false
    table.remove(ToPastureAndBack_RL.pendingGrazings, 1)
    local remaining = #ToPastureAndBack_RL.pendingGrazings
    -- cert 2026-07-07 symptom A (M1): remember where THIS peer dropped a herd so
    -- the next drop of the same run detects the shared farmland even before our
    -- own SendToPastureEvent round-trips back as a session.
    if eventFarmlandId ~= nil and eventFarmlandId > 0 then
        ToPastureAndBack_RL.recentDropFarmlands[eventFarmlandId] = true
    end
    if remaining == 0 then
        ToPastureAndBack_RL.pendingClass = nil
        ToPastureAndBack_RL.runWasMultiHerd = false
        ToPastureAndBack_RL.recentDropFarmlands = {}  -- end of run (M1)
    end

    -- Status line for the combined message on THIS peer:
    --   remaining > 0           -> "still transporting N" reminder
    --   remaining == 0 + multi  -> "that was the last herd" closing line
    --   remaining == 0 + single -> no status line (plain confirmation only)
    local statusLine = nil
    if remaining > 0 then
        statusLine = string.format(
            ToPastureAndBack_RL.textN("tpab_drop_more", remaining,
                "You are still transporting %d more herds. Press %s to drop the next one here, or take them to another field.",
                "You are still transporting %d more herd. Press %s to drop it here, or take it to another field."),
            remaining, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
    elseif runWasMulti then
        statusLine = g_i18n:getText("tpab_drop_last")
            or "That was the last herd. You are no longer transporting any animals for this pasture run."
    end

    if statusLine ~= nil then
        -- The renderer shows only the newest queued message, so the drop
        -- confirmation and the status line must be ONE message. Rebuild the
        -- same confirmation line a single drop shows, append the status line,
        -- and suppress the duplicate networked grazing message on THIS peer
        -- (keyed by sessionId) so a co-op partner still gets the plain one.
        ToPastureAndBack_RL.suppressLocalGrazingMsgFor = droppedSessionId
        local dPlaceable = dropped.barnData and dropped.barnData.placeable or nil
        local dFarm = ""
        if pastureDestName ~= nil and pastureDestName ~= "" then
            if eventFarmlandId ~= nil and eventFarmlandId > 0 then
                dFarm = string.format(ToPastureAndBack_RL.placeFmt("at_farmland"), pastureDestName, eventFarmlandId)
            else
                dFarm = string.format(ToPastureAndBack_RL.placeFmt("at"), pastureDestName)
            end
        elseif eventFarmlandId ~= nil and eventFarmlandId > 0 then
            dFarm = string.format(ToPastureAndBack_RL.placeFmt("farmland"), eventFarmlandId)
        end
        local dSpecies = ToPastureAndBack_RL.getSpeciesNoun(dropped.animalType, dPlaceable)
        local dLine
        if ToPastureAndBack_RL.getAnimalFieldTier(dropped.animalType) == "forager" then
            dLine = string.format(ToPastureAndBack_RL.outText(g_i18n:getText("tpab_pig_now_foraging") or "Your %s from %s are now out%s.", dFarm),
                dSpecies, dropped.barnName, dFarm)
        else
            local dVerb = ToPastureAndBack_RL.getSpeciesVerb(dropped.animalType, "be", dPlaceable)
            local dPoss = ToPastureAndBack_RL.getSpeciesPossessive(dropped.animalType, dPlaceable)
            dLine = string.format(ToPastureAndBack_RL.outText(g_i18n:getText("tpab_now_grazing") or "%s %s from %s %s now out%s.", dFarm),
                dPoss, dSpecies, dropped.barnName, dVerb, dFarm)
        end
        ToPastureAndBack_RL.showModInitiatedMessage(dLine .. "\n" .. statusLine)
    end
end


-- ============================================================================
-- Multiplayer event dispatch and execution
-- ============================================================================

--- Send a TPAB event to server (if client) or execute + broadcast (if server).
-- broadcastEvent only sends to connected clients, it does NOT call run() on the
-- server itself. So when we are the server, we must execute locally too.
function ToPastureAndBack_RL.sendEvent(event)
    if g_server ~= nil then
        -- We are the server (or single-player): execute locally + broadcast to clients
        g_server:broadcastEvent(event)
        event:run(nil)
    else
        -- We are a client: send to server for validation and broadcast
        g_client:getServerConnection():sendEvent(event)
    end
end

--- Find a barn data entry by world position (for multiplayer event execution).
-- Same tolerance as save/load reconstruction (20m).
-- @param animalType string e.g. "COW"
-- @param barnWorldX number Barn nav node world X
-- @param barnWorldZ number Barn nav node world Z
-- @return table|nil Barn data table from barnCache, or nil
function ToPastureAndBack_RL.findBarnDataByPosition(animalType, barnWorldX, barnWorldZ)
    local candidates = ToPastureAndBack_RL.getAllBarnsForType(animalType)
    if candidates == nil or #candidates == 0 then return nil end

    local bestBarn = nil
    local bestDist = 20  -- 20m tolerance

    for _, barn in ipairs(candidates) do
        local bx, bz = ToPastureAndBack_RL.getBarnCachePos(barn)  -- wire/key match, NOT getBarnAnchorPos
        if bx ~= nil then
            local dx = bx - barnWorldX
            local dz = bz - barnWorldZ
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < bestDist then
                bestDist = dist
                bestBarn = barn
            end
        end
    end

    return bestBarn
end

--- Execute a grazing session from event data (called on all clients after broadcast).
-- Creates the pasture point, session, and queues spawn. Each client executes independently.
-- If the barn cache isn't ready yet (client still loading), queues the event for later.
-- @param data table Event data with all fields from SendToPastureEvent
function ToPastureAndBack_RL.executeGrazingFromEvent(data)
    -- If barn cache isn't ready, queue this event for processing after barn scan.
    -- This happens when the server broadcasts reconstructed sessions to a client
    -- that hasn't finished its own initialization yet (~frame 350).
    if not ToPastureAndBack_RL.barnCacheReady then
        dbgLog("TPAB-RL: Barn cache not ready, queuing event for session %s", data.sessionId)
        table.insert(ToPastureAndBack_RL.pendingEventQueue, data)
        return
    end

    -- Check if this session already exists (server may have created it via reconstruction
    -- before the broadcast arrives back; avoid duplicate sessions)
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if session.id == data.sessionId then
            dbgLog("TPAB-RL: executeGrazingFromEvent: session %s already exists, skipping", data.sessionId)
            return
        end
    end

    -- Find the barn on this client by position matching
    local barnData = ToPastureAndBack_RL.findBarnDataByPosition(data.animalType, data.barnWorldX, data.barnWorldZ)
    if barnData == nil then
        Logging.warning("TPAB-RL: executeGrazingFromEvent: no barn found near (%.1f, %.1f) for %s",
            data.barnWorldX, data.barnWorldZ, data.animalType)
        return
    end

    -- 2026-05-11 MP duplicate-barn safeguard. Two players can independently pend
    -- the same barn (each holds a local pendingGrazings entry; neither knows
    -- about the other's selection). If both press RCtrl+G, two SendToPastureEvents
    -- arrive at the server, and without this guard each one spawns a separate
    -- grazing session from the same cluster, doubling the animals back into
    -- the barn on recall. Repro 2026-05-11 23:08 on Pichonniere Milk Cow Barn.
    -- Skip silently here (no message) because the player who lost the race
    -- already saw "Your X is now grazing" on their screen; the second event
    -- just no-ops on the wire. Pasture-point and session aren't created, so
    -- no orphan state.
    for _, existing in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if existing.barnPlaceable == barnData.placeable and existing.spawnState ~= "done" then
            Logging.warning("TPAB-RL: executeGrazingFromEvent: barn %s already has active session %s, rejecting duplicate %s (MP race)",
                data.barnName or "?", existing.id, data.sessionId)
            return
        end
    end

    -- 2026-05-11 MP: clear the pending-barn lock locally on every peer as the
    -- active session takes over as authoritative state.
    -- 2026-07-01: clear by PROXIMITY, not exact key (a freshly placed barn nav node can
    -- move between apply and here, leaking the lock and later stranding a relocated herd).
    if data.barnWorldX ~= nil and data.barnWorldZ ~= nil then
        local CLEAR_R2 = 15 * 15
        for _k, _lk in pairs(ToPastureAndBack_RL.remotePendingLocks) do
            if _lk.x ~= nil and _lk.z ~= nil then
                local _dx = _lk.x - data.barnWorldX
                local _dz = _lk.z - data.barnWorldZ
                if _dx * _dx + _dz * _dz <= CLEAR_R2 then
                    -- cert 2026-07-07 (M6): with two barns near each other, the 15m
                    -- proximity clear could wipe the ADJACENT barn's live lock. Only
                    -- clear when the nearest cached barn to the lock position IS the
                    -- sending barn's placeable, OR no cached barn exists within 20m
                    -- of the lock (stale ghost lock on a moved/fresh barn nav node,
                    -- keeps the Riverbend 2026-07-01 fix working).
                    local _nearestP = ToPastureAndBack_RL.findNearestCachedBarnPlaceable(_lk.x, _lk.z, 20)
                    if _nearestP == nil or _nearestP == barnData.placeable then
                        dbgLog("TPAB-RL: Pending lock auto-cleared (%.1fm from send) on session creation %s",
                            math.sqrt(_dx * _dx + _dz * _dz), data.sessionId)
                        ToPastureAndBack_RL.remotePendingLocks[_k] = nil
                    else
                        dbgLog("TPAB-RL: Pending lock at %s kept, nearest cached barn to it is not the sending barn (M6)", _k)
                    end
                end
            end
        end
    end

    -- Find existing pasture point with this ID (multi-herd batch shares one point), or create.
    local point = nil
    for _, existing in ipairs(ToPastureAndBack_RL.pasturePoints) do
        if existing.id == data.pasturePointId then
            point = existing
            break
        end
    end
    if point == nil then
        local terrainNode = g_currentMission.terrainRootNode
        local destY = getTerrainHeightAtWorldPos(terrainNode, data.destX, 0, data.destZ)
        point = ToPastureAndBack_RL.createPasturePoint(
            data.pasturePointId, data.destX, destY, data.destZ, data.fieldRadius, data.pasturePointName)
        point.fieldContour = data.fieldContour
        table.insert(ToPastureAndBack_RL.pasturePoints, point)
    end

    -- Update nextPastureId if needed
    if data.pasturePointId >= ToPastureAndBack_RL.nextPastureId then
        ToPastureAndBack_RL.nextPastureId = data.pasturePointId + 1
    end

    -- RL: Fetch individual animal list locally (can't serialize Animal objects over the network).
    -- Each client independently reads the same barn's RL animals.
    local rlAnimals = ToPastureAndBack_RL.getRLAnimalsFromBarn(barnData.placeable)

    -- Filter young animals (species minimum age, same as startPendingGrazingForBarn)
    local MIN_GRAZING_AGE = ToPastureAndBack_RL.getMinGrazingAge(data.animalType)
    local totalBeforeFilter = #rlAnimals
    local filtered = {}
    for _, animal in ipairs(rlAnimals) do
        if animal:getAge() >= MIN_GRAZING_AGE then
            table.insert(filtered, animal)
        end
    end
    rlAnimals = filtered
    local youngKept = totalBeforeFilter - #rlAnimals

    dbgLog("TPAB-RL: executeGrazingFromEvent: fetched %d RL animals from barn (after age filter, %d young kept)", #rlAnimals, youngKept)

    -- Create the grazing session (spawns via state machine in update())
    local session = ToPastureAndBack_RL.createGrazingSession(
        barnData.placeable,
        data.barnName,
        point,
        data.animalType,
        data.animalCount,
        data.durationHours,
        data.animalAge,
        rlAnimals
    )
    session.id = data.sessionId  -- use the session ID from the event (consistent across clients)
    session.farmlandId = data.farmlandId
    session.isPastureDestination = data.isPastureDestination or false
    session.pastureDestName = data.pastureDestName
    -- 2026-05-05 night: cache pasture barn entry by herd-center proximity.
    -- processSpawn used to re-query findPastureAtPosition with these coords,
    -- but tight tests reject the barn's own nav (= building center, OUTSIDE
    -- yard ring) for L-shaped yards. Pichonniere log evidence 2026-05-05.
    if session.isPastureDestination then
        local pastureBarn = ToPastureAndBack_RL.findBarnDataByPosition(
            data.animalType, data.destX, data.destZ)
        if pastureBarn ~= nil then
            session.pastureBarnData = pastureBarn
        else
            Logging.warning(
                "TPAB-RL: executeGrazingFromEvent: no pasture barn near (%.1f, %.1f) for session %s",
                data.destX, data.destZ, data.sessionId)
        end
    end
    table.insert(ToPastureAndBack_RL.grazingSessions, session)

    dbgLog("TPAB-RL: Grazing started from event! Session %s: %d %s from %s to %s",
        session.id, data.animalCount, data.animalType, data.barnName, point.name)

    -- HUD message (pig-specific wording: "foraging" instead of "grazing")
    local farmlandLabel = ""
    if data.pastureDestName ~= nil and data.pastureDestName ~= "" then
        if data.farmlandId ~= nil and data.farmlandId > 0 then
            farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at_farmland"), data.pastureDestName, data.farmlandId)
        else
            farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at"), data.pastureDestName)
        end
    elseif data.farmlandId ~= nil and data.farmlandId > 0 then
        farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("farmland"), data.farmlandId)
    end
    local tier = ToPastureAndBack_RL.getAnimalFieldTier(data.animalType)
    local species = ToPastureAndBack_RL.getSpeciesNoun(data.animalType, barnData.placeable)
    local grazingMsg
    if tier == "forager" then
        grazingMsg = string.format(
            ToPastureAndBack_RL.outText(g_i18n:getText("tpab_pig_now_foraging") or "Your %s from %s are now out%s.", farmlandLabel),
            species, data.barnName, farmlandLabel)
    else
        local grazingVerb = ToPastureAndBack_RL.getSpeciesVerb(data.animalType, "be", session)
        local grazingPoss = ToPastureAndBack_RL.getSpeciesPossessive(data.animalType, session)
        grazingMsg = string.format(
            ToPastureAndBack_RL.outText(g_i18n:getText("tpab_now_grazing") or "%s %s from %s %s now out%s.", farmlandLabel),
            grazingPoss, species, data.barnName, grazingVerb, farmlandLabel)
    end
    if youngKept > 0 and not data.suppressYoungKept then
        grazingMsg = grazingMsg .. "\n" .. string.format(
            ToPastureAndBack_RL.textN("tpab_young_kept", youngKept, "%d young animals remained in %s, too young to leave the barn.",
                "%d young animal remained in %s, too young to leave the barn."),
            youngKept, data.barnName)
    end
    -- 2026-05-26: skip the on-screen message during the client sync grace
    -- window. Per-session messages spammed by SyncRequest responses
    -- (when a client late-joins a host with active sessions) overwrote
    -- each other in the message queue and left the player believing only
    -- ONE herd was out when multiple were. After sync grace expires, a
    -- single summary message fires in the update loop instead.
    if ToPastureAndBack_RL.clientSyncInProgress then
        return
    end
    if data.batchInfo ~= nil and data.batchInfo.isMixed then
        if data.batchInfo.isLast then
            grazingMsg = string.format(
                ToPastureAndBack_RL.outText(g_i18n:getText("tpab_mixed_now_grazing") or "Your mixed herd is now out%s.", farmlandLabel),
                farmlandLabel)
            ToPastureAndBack_RL.showMessage(grazingMsg, nil, ToPastureAndBack_RL.farmOfPlaceable(barnData.placeable))
        end
        return
    end
    if ToPastureAndBack_RL.suppressLocalGrazingMsgFor ~= nil and ToPastureAndBack_RL.suppressLocalGrazingMsgFor == data.sessionId then
        -- Per-drop on this peer shows a combined confirmation+reminder instead.
        ToPastureAndBack_RL.suppressLocalGrazingMsgFor = nil
    else
        ToPastureAndBack_RL.showMessage(grazingMsg, nil, ToPastureAndBack_RL.farmOfPlaceable(barnData.placeable))
    end
end

--- Execute a recall from event data (called on all clients after broadcast).
-- @param sessionIds string Comma-separated session IDs or "ALL"
-- @param suppressMessage boolean If true, do NOT call showMessage at the end
--   (used by curfew flow so the herdsman umbrella message wins on screen).
function ToPastureAndBack_RL.executeRecallFromEvent(sessionIds, suppressMessage, isCurfewFlow, keepBarnSuppressed)
    local recallAll = (sessionIds == "ALL")
    local idSet = {}
    if not recallAll then
        for id in string.gmatch(sessionIds, "[^,]+") do
            idSet[id] = true
        end
    end

    local count = 0
    local recallMessages = {}
    local mineCount = 0
    for i = #ToPastureAndBack_RL.grazingSessions, 1, -1 do
        local session = ToPastureAndBack_RL.grazingSessions[i]
        if recallAll or idSet[session.id] then
            local mineForMsg = ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfSession(session))
            if mineForMsg then mineCount = mineCount + 1 end
            -- Build recall message
            local recallBarnName = session.barnName or "barn"
            if session.barnPlaceable ~= nil and session.barnPlaceable.getName ~= nil then
                local ok, fresh = ToPastureAndBack_RL.fcall(session.barnPlaceable.getName, session.barnPlaceable)
                if ok and fresh ~= nil then recallBarnName = fresh end
            end
            local farmlandLabel = ""
            if session.pastureDestName ~= nil and session.pastureDestName ~= "" then
                if session.farmlandId ~= nil and session.farmlandId > 0 then
                    farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at_farmland"), session.pastureDestName, session.farmlandId)
                else
                    farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at"), session.pastureDestName)
                end
            elseif session.farmlandId ~= nil and session.farmlandId > 0 then
                farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("farmland"), session.farmlandId)
            end
            local recallSpecies = ToPastureAndBack_RL.getSpeciesNoun(session.animalType, session)
            local recallVerb = ToPastureAndBack_RL.getSpeciesVerb(session.animalType, "be", session)
            local recallPoss = ToPastureAndBack_RL.getSpeciesPossessive(session.animalType, session)
            table.insert(recallMessages, string.format(
                g_i18n:getText("tpab_recall_returned") or "%s %s%s %s back at %s.",
                recallPoss, recallSpecies, farmlandLabel, recallVerb, recallBarnName))
            if not mineForMsg then table.remove(recallMessages) end  -- another farm's herd: no message here

            ToPastureAndBack_RL.cleanupSession(session, keepBarnSuppressed)
            -- Remove associated pasture point
            for j = #ToPastureAndBack_RL.pasturePoints, 1, -1 do
                if ToPastureAndBack_RL.pasturePoints[j] == session.pasturePoint then
                    table.remove(ToPastureAndBack_RL.pasturePoints, j)
                    dbgLog("TPAB-RL: Removed pasture point %s on recall", session.pasturePoint.name)
                    break
                end
            end
            count = count + 1
        end
    end

    dbgLog("TPAB-RL: Recalled %d session(s) from event, cleared pasture points (suppress=%s isCurfew=%s)",
        count, tostring(suppressMessage), tostring(isCurfewFlow))
    if suppressMessage then
        -- 2026-05-11: only show the herdsman/curfew umbrella message when
        -- the flow is genuinely the 22:00 curfew. Move-herd also uses
        -- suppressMessage=true (to silence the per-session "is back at
        -- barn" message because it shows its own composite "picked up
        -- from pasture" message), and previously the herdsman line
        -- fired in the middle of the day during move-herd. Now gated
        -- on isCurfewFlow.
        if isCurfewFlow and mineCount > 0 then
            ToPastureAndBack_RL.showModInitiatedMessage(g_i18n:getText("tpab_curfew_recall_msg"))
        end
    else
        if #recallMessages == 1 then
            ToPastureAndBack_RL.showMessage(recallMessages[1])
        elseif #recallMessages > 1 then
            ToPastureAndBack_RL.showMessage(g_i18n:getText("tpab_all_returned") or "All herds have returned to their barns.")
        end
    end
end

--- Execute a pasture point removal from event data (called on all clients after broadcast).
-- @param pasturePointId number ID of point to remove, or -1 for all
function ToPastureAndBack_RL.executeRemovePastureFromEvent(pasturePointId)
    if pasturePointId == -1 then
        -- Remove all: clean up sessions first, then all points
        local count = #ToPastureAndBack_RL.pasturePoints
        if count == 0 then return end

        local anyMine = false
        for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfSession(session)) then anyMine = true end
            ToPastureAndBack_RL.cleanupSession(session)
        end
        ToPastureAndBack_RL.grazingSessions = {}
        ToPastureAndBack_RL.pasturePoints = {}

        dbgLog("TPAB-RL: Removed all %d pasture marker(s) from event", count)
        if anyMine then
            ToPastureAndBack_RL.showMessage(g_i18n:getText("tpab_all_returning") or "All herds are returning to their barns.")
        end
    else
        -- Remove specific point by ID
        for i, point in ipairs(ToPastureAndBack_RL.pasturePoints) do
            if point.id == pasturePointId then
                -- Check if any session uses this point, recall it first
                local removeBarnName = nil
                local removeFarmlandId = nil
                local removeAnimalType = nil
                local removeBarnPlaceable = nil
                for j = #ToPastureAndBack_RL.grazingSessions, 1, -1 do
                    local session = ToPastureAndBack_RL.grazingSessions[j]
                    if session.pasturePoint ~= nil and session.pasturePoint.id == pasturePointId then
                        removeFarmlandId = session.farmlandId
                        removeAnimalType = session.animalType
                        removeBarnPlaceable = session.barnPlaceable
                        if session.barnPlaceable ~= nil and session.barnPlaceable.getName ~= nil then
                            local ok, fresh = ToPastureAndBack_RL.fcall(session.barnPlaceable.getName, session.barnPlaceable)
                            if ok and fresh ~= nil then removeBarnName = fresh end
                        end
                        if removeBarnName == nil then removeBarnName = session.barnName end
                        ToPastureAndBack_RL.cleanupSession(session)
                    end
                end

                table.remove(ToPastureAndBack_RL.pasturePoints, i)
                dbgLog("TPAB-RL: Removed pasture marker %s from event", point.name)
                do
                    local removeSpecies = ToPastureAndBack_RL.getSpeciesNoun(removeAnimalType, removeBarnPlaceable)
                    local removeMsg
                    local removeVerb = ToPastureAndBack_RL.getSpeciesVerb(removeAnimalType, "return_present", removeBarnPlaceable)
                    local removePoss = ToPastureAndBack_RL.getSpeciesPossessive(removeAnimalType, removeBarnPlaceable)
                    if removeFarmlandId ~= nil and removeFarmlandId > 0 and removeBarnName ~= nil then
                        removeMsg = string.format(
                            ToPastureAndBack_RL.farmText(g_i18n:getText("tpab_returning_to_barn") or "%s %s on {farmland} %d %s back to %s."),
                            removePoss, removeSpecies, removeFarmlandId, removeVerb, removeBarnName)
                    else
                        removeMsg = string.format(
                            g_i18n:getText("tpab_returning_home") or "%s %s on %s %s home.",
                            removePoss, removeSpecies, point.name, removeVerb)
                    end
                    ToPastureAndBack_RL.showMessage(removeMsg, nil, ToPastureAndBack_RL.farmOfPlaceable(removeBarnPlaceable))
                end
                break
            end
        end
    end
end


-- ============================================================================
-- XML save/load
-- ============================================================================

--- Get the savegame XML file path for this mod.
-- @return string Full path to FS25_ToPastureAndBack_RL.xml in the savegame folder
function ToPastureAndBack_RL.getSavePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        return nil
    end
    return savegameDir .. "/FS25_ToPastureAndBack_RL.xml"
end

--- Get the settings XML file path (separate from session data).
-- @return string Full path to FS25_ToPastureAndBack_settings.xml in the savegame folder
function ToPastureAndBack_RL.getSettingsPath()
    -- 2026-05-25: switched from per-savegame path to per-mod-per-user path.
    -- Previously wrote to savegameDirectory/FS25_ToPastureAndBack_RL_settings.xml, which on a MP
    -- client wiped on every reconnect (FS25 re-syncs the server's savegame
    -- snapshot into the client's local savegame0/ directory, overwriting any
    -- mod-written files there). the MP client's slider reverted to Auto on every
    -- rejoin even after a confirmed save. Mirror RL's pattern: use
    -- g_currentModSettingsDirectory, which lives under
    -- Documents/My Games/FarmingSimulator2025/modSettings/<modName>/ and is
    -- not touched by savegame sync. Side effect: settings are now per-user
    -- (apply across all savegames) instead of per-savegame.
    -- Use the value captured at file scope, NOT the live global (see comment
    -- on ToPastureAndBack_RL.modSettingsDirectory above).
    if ToPastureAndBack_RL.modSettingsDirectory == nil then return nil end
    return ToPastureAndBack_RL.modSettingsDirectory .. "FS25_ToPastureAndBack_RL_settings.xml"
end

--- Legacy per-savegame settings path. Read-only, kept for one-time migration
--- from pre-2026-05-25 saves where settings lived under savegameDirectory.
function ToPastureAndBack_RL.getLegacySettingsPath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        return nil
    end
    return savegameDir .. "/FS25_ToPastureAndBack_RL_settings.xml"
end

--- Load settings from XML. Falls back to defaults if file doesn't exist.
function ToPastureAndBack_RL.loadSettings()
    local path = ToPastureAndBack_RL.getSettingsPath()
    if path == nil then
        dbgLog("TPAB-RL: No mod settings path available, using defaults")
        return
    end

    local migratedFromLegacy = false
    if not fileExists(path) then
        -- One-time migration from pre-2026-05-25 per-savegame settings path.
        -- If the new mod-settings file doesn't exist yet but the legacy file
        -- does (in this savegame's dir), load from legacy and re-save to the
        -- new path at the end so the user's preferences carry over silently.
        local legacyPath = ToPastureAndBack_RL.getLegacySettingsPath()
        if legacyPath ~= nil and fileExists(legacyPath) then
            dbgLog("TPAB-RL: Migrating settings from legacy per-savegame path %s", legacyPath)
            path = legacyPath
            migratedFromLegacy = true
        else
            dbgLog("TPAB-RL: No settings file found, using defaults (auto-recall: Off)")
            return
        end
    end

    local xmlId = loadXMLFile("ToPastureAndBackRLSettings", path)
    if xmlId == nil or xmlId == 0 then
        Logging.warning("TPAB-RL: Failed to load settings from %s, using defaults", path)
        return
    end

    -- New settings: try to load directly
    local actionMsgs = getXMLInt(xmlId, "ToPastureAndBackRLSettings#actionMessagesIndex")
    if actionMsgs ~= nil and actionMsgs >= 1 and actionMsgs <= #ToPastureAndBack_RL.ACTION_MSGS_OPTIONS then
        ToPastureAndBack_RL.settings.actionMessagesIndex = actionMsgs
    else
        -- Migration: try old msgShowIndex and apply to both new settings
        local msgShow = getXMLInt(xmlId, "ToPastureAndBackRLSettings#msgShowIndex")
        if msgShow ~= nil and msgShow >= 1 then
            ToPastureAndBack_RL.settings.actionMessagesIndex = msgShow
            ToPastureAndBack_RL.settings.duskReminderIndex = msgShow
        end
    end

    local duskReminder = getXMLInt(xmlId, "ToPastureAndBackRLSettings#duskReminderIndex")
    if duskReminder ~= nil and duskReminder >= 1 and duskReminder <= #ToPastureAndBack_RL.DUSK_REMINDER_OPTIONS then
        ToPastureAndBack_RL.settings.duskReminderIndex = duskReminder
    end

    local msgSize = getXMLInt(xmlId, "ToPastureAndBackRLSettings#msgSizeIndex")
    if msgSize ~= nil and msgSize >= 1 and msgSize <= #ToPastureAndBack_RL.MSG_SIZE_OPTIONS then
        ToPastureAndBack_RL.settings.msgSizeIndex = msgSize
    end

    -- Color, position, background and warning style are stored as ids (message standard 2026-10-11).
    -- A file from v1.0.0.0 only has the old list indices, which are translated once here.
    local function idIndex(list, id)
        for k, v in ipairs(list) do
            if v == id then return k end
        end
        return nil
    end
    local colorIdx = idIndex(ToPastureAndBack_RL.MSG_COLOR_IDS, getXMLString(xmlId, "ToPastureAndBackRLSettings#msgColor"))
    if colorIdx == nil then
        local legacy = getXMLInt(xmlId, "ToPastureAndBackRLSettings#msgColorIndex")
        if legacy ~= nil and ToPastureAndBack_RL.MSG_COLOR_LEGACY[legacy] ~= nil then
            colorIdx = idIndex(ToPastureAndBack_RL.MSG_COLOR_IDS, ToPastureAndBack_RL.MSG_COLOR_LEGACY[legacy])
            dbgLog("TPAB-RL: message color migrated from old index %d to '%s'", legacy, tostring(ToPastureAndBack_RL.MSG_COLOR_IDS[colorIdx]))
        end
    end
    if colorIdx ~= nil then ToPastureAndBack_RL.settings.msgColorIndex = colorIdx end

    local posIdx = idIndex(ToPastureAndBack_RL.MSG_POSITION_IDS, getXMLString(xmlId, "ToPastureAndBackRLSettings#msgPosition"))
    if posIdx == nil then
        local legacy = getXMLInt(xmlId, "ToPastureAndBackRLSettings#msgPositionIndex")
        if legacy ~= nil and ToPastureAndBack_RL.MSG_POSITION_LEGACY[legacy] ~= nil then
            posIdx = idIndex(ToPastureAndBack_RL.MSG_POSITION_IDS, ToPastureAndBack_RL.MSG_POSITION_LEGACY[legacy])
            dbgLog("TPAB-RL: message position migrated from old index %d to '%s'", legacy, tostring(ToPastureAndBack_RL.MSG_POSITION_IDS[posIdx]))
        end
    end
    if posIdx ~= nil then ToPastureAndBack_RL.settings.msgPositionIndex = posIdx end

    local poultryIdx = idIndex(ToPastureAndBack_RL.POULTRY_CAP_IDS, getXMLString(xmlId, "ToPastureAndBackRLSettings#poultryCap"))
    if poultryIdx ~= nil then ToPastureAndBack_RL.settings.poultryCapIndex = poultryIdx end

    local bgIdx = idIndex(ToPastureAndBack_RL.MSG_BG_IDS, getXMLString(xmlId, "ToPastureAndBackRLSettings#msgBackground"))
    if bgIdx ~= nil then ToPastureAndBack_RL.settings.msgBackgroundIndex = bgIdx end
    local warnIdx = idIndex(ToPastureAndBack_RL.WARN_STYLE_IDS, getXMLString(xmlId, "ToPastureAndBackRLSettings#warnStyle"))
    if warnIdx ~= nil then ToPastureAndBack_RL.settings.warnStyleIndex = warnIdx end

    local confirmRecall = getXMLInt(xmlId, "ToPastureAndBackRLSettings#confirmRecallIndex")
    if confirmRecall ~= nil and confirmRecall >= 1 and confirmRecall <= #ToPastureAndBack_RL.CONFIRM_RECALL_OPTIONS then
        ToPastureAndBack_RL.settings.confirmRecallIndex = confirmRecall
    end

    local curfew = getXMLInt(xmlId, "ToPastureAndBackRLSettings#curfewIndex")
    if curfew ~= nil and curfew >= 1 and curfew <= #ToPastureAndBack_RL.CURFEW_OPTIONS then
        ToPastureAndBack_RL.settings.curfewIndex = curfew
    end

    local showFences = getXMLInt(xmlId, "ToPastureAndBackRLSettings#showFencesIndex")
    if showFences ~= nil and showFences >= 1 and showFences <= #ToPastureAndBack_RL.SHOW_FENCES_OPTIONS then
        ToPastureAndBack_RL.settings.showFencesIndex = showFences
    end

    delete(xmlId)

    dbgLog("TPAB-RL: Settings loaded: poultryCap=%s", tostring(ToPastureAndBack_RL.POULTRY_CAP_IDS[ToPastureAndBack_RL.settings.poultryCapIndex or 1]))
    dbgLog("TPAB-RL: Settings loaded: msgBg=%s, warnStyle=%s, msgSize=%d, msgColor=%d, msgPos=%d, actionMessages=%s, duskReminder=%s, curfew=%s",
        tostring(ToPastureAndBack_RL.MSG_BG_IDS[ToPastureAndBack_RL.settings.msgBackgroundIndex]), tostring(ToPastureAndBack_RL.WARN_STYLE_IDS[ToPastureAndBack_RL.settings.warnStyleIndex]),
        ToPastureAndBack_RL.settings.msgSizeIndex,
        ToPastureAndBack_RL.settings.msgColorIndex,
        ToPastureAndBack_RL.settings.msgPositionIndex,
        ToPastureAndBack_RL.ACTION_MSGS_OPTIONS[ToPastureAndBack_RL.settings.actionMessagesIndex] and "On" or "Off",
        ToPastureAndBack_RL.DUSK_REMINDER_OPTIONS[ToPastureAndBack_RL.settings.duskReminderIndex] and "On" or "Off",
        ToPastureAndBack_RL.CURFEW_OPTIONS[ToPastureAndBack_RL.settings.curfewIndex] and "On" or "Off")


    if migratedFromLegacy then
        ToPastureAndBack_RL.saveSettings()
        dbgLog("TPAB-RL: Legacy settings migration complete, settings now stored under g_currentModSettingsDirectory")
    end
end

--- Save settings to XML.
function ToPastureAndBack_RL.saveSettings()
    local path = ToPastureAndBack_RL.getSettingsPath()
    if path == nil then
        Logging.warning("TPAB-RL: Cannot determine modSettings path, skipping settings save")
        return
    end

    -- 2026-05-25 fix v3: FS25 does NOT auto-create the per-mod subdirectory
    -- under modSettings/. If it doesn't exist, createXMLFile succeeds (in-memory
    -- XML object) but saveXMLFile silently fails with no error return; the
    -- "Settings saved to ..." log line fires regardless because the code didn't
    -- check saveXMLFile's return value. createFolder is idempotent (no-op if
    -- the dir already exists), and matches the canonical pattern in gameSource
    -- dataS/scripts/vehicles/VehicleStateRecorder.lua. Without this call, fix v2
    -- produced a correct path but the file never landed on disk.
    if ToPastureAndBack_RL.modSettingsDirectory ~= nil then
        createFolder(ToPastureAndBack_RL.modSettingsDirectory)
    end

    local xmlId = createXMLFile("ToPastureAndBackRLSettings", path, "ToPastureAndBackRLSettings")
    if xmlId == nil or xmlId == 0 then
        Logging.warning("TPAB-RL: Failed to create settings XML: %s", tostring(path))
        return
    end

    setXMLInt(xmlId, "ToPastureAndBackRLSettings#msgSizeIndex", ToPastureAndBack_RL.settings.msgSizeIndex)
    setXMLString(xmlId, "ToPastureAndBackRLSettings#msgColor", ToPastureAndBack_RL.MSG_COLOR_IDS[ToPastureAndBack_RL.settings.msgColorIndex] or "white")
    setXMLString(xmlId, "ToPastureAndBackRLSettings#msgPosition", ToPastureAndBack_RL.MSG_POSITION_IDS[ToPastureAndBack_RL.settings.msgPositionIndex] or "middle")
    setXMLString(xmlId, "ToPastureAndBackRLSettings#msgBackground", ToPastureAndBack_RL.MSG_BG_IDS[ToPastureAndBack_RL.settings.msgBackgroundIndex] or "off")
    setXMLString(xmlId, "ToPastureAndBackRLSettings#warnStyle", ToPastureAndBack_RL.WARN_STYLE_IDS[ToPastureAndBack_RL.settings.warnStyleIndex] or "same")
    setXMLInt(xmlId, "ToPastureAndBackRLSettings#actionMessagesIndex", ToPastureAndBack_RL.settings.actionMessagesIndex)
    setXMLInt(xmlId, "ToPastureAndBackRLSettings#duskReminderIndex", ToPastureAndBack_RL.settings.duskReminderIndex)
    setXMLInt(xmlId, "ToPastureAndBackRLSettings#curfewIndex", ToPastureAndBack_RL.settings.curfewIndex)
    setXMLInt(xmlId, "ToPastureAndBackRLSettings#confirmRecallIndex", ToPastureAndBack_RL.settings.confirmRecallIndex or 2)
    setXMLInt(xmlId, "ToPastureAndBackRLSettings#showFencesIndex", ToPastureAndBack_RL.settings.showFencesIndex)
    setXMLString(xmlId, "ToPastureAndBackRLSettings#poultryCap", ToPastureAndBack_RL.POULTRY_CAP_IDS[ToPastureAndBack_RL.settings.poultryCapIndex or 1] or "same")

    saveXMLFile(xmlId)
    delete(xmlId)
    dbgLog("TPAB-RL: Settings saved to %s", path)
end

--- Build the in-game settings UI by cloning existing elements from the General Settings page.
-- Uses the same proven pattern as Realistic Livestock and MudSystem mods:
-- find existing UI template elements, clone them into the settings layout, customize.
-- Called once during loadMap. Hooks InGameMenuSettingsFrame.onFrameOpen to refresh state.
--- Remove the settings rows this mod cloned into the game's settings page. The page lives for the
--- whole game session, so a second savegame load used to append a second copy of the section.
--- delete(), not removeElement: delete also releases each element's focus registration.
function ToPastureAndBack_RL.teardownSettingsMenu()
    local built = ToPastureAndBack_RL._settingsBuilt
    if built ~= nil then
        for i = #built, 1, -1 do
            local el = built[i]
            if el ~= nil and el.delete ~= nil then el:delete() end
        end
    end
    ToPastureAndBack_RL._settingsBuilt = nil
end

function ToPastureAndBack_RL.buildSettingsMenu()
    -- Resolve the settings page and its layout container
    local inGameMenu = g_gui ~= nil and g_gui.screenControllers ~= nil
        and g_gui.screenControllers[InGameMenu] or nil
    if inGameMenu == nil or inGameMenu.pageSettings == nil then
        Logging.warning("TPAB-RL: [settings] InGameMenu.pageSettings unavailable, settings UI not built")
        return
    end

    local settingsPage = inGameMenu.pageSettings
    local settingsLayout = settingsPage.generalSettingsLayout or settingsPage.gameSettingsLayout
    if settingsLayout == nil then
        Logging.warning("TPAB-RL: [settings] No settings layout found on pageSettings, settings UI not built")
        return
    end

    -- One copy per game session: drop the rows an earlier savegame load added, then note what the
    -- layout holds so everything cloned below can be torn down again.
    ToPastureAndBack_RL.teardownSettingsMenu()
    local preexisting = {}
    for _, el in ipairs(settingsLayout.elements) do preexisting[el] = true end

    -- Find template elements to clone: a section header and a MultiTextOption wrapper.
    -- The layout contains Bitmap wrappers whose first child is the actual option element.
    local sectionHeaderTemplate = nil
    local multiOptionTemplate = nil

    for _, element in pairs(settingsLayout.elements) do
        if element.name == "sectionHeader" and sectionHeaderTemplate == nil then
            sectionHeaderTemplate = element
        end
        if element.typeName == "Bitmap" and element.elements ~= nil and #element.elements > 0 then
            if element.elements[1].typeName == "MultiTextOption" and multiOptionTemplate == nil then
                multiOptionTemplate = element
            end
        end
        if sectionHeaderTemplate ~= nil and multiOptionTemplate ~= nil then break end
    end

    if multiOptionTemplate == nil then
        Logging.warning("TPAB-RL: [settings] Could not find MultiTextOption template in settings layout")
        return
    end

    -- Clone section header for "To Pasture and Back" group
    if sectionHeaderTemplate ~= nil then
        local header = sectionHeaderTemplate:clone(settingsLayout)
        header:setText(g_i18n:getText("tpab_settings_header"))
    end

    -- ---- Action Messages toggle ----
    local actionMsgsBox = multiOptionTemplate:clone(settingsLayout)
    actionMsgsBox.id = "tpabActionMsgsBox"
    local actionMsgsOption, actionMsgsLabel = nil, nil
    for _, child in pairs(actionMsgsBox.elements) do
        if child.typeName == "MultiTextOption" then actionMsgsOption = child
        elseif child.typeName == "Text" then actionMsgsLabel = child end
    end
    if actionMsgsOption ~= nil then
        if actionMsgsLabel ~= nil then
            actionMsgsLabel:setText(g_i18n:getText("tpab_settings_action_msgs_label"))
            actionMsgsLabel.id = nil
        end
        if actionMsgsOption.elements ~= nil then
            for _, tc in pairs(actionMsgsOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, g_i18n:getText("tpab_settings_action_msgs_tooltip"))
                    break
                end
            end
        end
        local actionMsgsLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.ACTION_MSGS_KEYS) do
            table.insert(actionMsgsLabels, g_i18n:getText(key))
        end
        actionMsgsOption:setTexts(actionMsgsLabels)
        actionMsgsOption.id = "tpabActionMsgs"
        actionMsgsOption:setState(ToPastureAndBack_RL.settings.actionMessagesIndex)
        actionMsgsOption.target = ToPastureAndBack_RL
        actionMsgsOption:setCallback("onClickCallback", "onActionMessagesChanged")
        ToPastureAndBack_RL._settingsActionMsgs = actionMsgsOption
    end

    -- ---- Message Size dropdown ----
    local sizeBox = multiOptionTemplate:clone(settingsLayout)
    sizeBox.id = "tpabMsgSizeBox"
    local sizeOption, sizeLabel = nil, nil
    for _, child in pairs(sizeBox.elements) do
        if child.typeName == "MultiTextOption" then sizeOption = child
        elseif child.typeName == "Text" then sizeLabel = child end
    end
    if sizeOption ~= nil then
        if sizeLabel ~= nil then
            sizeLabel:setText(g_i18n:getText("tpab_settings_msg_size_label"))
            sizeLabel.id = nil
        end
        if sizeOption.elements ~= nil then
            for _, tc in pairs(sizeOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, g_i18n:getText("tpab_settings_msg_size_tooltip"))
                    break
                end
            end
        end
        local sizeLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.MSG_SIZE_KEYS) do
            table.insert(sizeLabels, g_i18n:getText(key))
        end
        sizeOption:setTexts(sizeLabels)
        sizeOption.id = "tpabMsgSize"
        sizeOption:setState(ToPastureAndBack_RL.settings.msgSizeIndex)
        sizeOption.target = ToPastureAndBack_RL
        sizeOption:setCallback("onClickCallback", "onMsgSizeChanged")
        ToPastureAndBack_RL._settingsMsgSize = sizeOption
    end

    -- ---- Message Color dropdown ----
    local colorBox = multiOptionTemplate:clone(settingsLayout)
    colorBox.id = "tpabMsgColorBox"
    local colorOption, colorLabel = nil, nil
    for _, child in pairs(colorBox.elements) do
        if child.typeName == "MultiTextOption" then colorOption = child
        elseif child.typeName == "Text" then colorLabel = child end
    end
    if colorOption ~= nil then
        if colorLabel ~= nil then
            colorLabel:setText(g_i18n:getText("tpab_settings_msg_color_label"))
            colorLabel.id = nil
        end
        if colorOption.elements ~= nil then
            for _, tc in pairs(colorOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, g_i18n:getText("tpab_settings_msg_color_tooltip"))
                    break
                end
            end
        end
        local colorLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.MSG_COLOR_KEYS) do
            table.insert(colorLabels, g_i18n:getText(key))
        end
        colorOption:setTexts(colorLabels)
        colorOption.id = "tpabMsgColor"
        colorOption:setState(ToPastureAndBack_RL.settings.msgColorIndex)
        colorOption.target = ToPastureAndBack_RL
        colorOption:setCallback("onClickCallback", "onMsgColorChanged")
        ToPastureAndBack_RL._settingsMsgColor = colorOption
    end

    -- ---- Message Position dropdown ----
    local positionBox = multiOptionTemplate:clone(settingsLayout)
    positionBox.id = "tpabMsgPositionBox"
    local positionOption, positionLabel = nil, nil
    for _, child in pairs(positionBox.elements) do
        if child.typeName == "MultiTextOption" then positionOption = child
        elseif child.typeName == "Text" then positionLabel = child end
    end
    if positionOption ~= nil then
        if positionLabel ~= nil then
            positionLabel:setText(g_i18n:getText("tpab_settings_msg_position_label"))
            positionLabel.id = nil
        end
        if positionOption.elements ~= nil then
            for _, tc in pairs(positionOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, g_i18n:getText("tpab_settings_msg_position_tooltip"))
                    break
                end
            end
        end
        local positionLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.MSG_POSITION_KEYS) do
            table.insert(positionLabels, g_i18n:getText(key))
        end
        positionOption:setTexts(positionLabels)
        positionOption.id = "tpabMsgPosition"
        positionOption:setState(ToPastureAndBack_RL.settings.msgPositionIndex)
        positionOption.target = ToPastureAndBack_RL
        positionOption:setCallback("onClickCallback", "onMsgPositionChanged")
        ToPastureAndBack_RL._settingsMsgPosition = positionOption
    end

    -- ---- tpab_settings_msg_bg_label ----
    local msgBgBox = multiOptionTemplate:clone(settingsLayout)
    msgBgBox.id = "tpabMsgBackgroundBox"
    local msgBgOption, msgBgLabel = nil, nil
    for _, child in pairs(msgBgBox.elements) do
        if child.typeName == "MultiTextOption" then msgBgOption = child
        elseif child.typeName == "Text" then msgBgLabel = child end
    end
    if msgBgOption ~= nil then
        if msgBgLabel ~= nil then
            msgBgLabel:setText(g_i18n:getText("tpab_settings_msg_bg_label"))
            msgBgLabel.id = nil
        end
        if msgBgOption.elements ~= nil then
            for _, tc in pairs(msgBgOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    if tc.setText ~= nil then tc:setText(g_i18n:getText("tpab_settings_msg_bg_tooltip")) end
                    break
                end
            end
        end
        local msgBgLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.MSG_BG_KEYS) do
            table.insert(msgBgLabels, g_i18n:getText(key))
        end
        msgBgOption:setTexts(msgBgLabels)
        msgBgOption.id = "tpabMsgBackground"
        msgBgOption:setState(ToPastureAndBack_RL.settings.msgBackgroundIndex)
        msgBgOption.target = ToPastureAndBack_RL
        msgBgOption:setCallback("onClickCallback", "onMsgBackgroundChanged")
        ToPastureAndBack_RL._settingsMsgBackground = msgBgOption
    end

    -- ---- tpab_settings_warn_style_label ----
    local warnStyleBox = multiOptionTemplate:clone(settingsLayout)
    warnStyleBox.id = "tpabWarnStyleBox"
    local warnStyleOption, warnStyleLabel = nil, nil
    for _, child in pairs(warnStyleBox.elements) do
        if child.typeName == "MultiTextOption" then warnStyleOption = child
        elseif child.typeName == "Text" then warnStyleLabel = child end
    end
    if warnStyleOption ~= nil then
        if warnStyleLabel ~= nil then
            warnStyleLabel:setText(g_i18n:getText("tpab_settings_warn_style_label"))
            warnStyleLabel.id = nil
        end
        if warnStyleOption.elements ~= nil then
            for _, tc in pairs(warnStyleOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    if tc.setText ~= nil then tc:setText(g_i18n:getText("tpab_settings_warn_style_tooltip")) end
                    break
                end
            end
        end
        local warnStyleLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.WARN_STYLE_KEYS) do
            table.insert(warnStyleLabels, g_i18n:getText(key))
        end
        warnStyleOption:setTexts(warnStyleLabels)
        warnStyleOption.id = "tpabWarnStyle"
        warnStyleOption:setState(ToPastureAndBack_RL.settings.warnStyleIndex)
        warnStyleOption.target = ToPastureAndBack_RL
        warnStyleOption:setCallback("onClickCallback", "onWarnStyleChanged")
        ToPastureAndBack_RL._settingsWarnStyle = warnStyleOption
    end

    -- ---- Dusk Reminder toggle ----
    local duskBox = multiOptionTemplate:clone(settingsLayout)
    duskBox.id = "tpabDuskReminderBox"
    local duskOption, duskLabel = nil, nil
    for _, child in pairs(duskBox.elements) do
        if child.typeName == "MultiTextOption" then duskOption = child
        elseif child.typeName == "Text" then duskLabel = child end
    end
    if duskOption ~= nil then
        if duskLabel ~= nil then
            duskLabel:setText(g_i18n:getText("tpab_settings_dusk_reminder_label"))
            duskLabel.id = nil
        end
        if duskOption.elements ~= nil then
            for _, tc in pairs(duskOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, string.format(g_i18n:getText("tpab_settings_dusk_reminder_tooltip"),
                        ToPastureAndBack_RL.formatGameTime(18), ToPastureAndBack_RL.formatGameTime(22)))
                    break
                end
            end
        end
        local duskLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.DUSK_REMINDER_KEYS) do
            table.insert(duskLabels, g_i18n:getText(key))
        end
        duskOption:setTexts(duskLabels)
        duskOption.id = "tpabDuskReminder"
        duskOption:setState(ToPastureAndBack_RL.settings.duskReminderIndex)
        duskOption.target = ToPastureAndBack_RL
        duskOption:setCallback("onClickCallback", "onDuskReminderChanged")
        ToPastureAndBack_RL._settingsDuskReminder = duskOption
    end

    -- ---- Curfew Recall toggle ----
    local curfewBox = multiOptionTemplate:clone(settingsLayout)
    curfewBox.id = "tpabCurfewBox"
    local curfewOption, curfewLabel = nil, nil
    for _, child in pairs(curfewBox.elements) do
        if child.typeName == "MultiTextOption" then curfewOption = child
        elseif child.typeName == "Text" then curfewLabel = child end
    end
    if curfewOption ~= nil then
        if curfewLabel ~= nil then
            curfewLabel:setText(string.format(g_i18n:getText("tpab_settings_curfew_label"), ToPastureAndBack_RL.formatGameTime(22)))
            curfewLabel.id = nil
        end
        if curfewOption.elements ~= nil then
            for _, tc in pairs(curfewOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, string.format(g_i18n:getText("tpab_settings_curfew_tooltip"), ToPastureAndBack_RL.formatGameTime(22)))
                    break
                end
            end
        end
        local curfewLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.CURFEW_KEYS) do
            table.insert(curfewLabels, g_i18n:getText(key))
        end
        curfewOption:setTexts(curfewLabels)
        curfewOption.id = "tpabCurfew"
        curfewOption:setState(ToPastureAndBack_RL.settings.curfewIndex)
        curfewOption.target = ToPastureAndBack_RL
        curfewOption:setCallback("onClickCallback", "onCurfewChanged")
        ToPastureAndBack_RL._settingsCurfew = curfewOption
    end

    -- ---- Confirm before recalling (2026-10-13) ----
    local confirmBox = multiOptionTemplate:clone(settingsLayout)
    confirmBox.id = "tpabConfirmRecallBox"
    local confirmOption, confirmLabel = nil, nil
    for _, child in pairs(confirmBox.elements) do
        if child.typeName == "MultiTextOption" then confirmOption = child
        elseif child.typeName == "Text" then confirmLabel = child end
    end
    if confirmOption ~= nil then
        if confirmLabel ~= nil then
            confirmLabel:setText(g_i18n:getText("tpab_settings_confirm_label"))
            confirmLabel.id = nil
        end
        if confirmOption.elements ~= nil then
            for _, tc in pairs(confirmOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, g_i18n:getText("tpab_settings_confirm_tooltip"))
                    break
                end
            end
        end
        local confirmLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.CONFIRM_RECALL_KEYS) do
            table.insert(confirmLabels, g_i18n:getText(key))
        end
        confirmOption:setTexts(confirmLabels)
        confirmOption.id = "tpabConfirmRecall"
        confirmOption:setState(ToPastureAndBack_RL.settings.confirmRecallIndex or 2)
        confirmOption.target = ToPastureAndBack_RL
        confirmOption:setCallback("onClickCallback", "onConfirmRecallChanged")
        ToPastureAndBack_RL._settingsConfirmRecall = confirmOption
    end

    -- ---- Show Fences toggle ----
    local fenceBox = multiOptionTemplate:clone(settingsLayout)
    fenceBox.id = "tpabShowFencesBox"
    local fenceOption, fenceLabel = nil, nil
    for _, child in pairs(fenceBox.elements) do
        if child.typeName == "MultiTextOption" then fenceOption = child
        elseif child.typeName == "Text" then fenceLabel = child end
    end
    if fenceOption ~= nil then
        if fenceLabel ~= nil then
            fenceLabel:setText(g_i18n:getText("tpab_settings_fences_label"))
            fenceLabel.id = nil
        end
        if fenceOption.elements ~= nil then
            for _, tc in pairs(fenceOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, g_i18n:getText("tpab_settings_fences_tooltip"))
                    break
                end
            end
        end
        local fenceLabels = {}
        for _, key in ipairs(ToPastureAndBack_RL.SHOW_FENCES_KEYS) do
            table.insert(fenceLabels, g_i18n:getText(key))
        end
        fenceOption:setTexts(fenceLabels)
        fenceOption.id = "tpabShowFences"
        fenceOption:setState(ToPastureAndBack_RL.settings.showFencesIndex)
        fenceOption.target = ToPastureAndBack_RL
        fenceOption:setCallback("onClickCallback", "onShowFencesChanged")
        ToPastureAndBack_RL._settingsShowFences = fenceOption
    end

    -- ---- tpab_settings_poultry_label (poultry limit, 2026-10-20) ----
    local poultryBox = multiOptionTemplate:clone(settingsLayout)
    poultryBox.id = "tpabPoultryCapBox"
    local poultryOption, poultryLabel = nil, nil
    for _, child in pairs(poultryBox.elements) do
        if child.typeName == "MultiTextOption" then poultryOption = child
        elseif child.typeName == "Text" then poultryLabel = child end
    end
    if poultryOption ~= nil then
        if poultryLabel ~= nil then
            poultryLabel:setText(g_i18n:getText("tpab_settings_poultry_label"))
            poultryLabel.id = nil
        end
        if poultryOption.elements ~= nil then
            for _, tc in pairs(poultryOption.elements) do
                if tc.typeName == "Text" or tc.name == "toolTip" then
                    ToPastureAndBack_RL.fcall(tc.setText, tc, g_i18n:getText("tpab_settings_poultry_tooltip"))
                    break
                end
            end
        end
        local poultryTexts = {}
        for _, id in ipairs(ToPastureAndBack_RL.POULTRY_CAP_IDS) do
            table.insert(poultryTexts, id == "same" and g_i18n:getText("tpab_settings_poultry_same") or id)
        end
        poultryOption:setTexts(poultryTexts)
        poultryOption.id = "tpabPoultryCap"
        poultryOption:setState(ToPastureAndBack_RL.settings.poultryCapIndex or 1)
        poultryOption.target = ToPastureAndBack_RL
        poultryOption:setCallback("onClickCallback", "onPoultryCapChanged")
        ToPastureAndBack_RL._settingsPoultryCap = poultryOption
    end

    local built = {}
    for _, el in ipairs(settingsLayout.elements) do
        if not preexisting[el] then built[#built + 1] = el end
    end
    ToPastureAndBack_RL._settingsBuilt = built
    if settingsLayout.invalidateLayout ~= nil then settingsLayout:invalidateLayout() end
    dbgLog("TPAB-RL: [settings] %d settings element(s) cloned", #built)

    -- Hook InGameMenuSettingsFrame.onFrameOpen to refresh state when settings page opens
    if InGameMenuSettingsFrame ~= nil and not ToPastureAndBack_RL._settingsFrameHooked then
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
            InGameMenuSettingsFrame.onFrameOpen,
            function()
                ToPastureAndBack_RL.refreshSettingsUI()
            end
        )
        ToPastureAndBack_RL._settingsFrameHooked = true
    end

    dbgLog("TPAB-RL: [settings] Settings UI built")
end

--- Callback when the message size dropdown is changed.
function ToPastureAndBack_RL.onMsgSizeChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.msgSizeIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Message size changed to %d", state)
end

--- Callback when the message color dropdown is changed.
function ToPastureAndBack_RL.onMsgColorChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.msgColorIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Message color changed to %d", state)
end

--- Callback when the message position dropdown is changed.
function ToPastureAndBack_RL.onMsgPositionChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.msgPositionIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Message position changed to %d", state)
end

--- Callback when the message background dropdown is changed.
function ToPastureAndBack_RL.onMsgBackgroundChanged(_, state)
    if state == nil or ToPastureAndBack_RL.MSG_BG_IDS[state] == nil then return end
    ToPastureAndBack_RL.settings.msgBackgroundIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Message background changed to %s", ToPastureAndBack_RL.MSG_BG_IDS[state])
end

--- Callback when the warning style dropdown is changed.
function ToPastureAndBack_RL.onWarnStyleChanged(_, state)
    if state == nil or ToPastureAndBack_RL.WARN_STYLE_IDS[state] == nil then return end
    ToPastureAndBack_RL.settings.warnStyleIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Warning style changed to %s", ToPastureAndBack_RL.WARN_STYLE_IDS[state])
end

--- Callback when the action messages toggle is changed.
function ToPastureAndBack_RL.onActionMessagesChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.actionMessagesIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Action messages changed to %s",
        ToPastureAndBack_RL.ACTION_MSGS_OPTIONS[state] and "On" or "Off")
end

--- Callback when the dusk reminder toggle is changed.
function ToPastureAndBack_RL.onDuskReminderChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.duskReminderIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Dusk reminder changed to %s",
        ToPastureAndBack_RL.DUSK_REMINDER_OPTIONS[state] and "On" or "Off")
end

--- Callback when the curfew recall toggle is changed.
function ToPastureAndBack_RL.onConfirmRecallChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.confirmRecallIndex = state
    ToPastureAndBack_RL._recallArm = nil
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Confirm before recalling changed to %s",
        ToPastureAndBack_RL.CONFIRM_RECALL_OPTIONS[state] and "On" or "Off")
end

function ToPastureAndBack_RL.onCurfewChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.curfewIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Curfew recall changed to %s",
        ToPastureAndBack_RL.CURFEW_OPTIONS[state] and "On" or "Off")
end

--- Callback when the show fences toggle is changed.
-- Immediately creates or removes fences on all active sessions.
function ToPastureAndBack_RL.onShowFencesChanged(_, state)
    if state == nil then return end
    ToPastureAndBack_RL.settings.showFencesIndex = state
    ToPastureAndBack_RL.saveSettings()
    local showFences = ToPastureAndBack_RL.SHOW_FENCES_OPTIONS[state]
    dbgLog("TPAB-RL: Show fences changed to %s", showFences and "On" or "Off")

    -- Apply immediately to all active sessions
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if session.spawnState == "active" then
            if showFences then
                ToPastureAndBack_RL.createPastureFence(session)
            else
                ToPastureAndBack_RL.removePastureFence(session)
            end
        end
    end
end

--- Refresh all settings UI elements to match current in-memory state.
-- Called when the settings frame opens.
function ToPastureAndBack_RL.refreshSettingsUI()
    -- Action messages
    local actionMsgsEl = ToPastureAndBack_RL._settingsActionMsgs
    if actionMsgsEl ~= nil then
        actionMsgsEl:setState(ToPastureAndBack_RL.settings.actionMessagesIndex)
    end

    -- Dusk reminder
    local duskEl = ToPastureAndBack_RL._settingsDuskReminder
    if duskEl ~= nil then
        duskEl:setState(ToPastureAndBack_RL.settings.duskReminderIndex)
    end

    -- Message size
    local sizeEl = ToPastureAndBack_RL._settingsMsgSize
    if sizeEl ~= nil then
        sizeEl:setState(ToPastureAndBack_RL.settings.msgSizeIndex)
    end

    -- Message color
    local colorEl = ToPastureAndBack_RL._settingsMsgColor
    if colorEl ~= nil then
        colorEl:setState(ToPastureAndBack_RL.settings.msgColorIndex)
    end

    -- Message position
    local positionEl = ToPastureAndBack_RL._settingsMsgPosition
    if positionEl ~= nil then
        positionEl:setState(ToPastureAndBack_RL.settings.msgPositionIndex)
    end

    -- Message background and warning style
    if ToPastureAndBack_RL._settingsMsgBackground ~= nil then
        ToPastureAndBack_RL._settingsMsgBackground:setState(ToPastureAndBack_RL.settings.msgBackgroundIndex or 1)
    end
    if ToPastureAndBack_RL._settingsWarnStyle ~= nil then
        ToPastureAndBack_RL._settingsWarnStyle:setState(ToPastureAndBack_RL.settings.warnStyleIndex or 1)
    end

    -- Curfew recall
    local curfewEl = ToPastureAndBack_RL._settingsCurfew
    if curfewEl ~= nil then
        curfewEl:setState(ToPastureAndBack_RL.settings.curfewIndex)
    end
    local confirmEl = ToPastureAndBack_RL._settingsConfirmRecall
    if confirmEl ~= nil then
        confirmEl:setState(ToPastureAndBack_RL.settings.confirmRecallIndex or 2)
    end

    -- Show fences
    local fenceEl = ToPastureAndBack_RL._settingsShowFences
    if fenceEl ~= nil then
        fenceEl:setState(ToPastureAndBack_RL.settings.showFencesIndex)
    end

    -- Poultry limit
    if ToPastureAndBack_RL._settingsPoultryCap ~= nil then
        ToPastureAndBack_RL._settingsPoultryCap:setState(ToPastureAndBack_RL.settings.poultryCapIndex or 1)
    end
end

--- Save all pasture points and active grazing sessions to XML.
function ToPastureAndBack_RL.saveToXML()
    local path = ToPastureAndBack_RL.getSavePath()
    if path == nil then
        Logging.warning("TPAB-RL: Cannot determine savegame path, skipping save")
        return
    end

    local xmlId = createXMLFile("ToPastureAndBack_RL", path, "ToPastureAndBack_RL")
    if xmlId == nil or xmlId == 0 then
        Logging.warning("TPAB-RL: Failed to create XML file: %s", tostring(path))
        return
    end

    -- Save pasture points
    for i, point in ipairs(ToPastureAndBack_RL.pasturePoints) do
        local key = string.format("ToPastureAndBack_RL.pasturePoints.point(%d)", i - 1)
        setXMLInt(xmlId, key .. "#id", point.id)
        setXMLString(xmlId, key .. "#name", point.name)
        setXMLFloat(xmlId, key .. "#x", point.x)
        setXMLFloat(xmlId, key .. "#y", point.y)
        setXMLFloat(xmlId, key .. "#z", point.z)
        setXMLFloat(xmlId, key .. "#radius", point.radius)
        if point.fieldContour ~= nil and #point.fieldContour > 0 then
            -- Serialize contour as space-separated "x1 z1 x2 z2 ..." string
            local parts = {}
            for _, cp in ipairs(point.fieldContour) do
                table.insert(parts, string.format("%.1f", cp.x))
                table.insert(parts, string.format("%.1f", cp.z))
            end
            setXMLString(xmlId, key .. "#fieldContour", table.concat(parts, " "))
        end
    end

    setXMLInt(xmlId, "ToPastureAndBack_RL#nextPastureId", ToPastureAndBack_RL.nextPastureId)

    -- Save active grazing sessions
    local env = g_currentMission.environment
    local currentDay = env and env.currentDay or 0
    local currentHour = env and (env.dayTime / 3600000) or 0
    local sessionIdx = 0
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if session.spawnState == "active" or session.spawnState == "waiting_ready"
                or session.spawnState == "waiting_hus_ready" or session.spawnState == "waiting_visuals" then
            local key = string.format("ToPastureAndBack_RL.grazingSessions.session(%d)", sessionIdx)

            -- Session identity (read fresh barn name in case player renamed since session started)
            local saveBarnName = session.barnName or ""
            if session.barnPlaceable ~= nil and session.barnPlaceable.getName ~= nil then
                local ok, freshName = ToPastureAndBack_RL.fcall(session.barnPlaceable.getName, session.barnPlaceable)
                if ok and freshName ~= nil then saveBarnName = freshName end
            end
            setXMLString(xmlId, key .. "#id", session.id)
            setXMLString(xmlId, key .. "#animalType", session.animalType)
            setXMLInt(xmlId, key .. "#animalCount", session.animalCount)
            setXMLInt(xmlId, key .. "#animalAge", session.animalAge or 36)
            setXMLFloat(xmlId, key .. "#durationHours", session.durationHours)
            setXMLString(xmlId, key .. "#barnName", saveBarnName)

            -- Barn world position for re-identification on load
            local bx, bz = ToPastureAndBack_RL.getBarnLockPos(session.barnPlaceable)
            if bx ~= nil then
                setXMLFloat(xmlId, key .. "#barnX", bx)
                setXMLFloat(xmlId, key .. "#barnZ", bz)
            end

            -- Pasture point ID for linking
            if session.pasturePoint ~= nil then
                setXMLInt(xmlId, key .. "#pasturePointId", session.pasturePoint.id)
            end

            -- Farmland ID
            if session.farmlandId ~= nil then
                setXMLInt(xmlId, key .. "#farmlandId", session.farmlandId)
            end

            -- Pasture destination flag and name (skip temp fences on reload, label in messages)
            if session.isPastureDestination then
                setXMLBool(xmlId, key .. "#isPastureDestination", true)
                if session.pastureDestName ~= nil and session.pastureDestName ~= "" then
                    setXMLString(xmlId, key .. "#pastureDestName", session.pastureDestName)
                end
            end

            -- Timer: compute elapsed hours and save remaining time
            local elapsedHours = 0
            if session.startDay ~= nil and session.startHour ~= nil then
                elapsedHours = (currentDay - session.startDay) * 24 + (currentHour - session.startHour)
            end
            local remainingHours = math.max(session.durationHours - elapsedHours, 0)
            setXMLFloat(xmlId, key .. "#remainingHours", remainingHours)

            -- Save RL animal identity triples so we can re-fetch the exact Animal
            -- objects from the barn's clusterSystem after reload. The identity triple
            -- (farmId, uniqueId, birthday.country) is how RL uniquely identifies each
            -- animal, see RLAnimalUtil.compare/find.
            local rlAnimals = session.rlAnimals or {}
            local animalIdx = 0
            for _, animal in ipairs(rlAnimals) do
                if animal ~= nil and animal.uniqueId ~= nil and animal.farmId ~= nil
                        and animal.birthday ~= nil then
                    local aKey = string.format("%s.animal(%d)", key, animalIdx)
                    setXMLString(xmlId, aKey .. "#uniqueId", tostring(animal.uniqueId))
                    setXMLString(xmlId, aKey .. "#farmId", tostring(animal.farmId))
                    setXMLInt(xmlId, aKey .. "#country", animal.birthday.country or 0)
                    animalIdx = animalIdx + 1
                end
            end
            setXMLInt(xmlId, key .. "#rlAnimalCount", animalIdx)

            sessionIdx = sessionIdx + 1
            dbgLog("TPAB-RL: Saved session %s: barn=%s, %d %s (rl=%d), %.1fh remaining",
                session.id, session.barnName, session.animalCount, session.animalType,
                animalIdx, remainingHours)
        end
    end

    saveXMLFile(xmlId)
    delete(xmlId)

    dbgLog("TPAB-RL: Saved %d pasture point(s) and %d grazing session(s) to %s",
        #ToPastureAndBack_RL.pasturePoints, sessionIdx, path)
end

--- Load pasture points and saved grazing sessions from XML.
-- Grazing sessions are stored as pendingReconstructions until barns are scanned
-- (deferred init at frame ~350), then reconstructed by reconstructSavedSessions().
function ToPastureAndBack_RL.loadFromXML()
    local path = ToPastureAndBack_RL.getSavePath()
    if path == nil then
        dbgLog("TPAB-RL: Cannot determine savegame path, skipping load")
        return
    end

    if not fileExists(path) then
        dbgLog("TPAB-RL: No save file found at %s, starting fresh", path)
        return
    end

    local xmlId = loadXMLFile("ToPastureAndBack_RL", path)
    if xmlId == nil or xmlId == 0 then
        Logging.warning("TPAB-RL: Failed to load XML file: %s", tostring(path))
        return
    end

    local nextId = getXMLInt(xmlId, "ToPastureAndBack_RL#nextPastureId")
    if nextId ~= nil and nextId > 0 then
        ToPastureAndBack_RL.nextPastureId = nextId
    end

    -- Load pasture points
    ToPastureAndBack_RL.pasturePoints = {}
    local i = 0
    while true do
        local key = string.format("ToPastureAndBack_RL.pasturePoints.point(%d)", i)
        local id = getXMLInt(xmlId, key .. "#id")
        if id == nil then break end

        local name = getXMLString(xmlId, key .. "#name") or string.format("Pasture %d", id)
        local x = getXMLFloat(xmlId, key .. "#x") or 0
        local y = getXMLFloat(xmlId, key .. "#y") or 0
        local z = getXMLFloat(xmlId, key .. "#z") or 0
        local radius = getXMLFloat(xmlId, key .. "#radius") or ToPastureAndBack_RL.DEFAULT_RADIUS
        -- Deserialize contour from space-separated "x1 z1 x2 z2 ..." string
        local contourStr = getXMLString(xmlId, key .. "#fieldContour")
        local fieldContour = nil
        if contourStr ~= nil and contourStr ~= "" then
            fieldContour = {}
            local nums = {}
            for num in contourStr:gmatch("[^ ]+") do
                table.insert(nums, tonumber(num))
            end
            for ci = 1, #nums - 1, 2 do
                table.insert(fieldContour, { x = nums[ci], z = nums[ci + 1] })
            end
            if #fieldContour < 4 then fieldContour = nil end
        end

        -- Legacy fallback: read old fieldExtentX/Z if contour not present
        if fieldContour == nil then
            local fieldExtentX = getXMLFloat(xmlId, key .. "#fieldExtentX")
            local fieldExtentZ = getXMLFloat(xmlId, key .. "#fieldExtentZ")
            if fieldExtentX ~= nil and fieldExtentZ ~= nil then
                -- Convert legacy rectangle to 4-point contour
                fieldContour = {
                    { x = x - fieldExtentX, z = z - fieldExtentZ },
                    { x = x + fieldExtentX, z = z - fieldExtentZ },
                    { x = x + fieldExtentX, z = z + fieldExtentZ },
                    { x = x - fieldExtentX, z = z + fieldExtentZ },
                }
            end
        end

        local point = ToPastureAndBack_RL.createPasturePoint(id, x, y, z, radius, name)
        point.fieldContour = fieldContour
        table.insert(ToPastureAndBack_RL.pasturePoints, point)

        i = i + 1
    end

    dbgLog("TPAB-RL: Loaded %d pasture point(s) from %s", #ToPastureAndBack_RL.pasturePoints, path)
    for _, point in ipairs(ToPastureAndBack_RL.pasturePoints) do
        dbgLog("TPAB-RL:   [%d] %s at (%.1f, %.1f, %.1f) r=%dm contour=%s",
            point.id, point.name, point.x, point.y, point.z, point.radius,
            point.fieldContour and tostring(#point.fieldContour) .. " pts" or "none")
    end

    -- Load saved grazing sessions as pending reconstructions.
    -- These cannot be fully reconstructed yet because barns haven't been scanned.
    -- They'll be processed by reconstructSavedSessions() after barn scan completes.
    ToPastureAndBack_RL.pendingReconstructions = {}
    local si = 0
    while true do
        local key = string.format("ToPastureAndBack_RL.grazingSessions.session(%d)", si)
        local sessionId = getXMLString(xmlId, key .. "#id")
        if sessionId == nil then break end

        local rec = {
            id = sessionId,
            animalType = getXMLString(xmlId, key .. "#animalType") or "COW",
            animalCount = getXMLInt(xmlId, key .. "#animalCount") or 0,
            animalAge = getXMLInt(xmlId, key .. "#animalAge") or 36,
            durationHours = getXMLFloat(xmlId, key .. "#durationHours") or 0,
            barnName = getXMLString(xmlId, key .. "#barnName") or "",
            barnX = getXMLFloat(xmlId, key .. "#barnX"),
            barnY = getXMLFloat(xmlId, key .. "#barnY"),
            barnZ = getXMLFloat(xmlId, key .. "#barnZ"),
            pasturePointId = getXMLInt(xmlId, key .. "#pasturePointId"),
            farmlandId = getXMLInt(xmlId, key .. "#farmlandId"),
            isPastureDestination = getXMLBool(xmlId, key .. "#isPastureDestination") or false,
            pastureDestName = getXMLString(xmlId, key .. "#pastureDestName"),
            remainingHours = getXMLFloat(xmlId, key .. "#remainingHours") or 0,
            rlAnimalIds = {},  -- populated below from saved identity triples
        }

        -- Load RL animal identity triples for re-fetching after barn scan
        local rlCount = getXMLInt(xmlId, key .. "#rlAnimalCount") or 0
        for ai = 0, rlCount - 1 do
            local aKey = string.format("%s.animal(%d)", key, ai)
            local uid = getXMLString(xmlId, aKey .. "#uniqueId")
            local fid = getXMLString(xmlId, aKey .. "#farmId")
            local country = getXMLInt(xmlId, aKey .. "#country")
            if uid ~= nil and fid ~= nil then
                table.insert(rec.rlAnimalIds, {
                    uniqueId = uid,
                    farmId = fid,
                    country = country or 0,
                })
            end
        end

        table.insert(ToPastureAndBack_RL.pendingReconstructions, rec)
        dbgLog("TPAB-RL: Loaded saved session %s: barn=%s at (%.1f,%.1f,%.1f), %d %s (rl=%d), %.1fh remaining",
            rec.id, rec.barnName,
            rec.barnX or 0, rec.barnY or 0, rec.barnZ or 0,
            rec.animalCount, rec.animalType, #rec.rlAnimalIds, rec.remainingHours)
        si = si + 1
    end

    if #ToPastureAndBack_RL.pendingReconstructions > 0 then
        dbgLog("TPAB-RL: %d saved grazing session(s) queued for reconstruction after barn scan",
            #ToPastureAndBack_RL.pendingReconstructions)
    end

    delete(xmlId)
end


-- ============================================================================
-- Input handling (rebindable action events, cert 2026-07-07 K1-K3)
--
-- The five global keybinds used to be a raw keyEvent handler with hardcoded
-- sym codes, so rebinding an action in the Controls menu changed the shown
-- glyphs but not the behavior (Giants cert 2026-07-07). They are now proper
-- action events (the modDesc inputBinding actions), registered through
-- ToPastureAndBack_RL.registerGlobalActionEvents via the
-- PlayerInputComponent.registerGlobalPlayerActionEvents hook installed at the
-- bottom of this file.
-- ============================================================================

-- The five rebindable global actions, in registration order. These are the
-- complete input surface of TPAB-RL (no barn-menu action: RL owns the
-- animal-screen flow, see the 2026-07-11 removal note).
ToPastureAndBack_RL.GLOBAL_ACTIONS = {
    "TPABRL_COLLECT_HERD",
    "TPABRL_CONFIRM_PASTURE",
    "TPABRL_CANCEL",
    "TPABRL_RECALL",
    "TPABRL_STATUS",
}

-- Event ids of the currently registered global action events (bookkeeping,
-- cleared on every re-register and in deleteMap), cert 2026-07-07 (K2).
ToPastureAndBack_RL.globalActionEventIds = {}

--- Cancel a pending grazing attempt. ONLY cancels a pending pickup (between
-- collect-herd at the barn and confirm at the field). Active grazing sessions
-- get recalled via the recall action, never via cancel. The previous
-- else-branch called removeAllPastures, which cascaded through
-- RemovePasturePointEvent and ended up recalling active herds, overlapping
-- recall's scope and surprising the player who only meant to cancel a
-- pending attempt.
-- Body extracted MOVE-ONLY from the old keyEvent Backspace branch,
-- cert 2026-07-07 (K1/K3).
function ToPastureAndBack_RL.cancelPendingGrazing()
    if ToPastureAndBack_RL.hasPendingGrazings() then
        -- Cancel = undo the pickup: field-pocketed herds (relocated from a
        -- pasture) re-deploy to that SAME pasture; barn-pocketed herds restore
        -- to the barn. ORDER IS LOAD-BEARING: clearPendingGrazings restores
        -- barn visuals via an unlock broadcast, so a field herd that is BOTH
        -- unlocked and re-deployed would double-count the cluster (MP
        -- duplicate-barn desync). Re-deploy + remove the field entries FIRST,
        -- then clearPendingGrazings runs on the barn-only remainder.
        local pendings = ToPastureAndBack_RL.pendingGrazings
        local fieldCount = 0
        local barnOnly = {}
        for _, pe in ipairs(pendings) do
            if pe.fieldOrigin == nil then
                table.insert(barnOnly, pe)
            elseif ToPastureAndBack_RL.redeployToFieldOrigin(pe) then
                fieldCount = fieldCount + 1
            else
                table.insert(barnOnly, pe)  -- redeploy failed (no barn node etc.): fall back to barn restore, never drop the herd
            end
        end
        local barnCount = #barnOnly
        ToPastureAndBack_RL.pendingGrazings = barnOnly
        if barnCount > 0 then
            ToPastureAndBack_RL.clearPendingGrazings()  -- unlock -> restoreBarnVisuals, barn-origin only
        else
            ToPastureAndBack_RL.pendingGrazings = {}
            ToPastureAndBack_RL.pendingClass = nil
            ToPastureAndBack_RL.runWasMultiHerd = false
        end
        dbgLog("TPAB-RL: Cancel: %d herd(s) returned to field, %d returned to barn", fieldCount, barnCount)
        ToPastureAndBack_RL.showMessage(g_i18n:getText("tpab_pasture_cancelled") or "Pasture run canceled.")
    else
        ToPastureAndBack_RL.showRefusal(string.format(
            g_i18n:getText("tpab_no_pending_to_cancel")
            or "No pending pasture run to cancel. Use %s to recall a herd that's already on pasture.",
            ToPastureAndBack_RL.getBindingText("TPABRL_RECALL")))
    end
end

--- Shared callback for the five global action events, cert 2026-07-07 (K1).
-- Registered with target = ToPastureAndBack_RL, so the engine passes the table
-- as the first argument. The initialized/initComplete gates moved here from
-- the old keyEvent handler.
function ToPastureAndBack_RL.onGlobalActionEvent(target, actionName, inputValue, callbackState, isAnalog)
    if not ToPastureAndBack_RL.initialized then return end
    if not ToPastureAndBack_RL.initComplete then
        ToPastureAndBack_RL.showRefusal(
            g_i18n:getText("tpab_init_pending") or "Animal status is still syncing, please wait.")
        return
    end

    if actionName == "TPABRL_COLLECT_HERD" then
        -- Step 1, initiate grazing at a barn
        dbgLog("TPAB-RL: Initiate grazing action triggered")
        ToPastureAndBack_RL.initiateGrazing()
    elseif actionName == "TPABRL_CONFIRM_PASTURE" then
        -- Step 2, confirm field destination and spawn herd
        dbgLog("TPAB-RL: Confirm destination action triggered")
        ToPastureAndBack_RL.confirmGrazingDestination()
    elseif actionName == "TPABRL_CANCEL" then
        dbgLog("TPAB-RL: Cancel pending action triggered")
        ToPastureAndBack_RL.cancelPendingGrazing()
    elseif actionName == "TPABRL_RECALL" then
        dbgLog("TPAB-RL: Recall action triggered")
        ToPastureAndBack_RL.testRecallAll()
    elseif actionName == "TPABRL_STATUS" then
        dbgLog("TPAB-RL: Status action triggered")
        ToPastureAndBack_RL.listPasturePoints()
    end
end

--- Register the five global action events, cert 2026-07-07 (K2). Called from
-- the PlayerInputComponent.registerGlobalPlayerActionEvents append at the
-- bottom of this file, which the engine invokes inside an already-open
-- begin/endActionEventsModification block: at local player load (player
-- context) and on every vehicle action-event rebuild (vehicle context).
-- @param contextName string|nil input context the engine is building (nil at player load)
function ToPastureAndBack_RL.registerGlobalActionEvents(contextName)
    if g_inputBinding == nil then return end

    -- Dedupe: vehicle action-event rebuilds re-run this hook, so drop any
    -- events we registered earlier before registering fresh ones.
    ToPastureAndBack_RL.fcall(g_inputBinding.removeActionEventsByTarget, g_inputBinding, ToPastureAndBack_RL)
    ToPastureAndBack_RL.globalActionEventIds = {}

    local registered = 0
    for _, name in ipairs(ToPastureAndBack_RL.GLOBAL_ACTIONS) do
        if InputAction ~= nil and InputAction[name] ~= nil then
            -- registerActionEvent returns success, eventId (two values), so
            -- the pcall capture below is okReg, isValid, eventId. Flags
            -- false, true, false, true = fire on key down only, start active
            local okReg, isValid, eventId = ToPastureAndBack_RL.fcall(g_inputBinding.registerActionEvent, g_inputBinding,
                InputAction[name], ToPastureAndBack_RL, ToPastureAndBack_RL.onGlobalActionEvent,
                false, true, false, true)
            if okReg and isValid == true and eventId ~= nil then
                table.insert(ToPastureAndBack_RL.globalActionEventIds, eventId)
                -- Transient-UI preference: keep the F1 help strip uncluttered.
                ToPastureAndBack_RL.fcall(g_inputBinding.setActionEventTextVisibility, g_inputBinding, eventId, false)
                registered = registered + 1
            else
                dbgLog("TPAB-RL: registerActionEvent failed for %s (ok=%s, valid=%s)",
                    name, tostring(okReg), tostring(isValid))
            end
        end
    end
    -- Runtime verification the senior review requires: one line per hook run.
    dbgLog("TPAB-RL: Registered %d/%d global action event(s) (context=%s)",
        registered, #ToPastureAndBack_RL.GLOBAL_ACTIONS, tostring(contextName))
end


--- Herds that ANOTHER player of this farm is carrying right now (picked up with the pick-up key, not yet
--- dropped), grouped by player. Read from the pickup locks every peer already keeps in sync
--- (applyPendingBarnLock); no new event. The local player's own pickups are left out because the local
--- pending list already reports them. 2026-11-01 (MP G2): the status said "No animals are out on
--- pasture" while the MP client was carrying a herd, which read as if the herd had vanished.
function ToPastureAndBack_RL.othersTransporting()
    local order, byName = {}, {}
    if ToPastureAndBack_RL.remotePendingLocks == nil then return order end
    for _, lock in pairs(ToPastureAndBack_RL.remotePendingLocks) do
        local placeable = ToPastureAndBack_RL.findCachedBarnPlaceableByPos(lock.x, lock.z)
        local own = false
        if placeable ~= nil and ToPastureAndBack_RL.pendingGrazings ~= nil then
            for _, pe in ipairs(ToPastureAndBack_RL.pendingGrazings) do
                if pe.barnData ~= nil and pe.barnData.placeable == placeable then
                    own = true
                    break
                end
            end
        end
        -- Farm rule: only this farm's barns. A lock whose barn is not in the cache cannot be placed on a
        -- farm, so it is left out rather than guessed.
        if placeable ~= nil and not own and ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfPlaceable(placeable)) then
            local name = lock.playerName
            if type(name) ~= "string" or name == "" then name = "?" end
            if byName[name] == nil then
                byName[name] = { name = name, count = 0 }
                table.insert(order, byName[name])
            end
            byName[name].count = byName[name].count + 1
        end
    end
    return order
end

--- "No animals are out" with what other players of this farm are carrying added, so the answer is not
--- read as herds gone missing.
function ToPastureAndBack_RL.noAnimalsOutText()
    local others = ToPastureAndBack_RL.othersTransporting()
    if #others == 0 then
        return g_i18n:getText("tpab_no_animals_out") or "No animals are out on pasture right now."
    end
    local first = others[1]
    local lines = { string.format(ToPastureAndBack_RL.textN("tpab_no_animals_out_but", first.count,
        "No animals are out on pasture right now, but %s is currently transporting %d herds.",
        "No animals are out on pasture right now, but %s is currently transporting %d herd."),
        first.name, first.count) }
    for i = 2, #others do
        table.insert(lines, ToPastureAndBack_RL.othersTransportingLine(others[i]))
    end
    dbgLog("TPAB-RL: no herds out for this player; %d other player(s) transporting herds", #others)
    return table.concat(lines, "\n")
end

function ToPastureAndBack_RL.othersTransportingLine(entry)
    return string.format(ToPastureAndBack_RL.textN("tpab_others_transporting", entry.count,
        "%s is currently transporting %d herds.", "%s is currently transporting %d herd."),
        entry.name, entry.count)
end

--- Show status: pending grazing, active sessions, barns, pasture points.
function ToPastureAndBack_RL.listPasturePoints()
    -- Show pending grazings (one log line per herd)
    if ToPastureAndBack_RL.hasPendingGrazings() then
        dbgLog("TPAB-RL: %d pending herd(s) awaiting field destination (RCtrl+G):",
            #ToPastureAndBack_RL.pendingGrazings)
        for _, p in ipairs(ToPastureAndBack_RL.pendingGrazings) do
            dbgLog("TPAB-RL:   %d %s from %s",
                p.animalCount, p.animalType, p.barnName or p.barnData.name)
        end
    end

    if #ToPastureAndBack_RL.pasturePoints > 0 then
        dbgLog("TPAB-RL: %d pasture point(s):", #ToPastureAndBack_RL.pasturePoints)
        for _, point in ipairs(ToPastureAndBack_RL.pasturePoints) do
            dbgLog("TPAB-RL:   [%d] %s at (%.1f, %.1f, %.1f) r=%dm",
                point.id, point.name, point.x, point.y, point.z, point.radius)
        end
    end

    if #ToPastureAndBack_RL.grazingSessions > 0 then
        dbgLog("TPAB-RL: %d active grazing session(s):", #ToPastureAndBack_RL.grazingSessions)
        for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
            dbgLog("TPAB-RL:   [%s] %s -> %s (%d animals, state=%s)",
                session.id, session.barnName, session.pasturePoint.name,
                #session.animalIds, session.spawnState)
        end
    end

    -- Show nearby barns and distances
    local px, _, pz = ToPastureAndBack_RL.getPlayerPosition()
    if px ~= nil then
        local allEntries = ToPastureAndBack_RL.getAllBarnsAllTypes()
        if #allEntries > 0 then
            dbgLog("TPAB-RL: Animal barns on map (distance from player):")
            for _, entry in ipairs(allEntries) do
                local bx, bz = ToPastureAndBack_RL.getBarnCachePos(entry.barn)
                if bx ~= nil then
                    local dx = bx - px
                    local dz = bz - pz
                    local dist = math.sqrt(dx * dx + dz * dz)
                    local nearby = dist <= ToPastureAndBack_RL.BARN_PROXIMITY and " <-- IN RANGE" or ""
                    dbgLog("TPAB-RL:   [%s] %s at %.0fm%s", entry.type, entry.barn.name, dist, nearby)
                end
            end
        end
    end

    -- Show status on screen: pendings (above the line) + active sessions (below the line)
    local lines = {}

    if ToPastureAndBack_RL.hasPendingGrazings() then
        if #ToPastureAndBack_RL.pendingGrazings == 1 then
            local p = ToPastureAndBack_RL.pendingGrazings[1]
            local pendBarnName = p.barnName or p.barnData.name
            local pendBarnPlaceable = p.barnData and p.barnData.placeable or nil
            local pendSpecies = ToPastureAndBack_RL.getSpeciesNoun(p.animalType, pendBarnPlaceable)
            local pendTier = ToPastureAndBack_RL.getAnimalFieldTier(p.animalType)
            local pendMsg
            if pendTier == "forager" then
                pendMsg = string.format(
                    g_i18n:getText("tpab_pig_move_prompt") or "Move your %s from %s to a mowed field or stubble. Go there and press %s.",
                    pendSpecies, pendBarnName, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
            else
                local pendPoss = ToPastureAndBack_RL.getSpeciesPossessive(p.animalType, p, true)
                pendMsg = string.format(
                    g_i18n:getText("tpab_moving_msg") or "Moving %s %s from %s. Go to a field and press %s.",
                    pendPoss, pendSpecies, pendBarnName, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
            end
            table.insert(lines, pendMsg)
        else
            -- UX 2026-07-09 : unified transporting lingo, destination phrase
            -- follows the pocket class (foragers get mowed field or stubble).
            local batchTier = ToPastureAndBack_RL.getAnimalFieldTier(ToPastureAndBack_RL.pendingGrazings[1].animalType)
            local headerKey, headerFallback
            if batchTier == "forager" then
                headerKey = "tpab_status_transporting_forage"
                headerFallback = "You're transporting %d herds. Move them to a mowed field or stubble. Go there, and press %s."
            else
                headerKey = "tpab_status_transporting"
                headerFallback = "You're transporting %d herds. Move them to a grass field or pasture. Go there, and press %s."
            end
            table.insert(lines, string.format(ToPastureAndBack_RL.textN(headerKey, #ToPastureAndBack_RL.pendingGrazings, headerFallback, headerFallback),
                #ToPastureAndBack_RL.pendingGrazings, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE")))
            for _, p in ipairs(ToPastureAndBack_RL.pendingGrazings) do
                local pBarnName = p.barnName or p.barnData.name
                local pPlaceable = p.barnData and p.barnData.placeable or nil
                local pSpecies = ToPastureAndBack_RL.getSpeciesNoun(p.animalType, pPlaceable)
                table.insert(lines, string.format("  " .. ToPastureAndBack_RL.locText("tpab_status_pending_line", "%d %s from %s"), p.animalCount, pSpecies, pBarnName))
            end
        end
    end

    if #ToPastureAndBack_RL.grazingSessions > 0 then
        local sessionLines = {}
        -- Farm rule (2026-10-22, MP T1): the status lists only the local player's farm's herds.
        local ownSessions = {}
        for _, s in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if ToPastureAndBack_RL.isOwnSession(s) then table.insert(ownSessions, s) end
        end
        for _, session in ipairs(ownSessions) do
            local sessionBarnName = session.barnName or "barn"
            if session.barnPlaceable ~= nil and session.barnPlaceable.getName ~= nil then
                local okN, fresh = ToPastureAndBack_RL.fcall(session.barnPlaceable.getName, session.barnPlaceable)
                if okN and fresh ~= nil then sessionBarnName = fresh end
            end
            local farmlandLabel = ""
            if session.pastureDestName ~= nil and session.pastureDestName ~= "" then
                if session.farmlandId ~= nil and session.farmlandId > 0 then
                    farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at_farmland"), session.pastureDestName, session.farmlandId)
                else
                    farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at"), session.pastureDestName)
                end
            elseif session.farmlandId ~= nil and session.farmlandId > 0 then
                farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("farmland"), session.farmlandId)
            end
            local sessionSpecies = ToPastureAndBack_RL.getSpeciesNoun(session.animalType, session)
            local sessionTier = ToPastureAndBack_RL.getAnimalFieldTier(session.animalType)
            local sessionVerb = (sessionTier == "forager") and ToPastureAndBack_RL.locText("tpab_status_on_field", "out on the field")
                or ToPastureAndBack_RL.locText("tpab_status_on_pasture", "on pasture")
            local sessionBeVerb = ToPastureAndBack_RL.getSpeciesVerb(session.animalType, "be", session)
            -- Locale "tpab_status_entry" is 6-placeholder: "%s %s from %s %s %s%s"
            -- (Possessive + species, "from", barn name, be-verb, action verb, farmland tail).
            -- Species-first phrasing avoids "Bianchi Cows's cows" stutter and matches TPAB-RL.
            -- Without sessionPoss as arg #1 the call drops to 5 args and string.format
            -- throws "missing argument #7", which silently aborted listPasturePoints
            -- before showModInitiatedMessage could fire (so RCtrl+L showed nothing on
            -- screen even though the log path completed).
            local sessionPoss = ToPastureAndBack_RL.getSpeciesPossessive(session.animalType, session)
            -- German "draußen" only when no place follows (outText); an emptied word leaves a
            -- double space in the template, so runs of spaces collapse to one (2026-10-27).
            sessionVerb = ToPastureAndBack_RL.outText(sessionVerb, farmlandLabel)
            local sessionLine = string.format(
                g_i18n:getText("tpab_status_entry") or "%s %s from %s %s %s%s",
                sessionPoss, sessionSpecies, sessionBarnName, sessionBeVerb, sessionVerb, farmlandLabel)
            sessionLine = string.gsub(sessionLine, "  +", " ")
            table.insert(sessionLines, sessionLine)
        end
        if #sessionLines == 0 then
            -- no herds of this farm are out
        elseif #sessionLines == 1 and #lines == 0 then
            table.insert(lines, sessionLines[1] .. ".")
        else
            table.insert(lines, string.format(ToPastureAndBack_RL.textN("tpab_status_herds_out", #sessionLines, "%d herds out:", "%d herd out:"), #sessionLines))
            for _, sl in ipairs(sessionLines) do
                table.insert(lines, "  " .. sl)
            end
        end
    end

    local msg
    if #lines == 0 then
        msg = ToPastureAndBack_RL.noAnimalsOutText()
    else
        -- Herds other players of this farm are carrying, one line each (2026-11-01).
        for _, entry in ipairs(ToPastureAndBack_RL.othersTransporting()) do
            table.insert(lines, ToPastureAndBack_RL.othersTransportingLine(entry))
        end
        msg = table.concat(lines, "\n")
    end
    ToPastureAndBack_RL.showModInitiatedMessage(msg)
end

--- Find the cached barn entry whose placeable matches the given placeable.
-- Used by the AnimalScreen menu button to resolve the husbandry the player
-- is looking at back to our cached barn data (with navNode, xmlFile, etc.).
-- @param placeable table Barn placeable from AnimalScreen.controller.husbandry
-- @return table|nil barnData, string|nil animalType
function ToPastureAndBack_RL.findBarnEntryByPlaceable(placeable)
    if placeable == nil or ToPastureAndBack_RL.barnCache == nil then
        return nil, nil
    end
    for typeName, candidates in pairs(ToPastureAndBack_RL.barnCache) do
        for _, barn in ipairs(candidates) do
            if barn.placeable == placeable then
                return barn, typeName
            end
        end
    end
    return nil, nil
end

--- Return the active grazing session for a specific barn placeable, or nil.
-- @param placeable table Barn placeable
-- @return table|nil session
function ToPastureAndBack_RL.getActiveSessionForPlaceable(placeable)
    if placeable == nil then return nil end
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if session.barnPlaceable == placeable then
            return session
        end
    end
    return nil
end

--- Recall the grazing session for a specific barn via multiplayer event.
-- @param placeable table Barn placeable
-- @return boolean true if a session was recalled
function ToPastureAndBack_RL.recallSessionForPlaceable(placeable)
    local session = ToPastureAndBack_RL.getActiveSessionForPlaceable(placeable)
    if session == nil then
        return false
    end
    local barnName = session.barnName or "barn"
    if placeable.getName ~= nil then
        local ok, fresh = ToPastureAndBack_RL.fcall(placeable.getName, placeable)
        if ok and fresh ~= nil then barnName = fresh end
    end
    dbgLog("TPAB-RL: Recalling session %s for %s via AnimalScreen menu", session.id, barnName)
    ToPastureAndBack_RL.sendEvent(RecallFromPastureEvent.new(session.id))
    return true
end

--- Step 1: Initiate grazing for a specific, already-resolved barn.
-- Shared between the RCtrl+J proximity path and the AnimalScreen menu button.
-- Performs the duplicate-session / empty-barn / too-young checks, then stores
-- pendingGrazing state so the player can confirm destination at a field.
-- @param barnData table Entry from barnCache (placeable, navNode, name, ...)
-- @param barnAnimalType string Animal type key e.g. "COW"
-- @return boolean true if pendingGrazing was set
function ToPastureAndBack_RL.startPendingGrazingForBarn(barnData, barnAnimalType, fieldOrigin)
    if barnData == nil or barnAnimalType == nil then
        return false
    end

    -- 2026-05-11 MP cross-peer pickup lock: reject the second player who tries
    -- to select a barn already held by another player's pending grazing.
    local lockedByOther, lockEntry = ToPastureAndBack_RL.isBarnLockedByOther(barnData.placeable)
    if lockedByOther then
        dbgLog("TPAB-RL: Pickup rejected - %s held by %s",
            barnData.name or "?", lockEntry.playerName or "?")
        ToPastureAndBack_RL.showRefusal(string.format(
            g_i18n:getText("tpab_barn_locked_other")
                or "The herd from %s has already been picked up by %s.",
            lockEntry.barnName or barnData.name or "barn",
            lockEntry.playerName or "another player"))
        return false
    end

    -- Multi-herd validation (2026-04-29): class match and same-barn duplicate before any other checks.
    -- GRAZER (cow/buffalo/horse/sheep/goat) cannot mix with FORAGER (pig) in one batch.
    local newClass = ToPastureAndBack_RL.getPendingClass(barnAnimalType)
    if ToPastureAndBack_RL.hasPendingGrazings() then
        if ToPastureAndBack_RL.pendingClass ~= newClass then
            local first = ToPastureAndBack_RL.pendingGrazings[1]
            local existingPlaceable = first.barnData and first.barnData.placeable or nil
            local existingSpecies = ToPastureAndBack_RL.getSpeciesNoun(first.animalType, existingPlaceable)
            dbgLog("TPAB-RL: Class mismatch: pending=%s, attempted=%s", tostring(ToPastureAndBack_RL.pendingClass), tostring(newClass))
            ToPastureAndBack_RL.showRefusal(string.format(
                g_i18n:getText("tpab_class_mismatch") or "Pigs and other animals can't be picked up together. Take your %s to a field and press %s, or press %s to cancel.",
                existingSpecies,
                ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"),
                ToPastureAndBack_RL.getBindingText("TPABRL_CANCEL")))
            return false
        end
        -- Same class: reject same-barn re-selection
        for _, pe in ipairs(ToPastureAndBack_RL.pendingGrazings) do
            if pe.barnData and pe.barnData.placeable == barnData.placeable then
                local pName = pe.barnName or pe.barnData.name
                dbgLog("TPAB-RL: Barn %s already in pending queue", pName)
                ToPastureAndBack_RL.showRefusal(string.format(
                    g_i18n:getText("tpab_already_collected") or "Already have a herd from %s in the queue.",
                    pName))
                return false
            end
        end
    end

    -- Check if this barn already has an active grazing session
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if session.barnPlaceable == barnData.placeable then
            local activeBarnName = barnData.placeable:getName() or barnData.name
            local locationLabel = ""
            if session.farmlandId ~= nil and session.farmlandId > 0 then
                locationLabel = string.format(" on Farmland %d", session.farmlandId)
            end
            local dupTier = ToPastureAndBack_RL.getAnimalFieldTier(session.animalType)
            local dupActionWord = (dupTier == "forager") and "foraging" or "grazing"
            dbgLog("TPAB-RL: Barn %s already has herd %s%s (session %s)", activeBarnName, dupActionWord, locationLabel, session.id)
            do
                local dupSpecies = ToPastureAndBack_RL.getSpeciesNoun(session.animalType, session or barnData.placeable)
                local dupVerb = ToPastureAndBack_RL.getSpeciesVerb(session.animalType, "be", session)
                local dupPoss = ToPastureAndBack_RL.getSpeciesPossessive(session.animalType, session)
                local dupMsg
                if session.farmlandId ~= nil and session.farmlandId > 0 then
                    if dupTier == "forager" then
                        dupMsg = string.format(
                            ToPastureAndBack_RL.farmText(g_i18n:getText("tpab_already_foraging_farmland") or "%s %s from %s %s already out on {farmland} %d."),
                            dupPoss, dupSpecies, activeBarnName, dupVerb, session.farmlandId)
                    else
                        dupMsg = string.format(
                            ToPastureAndBack_RL.farmText(g_i18n:getText("tpab_already_grazing_farmland") or "%s %s from %s %s already out on {farmland} %d."),
                            dupPoss, dupSpecies, activeBarnName, dupVerb, session.farmlandId)
                    end
                else
                    -- Species first, "from" separator avoids "Bianchi Horses's horses" stutter.
                    if dupTier == "forager" then
                        dupMsg = string.format(
                            g_i18n:getText("tpab_already_foraging") or "%s %s from %s %s already out.",
                            dupPoss, dupSpecies, activeBarnName, dupVerb)
                    else
                        dupMsg = string.format(
                            g_i18n:getText("tpab_already_on_pasture") or "%s %s from %s %s already on pasture.",
                            dupPoss, dupSpecies, activeBarnName, dupVerb)
                    end
                end
                ToPastureAndBack_RL.showRefusal(dupMsg)
            end
            return false
        end
    end

    -- Read fresh barn name from the placeable (not from cache, which may be stale after rename)
    local freshBarnName = barnData.placeable:getName() or barnData.name

    -- RL: Read individual animals from clusterSystem:getAnimals()
    local rlAnimals = ToPastureAndBack_RL.getRLAnimalsFromBarn(barnData.placeable)
    local barnAnimalCount = #rlAnimals

    if barnAnimalCount == 0 then
        dbgLog("TPAB-RL: Barn %s has no RL animals", freshBarnName)
        ToPastureAndBack_RL.showRefusal(string.format(g_i18n:getText("tpab_barn_no_animals") or "%s has no animals.", freshBarnName))
        return false
    end

    -- RL: Find youngest animal for age gate, and log animal details
    local youngestAge = nil
    local ageCounts = {}
    for _, animal in ipairs(rlAnimals) do
        local age = animal:getAge()
        ageCounts[age] = (ageCounts[age] or 0) + 1
        if youngestAge == nil or age < youngestAge then
            youngestAge = age
        end
    end
    local ageBreakdown = {}
    for age, count in pairs(ageCounts) do
        table.insert(ageBreakdown, string.format("%dm=%d", age, count))
    end
    table.sort(ageBreakdown)
    dbgLog("TPAB-RL: Barn %s has %d RL animals. Ages: %s",
        freshBarnName, barnAnimalCount, table.concat(ageBreakdown, ", "))

    -- Block young animals from grazing (species minimum age: pigs 3 months, others 6).
    local MIN_GRAZING_AGE = ToPastureAndBack_RL.getMinGrazingAge(barnAnimalType)
    local youngKeptCount = 0  -- tracks how many young animals stay behind (for messaging)
    if youngestAge ~= nil and youngestAge < MIN_GRAZING_AGE then
        -- Count how many are too young vs old enough
        local tooYoung = 0
        for _, animal in ipairs(rlAnimals) do
            if animal:getAge() < MIN_GRAZING_AGE then tooYoung = tooYoung + 1 end
        end
        if tooYoung == barnAnimalCount then
            -- All animals too young
            dbgLog("TPAB-RL: Barn %s all %d animals too young (youngest %d months)", freshBarnName, barnAnimalCount, youngestAge)
            ToPastureAndBack_RL.showRefusal(
                string.format(g_i18n:getText("tpab_too_young") or "The animals in %s are too young to leave the barn. They need to stay sheltered until they're older.", freshBarnName))
            return false
        else
            -- Filter out young ones, only graze adults
            local filtered = {}
            for _, animal in ipairs(rlAnimals) do
                if animal:getAge() >= MIN_GRAZING_AGE then
                    table.insert(filtered, animal)
                end
            end
            dbgLog("TPAB-RL: Filtered %d young animals (<%d months), sending %d to pasture",
                tooYoung, MIN_GRAZING_AGE, #filtered)
            youngKeptCount = tooYoung
            rlAnimals = filtered
            barnAnimalCount = #rlAnimals
        end
    end

    -- RL: representative age for session (median or first adult)
    local barnAge = rlAnimals[1]:getAge()

    -- Append to pending grazings list (multi-herd: queue, don't replace)
    table.insert(ToPastureAndBack_RL.pendingGrazings, {
        barnData = barnData,
        barnName = freshBarnName,
        animalCount = barnAnimalCount,
        animalType = barnAnimalType,
        animalAge = barnAge,
        rlAnimals = rlAnimals,  -- RL: individual Animal objects for this session
        fieldOrigin = fieldOrigin,  -- nil for barn pickups; set for field relocates so cancel re-deploys here
    })
    ToPastureAndBack_RL.pendingClass = newClass
    -- Track multi-herd runs so the final drop can confirm the pocket is empty.
    if #ToPastureAndBack_RL.pendingGrazings > 1 then ToPastureAndBack_RL.runWasMultiHerd = true end

    dbgLog("TPAB-RL: Grazing initiated from %s (%d animals, youngest %s months). Awaiting field destination (RCtrl+G).",
        freshBarnName, barnAnimalCount, tostring(youngestAge))
    -- Mixed-herd detection: 2+ distinct animalTypes in the queue swap to "mixed herd" wording.
    -- Mixed = any time 2+ herds are queued. See batchIsMixed comment in dispatch.
    local isMixed = #ToPastureAndBack_RL.pendingGrazings > 1
    local tier = ToPastureAndBack_RL.getAnimalFieldTier(barnAnimalType)
    local moveSpecies = ToPastureAndBack_RL.getSpeciesNoun(barnAnimalType, barnData and barnData.placeable or nil)
    local moveMsg
    if isMixed then
        moveMsg = string.format(
            g_i18n:getText("tpab_mixed_move_prompt") or "Take your mixed herd to a field and press %s.",
            ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
    elseif tier == "forager" then
        moveMsg = string.format(
            g_i18n:getText("tpab_pig_move_prompt") or "Move your %s from %s to a mowed field or stubble. Go there and press %s.",
            moveSpecies, freshBarnName, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
    else
        local movePoss = ToPastureAndBack_RL.getSpeciesPossessive(barnAnimalType, barnData and barnData.placeable or nil, true)
        moveMsg = string.format(
            g_i18n:getText("tpab_move_prompt") or "Move %s %s from %s to a grass field or pasture. Go there and press %s.",
            movePoss, moveSpecies, freshBarnName, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
    end
    -- Prefix "Additional animals added." for any 2nd+ herd in the queue (mixed or same-type).
    if #ToPastureAndBack_RL.pendingGrazings > 1 then
        local prefix = g_i18n:getText("tpab_additional_added") or "Additional animals added."
        moveMsg = prefix .. " " .. moveMsg
    end
    -- 2026-06-22: only mention young-kept on a BARN pickup. On a field relocate
    -- (fieldOrigin set) the young were already left behind at the original barn
    -- send, so re-announcing them every relocate is wrong (SP test).
    if youngKeptCount > 0 and fieldOrigin == nil then
        moveMsg = moveMsg .. "\n" .. string.format(
            ToPastureAndBack_RL.textN("tpab_young_kept", youngKeptCount, "%d young animals remained in %s, too young to leave the barn.",
                "%d young animal remained in %s, too young to leave the barn."),
            youngKeptCount, freshBarnName)
    end
    ToPastureAndBack_RL.showMessage(moveMsg)

    -- 2026-05-11 MP: broadcast pickup lock so other peers reject re-selection.
    local lockX, lockZ = ToPastureAndBack_RL.getBarnCachePos(barnData)
    if lockX == nil then lockX, lockZ = ToPastureAndBack_RL.getBarnWorldPos(barnData.placeable) end
    if lockX ~= nil then
        local myName = ToPastureAndBack_RL.getLocalPlayerName()
        ToPastureAndBack_RL.sendEvent(PendingBarnLockEvent.new(
            lockX, lockZ, freshBarnName, myName, true, fieldOrigin))
    end
    return true
end

--- v1.0.1 Feature 2: Find an active grazing session within range of the
-- player. Used by initiateGrazing to detect "I want to move this herd to
-- a different field without first recalling to the barn" scenarios.
-- @param px number Player world X
-- @param pz number Player world Z
-- @param maxDist number Maximum distance in meters (default 30)
-- @return session|nil Closest active session within range, or nil
-- @return number|nil Distance in meters
function ToPastureAndBack_RL.findNearestGrazingSession(px, pz, maxDist)
    if ToPastureAndBack_RL.grazingSessions == nil then return nil end

    -- Resolve the player's farmland once.
    local playerFarmlandId = nil
    if g_farmlandManager ~= nil then
        local okF, fid = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandIdAtWorldPosition, g_farmlandManager, px, pz)
        if okF and fid ~= nil and fid > 0 then playerFarmlandId = fid end
    end

    -- Single pass: track the NEAREST active session by real distance, and
    -- separately the nearest one on the player's OWN farmland. Prefer the
    -- nearest same-farmland herd (lets the player stand anywhere on the field
    -- where that herd grazes) and NEVER "the first in the list", which on a
    -- parcel hosting multiple barns (e.g. Pichonniere Farmland 3) could be a
    -- herd two fields over. Falls back to nearest-within-maxDist off-farmland.
    local bestSame, bestSameDist = nil, math.huge
    local bestAny, bestAnyDist = nil, math.huge
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if session.spawnState == "active"
                and ToPastureAndBack_RL.isOwnSession(session)
                and session.pasturePoint ~= nil
                and session.pasturePoint.x ~= nil
                and session.pasturePoint.z ~= nil then
            local dx = session.pasturePoint.x - px
            local dz = session.pasturePoint.z - pz
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < bestAnyDist then
                bestAny, bestAnyDist = session, dist
            end
            if playerFarmlandId ~= nil and session.farmlandId ~= nil
                    and session.farmlandId == playerFarmlandId
                    and dist < bestSameDist then
                bestSame, bestSameDist = session, dist
            end
        end
    end

    if bestSame ~= nil then
        return bestSame, bestSameDist
    end
    -- J REACH = K REACH (2026-10-13): a herd is picked up only from the farmland it is
    -- on, exactly the farmland Right Ctrl + K uses to recall a single herd. The old 30 m
    -- off-farmland fallback is gone (maxDist is no longer used).
    return nil
end


--- v1.0.1 Feature 2: Composite move-herd action. Player pressed RCtrl+J at
-- an active pasture; recall that session AND immediately set up a pending
-- grazing for the same source barn so the next RCtrl+G at a new field will
-- send the herd straight there. sendEvent runs synchronously on host so
-- by the time we call startPendingGrazingForBarn the session is already
-- gone from grazingSessions.
-- 2026-06-22: re-deploy a field-pocketed herd back to the pasture it was grabbed
-- from (used by cancel). Rebuilds the canonical SendToPastureEvent payload with a
-- FRESH nextPastureId and broadcasts it on the proven send path. RL re-fetches the
-- real Animal objects from the barn inside executeGrazingFromEvent, so the same
-- individuals (ear tags, genetics) respawn; only destination geometry is carried.
function ToPastureAndBack_RL.redeployToFieldOrigin(pe)
    local o = pe.fieldOrigin
    if o == nil or pe.barnData == nil then return false end
    local barnWorldX, barnWorldZ = 0, 0
    local bx, bz = ToPastureAndBack_RL.getBarnCachePos(pe.barnData)  -- wire/key position, NOT getBarnAnchorPos
    if bx ~= nil then barnWorldX, barnWorldZ = bx, bz end

    local newPointId = ToPastureAndBack_RL.nextPastureId
    ToPastureAndBack_RL.nextPastureId = newPointId + 1
    local sessionId = string.format("%s_%d_%d", pe.animalType, newPointId, math.random(10000, 99999))

    local eventData = {
        barnWorldX = barnWorldX,
        barnWorldZ = barnWorldZ,
        barnName = pe.barnName or (pe.barnData and pe.barnData.name),
        destX = o.x,
        destZ = o.z,
        destY = o.y,
        fieldContour = o.fieldContour,
        fieldRadius = o.radius,
        animalType = pe.animalType,
        animalCount = o.animalCount or pe.animalCount,
        animalAge = o.animalAge or pe.animalAge or 36,
        suppressYoungKept = true,  -- cancel restore to field: young never left the barn, do not re-announce
        durationHours = 0,
        farmlandId = o.farmlandId or 0,
        sessionId = sessionId,
        pasturePointId = newPointId,
        pasturePointName = string.format("Pasture %d", newPointId),
        isPastureDestination = o.isPastureDestination or false,
        pastureDestName = o.pastureDestName,
        batchInfo = { size = 1, index = 1, isMixed = false, isLast = true },
    }
    dbgLog("TPAB-RL: Cancel re-deploy: %d %s back to field at (%.1f,%.1f) point %d",
        eventData.animalCount, pe.animalType, o.x, o.z, newPointId)
    ToPastureAndBack_RL.sendEvent(SendToPastureEvent.new(eventData))
    return true
end

function ToPastureAndBack_RL.moveHerdToNewDestination(session)
    if session == nil then return false end
    local barnPlaceable = session.barnPlaceable
    local animalType = session.animalType
    local barnName = session.barnName or "barn"
    if barnPlaceable ~= nil and barnPlaceable.getName ~= nil then
        local okN, freshName = ToPastureAndBack_RL.fcall(barnPlaceable.getName, barnPlaceable)
        if okN and freshName ~= nil and freshName ~= "" then barnName = freshName end
    end

    if barnPlaceable == nil or animalType == nil then
        ToPastureAndBack_RL.showRefusal(
            g_i18n:getText("tpab_move_no_barn") or "Cannot move herd: source barn data missing.")
        return false
    end

    -- Resolve barnData entry from cache.
    local barnData = nil
    if ToPastureAndBack_RL.barnCache ~= nil and ToPastureAndBack_RL.barnCache[animalType] ~= nil then
        for _, b in ipairs(ToPastureAndBack_RL.barnCache[animalType]) do
            if b.placeable == barnPlaceable then
                barnData = b
                break
            end
        end
    end
    if barnData == nil then
        ToPastureAndBack_RL.showRefusal(
            g_i18n:getText("tpab_move_no_cache") or "Cannot move herd: source barn no longer cached.")
        return false
    end

    -- 2026-06-22 relocate-reject-before-recall fix: startPendingGrazingForBarn
    -- (below) can reject this pickup AFTER the recall has already sent the herd
    -- home and torn down the session/pasture-point, stranding it at its barn
    -- (repro: pocketed PIGS then relocated SHEEP, sheep recalled, then the class
    -- check failed, sheep stuck at barn instead of left grazing). Replicate the
    -- two rejections that can hit the relocate path (class-mismatch + same-barn
    -- duplicate) BEFORE any recall, so a rejected relocate leaves the herd
    -- grazing untouched. Pure local read, no event sent on rejection, no MP
    -- desync. The cross-peer lock check is intentionally NOT mirrored (it only
    -- fires for barns held by another player, which our own active session is not).
    if ToPastureAndBack_RL.hasPendingGrazings() then
        local newClass = ToPastureAndBack_RL.getPendingClass(animalType)
        if ToPastureAndBack_RL.pendingClass ~= newClass then
            local first = ToPastureAndBack_RL.pendingGrazings[1]
            local existingPlaceable = first.barnData and first.barnData.placeable or nil
            local existingSpecies = ToPastureAndBack_RL.getSpeciesNoun(first.animalType, existingPlaceable)
            dbgLog("TPAB-RL: Move-herd: relocate rejected pre-recall (class mismatch: pending=%s, attempted=%s); herd left grazing",
                tostring(ToPastureAndBack_RL.pendingClass), tostring(newClass))
            ToPastureAndBack_RL.showRefusal(string.format(
                g_i18n:getText("tpab_class_mismatch") or "Pigs and other animals can't be picked up together. Take your %s to a field and press %s, or press %s to cancel.",
                existingSpecies,
                ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"),
                ToPastureAndBack_RL.getBindingText("TPABRL_CANCEL")))
            return false
        end
        for _, pe in ipairs(ToPastureAndBack_RL.pendingGrazings) do
            if pe.barnData and pe.barnData.placeable == barnData.placeable then
                local pName = pe.barnName or pe.barnData.name
                dbgLog("TPAB-RL: Move-herd: relocate rejected pre-recall (barn %s already pending); herd left grazing", pName)
                ToPastureAndBack_RL.showRefusal(string.format(
                    g_i18n:getText("tpab_already_collected") or "Already have a herd from %s in the queue.",
                    pName))
                return false
            end
        end
    end

    -- 2026-06-22 cancel-restores-to-origin: capture the field origin BEFORE the
    -- recall below tears down session.pasturePoint, so canceling this pocketed
    -- herd re-deploys it to the SAME pasture instead of restoring it to the barn.
    -- RL re-fetches the actual Animal objects from the barn on every drop (it never
    -- serializes them) and the recall returns them to the barn first, so the same
    -- individuals (ear tags, genetics) respawn; only destination geometry is captured.
    local fieldOrigin = nil
    do
        local pp = session.pasturePoint
        if pp ~= nil and pp.x ~= nil then
            fieldOrigin = {
                animalType = session.animalType,
                x = pp.x, y = pp.y, z = pp.z,
                radius = pp.radius,
                fieldContour = pp.fieldContour,
                farmlandId = session.farmlandId or 0,
                animalCount = session.animalCount,
                animalAge = session.animalAge or 36,
                isPastureDestination = session.isPastureDestination or false,
                pastureDestName = session.pastureDestName,
            }
        end
    end

    -- 2026-07-01: release our own (possibly stale) lock on this barn BEFORE the recall so
    -- the re-pickup is not rejected as held and the recalled herd is not stranded.
    do
        local _ux, _uz = ToPastureAndBack_RL.getBarnCachePos(barnData)
        if _ux == nil then _ux, _uz = ToPastureAndBack_RL.getBarnWorldPos(barnData.placeable) end
        if _ux ~= nil then
            ToPastureAndBack_RL.sendEvent(PendingBarnLockEvent.new(
                _ux, _uz, barnName, ToPastureAndBack_RL.getLocalPlayerName(), false))
        end
    end

    dbgLog("TPAB-RL: Move-herd: recalling session %s to set up pickup from %s",
        session.id, barnName)
    local recalledSessionId = session.id
    ToPastureAndBack_RL.sendEvent(RecallFromPastureEvent.new(session.id, true, false, true))

    -- 2026-05-11 MP desync fix:
    -- ON HOST, sendEvent above runs synchronously: event:run() executes
    -- inline, calls executeRecallFromEvent -> cleanupSession (which sets
    -- spawnState="done"). The deferred-tick later removes the session
    -- from grazingSessions.
    -- ON CLIENT, sendEvent is async (dispatch to server, broadcast back).
    -- The visual cleanup does NOT run inline. Previously we just
    -- table.remove'd the session here to satisfy startPendingGrazingForBarn's
    -- duplicate-barn check, but that left the echo unable to find the
    -- session and therefore unable to call cleanupSession on the client.
    -- Result: client's pasture visuals stayed on the field after Move-herd
    -- (MP client repro 2026-05-10 on Pichonniere Field 14: heifers gone
    -- for host, still on field for client, never restored to barn).
    --
    -- Fix: inline-call cleanupSession before the table.remove. Idempotent
    -- via spawnState=="done" guard so the host's already-cleaned session
    -- is not double-cleaned.
    if session.spawnState ~= "done" then
        ToPastureAndBack_RL.cleanupSession(session, true)  -- relocate: keep barn pocketed
    end
    -- 2026-05-11 (b): also inline-remove the pasture point. The removal
    -- normally happens inside executeRecallFromEvent's grazingSessions
    -- loop, but because we inline-remove the session below, the echo
    -- arriving on the client finds 0 matching sessions and never
    -- removes the point from pasturePoints. Result: stale Pasture N
    -- blocks future sends at that position with "Too close to another
    -- pasture" (the MP client repro 2026-05-10 on Pichonniere: Farmland 13->14
    -- relocation rejected because Pasture 1's point was still alive).
    if session.pasturePoint ~= nil and ToPastureAndBack_RL.pasturePoints ~= nil then
        for j = #ToPastureAndBack_RL.pasturePoints, 1, -1 do
            if ToPastureAndBack_RL.pasturePoints[j] == session.pasturePoint then
                table.remove(ToPastureAndBack_RL.pasturePoints, j)
                dbgLog("TPAB-RL: Move-herd: removed pasture point %s from pasturePoints array",
                    session.pasturePoint.name or "?")
                break
            end
        end
    end
    if ToPastureAndBack_RL.grazingSessions ~= nil then
        for i = #ToPastureAndBack_RL.grazingSessions, 1, -1 do
            if ToPastureAndBack_RL.grazingSessions[i].id == recalledSessionId then
                table.remove(ToPastureAndBack_RL.grazingSessions, i)
                dbgLog("TPAB-RL: Move-herd: inline-removed session %s from grazingSessions array",
                    recalledSessionId)
                break
            end
        end
    end

    local ok = ToPastureAndBack_RL.startPendingGrazingForBarn(barnData, animalType, fieldOrigin)
    if not ok then
        Logging.warning("TPAB-RL: Move-herd: startPendingGrazingForBarn failed for %s after recall; restoring herd to avoid loss", barnName)
        -- DATA-LOSS SAFETY NET (2026-07-01): recall already tore down the session; redeploy
        -- the herd to its pasture instead of stranding it (Riverbend 197-cow loss).
        if fieldOrigin ~= nil then
            ToPastureAndBack_RL.redeployToFieldOrigin({
                animalType = animalType,
                barnData = barnData,
                barnName = barnName,
                animalCount = fieldOrigin.animalCount,
                animalAge = fieldOrigin.animalAge,
                fieldOrigin = fieldOrigin,
            })
        end
        return false
    end

    local species = ToPastureAndBack_RL.getSpeciesNoun(animalType, barnPlaceable)
    if type(species) == "string" and #species > 0 then
        species = species:sub(1, 1):upper() .. species:sub(2)
    end
    -- 2026-05-11: when this pickup makes the queue mixed (2+ pendings), use a
    -- mixed-variant message that acknowledges the pickup AND prompts the player
    -- to take the whole mixed herd to a new field. Otherwise the single-herd
    -- "X from Y picked up..." message overwrites the mixed-herd prompt that
    -- startPendingGrazingForBarn just emitted, and the player ends up thinking
    -- they only have one herd in hand.
    local pendingCount = #ToPastureAndBack_RL.pendingGrazings
    local msg
    if pendingCount > 1 then
        msg = string.format(
            g_i18n:getText("tpab_move_pickup_mixed")
                or "%s from %s picked up from pasture. Take your mixed herd to a new field and press %s.",
            species, barnName, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
    else
        msg = string.format(
            g_i18n:getText("tpab_move_pickup")
                or "%s from %s picked up from pasture. Press %s at a new field to relocate.",
            species, barnName, ToPastureAndBack_RL.getBindingText("TPABRL_CONFIRM_PASTURE"))
    end
    ToPastureAndBack_RL.showMessage(msg)
    return true
end


--- cert 2026-07-07 (M8): pocket-override eligibility. A barn is POCKETABLE when
-- it has grazing-age animals, has no active grazing session, is not already in
-- our own pending pocket, and is not locked by another player's pending pickup.
-- Reuses the SAME checks startPendingGrazingForBarn applies later in the pickup
-- path (lock, duplicate pending, active session, RL animal age scan), so a
-- true result here cannot dead-end at pickup time. RL edition: the age scan
-- reads RL's individual Animal objects via getRLAnimalsFromBarn (the same
-- source the pickup path uses, already filtered for dead/sold); an empty list
-- returns false because the pickup would refuse the barn anyway, no fallback
-- (senior review 2026-07-09).
function ToPastureAndBack_RL.isBarnPocketableForOverride(barnData, barnAnimalType)
    if barnData == nil or barnData.placeable == nil or barnAnimalType == nil then
        return false
    end
    local placeable = barnData.placeable
    -- No active grazing session for this barn
    if ToPastureAndBack_RL.getActiveSessionForPlaceable(placeable) ~= nil then
        return false
    end
    -- Not already in our own pending pocket
    if ToPastureAndBack_RL.pendingGrazings ~= nil then
        for _, pe in ipairs(ToPastureAndBack_RL.pendingGrazings) do
            if pe.barnData and pe.barnData.placeable == placeable then
                return false
            end
        end
    end
    -- Not locked by another player's pending pickup
    local lockedByOther = ToPastureAndBack_RL.isBarnLockedByOther(placeable)
    if lockedByOther then
        return false
    end
    -- Grazing-age animals present: same RL animal list the pickup path uses
    local rlAnimals = ToPastureAndBack_RL.getRLAnimalsFromBarn(placeable)
    if rlAnimals == nil or #rlAnimals == 0 then
        return false
    end
    for _, animal in ipairs(rlAnimals) do
        if animal:getAge() >= ToPastureAndBack_RL.getMinGrazingAge(barnAnimalType) then
            return true
        end
    end
    return false
end

--- Step 1 (keybind path): Initiate grazing from the nearest barn.
-- Player presses RCtrl+J while standing near a barn. Resolves the nearest
-- barn, then delegates to startPendingGrazingForBarn for the state setup.
-- Player then walks/drives to a grass field and presses RCtrl+G to confirm.
function ToPastureAndBack_RL.initiateGrazing()
    local px, _, pz = ToPastureAndBack_RL.getPlayerPosition()
    if px == nil then return end

    -- Find nearest barn of any animal type
    local barnData, barnDist, barnAnimalType = ToPastureAndBack_RL.findNearestBarnAnyType()

    -- Pick up whatever you're standing closest to. A grazing herd you are
    -- NEARER to wins over a barn that merely happens to be within range (e.g.
    -- an adjacent Calf Barn). Relocating is a PICKUP (in hand; the next RCtrl+G
    -- drops it), NOT a recall (recall = RCtrl+K, which sends the herd home).
    local nearbySession, herdDist = ToPastureAndBack_RL.findNearestGrazingSession(px, pz, 30)
    -- cert 2026-07-07 (M8, senior amendment): multi-barn override. When the
    -- nearest barn is POCKETABLE (grazing-age animals, no active session, not
    -- already pocketed, not locked by another player) AND within
    -- TPAB_BARN_POCKET_OVERRIDE_RADIUS, pocket the barn even if a grazing
    -- herd's centroid happens to be nearer (adjacent barns on one field).
    -- All other cases keep the 2026-06-03 barn-first + nearest-wins rule and
    -- the 2026-06-29 ownSession-relocate branch below unchanged.
    local barnPocketOverride = false
    if barnData ~= nil and barnDist ~= nil
            and barnDist <= TPAB_BARN_POCKET_OVERRIDE_RADIUS
            and ToPastureAndBack_RL.isBarnPocketableForOverride(barnData, barnAnimalType) then
        barnPocketOverride = true
        dbgLog("TPAB-RL: RCtrl+J: pocket-override, barn %s at %.1fm is pocketable, barn wins over any nearer herd",
            barnData.name or "?", barnDist)
    end
    if nearbySession ~= nil and not barnPocketOverride and (barnData == nil or (herdDist or math.huge) < (barnDist or math.huge)) then
        dbgLog("TPAB-RL: RCtrl+J: relocating nearest grazing herd %s (%.1fm; nearest barn %s)",
            nearbySession.id, herdDist or -1,
            barnData ~= nil and string.format("%.1fm", barnDist or -1) or "none")
        ToPastureAndBack_RL.moveHerdToNewDestination(nearbySession)
        return
    end

    if barnData == nil then
        -- No barn nearby, show distances to help the player
        local allEntries = ToPastureAndBack_RL.getAllBarnsAllTypes()
        if #allEntries > 0 then
            local barnList = {}
            for _, entry in ipairs(allEntries) do
                local bx, bz = ToPastureAndBack_RL.getBarnCachePos(entry.barn)
                if bx ~= nil then
                    local dx = bx - px
                    local dz = bz - pz
                    local dist = math.sqrt(dx * dx + dz * dz)
                    table.insert(barnList, string.format("%s (%.0fm)", entry.barn.name, dist))
                end
            end
            dbgLog("TPAB-RL: No animal barn within %dm. Barns on map: %s",
                ToPastureAndBack_RL.BARN_PROXIMITY, table.concat(barnList, ", "))
            ToPastureAndBack_RL.showRefusal(
                string.format(g_i18n:getText("tpab_not_near_barn")
                    or "You are not near any barn or active pasture. Go within %dm of a barn to collect a herd, "
                    .. "or onto the farmland where a herd is out to move it.", ToPastureAndBack_RL.BARN_PROXIMITY))
        else
            dbgLog("TPAB-RL: No animal barns found on map")
            ToPastureAndBack_RL.showRefusal(g_i18n:getText("tpab_no_barn_on_map") or "No animal barn found on this map.")
        end
        return
    end

    -- If RCtrl+J resolves to a barn whose own herd is already OUT grazing (e.g. a
    -- herd grazing on top of its own pasture, a barn without a roof), there is nothing
    -- in the barn to pocket, so J means "move that herd". Relocate the barn's own
    -- session instead of dead-ending in startPendingGrazingForBarn's "already grazing"
    -- block. The relocate branch above only fires when the herd center is STRICTLY
    -- nearer than the barn node, which it is not when the herd grazes on its own
    -- pasture (the barn node sits a few meters inside the grazing footprint).
    -- Senior-reviewed GO 2026-06-29 (Riverbend Cow Pasture).
    local ownSession = ToPastureAndBack_RL.getActiveSessionForPlaceable(barnData.placeable)
    if ownSession ~= nil then
        -- J REACH = K REACH (2026-10-13, Pichonniere log 19:19-19:29): an EMPTY barn used
        -- to hand over its herd from any field on the map. Now only when that herd is on the
        -- farmland the player stands on (its own attached pasture, the Riverbend case);
        -- otherwise a herd on the player's farmland is picked up, as K would recall it, and
        -- failing that the player is told where the barn's herd is.
        local playerFarmland = nil
        if g_farmlandManager ~= nil then
            local okF, fid = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandIdAtWorldPosition, g_farmlandManager, px, pz)
            if okF and fid ~= nil and fid > 0 then playerFarmland = fid end
        end
        if playerFarmland ~= nil and ownSession.farmlandId ~= nil and ownSession.farmlandId == playerFarmland then
            dbgLog("TPAB-RL: RCtrl+J at barn %s whose herd is out on this farmland (%d, session %s); relocating that herd",
                barnData.name or "?", playerFarmland, ownSession.id)
            ToPastureAndBack_RL.moveHerdToNewDestination(ownSession)
            return
        end
        if nearbySession ~= nil then
            dbgLog("TPAB-RL: RCtrl+J at barn %s whose herd is elsewhere; picking up herd %s on the player's farmland instead",
                barnData.name or "?", nearbySession.id)
            ToPastureAndBack_RL.moveHerdToNewDestination(nearbySession)
            return
        end
        local herdLabel = ownSession.barnName or barnData.name or "?"
        if ownSession.barnPlaceable ~= nil and ownSession.barnPlaceable.getName ~= nil then
            local okN, fresh = ToPastureAndBack_RL.fcall(ownSession.barnPlaceable.getName, ownSession.barnPlaceable)
            if okN and fresh ~= nil then herdLabel = fresh end
        end
        -- No recall hint here (2026-10-13): from a spot where this message shows, K would
        -- recall every herd, not just this one.
        dbgLog("TPAB-RL: RCtrl+J at barn %s: its herd %s is out on Farmland %s, player on %s; not picked up",
            herdLabel, ownSession.id, tostring(ownSession.farmlandId), tostring(playerFarmland))
        if ownSession.farmlandId ~= nil and ownSession.farmlandId > 0 then
            ToPastureAndBack_RL.showRefusal(string.format(ToPastureAndBack_RL.farmText(g_i18n:getText("tpab_herd_out_elsewhere")),
                herdLabel, ownSession.farmlandId))
        else
            ToPastureAndBack_RL.showRefusal(string.format(g_i18n:getText("tpab_herd_out_elsewhere_nf"),
                herdLabel))
        end
        return
    end

    ToPastureAndBack_RL.startPendingGrazingForBarn(barnData, barnAnimalType)
end

--- Recall all active grazing sessions via multiplayer event.
-- Triggered by RCtrl+K. Sends RecallFromPastureEvent which broadcasts to all clients.
function ToPastureAndBack_RL.testRecallAll()
    local ownIds, ownAll = ToPastureAndBack_RL.ownSessionIds()
    if #ownIds == 0 then
        -- cert 2026-07-07 (M2): with herds still pocketed, "no animals are out"
        -- is misleading, recall does nothing until they are dropped or canceled.
        -- Report the pocket instead. Recall stays recall-only (keybind contract).
        if ToPastureAndBack_RL.hasPendingGrazings() then
            local pocketCount = #ToPastureAndBack_RL.pendingGrazings
            dbgLog("TPAB-RL: No active sessions to recall, but %d pocketed herd(s) still in transit", pocketCount)
            ToPastureAndBack_RL.showRefusal(string.format(
                ToPastureAndBack_RL.textN("tpab_pocketed_reminder", pocketCount,
                    "You are still transporting %d herds. Drop them at a field or cancel to return them.",
                    "You are still transporting %d herd. Drop it at a field or cancel to return it."),
                pocketCount))
            return
        end
        dbgLog("TPAB-RL: No active sessions to recall")
        ToPastureAndBack_RL.showRefusal(ToPastureAndBack_RL.noAnimalsOutText())
        return
    end

    -- Farmland-based recall: if the player is standing on a field (not a road) within
    -- a farmland where a herd is grazing, recall only that herd. Otherwise recall all.
    -- The field ground check prevents roads that technically belong to a farmland
    -- from triggering a single-herd recall when the player expects recall-all.
    local px, py, pz = ToPastureAndBack_RL.getPlayerPosition()
    local matchedSession = nil

    if px ~= nil then
        local isField, isGrass = ToPastureAndBack_RL.isOnFieldGround(px, pz)
        local playerFarmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(px, pz)
        dbgLog("TPAB-RL: Recall check: player on Farmland %s, isField=%s, isGrass=%s",
            tostring(playerFarmlandId), tostring(isField), tostring(isGrass))

        -- 2026-05-08: dropped isField gate. Previously required isField=true
        -- so a player on a road technically belonging to a farmland would
        -- fall through to recall-all. Real-world behavior was the opposite:
        -- standing on Farmland X (road, path, or field) with a herd grazing
        -- on X should recall just that herd. If you're not on any farmland
        -- with a matching herd, recall-all still applies.
        if playerFarmlandId ~= nil and playerFarmlandId > 0 then
            -- cert 2026-07-07 (M4): several herds can graze the SAME farmland
            -- (multi-barn field). Among the sessions matching the player's
            -- farmland, pick the one whose pasture point is nearest the player
            -- (findNearestGrazingSession pattern) instead of the first match in
            -- list order. Farmland filter stays ANDed; off-farmland behavior
            -- (recall ALL) is unchanged; still one session per press.
            local bestDist = math.huge
            for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
                if session.farmlandId ~= nil and session.farmlandId == playerFarmlandId
                        and ToPastureAndBack_RL.isOwnSession(session) then
                    local dist = math.huge
                    if session.pasturePoint ~= nil
                            and session.pasturePoint.x ~= nil
                            and session.pasturePoint.z ~= nil then
                        local dx = session.pasturePoint.x - px
                        local dz = session.pasturePoint.z - pz
                        dist = math.sqrt(dx * dx + dz * dz)
                    end
                    if matchedSession == nil or dist < bestDist then
                        matchedSession = session
                        bestDist = dist
                    end
                end
            end
        end
    end

    -- CONFIRM BEFORE RECALLING (2026-10-13). The first press says exactly what this
    -- press would recall, the same resolution as below; a second press inside the window
    -- with the SAME target recalls. Moving onto another herd's farmland re-arms with the new
    -- target instead of recalling something the player was not told about.
    if ToPastureAndBack_RL.CONFIRM_RECALL_OPTIONS[ToPastureAndBack_RL.settings.confirmRecallIndex or 2] == true then
        local targetKey = matchedSession ~= nil and matchedSession.id or ("ALL:" .. table.concat(ownIds, ","))
        local now = g_time or 0
        local arm = ToPastureAndBack_RL._recallArm
        if arm == nil or arm.key ~= targetKey or now > arm.untilMs then
            local function labelOf(sess)
                local lbl = sess ~= nil and sess.barnName or "barn"
                if sess ~= nil and sess.barnPlaceable ~= nil and sess.barnPlaceable.getName ~= nil then
                    local okL, fresh = ToPastureAndBack_RL.fcall(sess.barnPlaceable.getName, sess.barnPlaceable)
                    if okL and fresh ~= nil then lbl = fresh end
                end
                return lbl
            end
            local single = matchedSession
            if single == nil and #ownIds == 1 then
                for _, gs in ipairs(ToPastureAndBack_RL.grazingSessions or {}) do
                    if gs.id == ownIds[1] then single = gs break end
                end
            end
            local keyText = ToPastureAndBack_RL.getBindingText("TPABRL_RECALL")
            -- The label and the template are resolved ONCE here: promptFor also runs every frame
            -- while the prompt counts down (draw), and must not call getName or getText per frame.
            local singleLabel = single ~= nil and labelOf(single) or nil
            local herdCount = #ownIds
            local tpl = g_i18n:getText(single ~= nil and "tpab_recall_confirm_one" or "tpab_recall_confirm_all")
            local function promptFor(secs)
                if singleLabel ~= nil then
                    return string.format(tpl, keyText, secs, singleLabel)
                end
                return string.format(tpl, keyText, secs, herdCount)
            end
            -- THE WINDOW IS A READING TIME (2026-10-13): reading time at 67 ms per character
            -- plus 2 s to reach the key, never under RECALL_CONFIRM_MS, in whole seconds, and the
            -- text states that number. The message stays up for the whole window.
            local probe = promptFor(math.floor(ToPastureAndBack_RL.RECALL_CONFIRM_MS / 1000 + 0.5))
            local windowMs = math.ceil(math.max(ToPastureAndBack_RL.RECALL_CONFIRM_MS, #probe * 67 + 2000) / 1000) * 1000
            local prompt = promptFor(math.floor(windowMs / 1000))
            ToPastureAndBack_RL._recallArm = { key = targetKey, untilMs = now + windowMs }
            -- The player's own action, shown on this screen only, always (not gated by the
            -- action-messages setting: a prompt nobody sees would make the key look dead).
            -- COUNTDOWN (2026-10-14: match UBW): the prompt is a stacked message of its own
            -- (topic "recall") whose text is rebuilt every frame with the whole seconds left, so N
            -- counts down to 1; it leaves when the second press is honoured or the window ends.
            ToPastureAndBack_RL.pushMessage({ text = prompt, remaining = windowMs, posted = g_time or 0, topic = "recall",
                textFn = promptFor })
            dbgLog("TPAB-RL: recall confirm armed for %s (%d ms)", targetKey, windowMs)
            return
        end
        ToPastureAndBack_RL._recallArm = nil
        if KijbevMessages ~= nil and KijbevMessages.dropTopic ~= nil then
            KijbevMessages.dropTopic(ToPastureAndBack_RL._messageQueue, "recall")
        end
        dbgLog("TPAB-RL: recall confirm honored for %s", targetKey)
    end

    if matchedSession ~= nil then
        -- Player is on the same farmland as a grazing herd, recall only that one
        local herdLabel = matchedSession.barnName or "barn"
        if matchedSession.barnPlaceable ~= nil and matchedSession.barnPlaceable.getName ~= nil then
            local ok, fresh = ToPastureAndBack_RL.fcall(matchedSession.barnPlaceable.getName, matchedSession.barnPlaceable)
            if ok and fresh ~= nil then herdLabel = fresh end
        end
        dbgLog("TPAB-RL: Player on Farmland %d where %s's herd is grazing, recalling only session %s",
            matchedSession.farmlandId, herdLabel, matchedSession.id)
        ToPastureAndBack_RL.sendEvent(RecallFromPastureEvent.new(matchedSession.id))
    else
        -- Player is not on any farmland with a grazing herd, recall all
        -- Every herd this player's farm has out (the event carries ids when other farms have herds out too).
        local payload = ownAll and "ALL" or table.concat(ownIds, ",")
        dbgLog("TPAB-RL: Player not on any farmland with a grazing herd, recalling the farm's %d session(s) (%s)",
            #ownIds, payload)
        ToPastureAndBack_RL.sendEvent(RecallFromPastureEvent.new(payload))
    end
end


-- NOTE: Barn scanning functions (scanBarnsForType, getBarnDataForType) are in the
-- "Barn data helpers" section below, alongside visual herd spawning code.


-- ============================================================================
-- Barn visual suppression
-- ============================================================================

--- Find the navigation root node for a barn's husbandry.
-- The nav root node is the scene graph parent of all visual animals rendered in the barn.
-- We discover it by probing known field paths on clusterHusbandry and spec_husbandryAnimals,
-- and by walking the barn's scene graph for NAVIGATIONMESH children.
-- @param barnPlaceable table The barn placeable
-- @return number|nil Scene graph node ID, or nil if not found
function ToPastureAndBack_RL.findBarnNavRootNode(barnPlaceable)
    local spec = barnPlaceable.spec_husbandryAnimals
    if spec == nil then return nil end
    local ch = spec.clusterHusbandry

    -- Probe 1: try known field paths on clusterHusbandry
    -- ch.navigationNode is the nav mesh shape itself (not its parent), but could serve
    -- as a fallback if we get its parent via getParent()
    if ch ~= nil then
        local candidates = {ch.navRootNode, ch.navNode, ch.navigationRootNode, ch.rootNode, ch.node}
        for _, node in ipairs(candidates) do
            if node ~= nil and type(node) == "number" and node > 0 then
                dbgLog("TPAB-RL: Found nav root via clusterHusbandry field: node=%d", node)
                return node
            end
        end
    end

    -- Probe 2: try known field paths on spec
    -- Confirmed via diagnostic dump: spec.navigationMeshRootNode is the correct field
    local specCandidates = {spec.navigationMeshRootNode, spec.navRootNode, spec.navigationRootNode, spec.animalNode, spec.rootNode}
    for _, node in ipairs(specCandidates) do
        if node ~= nil and type(node) == "number" and node > 0 then
            dbgLog("TPAB-RL: Found nav root via spec field: node=%d", node)
            return node
        end
    end

    -- Probe 3: walk the barn's scene graph children looking for NAVIGATIONMESH type
    local barnRootNode = barnPlaceable.rootNode
    if barnRootNode ~= nil and barnRootNode > 0 and entityExists(barnRootNode) then
        local numChildren = getNumOfChildren(barnRootNode)
        dbgLog("TPAB-RL: Walking barn scene graph: rootNode=%d, children=%d", barnRootNode, numChildren)
        for i = 0, numChildren - 1 do
            local child = getChildAt(barnRootNode, i)
            if child ~= nil and child > 0 then
                local ok, hasNavClass = ToPastureAndBack_RL.fcall(getHasClassId, child, ClassIds.NAVIGATION_MESH)
                if ok and hasNavClass then
                    dbgLog("TPAB-RL: Found NAVIGATIONMESH at child index %d: node=%d, name=%s",
                        i, child, getName(child) or "?")
                    return child
                end
                -- Also check grandchildren (nav mesh might be one level deeper)
                local ok2, grandCount = ToPastureAndBack_RL.fcallNode(getNumOfChildren, child)
                if ok2 and grandCount ~= nil and grandCount > 0 then
                    for j = 0, grandCount - 1 do
                        local grandchild = getChildAt(child, j)
                        if grandchild ~= nil and grandchild > 0 then
                            local ok3, hasNav = ToPastureAndBack_RL.fcall(getHasClassId, grandchild, ClassIds.NAVIGATION_MESH)
                            if ok3 and hasNav then
                                dbgLog("TPAB-RL: Found NAVIGATIONMESH at child %d/%d: node=%d, name=%s",
                                    i, j, grandchild, getName(grandchild) or "?")
                                -- Return the parent of the nav mesh (navigation root),
                                -- which is the rendering group for all animals
                                return child
                            end
                        end
                    end
                end
            end
        end
    end

    dbgLog("TPAB-RL: Could not find nav root node for barn %s", barnPlaceable:getName() or "?")
    return nil
end

--- Hide all visual animals in a barn by zeroing the visual animal budget.
-- Approach evolution:
-- 1. removeHusbandryAnimal: engine re-syncs visuals with cluster data, animals reappear
-- 2. setVisibility on navRootNode: nav node is not the parent of rendered animals,
--    the C++ husbandry renderer has its own rendering context
-- 3. (current) Zero maxVisualAnimals: tells the engine's ClusterHusbandry to render
--    zero animals during its visual sync. Also hides navRootNode and removes current
--    visual animals for immediate effect.
-- Barn cluster data (population, breeding, feeding) is untouched.
-- @param barnPlaceable table The barn placeable to suppress
-- @param animalAge number Animal age in months (stored for restore)
function ToPastureAndBack_RL.suppressBarnVisuals(barnPlaceable, rlAnimals)
    if barnPlaceable == nil then return end
    if ToPastureAndBack_RL.suppressedBarns[barnPlaceable] ~= nil then
        dbgLog("TPAB-RL: Barn %s already suppressed, skipping", barnPlaceable:getName() or "?")
        return
    end

    local spec = barnPlaceable.spec_husbandryAnimals
    if spec == nil or spec.clusterHusbandry == nil then return end
    local ch = spec.clusterHusbandry

    -- RL uses multiple husbandryIds (up to 8) per barn
    if ch.husbandryIds == nil or #ch.husbandryIds == 0 then
        dbgLog("TPAB-RL: No husbandryIds on barn %s, cannot suppress", barnPlaceable:getName() or "?")
        return
    end

    -- STEP 1: Remove visual animals from RL's 8-husbandry system,
    -- but ONLY for animals that are going to pasture (in rlAnimals).
    -- Young animals (below MIN_GRAZING_AGE) stay in the barn with their visuals.
    -- RL stores visuals in animalIdToCluster[husbandrySlot][animalId] = Animal
    -- Each Animal has .id = "slot-animalId" string and a deleteVisual() method.
    local removedCount = 0
    local keptCount = 0
    local totalVisuals = ch.visualAnimalCount or 0

    -- Build a lookup set of pastured animals for fast matching.
    -- We use direct object identity (rawequal) since rlAnimals contains the
    -- same RL Animal table references that animalIdToCluster stores.
    local pasturedSet = {}
    for _, animal in ipairs(rlAnimals or {}) do
        pasturedSet[animal] = true
    end
    local pasturedCount = 0
    for _ in pairs(pasturedSet) do pasturedCount = pasturedCount + 1 end

    if ch.animalIdToCluster ~= nil then
        for slotIdx, animalMap in pairs(ch.animalIdToCluster) do
            if type(animalMap) == "table" then
                local idsToRemove = {}
                for animalId, animal in pairs(animalMap) do
                    if pasturedSet[animal] then
                        -- This animal is going to pasture, remove its visual
                        table.insert(idsToRemove, { animalId = animalId, animal = animal })
                    else
                        -- This animal stays in the barn (e.g., too young), keep its visual
                        keptCount = keptCount + 1
                    end
                end
                for _, entry in ipairs(idsToRemove) do
                    local husEngineId = ch.husbandryIds[slotIdx]
                    if husEngineId ~= nil then
                        ToPastureAndBack_RL.fcall(removeHusbandryAnimal, husEngineId, entry.animalId)
                        if entry.animal ~= nil and entry.animal.deleteVisual ~= nil then
                            ToPastureAndBack_RL.fcall(entry.animal.deleteVisual, entry.animal)
                        end
                        -- Clear the RL animal's visual tracking
                        if entry.animal ~= nil then
                            entry.animal.id = nil
                            entry.animal.idFull = nil
                            entry.animal.visualAnimalIndex = nil
                        end
                        removedCount = removedCount + 1
                    end
                    animalMap[entry.animalId] = nil
                end
            end
        end
    end

    -- Update RL's visual count to reflect only the remaining (kept) visuals.
    -- If all animals were pastured, this becomes 0. If some young ones stayed,
    -- it becomes their count so RL's internal bookkeeping stays consistent.
    local origVisualCount = ch.visualAnimalCount or 0
    ch.visualAnimalCount = keptCount
    if ch.husbandryIdsToVisualAnimalCount ~= nil then
        -- We can't easily distribute keptCount across slots, but zeroing
        -- only matters for the repopulation guard. The hook blocks updateVisualAnimals
        -- entirely for suppressed barns, so these counts won't be used.
        for husId, _ in pairs(ch.husbandryIdsToVisualAnimalCount) do
            ch.husbandryIdsToVisualAnimalCount[husId] = 0
        end
    end
    -- Prevent RL's updateVisuals from running (the hook also blocks, this is belt-and-suspenders)
    ch.visualUpdatePending = false

    dbgLog("TPAB-RL: Suppressed barn %s: removed %d visuals, kept %d young (was %d total, %d pastured)",
        barnPlaceable:getName() or "?", removedCount, keptCount, totalVisuals, pasturedCount)

    -- Hide the nav root node only if ALL visuals were removed.
    -- If young animals were kept, they still need the nav mesh to walk around.
    local navRootNode = ToPastureAndBack_RL.findBarnNavRootNode(barnPlaceable)
    if navRootNode ~= nil and keptCount == 0 then
        ToPastureAndBack_RL.fcallNode(setVisibility, navRootNode, false)
        dbgLog("TPAB-RL: Also set navRootNode=%d invisible (all animals pastured)", navRootNode)
    elseif navRootNode ~= nil and keptCount > 0 then
        dbgLog("TPAB-RL: Keeping navRootNode=%d visible for %d young animals", navRootNode, keptCount)
    end

    -- Store restore data
    ToPastureAndBack_RL.suppressedBarns[barnPlaceable] = {
        hidden = true,
        origVisualCount = origVisualCount,
        navRootNode = navRootNode,
        navHidden = (keptCount == 0),  -- whether we actually hid the nav root
        removedCount = removedCount,
        keptCount = keptCount,
        rlAnimals = rlAnimals,  -- keep reference to RL Animal objects for restore
    }
end

--- Restore visual animals in a barn by triggering RL's own updateVisuals.
-- RL manages its own visual population across 8 husbandryIds per barn.
-- We just need to tell it to repopulate by setting visualUpdatePending=true
-- and providing the animal list via nextUpdateClusters.
-- @param barnPlaceable table The barn placeable to restore
function ToPastureAndBack_RL.restoreBarnVisuals(barnPlaceable)
    if barnPlaceable == nil then return end
    local suppData = ToPastureAndBack_RL.suppressedBarns[barnPlaceable]
    if suppData == nil then
        dbgLog("TPAB-RL: Barn %s was not suppressed, nothing to restore", barnPlaceable:getName() or "?")
        return
    end

    local spec = barnPlaceable.spec_husbandryAnimals
    if spec == nil or spec.clusterHusbandry == nil then
        ToPastureAndBack_RL.suppressedBarns[barnPlaceable] = nil
        return
    end
    local ch = spec.clusterHusbandry

    -- STEP 1: Restore nav root node visibility (only if we hid it)
    if suppData.navRootNode ~= nil and suppData.navHidden then
        ToPastureAndBack_RL.fcallNode(setVisibility, suppData.navRootNode, true)
    end

    -- STEP 2: Trigger RL's own visual repopulation.
    -- RL overrides PlaceableHusbandryAnimals.updateVisualAnimals to fetch animals
    -- from clusterSystem:getAnimals() and call clusterHusbandry:updateVisuals().
    -- The trigger chain: spec.updateVisuals=true -> onUpdate -> updateVisualAnimals()
    -- -> RL fetches animals -> creates visuals with ear tags, markers, breed models.
    local spec = barnPlaceable.spec_husbandryAnimals
    if spec ~= nil then
        spec.updateVisuals = true
        -- Also raise the placeable active so onUpdate fires on the next frame
        if barnPlaceable.raiseActive ~= nil then
            barnPlaceable:raiseActive()
        end
        local animalCount = #(suppData.rlAnimals or {})
        dbgLog("TPAB-RL: Restoring barn %s: set spec.updateVisuals=true for RL repopulation (%d animals)",
            barnPlaceable:getName() or "?", animalCount)
    else
        Logging.warning("TPAB-RL: Restoring barn %s: no spec_husbandryAnimals, cannot trigger visual update",
            barnPlaceable:getName() or "?")
    end

    ToPastureAndBack_RL.suppressedBarns[barnPlaceable] = nil
end


-- ============================================================================
-- GrazingSession data structure
-- ============================================================================

--- Create a new grazing session.
-- A session tracks one group of animals from one barn on one pasture.
-- @param barnPlaceable table The barn's placeable object
-- @param barnName string Display name for the barn
-- @param pasturePoint table The target PasturePoint
-- @param animalType string e.g. "COW", "SHEEP", "PIG", "HORSE"
-- @param animalCount number How many animals to display
-- @param durationHours number In-game hours for grazing
-- @param animalAge number Animal age in months (for correct visual model)
-- @return table GrazingSession
function ToPastureAndBack_RL.createGrazingSession(barnPlaceable, barnName, pasturePoint, animalType, animalCount, durationHours, animalAge, rlAnimals)
    local session = {
        id = string.format("%s_%d_%d", animalType, pasturePoint.id, math.random(1000, 9999)),
        barnPlaceable = barnPlaceable,
        barnName = barnName,
        pasturePoint = pasturePoint,
        animalType = animalType,
        animalCount = animalCount,
        animalAge = animalAge,  -- age in months, for visual model selection
        durationHours = durationHours,
        startDay = nil,         -- set when spawned
        startHour = nil,        -- set when spawned
        -- Visual state
        husId = nil,            -- husbandry ID from createAnimalHusbandry
        cloneNodeId = nil,      -- cloned nav mesh node ID
        animalIds = {},         -- list of animal IDs from addHusbandryAnimal
        fenceNodes = {},        -- list of cloned fence node IDs (poles + panels)
        spawnState = "pending", -- "pending", "waiting_ready", "waiting_hus_ready", "waiting_visuals", "active", "despawning", "done"
        readyFrames = 0,        -- frames waited for isHusbandryReady
        visualFrames = 0,       -- frames waited for model loading before createVisual
        spawnedAnimalData = nil, -- {husId, animalId, animal, earTagColours} per animal, for deferred createVisual
        farmlandId = nil,       -- set by confirmGrazingDestination for recall message
        classifiedSpecies = nil, -- "COW"/"BUFFALO"/"SHEEP"/"GOAT"/"MIXED_SHEEP_GOAT"/"PIG"/"HORSE", computed below
        -- RL: individual Animal objects for per-animal visual spawning and ear tags
        rlAnimals = rlAnimals or {},
    }
    -- Cache species classification once per session for consistent message rendering.
    -- Inspect rlAnimals while they're still populated (before suppression empties the barn).
    session.classifiedSpecies = ToPastureAndBack_RL.classifySpecies(animalType, {rlAnimals = session.rlAnimals})
    return session
end


-- ============================================================================
-- Visual herd spawning (Approach E: runtime nav mesh from contour polygon)
-- ============================================================================

--- Build a runtime pasture nav mesh over a field contour.
-- collisionMask RESULT (experiment 1, 2026-06-04, do not re-derive): the
-- engine REJECTS any nonzero collisionMask here. CollisionFlag.TERRAIN (256)
-- returned false cleanly on every build (pcall ok=true, result=false, no
-- engine error); only mask 0 builds. See the design doc sky-cow sections.
-- The mask-0 mesh is LAYERED: a terrain-following surface plus a
-- boundary-spanning contour cap that floats/buries ~1-2% of spawns on
-- non-flat fields. The cap cannot be excluded at build time; the ground
-- correction pass in runSpawnYDiag handles affected animals after spawn.
-- Validates with getNavMeshSurfaceArea, the same check the base game uses in
-- PlaceableHusbandryAnimals (binding absent from scriptBinding.xml but live
-- at game runtime; pcall + type-checked).
-- @return navNodeId or nil
function ToPastureAndBack_RL.buildPastureNavMesh(name, contourFlat, terrainNode, contourDeltaY, sessionId, animalTypeName)
    local navId = createNavMesh(name)
    if navId == nil or navId == 0 then
        Logging.warning("TPAB-RL: createNavMesh failed for %s session %s", animalTypeName, tostring(sessionId))
        return nil
    end
    link(getRootNode(), navId)
    local ok, success = ToPastureAndBack_RL.fcall(buildNavMeshFromContour,
        navId,
        contourFlat,
        terrainNode,
        0,           -- collisionMask: engine rejects nonzero values (see header)
        0.3,         -- cellSize
        0.1,         -- cellHeight
        1.6,         -- agentHeight
        0.5,         -- agentRadius
        0.3,         -- agentMaxClimb
        30.0,        -- agentMaxSlope
        8.0,         -- minRegionSize
        20.0,        -- mergeRegionSize
        6.0,         -- maxEdgeLength
        0.5)         -- maxSimplificationError
    if not ok or not success then
        Logging.warning("TPAB-RL: buildNavMeshFromContour failed (ok=%s, result=%s) for %s session %s",
            tostring(ok), tostring(success), animalTypeName, tostring(sessionId))
        ToPastureAndBack_RL.fcallNode(delete, navId)
        return nil
    end
    local area = nil
    local okA, a = ToPastureAndBack_RL.fcall(getNavMeshSurfaceArea, navId)
    if okA and type(a) == "number" then
        area = a
    end
    if area ~= nil and area <= 0 then
        Logging.warning("TPAB-RL: nav mesh has zero surface area for %s session %s, discarding",
            animalTypeName, tostring(sessionId))
        ToPastureAndBack_RL.fcallNode(delete, navId)
        return nil
    end
    dbgLog("TPAB-RL-NAV: mask=0 area=%s contourDeltaY=%.2fm type=%s session %s",
        tostring(area), contourDeltaY or -1, animalTypeName, tostring(sessionId))
    return navId
end

--- Spawn a visual herd on a pasture field.
-- Creates a nav mesh at runtime using buildNavMeshFromContour with a polygonal
-- contour matching the farmland boundary. No external I3D or shapes files needed.
-- Called from update() as a state machine (create -> wait ready -> add animals).
-- @param session table GrazingSession to spawn
-- @return boolean True if spawn initiated (may still be waiting for isHusbandryReady)
function ToPastureAndBack_RL.spawnVisualHerd(session)
    if session.spawnState ~= "pending" then
        return false
    end

    -- We still need barn data for the animal config (xmlFile, collisionMask, etc.)
    local barnData = ToPastureAndBack_RL.getBarnDataForType(session.animalType)
    if barnData == nil then
        Logging.warning("TPAB-RL: No barn found for animal type %s, cannot spawn", session.animalType)
        -- cert 2026-07-07 (M3): failed spawn must restore barn visuals. A bare
        -- spawnState="done" leaked permanent barn suppression; cleanupSession
        -- restores the barn and sets spawnState="done" itself.
        ToPastureAndBack_RL.cleanupSession(session)
        return false
    end

    local pp = session.pasturePoint
    local terrainNode = g_currentMission.terrainRootNode
    local fieldY = getTerrainHeightAtWorldPos(terrainNode, pp.x, 0, pp.z)

    local navNode

    if session.isPastureDestination then
        -- Pasture placeable destination: reuse the pasture's own nav mesh
        -- (same mesh that constrains animals purchased via the paw menu).
        -- 2026-05-05 night: use cached entry from event-execute time
        -- instead of re-querying by position (tight containment tests
        -- reject the barn nav for L-shaped yards because nav = building
        -- center, OUTSIDE the fenced yard ring). Defensive fallback to
        -- proximity-to-nav for cache-miss recovery.
        local pastureEntry = session.pastureBarnData
        if pastureEntry == nil then
            pastureEntry = ToPastureAndBack_RL.findBarnDataByPosition(
                session.animalType, pp.x, pp.z)
        end
        if pastureEntry == nil then
            Logging.warning("TPAB-RL: Cannot find pasture barn entry for session %s at (%.1f, %.1f)",
                session.id, pp.x, pp.z)
            session.spawnState = "done"
            return false
        end

        -- Re-resolve the nav HANDLE off the live placeable if the cached id went
        -- stale (the engine can rebuild a husbandry nav node after our initial scan).
        -- A stale-but-nonzero id slips past the ==0 check and would fail
        -- createAnimalHusbandry, so validate with entityExists and refresh the cache.
        navNode = pastureEntry.navNode
        local okBN, bnExists = ToPastureAndBack_RL.fcallNode(entityExists, navNode)
        if navNode == nil or navNode == 0 or not (okBN and bnExists) then
            local rp = pastureEntry.placeable
            local rspec = rp ~= nil and rp.spec_husbandryAnimals or nil
            local rch = rspec ~= nil and rspec.clusterHusbandry or nil
            local liveNav = rch ~= nil and rch.navigationNode or nil
            if liveNav ~= nil and liveNav ~= 0 then
                navNode = liveNav
                pastureEntry.navNode = liveNav
            end
        end
        if navNode == nil or navNode == 0 then
            Logging.warning("TPAB-RL: Pasture '%s' has no nav node, cannot spawn session %s",
                pastureEntry.name, session.id)
            session.spawnState = "done"
            return false
        end

        session.cloneNodeId = navNode
        session.borrowedNavMesh = true  -- don't delete on cleanup, we don't own this nav mesh
        dbgLog("TPAB-RL: Reusing pasture nav mesh from '%s' (navNode=%d) for session %s",
            pastureEntry.name, navNode, session.id)
    else
        -- Regular field destination: build the contour polygon, then the nav
        -- mesh (terrain-mask experiment + mask-0 fallback in buildPastureNavMesh).
        -- Build contour from polygon points (conforms to farmland boundary).
        -- Falls back to a rectangle if no contour data is available (legacy saves).
        local cx, cz = pp.x, pp.z
        local contourPts = pp.fieldContour
        if contourPts == nil or #contourPts < 4 then
            -- Fallback: build a rectangle from radius
            local fallbackR = pp.radius or ToPastureAndBack_RL.DEFAULT_RADIUS
            contourPts = {
                { x = cx - fallbackR, z = cz - fallbackR },
                { x = cx + fallbackR, z = cz - fallbackR },
                { x = cx + fallbackR, z = cz + fallbackR },
                { x = cx - fallbackR, z = cz + fallbackR },
            }
            dbgLog("TPAB-RL: Using fallback rectangular contour (radius=%.1f)", fallbackR)
        end

        -- Contour is a flat array of world-space XYZ positions for buildNavMeshFromContour.
        -- Use terrain height at each point for proper ground following.
        local contour = {}
        local minY, maxY = math.huge, -math.huge
        for i, cp in ipairs(contourPts) do
            local cornerY = getTerrainHeightAtWorldPos(terrainNode, cp.x, 0, cp.z)
            table.insert(contour, cp.x)
            table.insert(contour, cornerY)
            table.insert(contour, cp.z)
            if cornerY < minY then minY = cornerY end
            if cornerY > maxY then maxY = cornerY end
        end
        dbgLog("TPAB-RL: Contour elevation range: min=%.2f, max=%.2f, delta=%.2fm across %d points",
            minY, maxY, maxY - minY, #contourPts)
        session.contourDeltaY = maxY - minY

        navNode = ToPastureAndBack_RL.buildPastureNavMesh(
            "tpab_pasture_" .. session.id, contour, terrainNode,
            maxY - minY, session.id, session.animalType)
        if navNode == nil then
            session.spawnState = "done"
            return false
        end

        dbgLog("TPAB-RL: Built nav mesh from contour: center=(%.1f, %.1f), %d points",
            cx, cz, #contourPts)

        session.cloneNodeId = navNode
    end

    dbgLog("TPAB-RL: createAnimalHusbandry params: type=%s, xmlFile=%s, rayDist=%s, collMask=%s",
        session.animalType, tostring(barnData.xmlFile), tostring(barnData.rayDist), tostring(barnData.collMask))

    -- Create husbandry on our runtime-built nav mesh
    local husId = createAnimalHusbandry(
        session.animalType,
        navNode,
        barnData.xmlFile,
        barnData.rayDist or 10,
        CollisionMask.ANIMAL_POSITIONING,
        barnData.collMask,
        AudioGroup.ENVIRONMENT
    )

    if husId == nil or husId == 0 then
        Logging.warning("TPAB-RL: createAnimalHusbandry returned %s for session %s", tostring(husId), session.id)
        delete(navNode)
        session.cloneNodeId = nil
        session.spawnState = "done"
        return false
    end

    session.husId = husId
    session.spawnState = "waiting_ready"
    session.readyFrames = 0

    -- Record start time
    local env = g_currentMission.environment
    if env ~= nil then
        session.startDay = env.currentDay
        session.startHour = env.dayTime / 3600000  -- ms to hours
    end

    dbgLog("TPAB-RL: Husbandry created (husId=%d), waiting for ready...", husId)
    return true
end

--- Continue spawning Phase 1: wait for primary husbandry ready, create extras, add animals.
-- Does NOT call createVisual yet. Animal I3D models (including ear tag references)
-- load asynchronously after addHusbandryAnimal. We must wait several frames before
-- the full node hierarchy is available for RL's VisualAnimal:load() to resolve
-- ear tag, marker, and monitor nodes via safeIndexToObject + getChild.
-- Called from update() each frame for sessions in "waiting_ready" state.
-- @param session table GrazingSession
function ToPastureAndBack_RL.continueSpawn(session)
    if session.spawnState ~= "waiting_ready" then return end

    session.readyFrames = session.readyFrames + 1

    local ready = isHusbandryReady(session.husId)
    if not ready then
        if session.readyFrames > 60 then  -- timeout after 60 frames (~1 sec)
            Logging.warning("TPAB-RL: Husbandry not ready after %d frames, aborting session %s",
                session.readyFrames, session.id)
            ToPastureAndBack_RL.cleanupSession(session)
        end
        return
    end

    dbgLog("TPAB-RL: Husbandry ready after %d frames, adding %d animals",
        session.readyFrames, session.animalCount)

    local animalSystem = g_currentMission.animalSystem
    local rlAnimals = session.rlAnimals or {}
    local spawnCount = #rlAnimals

    if spawnCount == 0 then
        -- Fallback: if no RL animals stored (e.g. from a legacy save), use the old method
        Logging.warning("TPAB-RL: No RL animals on session %s, falling back to breed distribution", session.id)
        local breedList = ToPastureAndBack_RL.getBreedDistribution(
            session.barnPlaceable, session.animalCount, session.animalAge,
            { excludeYoung = true })
        for i = 1, #breedList do
            local visIdx = breedList[i]
            local animalId = addHusbandryAnimal(session.husId, visIdx)
            if animalId ~= nil and animalId > 0 then
                table.insert(session.animalIds, animalId)
                -- Round 4 port: visIdx only; fallback sessions have no RL
                -- animals, ear tags, or coat tiles to rebuild.
                session.rerollData = session.rerollData or {}
                session.rerollData[tostring(session.husId) .. ":" .. tostring(animalId)] = { visIdx = visIdx }
            end
        end
        session.spawnState = "active"
        dbgLog("TPAB-RL: Session %s active (fallback), %d animals on %s",
            session.id, #session.animalIds, session.pasturePoint.name)
        ToPastureAndBack_RL.scheduleSpawnYDiag(session)
        ToPastureAndBack_RL.createPastureFence(session)
        ToPastureAndBack_RL.suppressBarnVisuals(session.barnPlaceable, session.rlAnimals)
        return
    end

    dbgLog("TPAB-RL: Spawning %d individual RL animals on pasture (session %s)",
        spawnCount, session.id)

    -- Create additional husbandries on the same nav mesh if we need more than 25 animals.
    -- RL uses 8 husbandries per barn with 25 animals each (Ultra). We do the same.
    local MAX_PER_HUS = 25
    local MAX_HUSBANDRIES = 8
    local husIds = { session.husId }  -- first one already created by spawnVisualHerd
    local husAnimalCount = { 0 }
    local currentHusIdx = 1

    -- Pre-create extra husbandries if we need them
    local barnData = ToPastureAndBack_RL.getBarnDataForType(session.animalType)
    if spawnCount > MAX_PER_HUS and barnData ~= nil then
        local numExtraNeeded = math.min(math.ceil(spawnCount / MAX_PER_HUS) - 1, MAX_HUSBANDRIES - 1)
        for extra = 1, numExtraNeeded do
            local extraHus = createAnimalHusbandry(
                session.animalType, session.cloneNodeId,
                barnData.xmlFile, barnData.rayDist or 10,
                CollisionMask.ANIMAL_POSITIONING, barnData.collMask, AudioGroup.ENVIRONMENT)
            if extraHus ~= nil and extraHus ~= 0 then
                table.insert(husIds, extraHus)
                table.insert(husAnimalCount, 0)
                dbgLog("TPAB-RL: Created extra pasture husbandry %d/%d (husId=%d)",
                    extra + 1, numExtraNeeded + 1, extraHus)
            else
                Logging.warning("TPAB-RL: Failed to create extra husbandry %d", extra + 1)
                break
            end
        end
        dbgLog("TPAB-RL: Created %d pasture husbandries for %d animals", #husIds, spawnCount)
    end

    -- If we have extra husbandries, wait for them to be ready before adding animals
    if #husIds > 1 then
        session.pendingHusIds = husIds
        session.pendingHusAnimalCount = husAnimalCount
        session.spawnState = "waiting_hus_ready"
        session.readyFrames = 0
        dbgLog("TPAB-RL: Waiting for %d extra husbandries to be ready", #husIds - 1)
        return
    end

    -- Single husbandry, proceed directly to adding animals
    ToPastureAndBack_RL.addAnimalsToHusbandries(session, husIds, husAnimalCount)
end

--- Continue spawning Phase 1b: wait for ALL extra husbandries to be ready.
-- Called from update() each frame for sessions in "waiting_hus_ready" state.
-- @param session table GrazingSession
function ToPastureAndBack_RL.continueHusReady(session)
    if session.spawnState ~= "waiting_hus_ready" then return end

    session.readyFrames = session.readyFrames + 1

    local husIds = session.pendingHusIds or { session.husId }
    local allReady = true
    for _, hid in ipairs(husIds) do
        if not isHusbandryReady(hid) then
            allReady = false
            break
        end
    end

    if not allReady then
        if session.readyFrames > 120 then  -- timeout after ~2 sec
            Logging.warning("TPAB-RL: Extra husbandries not ready after %d frames, aborting session %s",
                session.readyFrames, session.id)
            ToPastureAndBack_RL.cleanupSession(session)
        end
        return
    end

    dbgLog("TPAB-RL: All %d husbandries ready after %d frames", #husIds, session.readyFrames)
    ToPastureAndBack_RL.addAnimalsToHusbandries(session, husIds, session.pendingHusAnimalCount or { 0 })
end

--- Add all RL animals to pasture husbandries (Phase 2 of spawn).
-- Adds animals via addHusbandryAnimal + setAnimalTextureTile but does NOT call
-- createVisual. Transitions to "waiting_visuals" state to allow I3D models
-- (including ear tag reference nodes) to finish loading before visual creation.
-- @param session table GrazingSession
-- @param husIds table list of husbandry IDs
-- @param husAnimalCount table per-husbandry animal counts
function ToPastureAndBack_RL.addAnimalsToHusbandries(session, husIds, husAnimalCount)
    local animalSystem = g_currentMission.animalSystem
    local rlAnimals = session.rlAnimals or {}
    local spawnCount = #rlAnimals
    local MAX_PER_HUS = 25
    local currentHusIdx = 1

    -- Fetch ear tag colors from the animal type config (same as RL's updateVisuals)
    local earTagColours = nil
    if animalSystem ~= nil and session.barnPlaceable ~= nil then
        local ok, typeIdx = ToPastureAndBack_RL.fcall(session.barnPlaceable.getAnimalTypeIndex, session.barnPlaceable)
        if ok and typeIdx ~= nil then
            local animalType = animalSystem.types[typeIdx]
            if animalType ~= nil then
                local colours = animalType.colours or animalSystem.baseColours
                if colours ~= nil and colours.earTagLeft ~= nil and colours.earTagLeft_text ~= nil then
                    earTagColours = colours
                else
                    earTagColours = animalSystem.baseColours
                end
            end
        end
    end

    -- Store per-animal spawn data for deferred createVisual
    session.spawnedAnimalData = {}

    for i, animal in ipairs(rlAnimals) do
        -- Get the correct visual index for this animal's breed and age
        local subTypeIdx = animal:getSubTypeIndex()
        local age = animal:getAge()
        age = age == -1 and 0 or age
        local visualAnimalIndex = nil  -- 1-based (RL convention)
        local visIdx = subTypeIdx - 1  -- 0-based fallback for addHusbandryAnimal

        if animalSystem ~= nil then
            local ok, result = ToPastureAndBack_RL.fcall(animalSystem.getVisualAnimalIndexByAge, animalSystem, subTypeIdx, age)
            if ok and result ~= nil then
                visualAnimalIndex = result
                visIdx = result - 1  -- 0-based for engine
            end
        end

        -- Cycle to next husbandry if current one is full
        while husAnimalCount[currentHusIdx] >= MAX_PER_HUS and currentHusIdx < #husIds do
            currentHusIdx = currentHusIdx + 1
        end
        if husAnimalCount[currentHusIdx] >= MAX_PER_HUS then
            Logging.warning("TPAB-RL: All %d pasture husbandries full at animal %d/%d",
                #husIds, i, spawnCount)
            break
        end

        local activeHusId = husIds[currentHusIdx]
        local animalId = addHusbandryAnimal(activeHusId, visIdx)

        -- If this husbandry rejected it, try the next ones
        while (animalId == nil or animalId == 0) and currentHusIdx < #husIds do
            currentHusIdx = currentHusIdx + 1
            activeHusId = husIds[currentHusIdx]
            animalId = addHusbandryAnimal(activeHusId, visIdx)
        end

        if animalId ~= nil and animalId > 0 then
            table.insert(session.animalIds, animalId)
            husAnimalCount[currentHusIdx] = husAnimalCount[currentHusIdx] + 1

            -- Coat variation (texture tile) is deferred to Phase 3 (continueVisuals)
            -- along with createVisual. If applied here before the I3D model finishes
            -- async loading, the engine ignores it and animals render with the default
            -- texture (e.g. Holsteins appear as Brown Swiss until createVisual runs).
            -- Resolve the variation index now so Phase 3 has it ready.
            local tileU, tileV = nil, nil
            if animalSystem ~= nil and visualAnimalIndex ~= nil then
                local ok3, visualData = ToPastureAndBack_RL.fcall(animalSystem.getVisualByAge, animalSystem, subTypeIdx, age)
                if ok3 and visualData ~= nil and visualData.visualAnimal ~= nil then
                    local variations = visualData.visualAnimal.variations
                    if variations ~= nil and #variations >= 1 then
                        local varIdx = animal.variation
                        if varIdx == nil or varIdx > #variations then
                            varIdx = math.random(1, #variations)
                            animal.variation = varIdx
                        end
                        local variation = variations[varIdx]
                        if variation ~= nil then
                            tileU = variation.tileUIndex
                            tileV = variation.tileVIndex
                        end
                    end
                end
            end

            -- Register in HUD lookup so PlayerHUDUpdater can resolve pasture animals
            if ToPastureAndBack_RL.pastureAnimalLookup[activeHusId] == nil then
                ToPastureAndBack_RL.pastureAnimalLookup[activeHusId] = {}
            end
            ToPastureAndBack_RL.pastureAnimalLookup[activeHusId][animalId] = animal

            -- Round 4 port: retain re-roll data so a cap-bound floater can
            -- be removed + re-added with identical identity and visuals
            -- (composite key: engine animal ids are only unique per husbandry).
            session.rerollData = session.rerollData or {}
            session.rerollData[tostring(activeHusId) .. ":" .. tostring(animalId)] = {
                visIdx = visIdx,
                animal = animal,
                earTagColours = earTagColours,
                tileU = tileU,
                tileV = tileV,
            }

            -- Store data for deferred createVisual (Phase 3)
            table.insert(session.spawnedAnimalData, {
                animal = animal,
                husId = activeHusId,
                animalId = animalId,
                earTagColours = earTagColours,
                tileU = tileU,
                tileV = tileV,
            })
        else
            Logging.warning("TPAB-RL: addHusbandryAnimal failed for animal %d/%d (visIdx=%d, tried %d husbandries)",
                i, spawnCount, visIdx, #husIds)
        end
    end

    -- Store all extra husbandry IDs for cleanup
    session.extraHusIds = {}
    for idx = 2, #husIds do
        table.insert(session.extraHusIds, husIds[idx])
    end
    if #session.extraHusIds > 0 then
        dbgLog("TPAB-RL: Stored %d extra husbandry IDs for cleanup", #session.extraHusIds)
    end

    -- Clean up temporary fields
    session.pendingHusIds = nil
    session.pendingHusAnimalCount = nil

    -- Transition to waiting_visuals: wait for I3D models (including ear tag
    -- reference nodes) to finish async loading before calling createVisual.
    session.spawnState = "waiting_visuals"
    session.visualFrames = 0
    dbgLog("TPAB-RL: Added %d/%d animals to pasture, waiting for models to load...",
        #session.animalIds, spawnCount)

    -- Suppress barn visuals immediately so the barn appears empty while models load
    ToPastureAndBack_RL.suppressBarnVisuals(session.barnPlaceable, session.rlAnimals)
end

--- Continue spawning Phase 3: wait for models to load, then create RL visuals.
-- Called from update() each frame for sessions in "waiting_visuals" state.
-- After addHusbandryAnimal, the engine loads animal I3D models asynchronously.
-- Ear tag sub-nodes (earTagScene.i3d references) need several frames to resolve.
-- Once loaded, we call createVisual + setVisualEarTagColours for each animal.
-- @param session table GrazingSession
function ToPastureAndBack_RL.continueVisuals(session)
    if session.spawnState ~= "waiting_visuals" then return end

    session.visualFrames = session.visualFrames + 1

    -- Wait 15 frames (~250ms at 60fps) for I3D models to fully load.
    -- RL's barn animals are loaded hundreds of frames before updateVisuals runs,
    -- so ear tag references are always resolved. Our pasture animals need the same
    -- settling time after addHusbandryAnimal before the full node hierarchy is ready.
    local VISUAL_WAIT_FRAMES = 15
    if session.visualFrames < VISUAL_WAIT_FRAMES then
        return
    end

    local spawnData = session.spawnedAnimalData or {}
    if #spawnData == 0 then
        dbgLog("TPAB-RL: No animal data for deferred visuals, activating session %s", session.id)
        session.spawnState = "active"
        ToPastureAndBack_RL.scheduleSpawnYDiag(session)
        session.spawnedAnimalData = nil
        ToPastureAndBack_RL.createPastureFence(session)
        return
    end

    dbgLog("TPAB-RL: Models loaded after %d frames, creating RL visuals for %d animals",
        session.visualFrames, #spawnData)

    -- Latch first (review 2026-10-11): a throw in the loop below happens once, not every frame.
    session.spawnState = "active"
    session.spawnedAnimalData = nil
    -- Fence and Y check BEFORE the loop (review 2026-10-27): if RL's code throws for one animal,
    -- the herd still gets its fence.
    ToPastureAndBack_RL.scheduleSpawnYDiag(session)
    ToPastureAndBack_RL.createPastureFence(session)
    local successCount = 0
    local skippedVisuals = 0
    for i, data in ipairs(spawnData) do
        local animal = data.animal
        local activeHusId = data.husId
        local animalId = data.animalId
        local earTagColours = data.earTagColours

        -- Apply coat texture BEFORE createVisual so the correct breed renders
        -- from the first visible frame. Must be after the 15-frame I3D load wait.
        if data.tileU ~= nil and data.tileV ~= nil then
            ToPastureAndBack_RL.fcall(setAnimalTextureTile, activeHusId, animalId, data.tileU, data.tileV)
        end

        -- fcall plus type guards, as the reroll path below (pcall-free since 2026-10-27, one
        -- standard for every Kijbev mod even though this edition never goes to ModHub).
        local visualReady = animal.createVisual ~= nil and type(activeHusId) == "number" and activeHusId ~= 0
            and type(animalId) == "number" and ToPastureAndBack_RL.canCreateRLVisual(animal)
        if not visualReady then
            skippedVisuals = skippedVisuals + 1
        end
        if visualReady then
            local ok2, err = ToPastureAndBack_RL.fcall(animal.createVisual, animal, activeHusId, animalId)
            if ok2 then
                -- Set ear tag colors (without this, text renders as black-on-black)
                if earTagColours ~= nil and animal.setVisualEarTagColours ~= nil then
                    ToPastureAndBack_RL.fcall(animal.setVisualEarTagColours, animal,
                        earTagColours.earTagLeft, earTagColours.earTagLeft_text,
                        earTagColours.earTagRight, earTagColours.earTagRight_text)
                end

                -- Propagate atlas texture to ALL mesh nodes (including LOD meshes).
                -- setAnimalTextureTile only sets the primary mesh. RL's updateVisuals
                -- does this same post-pass: read the atlas UV from the engine, then
                -- apply it recursively via setShaderParameterRec to the root node.
                -- Without this, distant LOD models render with the default breed texture.
                local ok3, rootNode = ToPastureAndBack_RL.fcall(getAnimalRootNode, activeHusId, animalId)
                if ok3 and rootNode ~= nil and rootNode ~= 0 then
                    local ok4, ax, ay, az, aw = ToPastureAndBack_RL.fcall(getAnimalShaderParameter, activeHusId, animalId, "atlasInvSizeAndOffsetUV")
                    if ok4 and ax ~= nil then
                        I3DUtil.setShaderParameterRec(rootNode, "atlasInvSizeAndOffsetUV", ax, ay, az, aw)
                    end
                    -- Also set dirt factor to match RL's post-pass
                    I3DUtil.setShaderParameterRec(rootNode, "dirt", 0.1, nil, nil, nil)
                end

                successCount = successCount + 1
            else
                Logging.warning("TPAB-RL: createVisual failed for animal %d/%d: %s",
                    i, #spawnData, tostring(err))
            end
        end
    end

    -- Clean up deferred data
    session.spawnedAnimalData = nil

    session.spawnState = "active"
    dbgLog("TPAB-RL: Session %s active, %d/%d visuals created (%d skipped: no birthday or age model), %d animals on %s",
        session.id, successCount, #spawnData, skippedVisuals, #session.animalIds,
        session.pasturePoint.name)
end

--- Despawn a visual herd and clean up all rendering resources.
-- Also restores barn visuals so animals reappear in the barn.
-- @param session table GrazingSession to clean up
function ToPastureAndBack_RL.cleanupSession(session, skipBarnRestore)
    -- Remove temporary fence
    ToPastureAndBack_RL.removePastureFence(session)

    -- RL: Delete RL visuals (ear tags, markers) from pasture animals before removing them.
    -- These were created by animal:createVisual() in continueVisuals.
    session.spawnedAnimalData = nil  -- clear any pending deferred visual data
    if session.rlAnimals ~= nil then
        for _, animal in ipairs(session.rlAnimals) do
            if animal ~= nil and animal.deleteVisual ~= nil then
                ToPastureAndBack_RL.fcall(animal.deleteVisual, animal)
            end
        end
        dbgLog("TPAB-RL: Deleted RL visuals for %d pasture animals", #session.rlAnimals)
    end

    -- Clear HUD lookup entries for this session's husbandries
    if session.husId ~= nil then
        ToPastureAndBack_RL.pastureAnimalLookup[session.husId] = nil
    end
    if session.extraHusIds ~= nil then
        for _, extraHusId in ipairs(session.extraHusIds) do
            ToPastureAndBack_RL.pastureAnimalLookup[extraHusId] = nil
        end
    end

    -- Remove pasture husbandries (deleting a husbandry removes all its animals).
    -- Delete extra husbandries first, then the primary one.
    if session.extraHusIds ~= nil then
        for _, extraHusId in ipairs(session.extraHusIds) do
            ToPastureAndBack_RL.fcallNode(delete, extraHusId)
        end
        dbgLog("TPAB-RL: Deleted %d extra pasture husbandries", #session.extraHusIds)
    end
    if session.husId ~= nil and session.husId ~= 0 then
        ToPastureAndBack_RL.fcallNode(delete, session.husId)
    end

    if session.cloneNodeId ~= nil and session.cloneNodeId ~= 0 then
        if session.borrowedNavMesh then
            -- Nav mesh belongs to the pasture placeable, don't delete it
            dbgLog("TPAB-RL: Skipping nav mesh delete for session %s (borrowed from pasture)", session.id)
        else
            ToPastureAndBack_RL.fcallNode(delete, session.cloneNodeId)
        end
    end

    -- Restore barn visuals (rendering slots are freed).
    -- Skip during map unload: engine is tearing down, addHusbandryAnimal will fail.
    if not ToPastureAndBack_RL.mapUnloading and not skipBarnRestore then
        ToPastureAndBack_RL.restoreBarnVisuals(session.barnPlaceable)
    end

    session.animalIds = {}
    session.fenceNodes = {}
    session.husId = nil
    session.extraHusIds = nil
    session.cloneNodeId = nil
    session.pendingHusIds = nil
    session.pendingHusAnimalCount = nil
    session.spawnedAnimalData = nil
    session.spawnState = "done"

    dbgLog("TPAB-RL: Session %s cleaned up", session.id)
end


-- ============================================================================
-- Temporary pasture fences
-- ============================================================================

--- Load the fence I3D template (sheepNetFence) and cache it for cloning.
-- Called once, on first use. The loaded root node stays in memory for the session.
function ToPastureAndBack_RL.loadFenceTemplate()
    if ToPastureAndBack_RL.fenceTemplateLoaded then
        return ToPastureAndBack_RL.fenceTemplateRoot ~= nil
    end
    ToPastureAndBack_RL.fenceTemplateLoaded = true

    local i3dPath = ToPastureAndBack_RL.FENCE_I3D_PATH
    local rootNode = g_i3DManager:loadI3DFile(i3dPath, false, false)
    if rootNode == nil or rootNode == 0 then
        Logging.warning("TPAB-RL: Failed to load fence I3D: %s", i3dPath)
        return false
    end

    -- Hide the template (we only clone from it, never render it directly)
    setVisibility(rootNode, false)
    link(getRootNode(), rootNode)
    ToPastureAndBack_RL.fenceTemplateRoot = rootNode

    dbgLog("TPAB-RL: Fence template loaded from %s (rootNode=%d, children=%d)", i3dPath, rootNode, getNumOfChildren(rootNode))
    return true
end

--- Collect all fence segments (from map fences, player fences, and barn fences)
-- that are within searchRadius of the given center point.
-- Returns a flat list of {x1, z1, x2, z2} tables in world coordinates.
-- @param centerX number World X of contour center
-- @param centerZ number World Z of contour center
-- @param searchRadius number Max distance from center to consider
-- @return table List of {x1, z1, x2, z2} segments
function ToPastureAndBack_RL.collectNearbyFenceSegments(centerX, centerZ, searchRadius)
    local result = {}
    local radiusSq = searchRadius * searchRadius
    local placeables = g_currentMission.placeableSystem.placeables

    if placeables == nil then
        return result
    end

    for _, placeable in pairs(placeables) do
        -- Type 1: Map-maker fences (PlaceableFence, spec_fence)
        local specFence = placeable.spec_fence
        if specFence ~= nil and specFence.segments ~= nil then
            for _, seg in pairs(specFence.segments) do
                if seg.x1 ~= nil and seg.z1 ~= nil and seg.x2 ~= nil and seg.z2 ~= nil then
                    -- Check if segment midpoint is within search radius
                    local mx = (seg.x1 + seg.x2) * 0.5
                    local mz = (seg.z1 + seg.z2) * 0.5
                    local dxC = mx - centerX
                    local dzC = mz - centerZ
                    if (dxC * dxC + dzC * dzC) <= radiusSq then
                        table.insert(result, {x1 = seg.x1, z1 = seg.z1, x2 = seg.x2, z2 = seg.z2})
                    end
                end
            end
        end

        -- Type 2 & 3: Player fences (spec_newFence) and barn fences (spec_husbandryFence)
        -- Both use getFence().segments with startPosX/Z, endPosX/Z
        for _, specName in ipairs({"spec_newFence", "spec_husbandryFence"}) do
            local spec = placeable[specName]
            if spec ~= nil and placeable.getFence ~= nil then
                local ok, fence = ToPastureAndBack_RL.fcall(placeable.getFence, placeable)
                if ok and fence ~= nil and fence.segments ~= nil then
                    for _, seg in ipairs(fence.segments) do
                        if seg.startPosX ~= nil and seg.startPosZ ~= nil and seg.endPosX ~= nil and seg.endPosZ ~= nil then
                            local mx = (seg.startPosX + seg.endPosX) * 0.5
                            local mz = (seg.startPosZ + seg.endPosZ) * 0.5
                            local dxC = mx - centerX
                            local dzC = mz - centerZ
                            if (dxC * dxC + dzC * dzC) <= radiusSq then
                                table.insert(result, {x1 = seg.startPosX, z1 = seg.startPosZ, x2 = seg.endPosX, z2 = seg.endPosZ})
                            end
                        end
                    end
                end
            end
        end
    end

    dbgLog("TPAB-RL: Collected %d fence segments near (%.1f, %.1f) within %.0fm", #result, centerX, centerZ, searchRadius)
    return result
end

--- Raycast callback for static fence detection. Sets fenceRaycastHit = true
-- when a static object is hit (ignoring terrain).
-- @param nodeId number Hit node ID
-- @return boolean false to stop reporting further hits
function ToPastureAndBack_RL:fenceRaycastCallback(nodeId, x, y, z, distance, nx, ny, nz, subShapeIndex, shapeId, isLast)
    if nodeId ~= nil and nodeId ~= 0 and nodeId ~= g_terrainNode then
        ToPastureAndBack_RL.fenceRaycastHit = true
        ToPastureAndBack_RL.fenceRaycastDist = distance
        ToPastureAndBack_RL.fenceRaycastNodeId = nodeId
    end
    return false
end

--- Probe a contour edge for baked-in (static I3D) fences using raycasts.
-- Casts horizontal rays perpendicular to the edge at sample points, detecting
-- static collision geometry that indicates a fence post or panel.
-- @param p1 table {x, z} Start point of contour edge
-- @param p2 table {x, z} End point of contour edge
-- @param cx number Polygon center X (used to determine outward direction)
-- @param cz number Polygon center Z
-- @return boolean true if the edge appears to have a static fence alongside it
function ToPastureAndBack_RL.probeStaticFenceOnEdge(p1, p2, cx, cz)
    local edgeDx = p2.x - p1.x
    local edgeDz = p2.z - p1.z
    local edgeLen = math.sqrt(edgeDx * edgeDx + edgeDz * edgeDz)
    if edgeLen < 1.0 then
        return false
    end

    local spacing = ToPastureAndBack_RL.FENCE_RAYCAST_SPACING
    local maxDist = ToPastureAndBack_RL.FENCE_RAYCAST_MAX_DIST
    local rayHeight = ToPastureAndBack_RL.FENCE_RAYCAST_HEIGHT
    local hitRatio = ToPastureAndBack_RL.FENCE_RAYCAST_HIT_RATIO
    local terrainNode = g_currentMission.terrainRootNode

    -- Edge direction (normalized)
    local edgeNx = edgeDx / edgeLen
    local edgeNz = edgeDz / edgeLen

    -- Perpendicular direction (two options: rotate 90 degrees CW or CCW)
    -- Choose the one pointing AWAY from the polygon center
    local perpAx, perpAz = -edgeNz, edgeNx   -- rotated 90 CW
    local midX = (p1.x + p2.x) * 0.5
    local midZ = (p1.z + p2.z) * 0.5
    local toCenterX = cx - midX
    local toCenterZ = cz - midZ
    -- If perpA points toward the center, flip it
    if (perpAx * toCenterX + perpAz * toCenterZ) > 0 then
        perpAx, perpAz = -perpAx, -perpAz
    end

    -- Sample points along the edge
    local nSamples = math.max(2, math.floor(edgeLen / spacing) + 1)
    local hits = 0

    for s = 0, nSamples - 1 do
        local t = s / (nSamples - 1)
        local sx = p1.x + edgeDx * t
        local sz = p1.z + edgeDz * t
        local sy = getTerrainHeightAtWorldPos(terrainNode, sx, 0, sz) + rayHeight

        -- Cast ray outward from the polygon edge
        ToPastureAndBack_RL.fenceRaycastHit = false
        raycastClosest(sx, sy, sz, perpAx, 0, perpAz, maxDist, "fenceRaycastCallback", ToPastureAndBack_RL, CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING)

        if ToPastureAndBack_RL.fenceRaycastHit then
            hits = hits + 1
        end

        -- Also cast inward (fence might be on the inside of the contour)
        if not ToPastureAndBack_RL.fenceRaycastHit then
            ToPastureAndBack_RL.fenceRaycastHit = false
            raycastClosest(sx, sy, sz, -perpAx, 0, -perpAz, maxDist, "fenceRaycastCallback", ToPastureAndBack_RL, CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING)
            if ToPastureAndBack_RL.fenceRaycastHit then
                hits = hits + 1
            end
        end
    end

    local ratio = hits / nSamples
    if ratio >= hitRatio then
        dbgLog("TPAB-RL: Static fence detected on edge (%.0f,%.0f)-(%.0f,%.0f): %d/%d rays hit (%.0f%%)",
            p1.x, p1.z, p2.x, p2.z, hits, nSamples, ratio * 100)
        return true
    end
    return false
end

--- Test whether the area around (cx, cz) is enclosed by collision objects on
-- all sides. Casts radial rays from the center; if most rays hit collision
-- within maxRay, the area is treated as enclosed regardless of how the
-- enclosing geometry is stored: placeable fence, baked map fence mesh, walls,
-- hedges with collision, or buildings forming a perimeter. This catches cases
-- the contour-based coverage check misses, e.g. when scanFieldExtent produces
-- a contour larger than the actual fenced area so most contour edges are too
-- far from the real fence to register a perpendicular hit.
-- Verified necessary on Pichonniere Farmland 6, where the perimeter fence is
-- a static map mesh (not a placeable) and 78% of contour edges were >12m
-- away from any fence.
-- @param cx number Center X
-- @param cz number Center Z
-- @param contourMaxRadius number|nil Hint: maximum distance from center to a
--                                     contour vertex; rays reach a bit further.
-- @return boolean enclosed True if at least (NUM_RAYS - tolerance) rays hit collision
function ToPastureAndBack_RL.isAreaRadiallyEnclosed(cx, cz, contourMaxRadius, farmlandId)
    -- 2026-05-05: farmlandId param (optional). When set and > 0, each ray's
    -- effective max distance is clamped to the source farmland's boundary.
    -- Prevents the contour from extending past the source farmland and
    -- including roads/adjacent farmlands when the local fence has gaps and
    -- the ray flies through to hit a fence in a different farmland.
    -- Pichonniere-Pasture-1 repro 2026-05-05: 36/36 hits at 30-88m, contour
    -- vertices at 88m extended into Farmland 3 territory, cows walked there.
    local terrainNode = g_currentMission and g_currentMission.terrainRootNode
    if terrainNode == nil then return false, nil end
    local clampToFarmland = farmlandId ~= nil and farmlandId > 0
            and g_farmlandManager ~= nil and g_farmlandManager.getFarmlandIdAtWorldPosition ~= nil
    -- Ray reach: enough to clear the contour plus a generous overshoot for fences
    -- that sit outside the farmland-derived contour boundary.
    local maxRay = math.max(60, (contourMaxRadius or 0) + 20)
    local NUM_RAYS = 36
    -- TOLERANCE is load-bearing (see Phase1_Spec "Load-Bearing Guards"). Keeps
    -- Etruria-style truly-open fields registering as not enclosed.
    local TOLERANCE = 4
    local ENCLOSED_THRESHOLD = NUM_RAYS - TOLERANCE
    -- Step size 1m (was 4m, 2026-05-04): re-anchors Y to local terrain at every
    -- meter. On a slope, a 4m horizontal segment from terrain+1m can fly 1-2m
    -- above local terrain by the segment's end and skip over a 1m fence post
    -- (verified Pichonniere 2026-05-04, 2/36 rays missed despite a complete
    -- fence). 1m steps keep the ray hugging the terrain.
    local STEP_SIZE = 1
    -- Multi-height sampling per step (additive, not a filter swap): 3 ray heights
    -- cover both the slope-flying-over case (2.0m catches taller fence at lower
    -- ground) AND the slope-going-underground case (0.3m catches fence base when
    -- ray starts higher than fence). ANY height hitting counts for the step.
    local RAY_HEIGHTS = { 0.3, 1.0, 2.0 }
    local NUM_HEIGHTS = #RAY_HEIGHTS
    local collMask = CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING

    local hitCount = 0
    local boundaryHits = 0  -- 2026-05-05: rays terminated at farmland edge (not fence)
    local minHit, maxHit = nil, nil
    -- Per-direction record so callers can build a fence-aligned contour.
    -- hitArr[i] = { angle = θ, dist = d } on hit, or { angle = θ, miss = true } on miss.
    local hitArr = {}

    for i = 0, NUM_RAYS - 1 do
        local angle = (i / NUM_RAYS) * 2 * math.pi
        local dirX = math.cos(angle)
        local dirZ = math.sin(angle)

        local hit = false
        local hitDist = nil
        local stepStartDist = 0
        while stepStartDist < maxRay do
            local sx = cx + dirX * stepStartDist
            local sz = cz + dirZ * stepStartDist
            local okT, ty = ToPastureAndBack_RL.fcall(getTerrainHeightAtWorldPos, terrainNode, sx, 0, sz)
            if not okT or ty == nil then break end

            local stepLen = math.min(STEP_SIZE, maxRay - stepStartDist)
            -- Try each ray height; first hit at any height counts the step as hit.
            local stepHit = false
            local stepHitDist = nil
            for hi = 1, NUM_HEIGHTS do
                local sy = ty + RAY_HEIGHTS[hi]
                ToPastureAndBack_RL.fenceRaycastHit = false
                ToPastureAndBack_RL.fenceRaycastDist = nil
                raycastClosest(sx, sy, sz, dirX, 0, dirZ, stepLen,
                    "fenceRaycastCallback", ToPastureAndBack_RL, collMask)
                if ToPastureAndBack_RL.fenceRaycastHit then
                    stepHit = true
                    local d = stepStartDist + (ToPastureAndBack_RL.fenceRaycastDist or 0)
                    if stepHitDist == nil or d < stepHitDist then
                        stepHitDist = d
                    end
                end
            end
            if stepHit then
                hit = true
                hitDist = stepHitDist
                break
            end

            -- Farmland boundary clamp: if the end of this step is in a
            -- different farmland (or on a road, where farmlandId == 0),
            -- terminate the ray here. The contour vertex at this angle
            -- gets placed at the farmland edge instead of running to
            -- maxRay or hitting an unrelated fence in a neighbor.
            if clampToFarmland then
                local endX = sx + dirX * stepLen
                local endZ = sz + dirZ * stepLen
                local okF, fid = ToPastureAndBack_RL.fcall(g_farmlandManager.getFarmlandIdAtWorldPosition,
                    g_farmlandManager, endX, endZ)
                if okF and fid ~= nil and fid ~= farmlandId then
                    hit = true
                    hitDist = stepStartDist + stepLen
                    boundaryHits = boundaryHits + 1
                    break
                end
            end

            stepStartDist = stepStartDist + STEP_SIZE
        end

        if hit then
            hitCount = hitCount + 1
            if minHit == nil or hitDist < minHit then minHit = hitDist end
            if maxHit == nil or hitDist > maxHit then maxHit = hitDist end
            hitArr[i + 1] = { angle = angle, dist = hitDist }
        else
            hitArr[i + 1] = { angle = angle, miss = true }
        end
    end

    -- Real hits = stepped-ray collisions that found an actual STATIC_OBJECT
    -- or BUILDING within the farmland. Boundary-clamp "hits" do NOT count
    -- toward enclosure because the farmland edge isn't a fence; the clamp
    -- exists to terminate the ray and place a contour vertex at the
    -- boundary, not to claim the boundary itself stops cows. See F2 on
    -- Pichonniere (borrowed-fence pattern) regression-guard.
    local realHits = hitCount - boundaryHits
    local enclosed = realHits >= ENCLOSED_THRESHOLD
    dbgLog("TPAB-RL: isAreaRadiallyEnclosed at (%.1f, %.1f): %d/%d stepped rays hit (real=%d, boundaryClamp=%d, max=%.1fm, step=%dm, heights=%d), nearest=%.1fm, farthest=%.1fm, enclosed=%s",
        cx, cz, hitCount, NUM_RAYS, realHits, boundaryHits, maxRay, STEP_SIZE, NUM_HEIGHTS,
        minHit or -1, maxHit or -1, tostring(enclosed))
    -- 2026-05-09: return realHits as 3rd value so the F6 swap gate (in
    -- confirmGrazingDestination) can require a minimum real-fence-hit count
    -- before replacing the farmland contour. Helden field 62 surfaced a
    -- regression where 36/36 hits were ALL boundary clamps (real=0) yet the
    -- swap still fired, inflating the polygon onto the farmland's adjacent
    -- dirt road. Existing callers using 2-return assignment are unaffected.
    return enclosed, hitArr, realHits
end

--- Build a closed polygon from radial-scan hit data, pulled inward by `bufferM`.
-- Used to align the nav mesh contour to the actual fence boundary detected by
-- isAreaRadiallyEnclosed instead of using the smaller farmland-derived contour.
-- The inward buffer (default 3.0m) prevents animals from clipping into the fence
-- visually. Animal body width is ~1m and pathfinding/animation jitter adds
-- another ~1m, so a 3m buffer gives ~2m of safe visual margin to the wire.
-- Calibrated 2026-05-08 after F6 cows escaped at 1m buffer.
-- Missed-ray directions (gates/openings) are filled by averaging the nearest
-- hit distances on either side, so the polygon stays closed.
-- @param cx number Center X of the radial scan
-- @param cz number Center Z
-- @param hits table Array from isAreaRadiallyEnclosed second return value
-- @param bufferM number|nil Inward buffer in meters (default 3.0)
-- @return table|nil Array of {x, z} polygon vertices, or nil if fewer than 8
--                   directions had usable distance data after gap-filling.
function ToPastureAndBack_RL.buildContourFromRadialHits(cx, cz, hits, bufferM)
    if hits == nil then return nil end
    local n = #hits
    if n < 8 then return nil end
    bufferM = bufferM or 3.0

    -- Pass 1: collect hit distances by index, leaving misses as nil.
    local dists = {}
    for i = 1, n do
        if hits[i] ~= nil and not hits[i].miss and hits[i].dist ~= nil then
            dists[i] = hits[i].dist
        end
    end

    -- Pass 2: fill missing entries by averaging nearest hits on either side.
    for i = 1, n do
        if dists[i] == nil then
            local prevD, nextD = nil, nil
            for k = 1, n do
                local j = ((i - 1 - k) % n) + 1
                if dists[j] ~= nil then prevD = dists[j]; break end
            end
            for k = 1, n do
                local j = ((i - 1 + k) % n) + 1
                if dists[j] ~= nil then nextD = dists[j]; break end
            end
            if prevD ~= nil and nextD ~= nil then
                dists[i] = (prevD + nextD) * 0.5
            elseif prevD ~= nil then
                dists[i] = prevD
            elseif nextD ~= nil then
                dists[i] = nextD
            else
                return nil  -- all misses, can't reconstruct
            end
        end
    end

    -- Pass 3: build polygon, pulling each vertex inward by bufferM.
    -- Minimum distance clamp at 2m so we never collapse to a point or invert.
    local result = {}
    for i = 1, n do
        local angle = hits[i].angle
        local effDist = math.max(2.0, dists[i] - bufferM)
        table.insert(result, {
            x = cx + math.cos(angle) * effDist,
            z = cz + math.sin(angle) * effDist,
        })
    end

    -- Sanity: polygon area must be reasonable (>=100 sqm, otherwise nav mesh
    -- build would fail and we'd be better off with the farmland contour).
    local area = 0
    for i = 1, n do
        local j = (i % n) + 1
        area = area + (result[i].x * result[j].z)
        area = area - (result[j].x * result[i].z)
    end
    area = math.abs(area) / 2
    if area < 100 then
        dbgLog("TPAB-RL: buildContourFromRadialHits: degenerate area %.0f sqm, rejecting", area)
        return nil
    end

    dbgLog("TPAB-RL: buildContourFromRadialHits: %d-point fence-aligned contour, area=%.0f sqm, buffer=%.1fm",
        #result, area, bufferM)
    return result
end

--- 2026-05-08 F2 fix: split fence segments into one polygon per connected
-- ring. Map-maker placeables can contain multiple disjoint fence rings (e.g.
-- Pichonniere has a single "Fence" placeable that holds both F1's perimeter
-- and F3's perimeter as separate rings). The convex-hull buildFencePolygon
-- below treats them as one big hull and the hull spans F2 in the middle
-- (false-positive enclosure -> temp fence skipped -> cows escape).
--
-- This function walks segments by matching endpoints, returning each
-- connected component as its own ordered polygon (no hull, no smoothing).
-- Endpoint matching tolerance is 0.5m which is plenty for placed-fence
-- post precision.
--
-- @param segments table  Array of {startPosX, startPosZ, endPosX, endPosZ}
-- @return table          Array of ring polygons, each an array of {x, z}
function ToPastureAndBack_RL.buildFencePolygons(segments)
    if segments == nil or #segments < 3 then return {} end

    local TOL_SQ = 0.5 * 0.5
    local visited = {}
    local rings = {}

    local function near(ax, az, bx, bz)
        local dx, dz = ax - bx, az - bz
        return (dx * dx + dz * dz) < TOL_SQ
    end

    -- Find an unvisited segment with an endpoint near (tx, tz).
    -- Returns segIdx, reversed (false if start matches, true if end matches).
    local function findMatch(tx, tz)
        for i, s in ipairs(segments) do
            if not visited[i]
                    and s.startPosX ~= nil and s.endPosX ~= nil then
                if near(s.startPosX, s.startPosZ, tx, tz) then
                    return i, false
                end
                if near(s.endPosX, s.endPosZ, tx, tz) then
                    return i, true
                end
            end
        end
        return nil, false
    end

    for startIdx, startSeg in ipairs(segments) do
        if not visited[startIdx]
                and startSeg.startPosX ~= nil and startSeg.endPosX ~= nil then
            visited[startIdx] = true
            local ring = {{x = startSeg.startPosX, z = startSeg.startPosZ}}
            local tailX, tailZ = startSeg.endPosX, startSeg.endPosZ
            table.insert(ring, {x = tailX, z = tailZ})

            -- Walk the chain forward from the tail
            local guard = #segments + 1  -- prevent infinite loops on weird topologies
            while guard > 0 do
                guard = guard - 1
                local nextIdx, reversed = findMatch(tailX, tailZ)
                if nextIdx == nil then break end
                visited[nextIdx] = true
                local s = segments[nextIdx]
                if reversed then
                    tailX, tailZ = s.startPosX, s.startPosZ
                else
                    tailX, tailZ = s.endPosX, s.endPosZ
                end
                table.insert(ring, {x = tailX, z = tailZ})
                -- Stop if we've closed back to the start (proper ring)
                if near(tailX, tailZ,
                        startSeg.startPosX, startSeg.startPosZ) then
                    break
                end
            end

            -- Walk backward from the original start as well, in case the chain
            -- extends in both directions (open chains where startSeg is mid-chain).
            tailX, tailZ = startSeg.startPosX, startSeg.startPosZ
            guard = #segments + 1
            while guard > 0 do
                guard = guard - 1
                local prevIdx, reversed = findMatch(tailX, tailZ)
                if prevIdx == nil then break end
                visited[prevIdx] = true
                local s = segments[prevIdx]
                if reversed then
                    tailX, tailZ = s.startPosX, s.startPosZ
                else
                    tailX, tailZ = s.endPosX, s.endPosZ
                end
                table.insert(ring, 1, {x = tailX, z = tailZ})
            end

            if #ring >= 3 then
                table.insert(rings, ring)
            end
        end
    end

    return rings
end

--- Check what fraction of a contour polygon's perimeter is already covered by
-- existing fence segments (Placeable-based) or baked-in static fences (raycast-based).
-- A contour edge is "covered" if a Placeable fence segment runs nearby and roughly
-- parallel, OR if raycasts perpendicular to the edge detect static collision geometry.
-- @param contourPts table Array of {x, z} points forming the contour polygon
-- @param fenceSegments table Array of {x1, z1, x2, z2} from collectNearbyFenceSegments
-- @param cx number Polygon center X (for raycast outward direction)
-- @param cz number Polygon center Z
-- @return number Coverage fraction (0.0 to 1.0)
--- Build a containment polygon from a list of FenceSegment objects by taking
-- the convex hull of all segment endpoints. This is more robust than ordered
-- chaining: it survives gates, branches, multiple sub-rings, and unordered
-- segment data. For any roughly-convex fenced area (most real-world farm
-- fences) the convex hull is a correct superset of "inside the fence."
-- For highly concave shapes the hull over-includes the concave pocket, which
-- is still useful for our "is this area fenced?" question but not exact.
-- @param segments table Array of FenceSegment objects with startPosX/Z, endPosX/Z
-- @return table|nil Polygon as array of {x, z} (convex hull), or nil if not enough points
function ToPastureAndBack_RL.buildFencePolygon(segments)
    if segments == nil or #segments < 3 then return nil end

    -- Collect all endpoints
    local pts = {}
    for _, seg in ipairs(segments) do
        if seg.startPosX ~= nil and seg.startPosZ ~= nil then
            table.insert(pts, {x = seg.startPosX, z = seg.startPosZ})
        end
        if seg.endPosX ~= nil and seg.endPosZ ~= nil then
            table.insert(pts, {x = seg.endPosX, z = seg.endPosZ})
        end
    end
    if #pts < 3 then return nil end

    -- Deduplicate points within a small tolerance so the hull construction is stable.
    -- Cheap approach: quantize to 0.1m grid and keep one representative per cell.
    local unique = {}
    local dedup = {}
    for _, p in ipairs(pts) do
        local key = string.format("%d:%d", math.floor(p.x * 10), math.floor(p.z * 10))
        if dedup[key] == nil then
            dedup[key] = true
            table.insert(unique, p)
        end
    end
    if #unique < 3 then return nil end

    -- Sort points by (x, then z)
    table.sort(unique, function(a, b)
        if a.x == b.x then return a.z < b.z end
        return a.x < b.x
    end)

    -- Andrew's monotone chain convex hull.
    -- cross(o, a, b) > 0 means counter-clockwise turn from oa to ob.
    local function cross(o, a, b)
        return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
    end

    local lower = {}
    for i = 1, #unique do
        while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], unique[i]) <= 0 do
            table.remove(lower, #lower)
        end
        table.insert(lower, unique[i])
    end

    local upper = {}
    for i = #unique, 1, -1 do
        while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], unique[i]) <= 0 do
            table.remove(upper, #upper)
        end
        table.insert(upper, unique[i])
    end

    -- Concatenate lower + upper, dropping the last point of each (duplicates)
    local hull = {}
    for i = 1, #lower - 1 do table.insert(hull, lower[i]) end
    for i = 1, #upper - 1 do table.insert(hull, upper[i]) end

    if #hull < 3 then return nil end
    return hull
end


--- Test whether a 2D point is inside a polygon using ray-casting.
-- The polygon is a list of {x, z} points; edges are implicit between
-- consecutive points (and between the last and first, closing the loop).
-- @param x number Point x coordinate
-- @param z number Point z coordinate
-- @param polygon table Array of {x, z} points forming the polygon ring
-- @return boolean true if the point is inside the polygon
function ToPastureAndBack_RL.isInsidePolygon(x, z, polygon)
    if polygon == nil or #polygon < 3 then return false end
    local n = #polygon
    local inside = false
    local j = n
    for i = 1, n do
        local pi = polygon[i]
        local pj = polygon[j]
        if (pi.z > z) ~= (pj.z > z) then
            local dz = pj.z - pi.z
            if dz ~= 0 then
                local xIntersect = (pj.x - pi.x) * (z - pi.z) / dz + pi.x
                if x < xIntersect then
                    inside = not inside
                end
            end
        end
        j = i
    end
    return inside
end




--- Check if (x, z) falls inside the fence polygon of ANY cached barn.
-- Iterates all barns of all animal types. Returns the first matching barn entry.
-- @param x number Query x
-- @param z number Query z
-- @return table|nil The barn entry whose fencePolygon contains the point, or nil
function ToPastureAndBack_RL.findEnclosingFence(x, z)
    -- Scan ALL placeables in the world for fence data. Three fence spec types exist:
    --   spec_fence          - map-maker placed PlaceableFence
    --   spec_newFence       - player-placed fences (construction menu)
    --   spec_husbandryFence - pastures and barns-with-yards
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then return nil end
    local placeables = g_currentMission.placeableSystem.placeables
    if placeables == nil then return nil end

    -- Spatial prefilter on placeable rootNode distance (generous because fence rings can be large)
    local MAX_DIST = 1200
    local maxDistSq = MAX_DIST * MAX_DIST

    local nScanned, nWithFence, nClosed, nMatched = 0, 0, 0, 0

    for _, placeable in pairs(placeables) do
        nScanned = nScanned + 1
        local isFar = false
        if placeable.rootNode ~= nil then
            local okR, rx, _, rz = ToPastureAndBack_RL.fcallNode(getWorldTranslation, placeable.rootNode)
            if okR and rx ~= nil and rz ~= nil then
                local dx, dz = rx - x, rz - z
                if (dx * dx + dz * dz) > maxDistSq then
                    isFar = true
                end
            end
        end

        if not isFar then
            local segments = nil
            local fenceType = nil

            if placeable.spec_fence ~= nil and placeable.spec_fence.segments ~= nil then
                segments = {}
                for _, seg in pairs(placeable.spec_fence.segments) do
                    if seg.x1 ~= nil and seg.z1 ~= nil and seg.x2 ~= nil and seg.z2 ~= nil then
                        table.insert(segments, {
                            startPosX = seg.x1, startPosZ = seg.z1,
                            endPosX   = seg.x2, endPosZ   = seg.z2,
                        })
                    end
                end
                if #segments > 0 then fenceType = "spec_fence" end
                if #segments == 0 then segments = nil end
            end

            if segments == nil then
                for _, specName in ipairs({"spec_newFence", "spec_husbandryFence"}) do
                    local spec = placeable[specName]
                    if spec ~= nil and placeable.getFence ~= nil then
                        local okF, fence = ToPastureAndBack_RL.fcall(placeable.getFence, placeable)
                        if okF and fence ~= nil and fence.segments ~= nil and #fence.segments >= 3 then
                            segments = fence.segments
                            fenceType = specName
                            break
                        end
                    end
                end
            end

            if segments ~= nil and #segments >= 3 then
                nWithFence = nWithFence + 1
                local name = "unnamed"
                if placeable.getName ~= nil then
                    local okN, n = ToPastureAndBack_RL.fcall(placeable.getName, placeable)
                    if okN and n ~= nil then name = n end
                end
                -- 2026-05-08 F2 fix: use ring-aware splitter. Map-maker placeables
                -- can contain multiple disjoint rings (e.g. Pichonniere "Fence"
                -- = F1 perimeter + F3 perimeter combined). The previous convex
                -- hull on all endpoints falsely engulfed F2 between the rings.
                local rings = ToPastureAndBack_RL.buildFencePolygons(segments)
                if rings == nil or #rings == 0 then
                    dbgLog("TPAB-RL: findEnclosingFence: placeable '%s' (type=%s) %d segments yielded no rings",
                        name, fenceType, #segments)
                else
                    nClosed = nClosed + #rings
                    local matchedRing = nil
                    for ri, ring in ipairs(rings) do
                        if ToPastureAndBack_RL.isInsidePolygon(x, z, ring) then
                            matchedRing = ring
                            dbgLog("TPAB-RL: findEnclosingFence: MATCH placeable '%s' (type=%s) ring %d/%d with %d points",
                                name, fenceType, ri, #rings, #ring)
                            break
                        end
                    end
                    if matchedRing ~= nil then
                        nMatched = nMatched + 1
                        return {name = name, placeable = placeable, fencePolygon = matchedRing}
                    else
                        dbgLog("TPAB-RL: findEnclosingFence: placeable '%s' (type=%s) %d ring(s) do NOT contain (%.1f, %.1f)",
                            name, fenceType, #rings, x, z)
                    end
                end
            end
        end
    end

    dbgLog("TPAB-RL: findEnclosingFence: scanned %d placeables, %d with fence data, %d built polygon, %d matched (none enclosing (%.1f, %.1f))",
        nScanned, nWithFence, nClosed, nMatched, x, z)
    return nil
end


function ToPastureAndBack_RL.checkExistingFenceCoverage(contourPts, fenceSegments, cx, cz)
    if contourPts == nil or #contourPts < 3 then
        return 0
    end

    local hasFenceSegments = (fenceSegments ~= nil and #fenceSegments > 0)
    local proximity = ToPastureAndBack_RL.FENCE_DETECT_PROXIMITY
    local angleTolRad = math.rad(ToPastureAndBack_RL.FENCE_DETECT_ANGLE_TOLERANCE)
    local cosAngleTol = math.cos(angleTolRad)
    local nPts = #contourPts
    local totalPerimeter = 0
    local coveredPerimeter = 0
    local placeableCovered = 0
    local raycastCovered = 0

    for i = 1, nPts do
        local p1 = contourPts[i]
        local p2 = contourPts[(i % nPts) + 1]

        local edgeDx = p2.x - p1.x
        local edgeDz = p2.z - p1.z
        local edgeLen = math.sqrt(edgeDx * edgeDx + edgeDz * edgeDz)

        if edgeLen < 0.5 then
            -- Skip degenerate edges
            totalPerimeter = totalPerimeter + edgeLen
        else
            totalPerimeter = totalPerimeter + edgeLen

            -- Normalize contour edge direction
            local edgeNx = edgeDx / edgeLen
            local edgeNz = edgeDz / edgeLen

            -- Pass 1: Check Placeable fence segments against this contour edge
            local edgeCovered = false
            if hasFenceSegments then
                for _, fs in ipairs(fenceSegments) do
                    -- Fence segment direction
                    local fDx = fs.x2 - fs.x1
                    local fDz = fs.z2 - fs.z1
                    local fLen = math.sqrt(fDx * fDx + fDz * fDz)

                    if fLen >= 0.5 then
                        local fNx = fDx / fLen
                        local fNz = fDz / fLen

                        -- Check angle: use absolute dot product (direction doesn't matter)
                        local dot = math.abs(edgeNx * fNx + edgeNz * fNz)
                        if dot >= cosAngleTol then
                            -- Check proximity: perpendicular distance from contour edge midpoint to fence segment line
                            local emx = (p1.x + p2.x) * 0.5
                            local emz = (p1.z + p2.z) * 0.5

                            -- Distance from edge midpoint to the closest point on the fence segment
                            local t = ((emx - fs.x1) * fNx + (emz - fs.z1) * fNz) / fLen
                            t = math.max(0, math.min(1, t))
                            local closestX = fs.x1 + fDx * t
                            local closestZ = fs.z1 + fDz * t

                            local distX = emx - closestX
                            local distZ = emz - closestZ
                            local dist = math.sqrt(distX * distX + distZ * distZ)

                            if dist <= proximity then
                                edgeCovered = true
                                placeableCovered = placeableCovered + edgeLen
                                break
                            end
                        end
                    end
                end
            end

            -- Pass 2: If not covered by Placeable segments, probe for baked-in static fences
            if not edgeCovered then
                if ToPastureAndBack_RL.probeStaticFenceOnEdge(p1, p2, cx, cz) then
                    edgeCovered = true
                    raycastCovered = raycastCovered + edgeLen
                end
            end

            if edgeCovered then
                coveredPerimeter = coveredPerimeter + edgeLen
            end
        end
    end

    local coverage = 0
    if totalPerimeter > 0 then
        coverage = coveredPerimeter / totalPerimeter
    end

    dbgLog("TPAB-RL: Fence coverage: %.1fm of %.1fm perimeter covered (%.0f%%), placeable=%.1fm, static=%.1fm",
        coveredPerimeter, totalPerimeter, coverage * 100, placeableCovered, raycastCovered)
    return coverage
end

--- Create a temporary fence around a grazing session's contour polygon.
-- Clones poles and panels from the chickenNetFence template, places them along
-- the contour edges with ~2m post spacing. Uses setDirection() to follow terrain
-- slope, preventing the stepping artifact on hills.
-- @param session table GrazingSession with pasturePoint.fieldContour
--- Compute the maximum distance from a session's pasture center to any
--- contour vertex. Used by the multi-session fence ownership logic to
--- pick the LARGEST contour as the visible fence so all herds on the
--- same farmland stay inside it.
function ToPastureAndBack_RL._maxContourRadius(session)
    if session == nil or session.pasturePoint == nil
            or session.pasturePoint.fieldContour == nil then
        return 0
    end
    local cx, cz = session.pasturePoint.x, session.pasturePoint.z
    local maxR = 0
    for _, pt in ipairs(session.pasturePoint.fieldContour) do
        local dx = pt.x - cx
        local dz = pt.z - cz
        local d = math.sqrt(dx * dx + dz * dz)
        if d > maxR then maxR = d end
    end
    return maxR
end

function ToPastureAndBack_RL.createPastureFence(session)
    -- Skip temp fences for pasture destinations (pastures have their own built-in fences)
    if session.isPastureDestination then
        dbgLog("TPAB-RL: Skipping temp fence for pasture destination session %s", session.id)
        return
    end

    -- Check if fences are enabled in settings
    if ToPastureAndBack_RL.SHOW_FENCES_OPTIONS[ToPastureAndBack_RL.settings.showFencesIndex] == false then
        dbgLog("TPAB-RL: Skipping fence creation, fences disabled in settings")
        return
    end

    if not ToPastureAndBack_RL.loadFenceTemplate() then
        dbgLog("TPAB-RL: Skipping fence creation, template not available")
        return
    end

    local contourPts = session.pasturePoint.fieldContour
    if contourPts == nil or #contourPts < 3 then
        dbgLog("TPAB-RL: Skipping fence creation, not enough contour points (%d)",
            contourPts and #contourPts or 0)
        return
    end

    -- Multi-session fence ownership (2026-05-03 fix): when multiple sessions
    -- graze the same farmland, only ONE fence renders, and it must be the
    -- LARGEST (so all sessions' animals stay visually contained). If an
    -- existing fenced session has a larger or equal contour, skip ours. If
    -- ours is larger, remove the existing fence and fall through to build ours.
    if session.farmlandId ~= nil and session.farmlandId > 0 then
        local mySize = ToPastureAndBack_RL._maxContourRadius(session)
        local fencedOther = nil
        local fencedOtherSize = 0
        for _, other in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if other.id ~= session.id
                    and other.farmlandId == session.farmlandId
                    and other.fenceNodes ~= nil
                    and #other.fenceNodes > 0 then
                fencedOther = other
                fencedOtherSize = ToPastureAndBack_RL._maxContourRadius(other)
                break
            end
        end
        if fencedOther ~= nil then
            if mySize > fencedOtherSize + 0.5 then
                dbgLog("TPAB-RL: Replacing fence on Farmland %d: %s (radius %.1fm) -> %s (radius %.1fm)",
                    session.farmlandId, fencedOther.id, fencedOtherSize, session.id, mySize)
                -- Remove the existing fence directly. Don't call
                -- removePastureFence on it, that would trigger the
                -- ownership-transfer logic and re-fence the wrong session.
                for _, nodeId in ipairs(fencedOther.fenceNodes) do
                    if nodeId ~= nil and nodeId ~= 0 then
                        ToPastureAndBack_RL.fcallNode(delete, nodeId)
                    end
                end
                fencedOther.fenceNodes = {}
                -- Fall through to build ours.
            else
                dbgLog("TPAB-RL: Farmland %d already fenced by session %s (radius %.1fm >= ours %.1fm), skipping temp fence for %s",
                    session.farmlandId, fencedOther.id, fencedOtherSize, mySize, session.id)
                return
            end
        end
    end

    -- Primary fence-skip check: point-in-polygon on real fence geometry.
    -- If the session center is inside a closed fence ring from any cached barn,
    -- skip deploying a temp fence. This correctly handles big fenced farmlands
    -- where scanFieldExtent produces a small contour nowhere near the real fence
    -- perimeter (see design doc section on Husbandry Placeable Containment).
    local enclosing = ToPastureAndBack_RL.findEnclosingFence(session.pasturePoint.x, session.pasturePoint.z)
    if enclosing ~= nil then
        dbgLog("TPAB-RL: Inside existing fence of '%s', skipping temp fence for %s",
            enclosing.name, session.id)
        return
    end

    -- Secondary check: radial raycast scan from the session center. Detects
    -- enclosure by ANY collision (placeable fence, baked map fence mesh,
    -- walls, hedges with collision). Catches cases where contour shape
    -- doesn't align with the real fence so the per-edge coverage scan below
    -- registers <70%. See isAreaRadiallyEnclosed for details.
    local cxRadial, czRadial = session.pasturePoint.x, session.pasturePoint.z
    local maxContourRadius = 0
    for _, pt in ipairs(contourPts) do
        local dxP = pt.x - cxRadial
        local dzP = pt.z - czRadial
        local d = math.sqrt(dxP * dxP + dzP * dzP)
        if d > maxContourRadius then maxContourRadius = d end
    end
    if ToPastureAndBack_RL.isAreaRadiallyEnclosed(cxRadial, czRadial, maxContourRadius, session.farmlandId) then
        dbgLog("TPAB-RL: Area enclosed by collision (radial scan), skipping temp fence for %s", session.id)
        return
    end

    -- Check if the field already has fences covering most of the perimeter
    local cx, cz = session.pasturePoint.x, session.pasturePoint.z
    local searchRadius = ToPastureAndBack_RL.FENCE_DETECT_SEARCH_RADIUS
    -- Use contour radius + buffer so we catch fences around large fields
    local maxContourDist = 0
    for _, pt in ipairs(contourPts) do
        local dxP = pt.x - cx
        local dzP = pt.z - cz
        local d = math.sqrt(dxP * dxP + dzP * dzP)
        if d > maxContourDist then maxContourDist = d end
    end
    searchRadius = math.max(searchRadius, maxContourDist + ToPastureAndBack_RL.FENCE_DETECT_PROXIMITY)

    local fenceSegments = ToPastureAndBack_RL.collectNearbyFenceSegments(cx, cz, searchRadius)
    local coverage = ToPastureAndBack_RL.checkExistingFenceCoverage(contourPts, fenceSegments, cx, cz)
    if coverage >= ToPastureAndBack_RL.FENCE_DETECT_COVERAGE_THRESHOLD then
        dbgLog("TPAB-RL: Field already fenced (%.0f%% coverage), skipping temp fence for %s", coverage * 100, session.id)
        return
    end

    local templateRoot = ToPastureAndBack_RL.fenceTemplateRoot
    -- chickenNetFence I3D: flat structure (no intermediate groups)
    --   child 0 = "pole01" (TransformGroup with col + visual)
    --   child 1 = "panel01" (TransformGroup with col + visual)
    local poleTemplate = getChildAt(templateRoot, 0)
    local panelTemplate = getChildAt(templateRoot, 1)

    if poleTemplate == nil or poleTemplate == 0 or panelTemplate == nil or panelTemplate == 0 then
        Logging.warning("TPAB-RL: Fence template structure unexpected, skipping fence creation")
        return
    end

    local terrainNode = g_currentMission.terrainRootNode
    local fenceNodes = {}
    local postSpacing = ToPastureAndBack_RL.FENCE_POST_SPACING
    local panelBaseLen = ToPastureAndBack_RL.FENCE_PANEL_LENGTH
    local maxScale = ToPastureAndBack_RL.FENCE_MAX_SCALE
    local yScale = ToPastureAndBack_RL.FENCE_Y_SCALE
    local poleYScale = ToPastureAndBack_RL.FENCE_POLE_Y_SCALE

    -- Create a container node to hold all fence pieces (easy bulk cleanup)
    local fenceRoot = createTransformGroup("tpab_fence_" .. session.id)
    link(getRootNode(), fenceRoot)
    table.insert(fenceNodes, fenceRoot)

    local totalPoles = 0
    local totalPanels = 0
    local nPts = #contourPts

    for i = 1, nPts do
        local p1 = contourPts[i]
        local p2 = contourPts[(i % nPts) + 1]  -- wrap to first point

        local dx = p2.x - p1.x
        local dz = p2.z - p1.z
        local edgeLen = math.sqrt(dx * dx + dz * dz)

        if edgeLen >= 0.5 then
            -- How many posts along this edge (at least 1 at start, plus intermediates)
            local numSegments = math.max(1, math.floor(edgeLen / postSpacing + 0.5))
            local segLen = edgeLen / numSegments

            for j = 0, numSegments - 1 do
                local t = j / numSegments
                local px = p1.x + dx * t
                local pz = p1.z + dz * t
                local py = getTerrainHeightAtWorldPos(terrainNode, px, 0, pz)

                -- Next pole position (for 3D direction vector)
                local nextT = (j + 1) / numSegments
                local nx = p1.x + dx * nextT
                local nz = p1.z + dz * nextT
                local ny = getTerrainHeightAtWorldPos(terrainNode, nx, 0, nz)

                -- 3D direction from this pole to the next (includes slope)
                local dirX = nx - px
                local dirY = ny - py
                local dirZ = nz - pz

                -- Clone and place pole, oriented along fence line
                local pole = clone(poleTemplate, false, false, false)
                setVisibility(pole, true)
                link(fenceRoot, pole)
                setWorldTranslation(pole, px, py, pz)
                setDirection(pole, dirX, dirY, dirZ, 0, 1, 0)
                setScale(pole, 1, poleYScale, 1)
                totalPoles = totalPoles + 1

                -- Clone and place panel from this pole toward the next
                local panel = clone(panelTemplate, false, false, false)
                setVisibility(panel, true)
                link(fenceRoot, panel)
                setWorldTranslation(panel, px, py, pz)
                setDirection(panel, dirX, dirY, dirZ, 0, 1, 0)

                -- Scale panel along Z (local forward axis) to match segment length,
                -- and Y to reduce height for temporary fence look
                local scaleZ = segLen / panelBaseLen
                if scaleZ > maxScale then scaleZ = maxScale end
                if scaleZ < 0.5 then scaleZ = 0.5 end
                setScale(panel, 1, yScale, scaleZ)
                totalPanels = totalPanels + 1
            end
        end
    end

    session.fenceNodes = fenceNodes
    dbgLog("TPAB-RL: Created pasture fence for %s: %d poles, %d panels around %d contour points",
        session.id, totalPoles, totalPanels, nPts)
end

--- Remove temporary fence from a grazing session.
-- Deletes all cloned fence nodes.
-- @param session table GrazingSession
function ToPastureAndBack_RL.removePastureFence(session)
    if session.fenceNodes == nil or #session.fenceNodes == 0 then
        return
    end

    for _, nodeId in ipairs(session.fenceNodes) do
        if nodeId ~= nil and nodeId ~= 0 then
            ToPastureAndBack_RL.fcallNode(delete, nodeId)
        end
    end

    local count = #session.fenceNodes
    session.fenceNodes = {}
    dbgLog("TPAB-RL: Removed pasture fence for %s (%d root nodes deleted)", session.id, count)

    -- Transfer fence ownership (2026-05-03 fix): when our fence comes down
    -- but other active sessions are still on the same farmland, build a
    -- fence for the LARGEST remaining session. Largest contour ensures
    -- every remaining herd's animals stay visually contained.
    if session.farmlandId ~= nil and session.farmlandId > 0 then
        local newOwner = nil
        local newOwnerSize = 0
        for _, other in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if other.id ~= session.id
                    and other.spawnState == "active"
                    and other.farmlandId == session.farmlandId
                    and (other.fenceNodes == nil or #other.fenceNodes == 0)
                    and not other.isPastureDestination then
                local sz = ToPastureAndBack_RL._maxContourRadius(other)
                if sz > newOwnerSize then
                    newOwner = other
                    newOwnerSize = sz
                end
            end
        end
        if newOwner ~= nil then
            dbgLog("TPAB-RL: Transferring fence ownership on Farmland %d to session %s (largest, radius %.1fm)",
                session.farmlandId, newOwner.id, newOwnerSize)
            ToPastureAndBack_RL.createPastureFence(newOwner)
        end
    end
end


-- ============================================================================
-- Barn data helpers
-- ============================================================================

--- Get cached barn data for an animal type (nav mesh, XML, collision mask, etc.).
-- On first call for a given type, scans all husbandry placeables.
-- @param animalType string e.g. "COW"
-- @return table {navNode, xmlFile, name, collMask, rayDist, placeable} or nil
--- Get any barn for the given animal type (for nav mesh cloning, where any barn works).
-- Prefers non-calf barns.
function ToPastureAndBack_RL.getBarnDataForType(animalType)
    local candidates = ToPastureAndBack_RL.getAllBarnsForType(animalType)
    if candidates == nil or #candidates == 0 then
        return nil
    end

    -- Return first available barn
    return candidates[1]
end

--- Get all cached barn candidates for an animal type, scanning if needed.
function ToPastureAndBack_RL.getAllBarnsForType(animalType)
    if ToPastureAndBack_RL.barnCache[animalType] == nil then
        ToPastureAndBack_RL.scanBarnsForType(animalType)
    end
    return ToPastureAndBack_RL.barnCache[animalType]
end

--- Find the nearest barn of ANY animal type within range.
-- Searches all cached animal types and returns the closest barn regardless of species.
-- @param maxDistance number|nil Max search radius (defaults to BARN_PROXIMITY)
-- @return table|nil Barn data, number|nil distance, string|nil animal type name
function ToPastureAndBack_RL.findNearestBarnAnyType(maxDistance)
    maxDistance = maxDistance or ToPastureAndBack_RL.BARN_PROXIMITY

    local px, _, pz = ToPastureAndBack_RL.getPlayerPosition()
    if px == nil then return nil end

    local bestBarn = nil
    local bestDist = math.huge
    local bestType = nil

    for typeName, candidates in pairs(ToPastureAndBack_RL.barnCache) do
        for _, barn in ipairs(candidates) do
            local bx, bz = ToPastureAndBack_RL.getBarnCachePos(barn)
            if bx ~= nil then
                local dx = bx - px
                local dz = bz - pz
                local dist = math.sqrt(dx * dx + dz * dz)
                if dist < bestDist and dist <= maxDistance then
                    bestDist = dist
                    bestBarn = barn
                    bestType = typeName
                end
            end
        end
    end

    if bestBarn ~= nil then
        dbgLog("TPAB-RL: findNearestBarnAnyType: nearest barn is %s (%s) at %.1fm", bestBarn.name, bestType, bestDist)
    else
        dbgLog("TPAB-RL: findNearestBarnAnyType: no barn within %.0fm of player", maxDistance)
    end

    return bestBarn, bestDist, bestType
end

--- Find a pasture placeable at the player's position for a given animal type.
-- Checks all barn cache entries for the given type, looking for a husbandry
-- placeable whose farmland matches the player's current farmland (and is not
-- the source barn). This allows pasture placeables (outdoor husbandry areas
-- with groundType=0) to serve as valid grazing destinations.
-- @param x number World X position to check
-- @param z number World Z position to check
-- @param animalType string e.g. "COW"
-- @param sourceBarnPlaceable table|nil The barn the herd is coming from (excluded)
-- @return table|nil Matching barn data entry, or nil if not inside a pasture
function ToPastureAndBack_RL.findPastureAtPosition(x, z, animalType, sourceBarnPlaceable)
    local candidates = ToPastureAndBack_RL.getAllBarnsForType(animalType)
    if candidates == nil or #candidates == 0 then
        dbgLog("TPAB-RL: findPastureAtPosition: no %s barns in cache", animalType)
        return nil
    end

    -- Get the farmland ID at the player's position
    local playerFarmlandId = ToPastureAndBack_RL.getFarmlandIdAtPosition(x, z)
    if playerFarmlandId == nil or playerFarmlandId <= 0 then
        dbgLog("TPAB-RL: findPastureAtPosition: no farmland at (%.1f, %.1f)", x, z)
        return nil
    end

    dbgLog("TPAB-RL: findPastureAtPosition: checking %d %s candidates, player on farmland %d",
        #candidates, animalType, playerFarmlandId)

    -- A farmland parcel can contain a pasture placeable AND regular crop/grass
    -- fields (e.g. Etruria farmland 9). Same-farmland alone is insufficient
    -- proof of "inside the pasture", we must verify proximity to the pasture's
    -- nav node center. Typical fenced placeables are 20-40m radius, so 50m is
    -- a safe cap that admits players standing inside while rejecting matches
    -- on adjacent fields within the same parcel.
    local PASTURE_INSIDE_RADIUS = 50

    -- cert 2026-07-07 (M5): with several pastures on one farmland, do not return
    -- the first candidate in cache order. Collect every candidate that passes the
    -- contained AND sameFarmland guards (both untouched), then pick the best one
    -- after the loop: tightest containment tier first (engine-polygon >
    -- fence-circle > nav-circle), nearest to the queried position within a tier.
    local passing = {}

    for _, barn in ipairs(candidates) do
        -- 2026-05-06 v27.7: source-barn-exclusion removed. Allows self-yard
        -- sends (e.g. cows from Milk Cow Barn(3) -> Milk Cow Barn(3)'s yard
        -- on Pichonniere Farmland 3) so the visual wear simulation runs on
        -- a barn's own attached pasture if the player wants visual parity
        -- with player-grazed open fields.
        do
            local bx, bz = ToPastureAndBack_RL.getBarnCachePos(barn)  -- farmland-id only, NOT getBarnAnchorPos (findPastureAtPosition containment uses fence/contour, see guards)
            if bx ~= nil then
                local barnFarmlandId = ToPastureAndBack_RL.getFarmlandIdAtPosition(bx, bz)
                local dx = bx - x
                local dz = bz - z
                local dist = math.sqrt(dx * dx + dz * dz)
                local sameFarmland = (barnFarmlandId ~= nil and barnFarmlandId == playerFarmlandId)
                -- Containment test (LOAD-BEARING ENGINE API).
                --   1. Engine-provided outdoorContourPolygon:getIsPosInside.
                --      The placeable's spec_husbandryAnimals has an
                --      outdoorContourPolygon field built from the fence
                --      outline MINUS the indoor navigation mesh shape. It
                --      defines the EXACT 2D yard area where animals walk
                --      when outside the building. The engine itself uses
                --      this polygon to answer "is a feed pallet in the
                --      delivery area" (PlaceableHusbandryAnimals:
                --      getIsInAnimalDeliveryArea, gameSource.zip dataS/
                --      scripts/animals/husbandry/placeables/
                --      PlaceableHusbandryAnimals.lua:899). This is the
                --      canonical answer; do NOT replace with derived
                --      geometry (convex hull, ray-crossing on segments,
                --      reachability raycast) -- those approaches were all
                --      tried 2026-05-05 morning/evening/night and ALL
                --      failed because they tried to derive what the engine
                --      already computes.
                --   2. fenceRadius bounding circle. Fallback for placeables
                --      whose outdoorContourPolygon is nil (e.g., husbandry
                --      without a defined navigation#shape XML attribute).
                --   3. PASTURE_INSIDE_RADIUS=50m nav-distance. Last resort
                --      for pure indoor barns with no fence at all.
                local contained = false
                local containmentLabel
                local diagDist, diagRadius
                -- Diagnostics regardless of which tier fires
                if barn.fenceCenterX ~= nil and barn.fenceCenterZ ~= nil then
                    local fdx = barn.fenceCenterX - x
                    local fdz = barn.fenceCenterZ - z
                    diagDist = math.sqrt(fdx * fdx + fdz * fdz)
                    diagRadius = barn.fenceRadius or 0
                else
                    diagDist = dist
                    diagRadius = barn.fenceRadius or 0
                end
                local spec = barn.placeable and barn.placeable.spec_husbandryAnimals
                local polygon = spec and spec.outdoorContourPolygon
                if polygon ~= nil and polygon.getIsPosInside ~= nil then
                    local okInside, inside = ToPastureAndBack_RL.fcall(polygon.getIsPosInside, polygon, x, z)
                    if okInside then
                        contained = inside == true
                        containmentLabel = "engine-polygon"
                    else
                        -- Engine call errored (rare). Fall through to circle.
                        polygon = nil
                    end
                end
                if containmentLabel == nil then
                    if barn.fenceRadius ~= nil then
                        contained = (diagDist <= diagRadius)
                        containmentLabel = "fence-circle"
                    else
                        contained = (dist <= PASTURE_INSIDE_RADIUS)
                        diagDist = dist
                        diagRadius = PASTURE_INSIDE_RADIUS
                        containmentLabel = "nav-circle"
                    end
                end
                -- LOAD-BEARING GUARD - DO NOT REMOVE EITHER FILTER WITHOUT
                -- READING design doc "Load-Bearing Guards" SECTION FIRST.
                --
                -- BOTH conditions are required (must be ANDed, never swapped):
                --   1. contained (geometric containment)
                --      Tightest available test: polygon (convex hull) > fence
                --      bounding circle > nav-distance fallback. Prevents false
                --      matches like:
                --      - Etruria farmland-9 same-parcel-different-area: Bianchi
                --        Barn 2 has full Meadow stack but is a barn-with-yard.
                --        Polygon/circle gates a player on the crop portion of
                --        farmland 9 from matching at 95m+.
                --      - Pichonniere Field-3 Cow Barn (2026-05-04 night): the
                --        L-shaped fence's centroid+max-radius bounding circle
                --        (81.5m) geometrically contained an open-field point
                --        54.7m from centroid. Bounding-circle test wrongly
                --        accepted; polygon test correctly rejects.
                --   2. sameFarmland (farmland-equality gate)
                --      prevents Pichonniere Calf-Barn cross-farmland match: Calf
                --      Barn fenceRadius=50m extends across property lines into
                --      Farmland 6, so player on Farmland 6 (a different farmland)
                --      was matching Calf Barn just because they were 38.7m from
                --      its nav center. Resulted in 102 Milk-Cow-Barn cows being
                --      crammed into the Calf Barn building (2026-05-04 night).
                --
                -- HISTORY of regressions on this conditional:
                --   2026-04-22 session 2: sameFarmland filter introduced.
                --   2026-04-22 session 3: REPLACED with PASTURE_INSIDE_RADIUS=50.
                --      Lost sameFarmland. Re-opened cross-farmland bug.
                --   2026-04-23 session 2: 50m -> per-barn fenceRadius. Still no
                --      sameFarmland. Cross-farmland bug still latent.
                --   2026-05-04 night: re-introduced sameFarmland as AND. Both
                --      guards in place. Added load-bearing-guard comment.
                --   2026-05-05 morning: replaced bounding-circle distance gate
                --      with convex-hull point-in-polygon. Looked tighter than
                --      the bounding circle, but for L-shaped Pichonniere Field-3
                --      Cow Barn yard the hull was still over-permissive: hull
                --      swallowed the open-field area between the L's two arms,
                --      same false-match recurred (test=polygon hit at 40.1m).
                --   2026-05-05 evening: replaced convex-hull polygon test with
                --      ray-crossing (even-odd rule) on RAW unordered fence
                --      segments. ALSO failed: spec.fence:getSegments() returns
                --      ONLY the yard fence, not the building wall. The segment
                --      list is an open polygon for any L-shaped or U-shaped
                --      yard where the building closes one side. Ray-crossing
                --      parity gave wrong answer for Pichonniere open Field 3
                --      (matched Milk Cow Barn(3) L-shaped yard).
                --   2026-05-05 night: replaced ray-crossing with REACHABILITY
                --      RAYCAST. Cast horizontal rays from query to nav node
                --      at multiple heights; any collision blocks the line ->
                --      outside the closed loop. Independent of segment list
                --      completeness because the building wall blocks the ray
                --      exactly as a fence does. Bounding circle and nav-distance
                --      retained as fallbacks. sameFarmland AND-clause preserved.
                --
                -- If you find a NEW bug in this code: DO NOT replace either
                -- filter. ADD a third filter with `and`. The repro scenarios
                -- for both existing filters (Etruria farmland 9 cross-area and
                -- Pichonniere cross-farmland) are still real.
                if contained and sameFarmland then
                    -- cert 2026-07-07 (M5): collect, pick best after the loop.
                    local tierRank = 3  -- nav-circle
                    if containmentLabel == "engine-polygon" then
                        tierRank = 1
                    elseif containmentLabel == "fence-circle" then
                        tierRank = 2
                    end
                    table.insert(passing, {
                        barn = barn,
                        tier = tierRank,
                        dist = diagDist,
                        label = containmentLabel,
                    })
                    dbgLog("TPAB-RL: findPastureAtPosition: candidate pasture '%s' passed (test=%s, %.1fm from fence center, fenceRadius=%.1fm, sameFarmland=%s)",
                        barn.name, containmentLabel, diagDist, diagRadius, tostring(sameFarmland))
                elseif contained then
                    dbgLog("TPAB-RL: findPastureAtPosition: REJECTED '%s' (test=%s contained but sameFarmland=false; player on different farmland)",
                        barn.name, containmentLabel)
                end
            end
        end
    end

    -- cert 2026-07-07 (M5): pick the best passing candidate.
    if #passing > 0 then
        local best = passing[1]
        for i = 2, #passing do
            local cand = passing[i]
            if cand.tier < best.tier
                    or (cand.tier == best.tier and cand.dist < best.dist) then
                best = cand
            end
        end
        dbgLog("TPAB-RL: findPastureAtPosition: matched pasture '%s' (test=%s, %.1fm, %d passing candidate(s))",
            best.barn.name, best.label, best.dist, #passing)
        return best.barn
    end

    dbgLog("TPAB-RL: findPastureAtPosition: no pasture found for %s at (%.1f, %.1f)", animalType, x, z)
    return nil
end

--- Get all barns across all cached animal types.
-- @return table List of {barn=barnData, type=typeName} entries
function ToPastureAndBack_RL.getAllBarnsAllTypes()
    local result = {}
    for typeName, candidates in pairs(ToPastureAndBack_RL.barnCache) do
        for _, barn in ipairs(candidates) do
            table.insert(result, { barn = barn, type = typeName })
        end
    end
    return result
end

--- Get the animal config XML filename for a given animal type.
-- In base game, this is not stored on clusterHusbandry. We derive it from g_currentMission.animalSystem.
-- @param animalType string e.g. "COW"
-- @return string XML filename, or nil if not found
function ToPastureAndBack_RL.getAnimalXmlFile(animalType)
    local animalSystem = g_currentMission.animalSystem
    if animalSystem == nil then
        dbgLog("TPAB-RL: getAnimalXmlFile: animalSystem is nil")
        return nil
    end

    -- Try animalSystem.typesByName
    if animalSystem.typesByName ~= nil then
        local typeData = animalSystem.typesByName[string.upper(animalType)]
        if typeData ~= nil then
            if typeData.configFilename ~= nil then return typeData.configFilename end
            if typeData.xmlFilename ~= nil then return typeData.xmlFilename end
            if typeData.filename ~= nil then return typeData.filename end
        end
    end

    -- Try animalSystem.types (array)
    if animalSystem.types ~= nil then
        for _, typeData in pairs(animalSystem.types) do
            local name = typeData.name or typeData.typeName or ""
            if string.upper(name) == string.upper(animalType) then
                if typeData.configFilename ~= nil then return typeData.configFilename end
                if typeData.xmlFilename ~= nil then return typeData.xmlFilename end
                if typeData.filename ~= nil then return typeData.filename end
            end
        end
    end

    dbgLog("TPAB-RL: getAnimalXmlFile: could not find XML for %s", animalType)
    return nil
end

-- Animal types to exclude from grazing.
-- CHICKEN: too small to meaningfully pasture.
-- FISH / SALMONTROUT: aquatic.
--
-- Notes on HORSE (intentionally NOT excluded):
--   1. While on pasture, horses cannot be mounted because our pasture animals are
--      engine-level visuals and not linked into RL's clusterSystem, so the mount
--      prompt's getClusterByAnimalId lookup returns nil. This applies to every
--      species equally; players simply recall before interacting.
--   2. Mounting a recalled horse in its barn can black-screen if HofBergmann is
--      loaded on a non-HofBergmann map. That is a HofBergmann bug: it overrides
--      horse.xml globally but the override is not registered as a vehicle
--      storeItem, so PlaceableHusbandryAnimals:startRiding errors inside
--      VehicleLoadingData:setFilename. Workaround: deselect HofBergmann on saves
--      that are not HofBergmann. Not our bug to work around.
ToPastureAndBack_RL.EXCLUDED_TYPES = {
    CHICKEN = true, FISH = true, SALMONTROUT = true,
    QUAIL = true, RABBIT = true, GOOSE = true, DUCK = true, DUCKWILD = true,
    CAT = true, DOG = true,
}

--- Scan all husbandry placeables and discover every animal type present on the map.
-- Calls scanBarnsForType for each unique type found (except excluded types like CHICKEN).
function ToPastureAndBack_RL.scanAllBarnTypes()
    if g_currentMission.husbandrySystem == nil then return end

    local placeables = g_currentMission.husbandrySystem.placeables
    if placeables == nil or #placeables == 0 then
        dbgLog("TPAB-RL: No husbandry placeables found on map")
        return
    end

    -- Discover unique animal types across all barns
    local typesFound = {}
    for _, placeable in ipairs(placeables) do
        local spec = placeable.spec_husbandryAnimals
        if spec ~= nil and spec.animalType ~= nil then
            local typeName = ""
            if spec.animalType.name ~= nil then
                typeName = string.upper(spec.animalType.name)
            elseif spec.animalType.type ~= nil then
                typeName = string.upper(tostring(spec.animalType.type))
            end
            if typeName ~= "" and not ToPastureAndBack_RL.EXCLUDED_TYPES[typeName] then
                typesFound[typeName] = true
            end
        end
    end

    -- Scan each discovered type
    local typeList = {}
    for typeName, _ in pairs(typesFound) do
        table.insert(typeList, typeName)
        ToPastureAndBack_RL.scanBarnsForType(typeName)
    end

    if #typeList > 0 then
        table.sort(typeList)
        dbgLog("TPAB-RL: Animal types on map: %s", table.concat(typeList, ", "))
    else
        dbgLog("TPAB-RL: No supported animal barns found on map")
    end
end

--- Scan all husbandry placeables for barns of a given animal type.
-- Caches the best barn (prefers adult animals, largest capacity).
-- @param animalType string e.g. "COW", "SHEEP", "PIG", "HORSE"
function ToPastureAndBack_RL.scanBarnsForType(animalType)
    if g_currentMission.husbandrySystem == nil then return end

    local placeables = g_currentMission.husbandrySystem.placeables
    if placeables == nil or #placeables == 0 then return end

    local candidates = {}
    for _, placeable in ipairs(placeables) do
        local spec = placeable.spec_husbandryAnimals
        if spec ~= nil and spec.animalType ~= nil then
            local typeName = ""
            if spec.animalType.name ~= nil then
                typeName = string.upper(spec.animalType.name)
            elseif spec.animalType.type ~= nil then
                typeName = string.upper(tostring(spec.animalType.type))
            end

            if typeName == string.upper(animalType) then
                local ch = spec.clusterHusbandry
                if ch ~= nil and ch.navigationNode ~= nil then
                    local barnName = placeable:getName() or "Unknown"

                    -- Get xmlFilename, collisionMask, raycastDistance
                    -- In base game, these are NOT stored on clusterHusbandry (only MVA/RL adds them).
                    -- Try MVA/RL fields first, then derive from animal system and known defaults.
                    local xmlFile = ch.xmlFilename
                    local collMask = ch.collisionMask
                    local rayDist = ch.raycastDistance

                    -- Derive xmlFile from animal system if not available
                    if xmlFile == nil then
                        xmlFile = ToPastureAndBack_RL.getAnimalXmlFile(animalType)
                    end

                    -- Use multiplayer-safe collision mask default from Diagnostic 3
                    if collMask == nil then
                        collMask = 2097152  -- CollisionMask.ANIMAL_MULTIPLAYER, confirmed on Pichonniere
                    end

                    -- Use default raycast distance from barn configs
                    if rayDist == nil then
                        rayDist = 10
                    end

                    -- Per-barn containment measured from actual fence geometry.
                    -- Spec-based detection (spec_husbandryFence / spec_husbandryMeadow) was
                    -- insufficient: Edomod's Etruria Bianchi Barn 2 has the full Meadow stack
                    -- but is still a barn-with-yard that should NOT be a grazing destination.
                    -- Solution: iterate spec.fence:getSegments() world-space endpoints, compute
                    -- centroid + max-distance-from-centroid. That's a real bounding circle
                    -- sized to the actual fenced area, wherever and however large it is.
                    -- Pure indoor barns have no fence -> fall back to a fixed 50m default.
                    local fenceCenterX, fenceCenterZ, fenceRadius = nil, nil, nil
                    local fencePolygon = nil
                    local specFence = placeable.spec_husbandryFence
                    if specFence ~= nil and specFence.fence ~= nil then
                        local okS, segments = ToPastureAndBack_RL.fcall(specFence.fence.getSegments, specFence.fence)
                        if okS and segments ~= nil and #segments > 0 then
                            local sumX, sumZ, n = 0, 0, 0
                            local pts = {}
                            for _, seg in ipairs(segments) do
                                if seg.startPosX ~= nil and seg.startPosZ ~= nil then
                                    table.insert(pts, {x = seg.startPosX, z = seg.startPosZ})
                                    sumX = sumX + seg.startPosX
                                    sumZ = sumZ + seg.startPosZ
                                    n = n + 1
                                end
                                if seg.endPosX ~= nil and seg.endPosZ ~= nil then
                                    table.insert(pts, {x = seg.endPosX, z = seg.endPosZ})
                                    sumX = sumX + seg.endPosX
                                    sumZ = sumZ + seg.endPosZ
                                    n = n + 1
                                end
                            end
                            if n >= 3 then
                                fenceCenterX = sumX / n
                                fenceCenterZ = sumZ / n
                                local maxD2 = 0
                                for _, p in ipairs(pts) do
                                    local dx = p.x - fenceCenterX
                                    local dz = p.z - fenceCenterZ
                                    local d2 = dx * dx + dz * dz
                                    if d2 > maxD2 then maxD2 = d2 end
                                end
                                fenceRadius = math.sqrt(maxD2)
                                -- Convex hull polygon kept for findEnclosingFence (the
                                -- promote-to-pasture-destination hint, intentionally
                                -- permissive). findPastureAtPosition uses the ENGINE's
                                -- outdoorContourPolygon directly, NOT derived geometry --
                                -- see Phase1_Spec.md "Load-Bearing Engine APIs".
                                fencePolygon = ToPastureAndBack_RL.buildFencePolygon(segments)
                            end
                        end
                    end

                    table.insert(candidates, {
                        placeable = placeable,
                        navNode = ch.navigationNode,
                        xmlFile = xmlFile,
                        collMask = collMask,
                        rayDist = rayDist,
                        name = barnName,
                        husbandryId = ch.husbandryId,
                        fenceCenterX = fenceCenterX,
                        fenceCenterZ = fenceCenterZ,
                        fenceRadius = fenceRadius,
                        fencePolygon = fencePolygon,
                    })
                    dbgLog("TPAB-RL: Found %s barn %s (navNode=%s, xmlFile=%s, collMask=%s, rayDist=%s, husId=%s)",
                        animalType, barnName, tostring(ch.navigationNode),
                        tostring(xmlFile), tostring(collMask), tostring(rayDist), tostring(ch.husbandryId))
                end
            end
        end
    end

    if #candidates == 0 then
        dbgLog("TPAB-RL: No barns found for animal type %s", animalType)
        return
    end

    -- Cache ALL candidates (not just one), keyed by animal type
    ToPastureAndBack_RL.barnCache[animalType] = candidates
    dbgLog("TPAB-RL: Cached %d barn(s) for %s", #candidates, animalType)

    -- Per-barn summary (debug only)
    if ToPastureAndBack_RL.DEBUG then
        for _, barn in ipairs(candidates) do
            local p = barn.placeable
            local totalCount = 0
            if p.getNumOfAnimals ~= nil then
                local ok, n = ToPastureAndBack_RL.fcall(p.getNumOfAnimals, p)
                if ok and n ~= nil then totalCount = n end
            end
            dbgLog("TPAB-RL:   %s: %d animals", barn.name, totalCount)
        end
    end
end

--- Reconstruct saved grazing sessions after barn scan completes.
-- Called once from update() after barnCacheReady becomes true.
-- Matches each saved session to a barn by name + position proximity,
-- links to the pasture point by ID, and creates a live session in "pending" state
-- so the normal update loop rebuilds nav mesh, husbandry, and animals.
function ToPastureAndBack_RL.reconstructSavedSessions()
    local recs = ToPastureAndBack_RL.pendingReconstructions
    if recs == nil or #recs == 0 then return end

    dbgLog("TPAB-RL: Reconstructing %d saved grazing session(s)...", #recs)

    -- Build a lookup of pasture points by ID for fast matching
    local pointById = {}
    for _, point in ipairs(ToPastureAndBack_RL.pasturePoints) do
        pointById[point.id] = point
    end

    local reconstructed = 0
    local failed = 0

    -- cert 2026-07-07 (M7): placeables already bound to an earlier session in
    -- THIS reconstruction pass. Same-name adjacent barns with near-coincident
    -- saved positions must not both bind to barn 1.
    local claimedBarns = {}

    -- Helper to remove a pasture point by ID
    local function removePasturePointById(pointId)
        for j = #ToPastureAndBack_RL.pasturePoints, 1, -1 do
            if ToPastureAndBack_RL.pasturePoints[j].id == pointId then
                table.remove(ToPastureAndBack_RL.pasturePoints, j)
                return
            end
        end
    end

    for _, rec in ipairs(recs) do
        -- Skip sessions that genuinely expired (had a timed duration and ran out).
        -- durationHours=0 means manual recall (no timer), those never expire.
        local isExpired = rec.durationHours > 0 and rec.remainingHours <= 0
        -- Also skip sessions whose animal type is now excluded (e.g. HORSE was
        -- added to EXCLUDED_TYPES after a save with horses on pasture was made).
        local isExcluded = rec.animalType ~= nil and
            ToPastureAndBack_RL.EXCLUDED_TYPES[string.upper(rec.animalType)]
        if isExpired then
            dbgLog("TPAB-RL: Session %s expired during save/load, duration=%.1fh, remaining=%.1fh, discarding",
                rec.id, rec.durationHours, rec.remainingHours)
            if rec.pasturePointId ~= nil then removePasturePointById(rec.pasturePointId) end
            failed = failed + 1
        elseif isExcluded then
            dbgLog("TPAB-RL: Session %s discarded on load: animal type %s is no longer supported for pasture",
                rec.id, tostring(rec.animalType))
            if rec.pasturePointId ~= nil then removePasturePointById(rec.pasturePointId) end
            failed = failed + 1
        else
            -- Find the matching pasture point
            local pasturePoint = pointById[rec.pasturePointId]
            if pasturePoint == nil then
                Logging.warning("TPAB-RL: Session %s: pasture point %s not found, discarding",
                    rec.id, tostring(rec.pasturePointId))
                failed = failed + 1
            else
                -- Find the matching barn by name + position proximity
                local barnPlaceable = ToPastureAndBack_RL.findBarnForReconstruction(
                    rec.animalType, rec.barnName, rec.barnX, rec.barnZ, claimedBarns)
                if barnPlaceable == nil then
                    Logging.warning("TPAB-RL: Session %s: barn %s no longer exists, discarding",
                        rec.id, rec.barnName)
                    if rec.pasturePointId ~= nil then removePasturePointById(rec.pasturePointId) end
                    failed = failed + 1
                else
                    claimedBarns[barnPlaceable] = true  -- cert 2026-07-07 (M7)
                    -- Re-fetch RL Animal objects from the barn's clusterSystem.
                    -- Animal objects can't be serialized, so we saved identity triples
                    -- (farmId, uniqueId, country) and now match them against the live
                    -- animals that RL restored from its own save data.
                    local allBarnAnimals = ToPastureAndBack_RL.getRLAnimalsFromBarn(barnPlaceable)
                    local rlAnimals = {}

                    if rec.rlAnimalIds ~= nil and #rec.rlAnimalIds > 0 then
                        -- Build a lookup from the barn's live animals for O(n) matching
                        local barnLookup = {}
                        for _, animal in ipairs(allBarnAnimals) do
                            if animal.uniqueId ~= nil and animal.farmId ~= nil and animal.birthday ~= nil then
                                local lookupKey = tostring(animal.farmId) .. "|" .. tostring(animal.uniqueId)
                                    .. "|" .. tostring(animal.birthday.country)
                                barnLookup[lookupKey] = animal
                            end
                        end

                        for _, saved in ipairs(rec.rlAnimalIds) do
                            local lookupKey = tostring(saved.farmId) .. "|" .. tostring(saved.uniqueId)
                                .. "|" .. tostring(saved.country)
                            local animal = barnLookup[lookupKey]
                            if animal ~= nil then
                                table.insert(rlAnimals, animal)
                            else
                                dbgLog("TPAB-RL: Reconstruct: animal %s not found in barn (sold/died?)",
                                    saved.uniqueId)
                            end
                        end

                        dbgLog("TPAB-RL: Reconstruct: matched %d/%d RL animals from barn %s",
                            #rlAnimals, #rec.rlAnimalIds, rec.barnName)
                    else
                        -- Legacy save without RL identity data, grab all barn animals
                        rlAnimals = allBarnAnimals
                        dbgLog("TPAB-RL: Reconstruct: no saved RL IDs, using all %d barn animals",
                            #rlAnimals)
                    end

                    if #rlAnimals == 0 then
                        Logging.warning("TPAB-RL: Session %s: no RL animals found in barn %s, discarding",
                            rec.id, rec.barnName)
                        if rec.pasturePointId ~= nil then removePasturePointById(rec.pasturePointId) end
                        failed = failed + 1
                    else
                        -- Adjust animal count to match what we actually found
                        local actualCount = #rlAnimals

                        -- Create a live grazing session with RL animals
                        local session = ToPastureAndBack_RL.createGrazingSession(
                            barnPlaceable,
                            rec.barnName,
                            pasturePoint,
                            rec.animalType,
                            actualCount,
                            rec.remainingHours,  -- use remaining time as new duration
                            rec.animalAge,
                            rlAnimals
                        )
                        session.farmlandId = rec.farmlandId
                        session.isPastureDestination = rec.isPastureDestination or false
                        session.pastureDestName = rec.pastureDestName
                        table.insert(ToPastureAndBack_RL.grazingSessions, session)

                        dbgLog("TPAB-RL: Reconstructed session %s: barn=%s, %d %s on %s, %.1fh remaining",
                            session.id, rec.barnName, actualCount, rec.animalType,
                            pasturePoint.name, rec.remainingHours)
                        reconstructed = reconstructed + 1
                    end
                end
            end
        end
    end

    ToPastureAndBack_RL.pendingReconstructions = nil

    dbgLog("TPAB-RL: Session reconstruction complete: %d restored, %d discarded",
        reconstructed, failed)

    -- MP sync: broadcast reconstructed sessions to connected clients.
    -- The server already created these sessions locally via the reconstruction path above,
    -- but clients don't have the save file so they have no sessions. Broadcasting
    -- SendToPastureEvent for each session tells clients to create their own visual herds.
    -- The duplicate-session guard in executeGrazingFromEvent prevents the server from
    -- creating a second copy if the broadcast comes back to itself.
    if g_server ~= nil and reconstructed > 0 then
        dbgLog("TPAB-RL: Broadcasting %d reconstructed session(s) to connected clients", reconstructed)
        for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if session.spawnState ~= "done" then
                -- Build event data from the reconstructed session
                local barnWorldX, barnWorldZ = 0, 0
                local bx, bz = ToPastureAndBack_RL.getBarnLockPos(session.barnPlaceable)
                if bx ~= nil then barnWorldX, barnWorldZ = bx, bz end

                local pp = session.pasturePoint
                local eventData = {
                    barnWorldX = barnWorldX,
                    barnWorldZ = barnWorldZ,
                    barnName = session.barnName,
                    destX = pp.x,
                    destZ = pp.z,
                    destY = pp.y,
                    fieldContour = pp.fieldContour,
                    fieldRadius = pp.radius,
                    animalType = session.animalType,
                    animalCount = session.animalCount,
                    animalAge = session.animalAge or 36,
                    durationHours = session.durationHours,
                    farmlandId = session.farmlandId or 0,
                    sessionId = session.id,
                    pasturePointId = pp.id,
                    pasturePointName = pp.name,
                    isPastureDestination = session.isPastureDestination,
                    pastureDestName = session.pastureDestName,
                }

                -- broadcastEvent only sends to connected clients, does NOT run locally.
                -- The server's session was already created above, so no local re-execution.
                g_server:broadcastEvent(SendToPastureEvent.new(eventData))
                dbgLog("TPAB-RL: Broadcast reconstructed session %s to clients", session.id)
            end
        end
    end
end

--- Find a barn placeable matching the saved world position and name.
-- Used during session reconstruction to re-identify barns after a save/load cycle.
-- Position is the primary match criterion (barns don't move), name is a tiebreaker
-- (players can rename barns between save and load).
-- @param animalType string e.g. "COW"
-- @param barnName string Saved barn display name (may be stale after rename)
-- @param savedX number Saved barn world X (may be nil)
-- @param savedZ number Saved barn world Z (may be nil)
-- @param claimed table|nil Set of placeables already bound by an earlier session
--        in the same reconstruction pass; those are skipped (cert 2026-07-07 M7)
-- @return table|nil The barn's placeable object, or nil if not found
function ToPastureAndBack_RL.findBarnForReconstruction(animalType, barnName, savedX, savedZ, claimed)
    local candidates = ToPastureAndBack_RL.getAllBarnsForType(animalType)
    if candidates == nil or #candidates == 0 then return nil end

    -- Primary: position proximity across ALL candidates (handles renames)
    if savedX ~= nil and savedZ ~= nil then
        local bestBarn = nil
        local bestDist = 20  -- max 20m tolerance for position matching

        for _, barn in ipairs(candidates) do
            -- cert 2026-07-07 (M7): skip placeables claimed earlier in this pass
            if claimed == nil or not claimed[barn.placeable] then
                local bx, bz = ToPastureAndBack_RL.getBarnCachePos(barn)  -- save/load key match, NOT getBarnAnchorPos (must stay consistent across reloads)
                if bx ~= nil then
                    local dx = bx - savedX
                    local dz = bz - savedZ
                    local dist = math.sqrt(dx * dx + dz * dz)
                    if dist < bestDist then
                        bestDist = dist
                        bestBarn = barn
                    end
                end
            end
        end

        if bestBarn ~= nil then
            -- Read the barn's current name for logging (may differ from saved name)
            local currentName = bestBarn.placeable:getName() or bestBarn.name
            if currentName ~= barnName then
                dbgLog("TPAB-RL: findBarnForReconstruction: barn was renamed %s -> %s, matched by position (%.1fm)",
                    barnName, currentName, bestDist)
            else
                dbgLog("TPAB-RL: findBarnForReconstruction: matched %s at %.1fm from saved position",
                    currentName, bestDist)
            end
            return bestBarn.placeable
        end
    end

    -- Fallback: name match if no saved position (shouldn't happen, but be safe)
    for _, barn in ipairs(candidates) do
        -- cert 2026-07-07 (M7): skip placeables claimed earlier in this pass
        if (claimed == nil or not claimed[barn.placeable])
                and (barn.placeable:getName() == barnName or barn.name == barnName) then
            dbgLog("TPAB-RL: findBarnForReconstruction: matched %s by name (no position data)", barnName)
            return barn.placeable
        end
    end

    return nil
end

--- Clean up stale pasture points that have no active grazing session.
-- Called after session reconstruction to remove orphaned points from earlier testing.
function ToPastureAndBack_RL.cleanupStalePasturePoints()
    -- Build a set of pasture point IDs that are linked to active sessions
    local activePointIds = {}
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        if session.pasturePoint ~= nil then
            activePointIds[session.pasturePoint.id] = true
        end
    end

    -- Remove points with no active session
    local removed = 0
    for i = #ToPastureAndBack_RL.pasturePoints, 1, -1 do
        local point = ToPastureAndBack_RL.pasturePoints[i]
        if not activePointIds[point.id] then
            dbgLog("TPAB-RL: Removing stale pasture point [%d] %s (no active session)",
                point.id, point.name)
            table.remove(ToPastureAndBack_RL.pasturePoints, i)
            removed = removed + 1
        end
    end

    if removed > 0 then
        dbgLog("TPAB-RL: Cleaned up %d stale pasture point(s)", removed)
    end
end

--- Get the correct 0-based visual model index for addHusbandryAnimal.
-- Uses animalSystem:getVisualByAge to look up the visual matching the barn's actual age.
-- Falls back to subTypeIndex - 1 if the API is unavailable.
-- @param barnPlaceable table The barn placeable to read breed from
-- @param age number Animal age in months (from barn cluster data)
-- @return number The 0-based visual index for addHusbandryAnimal (defaults to 0)
function ToPastureAndBack_RL.getBreedVisualIndex(barnPlaceable, age)
    age = age or 36  -- fallback to adult if age not provided

    -- Step 1: Get subTypeIndex from any barn cluster
    local subTypeIndex = ToPastureAndBack_RL.getSubTypeFromBarn(barnPlaceable)
    if subTypeIndex == nil then
        dbgLog("TPAB-RL: getBreedVisualIndex: could not determine subTypeIndex, defaulting to 0")
        return 0
    end

    -- Step 2: Try animalSystem:getVisualByAge for the correct age model
    local animalSystem = g_currentMission.animalSystem
    if animalSystem ~= nil then
        local ok, visual = ToPastureAndBack_RL.fcall(function()
            return animalSystem:getVisualByAge(subTypeIndex, age)
        end)
        if ok and visual ~= nil then
            -- getVisualByAge returns a table with visualAnimalIndex (1-based)
            local visAnimalIdx = nil
            if type(visual) == "table" then
                visAnimalIdx = visual.visualAnimalIndex
            elseif type(visual) == "number" then
                visAnimalIdx = visual
            end
            if visAnimalIdx ~= nil then
                -- Convert from 1-based (game API) to 0-based (addHusbandryAnimal C++ API)
                local result = visAnimalIdx - 1
                dbgLog("TPAB-RL: getBreedVisualIndex: subType=%d, age=%d -> visualAnimalIndex=%d -> addHusbandry=%d",
                    subTypeIndex, age, visAnimalIdx, result)
                return result
            end
        else
            dbgLog("TPAB-RL: getVisualByAge failed or returned nil (ok=%s)", tostring(ok))
        end
    end

    -- Step 3: Fallback, log a warning so we know to investigate
    Logging.warning("TPAB-RL: getBreedVisualIndex: getVisualByAge not available, using subTypeIndex-1 as fallback (subType=%d -> visIdx=%d)",
        subTypeIndex, subTypeIndex - 1)
    return subTypeIndex - 1
end

--- Build a breed distribution list for spawning on pasture.
-- Reads ALL cluster entries from the barn, counts how many animals of each subType
-- exist, then maps each subType to its visual index via getVisualByAge.
-- Returns a flat list of visual indices, one per animal to spawn, preserving the
-- barn's actual breed proportions (e.g. 7 sheep + 3 goats -> 7x visIdx_A + 3x visIdx_B).
-- For barns with only one breed, this is equivalent to getBreedVisualIndex repeated N times.
-- @param barnPlaceable table The barn placeable
-- @param animalCount number Total animals to spawn
-- @param age number Animal age in months
-- @return table List of 0-based visual indices, length == animalCount
function ToPastureAndBack_RL.getBreedDistribution(barnPlaceable, animalCount, fallbackAge, opts)
    fallbackAge = fallbackAge or 36
    opts = opts or {}
    -- excludeYoung default true preserves existing pasture-send semantics. Set
    -- false for barn rendering. Note: TPAB-RL's main spawn path is per-Animal
    -- (each rlAnimal carries its own age + subType), so this function is only
    -- exercised by the legacy-save fallback path. Even so, the cluster-aware
    -- shape matches TPAB for consistency, and means the fallback renders mixed
    -- ages correctly.
    local excludeYoung = opts.excludeYoung
    if excludeYoung == nil then excludeYoung = true end
    local MIN_GRAZING_AGE_FOR_DIST = ToPastureAndBack_RL.getMinGrazingAgeForPlaceable(barnPlaceable)

    -- Step 1: Group cluster entries by (subTypeIndex, age) tuples, mirroring
    -- TPAB's 2026-05-08 mixed-age fix. RL's animalIdToCluster has each animal
    -- as its own cluster with a per-individual age, so this gives per-animal
    -- granularity automatically.
    local buckets = {}        -- "subType:age" -> { subType, age, count }
    local bucketOrder = {}
    local totalInBarn = 0

    local function addBucket(subType, age, count)
        if subType == nil or count == nil or count <= 0 then return end
        if excludeYoung and age ~= nil and age < MIN_GRAZING_AGE_FOR_DIST then return end
        local effectiveAge = age or fallbackAge
        local key = string.format("%d:%d", subType, math.floor(effectiveAge))
        local b = buckets[key]
        if b == nil then
            b = { subType = subType, age = effectiveAge, count = 0 }
            buckets[key] = b
            table.insert(bucketOrder, key)
        end
        b.count = b.count + count
        totalInBarn = totalInBarn + count
    end

    local spec = barnPlaceable.spec_husbandryAnimals
    if spec ~= nil and spec.clusterHusbandry ~= nil and spec.clusterHusbandry.animalIdToCluster ~= nil then
        for _, cluster in pairs(spec.clusterHusbandry.animalIdToCluster) do
            if type(cluster) == "table" and cluster.subTypeIndex ~= nil then
                addBucket(cluster.subTypeIndex, cluster.age, 1)
            end
        end
    end

    -- Fallback: no cluster data, single visIdx for the whole batch
    if totalInBarn == 0 then
        local visIdx = ToPastureAndBack_RL.getBreedVisualIndex(barnPlaceable, fallbackAge)
        local result = {}
        local subTypeList = {}
        local ageList = {}
        for i = 1, animalCount do
            result[i] = visIdx
            subTypeList[i] = nil
            ageList[i] = fallbackAge
        end
        result._subTypes = subTypeList
        result._ages = ageList
        dbgLog("TPAB-RL: getBreedDistribution: no cluster data, using single visIdx=%d x%d", visIdx, animalCount)
        return result
    end

    -- Step 2: Resolve visIdx per (subType, age) bucket via getVisualByAge.
    local animalSystem = g_currentMission.animalSystem
    local breedEntries = {}
    for _, key in ipairs(bucketOrder) do
        local b = buckets[key]
        local visIdx = b.subType - 1  -- fallback: subType-1
        if animalSystem ~= nil then
            local ok, visual = ToPastureAndBack_RL.fcall(function()
                return animalSystem:getVisualByAge(b.subType, b.age)
            end)
            if ok and visual ~= nil then
                local vai = nil
                if type(visual) == "table" then vai = visual.visualAnimalIndex
                elseif type(visual) == "number" then vai = visual end
                if vai ~= nil then visIdx = vai - 1 end
            end
        end
        table.insert(breedEntries, { subType = b.subType, age = b.age, visIdx = visIdx, count = b.count })
        dbgLog("TPAB-RL: getBreedDistribution: subType=%d age=%d -> visIdx=%d, barnCount=%d",
            b.subType, b.age, visIdx, b.count)
    end

    -- Step 3a: proportional shares per (subType, age) bucket
    table.sort(breedEntries, function(a, b) return a.count > b.count end)
    local pending = {}
    local assigned = 0
    for i, entry in ipairs(breedEntries) do
        local share
        if i == #breedEntries then
            share = animalCount - assigned
        else
            share = math.floor((entry.count / totalInBarn) * animalCount + 0.5)
            share = math.min(share, animalCount - assigned)
        end
        if share > 0 then
            table.insert(pending, {
                subType = entry.subType,
                age = entry.age,
                visIdx = entry.visIdx,
                remaining = share,
            })
        end
        assigned = assigned + share
    end

    -- Step 3b: round-robin emit so a 25-cap chunk shows a mixed herd, not 25
    -- of the dominant bucket.
    local result = {}
    local subTypeList = {}
    local ageList = {}
    while #pending > 0 do
        for i = 1, #pending do
            local p = pending[i]
            if p.remaining > 0 then
                table.insert(result, p.visIdx)
                table.insert(subTypeList, p.subType)
                table.insert(ageList, p.age)
                p.remaining = p.remaining - 1
            end
        end
        for i = #pending, 1, -1 do
            if pending[i].remaining <= 0 then table.remove(pending, i) end
        end
    end
    result._subTypes = subTypeList
    result._ages = ageList

    local parts = {}
    for _, entry in ipairs(breedEntries) do
        local share = 0
        for _, v in ipairs(result) do if v == entry.visIdx then share = share + 1 end end
        table.insert(parts, string.format("subType%d:age%d:visIdx%d=%d",
            entry.subType, entry.age, entry.visIdx, share))
    end
    dbgLog("TPAB-RL: Breed distribution for %d animals: %s (barn had %d total %s)",
        animalCount, table.concat(parts, ", "), totalInBarn,
        excludeYoung and "[excludeYoung=on]" or "[excludeYoung=off]")

    return result
end

-- ============================================================================
-- RL Animal Data Layer
-- These functions read from Realistic Livestock's individual Animal objects
-- via clusterSystem:getAnimals() instead of base game's cluster groups.
-- ============================================================================

--- Get the list of individual RL Animal objects from a barn.
-- RL replaces base game AnimalCluster groups with individual Animal objects,
-- each with breed, age, gender, uniqueId, name, genetics, ear tags.
-- @param barnPlaceable table The barn placeable
-- @return table List of Animal objects (may be empty)
function ToPastureAndBack_RL.getRLAnimalsFromBarn(barnPlaceable)
    local spec = barnPlaceable.spec_husbandryAnimals
    if spec == nil then return {} end

    local clusterSystem = spec.clusterSystem
    if clusterSystem == nil then return {} end

    -- RL adds getAnimals() to AnimalClusterSystem, returns flat list of Animal objects
    if clusterSystem.getAnimals == nil then
        dbgLog("TPAB-RL: clusterSystem.getAnimals not available, RL may not be loaded")
        return {}
    end

    local animals = clusterSystem:getAnimals()
    if animals == nil then return {} end

    -- Filter out dead/sold animals
    local result = {}
    for _, animal in ipairs(animals) do
        if animal ~= nil and not animal.isDead and not animal.isSold then
            table.insert(result, animal)
        end
    end

    return result
end

--- Return the FIRST RL Animal's age in the barn. Not "representative" in any
-- statistical sense; just the first animal returned by getRLAnimalsFromBarn.
-- Callers that care about per-animal age should iterate rlAnimals directly,
-- which the main spawn path already does (each Animal carries its own age,
-- subType, ear tags, genetics). This helper exists for the legacy fallback
-- path and for messages that just need ANY age value.
-- @param barnPlaceable table The barn placeable
-- @return number Age in months of the first listed animal, or nil if empty
function ToPastureAndBack_RL.getAnimalAgeFromBarn(barnPlaceable)
    local animals = ToPastureAndBack_RL.getRLAnimalsFromBarn(barnPlaceable)
    if #animals > 0 then
        return animals[1]:getAge()
    end
    return nil
end

--- Read subTypeIndex from a barn via RL individual animals.
-- @param barnPlaceable table The barn placeable
-- @return number subTypeIndex, or nil
function ToPastureAndBack_RL.getSubTypeFromBarn(barnPlaceable)
    local animals = ToPastureAndBack_RL.getRLAnimalsFromBarn(barnPlaceable)
    if #animals > 0 then
        return animals[1]:getSubTypeIndex()
    end
    return nil
end

-- NOTE: Legacy functions getVisualIndicesForBarn, findVisualIndicesFromBarns,
-- and extractVisualIndices were removed (2026-04-05). They read barn-internal
-- animalIdToVisualAnimalIndex which is NOT the same as addHusbandryAnimal's
-- visual index. Breed resolution now uses getBreedVisualIndex (above) which
-- calls animalSystem:getVisualByAge for the correct mapping.


-- ============================================================================
-- Grazing timer management
-- ============================================================================

--- Check all active grazing sessions and despawn any that have expired.
-- Called from update() each frame.
function ToPastureAndBack_RL.updateGrazingSessions(dt)
    local env = g_currentMission.environment
    if env == nil then return end

    local currentDay = env.currentDay
    local currentHour = env.dayTime / 3600000  -- ms to hours

    for i = #ToPastureAndBack_RL.grazingSessions, 1, -1 do
        local session = ToPastureAndBack_RL.grazingSessions[i]

        -- Handle spawn state machine
        if session.spawnState == "pending" then
            ToPastureAndBack_RL.spawnVisualHerd(session)
        elseif session.spawnState == "waiting_ready" then
            ToPastureAndBack_RL.continueSpawn(session)
        elseif session.spawnState == "waiting_hus_ready" then
            ToPastureAndBack_RL.continueHusReady(session)
        elseif session.spawnState == "waiting_visuals" then
            ToPastureAndBack_RL.continueVisuals(session)
        elseif session.spawnState == "active" then
            -- Check timer expiry (only server triggers auto-recall, skip if durationHours is 0 = Off)
            if g_server ~= nil and session.durationHours > 0
                    and session.startDay ~= nil and session.startHour ~= nil then
                local elapsedHours = (currentDay - session.startDay) * 24 + (currentHour - session.startHour)
                if elapsedHours >= session.durationHours then
                    dbgLog("TPAB-RL: Session %s expired (%.1fh elapsed, %.1fh duration), sending recall event",
                        session.id, elapsedHours, session.durationHours)
                    ToPastureAndBack_RL.sendEvent(RecallFromPastureEvent.new(session.id))
                end
            end
        end

        -- Remove completed sessions and their pasture points
        if session.spawnState == "done" then
            for j = #ToPastureAndBack_RL.pasturePoints, 1, -1 do
                if ToPastureAndBack_RL.pasturePoints[j] == session.pasturePoint then
                    table.remove(ToPastureAndBack_RL.pasturePoints, j)
                    break
                end
            end
            table.remove(ToPastureAndBack_RL.grazingSessions, i)
            dbgLog("TPAB-RL: Session %s removed from active list", session.id)
        end
    end

    -- Dusk reminder: fires once per game day at 18:00 game time when herds are out and setting is enabled.
    -- Pig sessions use "foraging" wording, others use "grazing".
    if true then
        local activeCount = 0
        local spawningCount = 0
        local hasPigs = false
        local hasGrazers = false
        for _, s in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if s.spawnState == "active" and ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfSession(s)) then
                activeCount = activeCount + 1
                local tier = ToPastureAndBack_RL.getAnimalFieldTier(s.animalType)
                if tier == "forager" then hasPigs = true else hasGrazers = true end
            elseif s.spawnState ~= "done" and ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfSession(s)) then
                spawningCount = spawningCount + 1
            end
        end
        -- Herds still appearing after a load are not "active" yet. Counting only the active ones
        -- latched the day on a short count, so the reminder named too few herds (design doc
        -- 2026-07-16). Wait for them, at most 60 s, then remind with whatever is out (2026-10-27).
        local duskDue = currentHour >= ToPastureAndBack_RL.DUSK_REMINDER_HOUR and currentDay ~= ToPastureAndBack_RL.lastDuskReminderDay
        local duskWait = false
        if duskDue and spawningCount > 0 then
            local now = g_time or 0
            if ToPastureAndBack_RL._duskDeferSince == nil then
                ToPastureAndBack_RL._duskDeferSince = now
                dbgLog("TPAB-RL: dusk reminder waits for %d herd(s) still appearing (%d out)", spawningCount, activeCount)
            end
            duskWait = (now - ToPastureAndBack_RL._duskDeferSince) < 60000
        end
        if not duskWait then
            ToPastureAndBack_RL._duskDeferSince = nil
        end
        if duskDue and not duskWait and activeCount > 0 then
            ToPastureAndBack_RL.lastDuskReminderDay = currentDay
            local msg
            if activeCount == 1 then
                -- Find the one active session for a specific message
                for _, s in ipairs(ToPastureAndBack_RL.grazingSessions) do
                    if s.spawnState == "active" and ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfSession(s)) then
                        local barnName = s.barnName or "barn"
                        if s.barnPlaceable ~= nil and s.barnPlaceable.getName ~= nil then
                            local okN, fresh = ToPastureAndBack_RL.fcall(s.barnPlaceable.getName, s.barnPlaceable)
                            if okN and fresh ~= nil then barnName = fresh end
                        end
                        -- Build a farmland/pasture label so the dusk reminder
                        -- includes the destination (Field N), not just the barn.
                        local farmlandLabel = ""
                        if s.pastureDestName ~= nil and s.pastureDestName ~= "" then
                            if s.farmlandId ~= nil and s.farmlandId > 0 then
                                farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at_farmland"), s.pastureDestName, s.farmlandId)
                            else
                                farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("at"), s.pastureDestName)
                            end
                        elseif s.farmlandId ~= nil and s.farmlandId > 0 then
                            farmlandLabel = string.format(ToPastureAndBack_RL.placeFmt("farmland"), s.farmlandId)
                        end
                        local tier = ToPastureAndBack_RL.getAnimalFieldTier(s.animalType)
                        if tier == "forager" then
                            -- tpab_pig_dusk_single is pigs-specific and already names the species
                            msg = string.format(ToPastureAndBack_RL.outText(g_i18n:getText("tpab_pig_dusk_single"), farmlandLabel),
                                barnName, farmlandLabel, ToPastureAndBack_RL.getBindingText("TPABRL_RECALL"))
                        else
                            local duskSpecies = ToPastureAndBack_RL.getSpeciesNoun(s.animalType, s)
                            local duskPossessive = ToPastureAndBack_RL.getSpeciesPossessive(s.animalType, s)
                            local duskVerb = ToPastureAndBack_RL.getSpeciesVerb(s.animalType, "be", s)
                            msg = string.format(ToPastureAndBack_RL.outText(g_i18n:getText("tpab_dusk_reminder_single"), farmlandLabel),
                                duskPossessive, duskSpecies, barnName, duskVerb, farmlandLabel)
                        end
                        break
                    end
                end
            else
                -- Multiple herds: if mix of pigs and grazers, use generic multi
                if hasPigs and not hasGrazers then
                    msg = string.format(g_i18n:getText("tpab_pig_dusk_multi"), activeCount, ToPastureAndBack_RL.getBindingText("TPABRL_RECALL"))
                else
                    msg = string.format(g_i18n:getText("tpab_dusk_reminder_multi"), activeCount)
                end
            end
            if msg ~= nil then
                ToPastureAndBack_RL.showDuskReminder(msg)
            end
        end
    end

    -- Curfew recall: at 10 PM game time, auto-recall ALL active sessions.
    -- Server-only trigger; the herdsman umbrella message is shown by
    -- executeRecallFromEvent on every peer that processes the broadcast,
    -- so per-peer curfew settings (which are NOT synced across the network)
    -- don't matter for the message itself. Fires once per game day.
    if g_server ~= nil
            and ToPastureAndBack_RL.CURFEW_OPTIONS[ToPastureAndBack_RL.settings.curfewIndex] == true
            and currentHour >= ToPastureAndBack_RL.CURFEW_HOUR
            and currentDay ~= ToPastureAndBack_RL.lastCurfewDay then
        local hasActive = false
        for _, s in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if s.spawnState == "active" then hasActive = true; break end
        end
        if hasActive then
            ToPastureAndBack_RL.lastCurfewDay = currentDay
            dbgLog("TPAB-RL: Curfew recall at %d:00", ToPastureAndBack_RL.CURFEW_HOUR)
            ToPastureAndBack_RL.sendEvent(RecallFromPastureEvent.new("ALL", true, true))  -- isCurfewFlow=true
        end
    end
end


-- ============================================================================
-- Mod event listener callbacks
-- ============================================================================

function ToPastureAndBack_RL:loadMap(filename)
    Logging.info("TPAB-RL: To Pasture and Back v1.0.0.0 loading")
    -- The shared help panel lists every loaded Kijbev mod, so it is set up even when this edition
    -- switches itself off further down (its own section is then hidden through KijbevHelp.hide).
    if KijbevHelp ~= nil and KijbevHelp.onLoadMap ~= nil then
        KijbevHelp.onLoadMap("TPABRL")
    else
        Logging.warning("TPAB-RL: KijbevHelp module not loaded, help panel unavailable. Check the <sourceFile> ORDER in modDesc.xml.")
    end

    -- Check that Realistic Livestock is installed and loaded.
    -- Without RL, this mod's Animal-level APIs (clusterSystem:getAnimals,
    -- animal:createVisual, ear tags, identity triples) do not exist.
    local rlLoaded = g_modIsLoaded ~= nil and g_modIsLoaded["FS25_RealisticLivestockRM"] == true
    if not rlLoaded then
        Logging.error("TPAB-RL: Realistic Livestock (FS25_RealisticLivestockRM) is not installed or not active. This mod requires Realistic Livestock by Ritter. The mod will not function without it.")
        ToPastureAndBack_RL.initialized = false
        ToPastureAndBack_RL.rlMissing = true
        if KijbevHelp ~= nil and type(KijbevHelp.hide) == "function" then
            KijbevHelp.hide("TPABRL_")
        end
        return
    end

    -- Input is handled via rebindable action events, cert 2026-07-07 (K1):
    -- see registerGlobalActionEvents and the PlayerInputComponent hook at the
    -- bottom of this file.

    -- Load settings first (auto-recall preference etc.)
    ToPastureAndBack_RL.loadSettings()

    -- Build settings UI (dropdown in General Settings page)
    ToPastureAndBack_RL.buildSettingsMenu()

    -- Load saved pasture points and grazing sessions
    ToPastureAndBack_RL.loadFromXML()

    -- Hook PlayerHUDUpdater so hovering over pasture animals shows RL data
    -- (name, genetics, diseases, etc.). Runs after RL's own appended hook,
    -- catching animals in our temporary pasture husbandries that RL's
    -- cluster lookup misses.
    ToPastureAndBack_RL.installHudHook()

    -- Hook updateVisualAnimals so RL's periodic visual refresh (triggered by
    -- updateClusters on each in-game hour) skips barns we've suppressed.
    -- Without this, RL re-creates barn visuals from cluster data after our
    -- suppression, causing double-rendering (animals in barn AND on pasture).
    ToPastureAndBack_RL.installSuppressHook()

    -- Hook RL's AnimalClusterHusbandry.updateVisuals so animal buys/moves don't restore
    -- visuals of pastured animals while a TPAB session is active.
    ToPastureAndBack_RL.installRLUpdateVisualsHook()

    -- Poultry limit: outermost, so it wraps RL's routine and the re-suppress hook above.
    ToPastureAndBack_RL.installPoultryCapHook()

    -- Install Placeable lifecycle hooks for cache invalidation on sold/built placeables
    ToPastureAndBack_RL.installPlaceableLifecycleHooks()

    -- 2026-06-23: release a leaving player's stuck barn locks (mid-pocket disconnect),
    -- which restores the barn + the pocketed herd for everyone. Server acts; clients no-op.
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.USER_REMOVED ~= nil then
        g_messageCenter:subscribe(MessageType.USER_REMOVED, ToPastureAndBack_RL.onUserRemovedCleanup, ToPastureAndBack_RL)
    end

    ToPastureAndBack_RL.initialized = true
    dbgLog("TPAB-RL: Initialization complete")
end

--- Hook PlayerHUDUpdater.updateRaycastObject so that pasture animals show
-- RL info (name, genetics, diseases) in the right-hand HUD panel.
--
-- RL hooks the same function to resolve animals via its cluster system,
-- but our temporary pasture husbandries are not registered there. We append
-- a second check that looks up our pastureAnimalLookup table. Because we
-- store the original RL Animal objects, all of RL's showInfo / showGeneticsInfo /
-- showDiseasesInfo methods work natively, no proxying needed.
--- Hook for Placeable.delete. Called when any placeable is destroyed (sold,
-- bulldozed, map unload). We clean up any active grazing session whose source
-- barn is this placeable (minimal cleanup, don't touch the dying barn), then
-- remove all cache entries pointing at this placeable.
function ToPastureAndBack_RL.onPlaceableDeleted(placeable)
    if placeable == nil or placeable.spec_husbandryAnimals == nil then return end

    -- Abandon sessions whose source barn is this placeable
    if ToPastureAndBack_RL.grazingSessions ~= nil then
        local remaining = {}
        for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
            if session.barnPlaceable == placeable then
                dbgLog("TPAB-RL: Source barn deleted mid-session, cleaning up session %s",
                    session.id)
                -- skipBarnRestore instead of a global flag: a throw inside cleanup can no longer leave
                -- mapUnloading stuck on for the rest of the session (review 2026-10-11).
                ToPastureAndBack_RL.cleanupSession(session, true)
            else
                table.insert(remaining, session)
            end
        end
        ToPastureAndBack_RL.grazingSessions = remaining
    end

    -- Remove cache entries for this placeable across all animal types
    if ToPastureAndBack_RL.barnCache ~= nil then
        for animalType, entries in pairs(ToPastureAndBack_RL.barnCache) do
            local newEntries = {}
            local removed = 0
            for _, entry in ipairs(entries) do
                if entry.placeable == placeable then
                    removed = removed + 1
                else
                    table.insert(newEntries, entry)
                end
            end
            if removed > 0 then
                ToPastureAndBack_RL.barnCache[animalType] = newEntries
                dbgLog("TPAB-RL: Removed %d stale cache entry(s) from %s cache (sold husbandry)",
                    removed, animalType)
            end
        end
    end
end


--- Hook for Placeable.finalizePlacement. Called when a newly-built placeable
-- finishes placement. If it's a supported husbandry type, schedule a cache
-- rescan for that animal type in 100 frames (gives the nav mesh time to build).
function ToPastureAndBack_RL.onPlaceableFinalized(placeable)
    if placeable == nil or placeable.spec_husbandryAnimals == nil then return end

    local spec = placeable.spec_husbandryAnimals
    local animalType = ""
    if spec.animalType ~= nil then
        if spec.animalType.name ~= nil then
            animalType = string.upper(spec.animalType.name)
        elseif spec.animalType.type ~= nil then
            animalType = string.upper(tostring(spec.animalType.type))
        end
    end
    if animalType == "" then return end
    if ToPastureAndBack_RL.EXCLUDED_TYPES ~= nil and ToPastureAndBack_RL.EXCLUDED_TYPES[animalType] then return end
    -- Skip during initial load: finalizePlacement fires for every placeable when
    -- the map loads from savegame, and the initial scan at frame ~350 catches them all.
    -- Only react to placements that happen AFTER barn cache is ready (player-built mid-game).
    if not ToPastureAndBack_RL.barnCacheReady then return end

    ToPastureAndBack_RL.pendingRescans = ToPastureAndBack_RL.pendingRescans or {}
    ToPastureAndBack_RL.pendingRescans[animalType] = 100
    dbgLog("TPAB-RL: New %s husbandry built, scheduled cache rescan in 100 frames", animalType)
end


--- Install Placeable.delete and Placeable.finalizePlacement hooks.
function ToPastureAndBack_RL.installPlaceableLifecycleHooks()
    if Placeable == nil then
        Logging.warning("TPAB-RL: Placeable class unavailable, lifecycle hooks not installed")
        return
    end

    Placeable.delete = Utils.appendedFunction(Placeable.delete, function(self)
        if not ToPastureAndBack_RL.initialized then return end
        if ToPastureAndBack_RL.mapUnloading then return end
        ToPastureAndBack_RL.onPlaceableDeleted(self)
    end)

    Placeable.finalizePlacement = Utils.appendedFunction(Placeable.finalizePlacement, function(self)
        if not ToPastureAndBack_RL.initialized then return end
        ToPastureAndBack_RL.onPlaceableFinalized(self)
    end)

    dbgLog("TPAB-RL: Placeable lifecycle hooks installed (delete + finalizePlacement)")
end


function ToPastureAndBack_RL.installHudHook()
    if PlayerHUDUpdater == nil then
        Logging.warning("TPAB-RL: PlayerHUDUpdater unavailable, HUD hook not installed")
        return
    end

    PlayerHUDUpdater.updateRaycastObject = Utils.appendedFunction(
        PlayerHUDUpdater.updateRaycastObject,
        function(self)
            -- Only run if nobody else already resolved the animal
            if self.isAnimal then return end
            if self.currentRaycastTarget == nil then return end
            local ok, exists = ToPastureAndBack_RL.fcallNode(entityExists, self.currentRaycastTarget)
            if not ok or not exists then return end

            -- Ask the engine which husbandry + animal this collision node belongs to
            local ok2, husId, animalId = ToPastureAndBack_RL.fcall(getAnimalFromCollisionNode, self.currentRaycastTarget)
            if not ok2 or husId == nil or husId == 0 then return end

            -- Check our lookup table
            local husTable = ToPastureAndBack_RL.pastureAnimalLookup[husId]
            if husTable == nil then return end

            local animal = husTable[animalId]
            if animal == nil then return end

            -- Found a pasture animal, hand it to the HUD pipeline
            self.isAnimal = true
            self.object = animal
        end
    )
    dbgLog("TPAB-RL: PlayerHUDUpdater hook installed for pasture animal HUD")
end

--- Hook PlaceableHusbandryAnimals.updateVisualAnimals so that RL's periodic
-- visual refresh (triggered by updateClusters on each in-game hour tick) skips
-- barns that we've suppressed. Without this hook, RL re-reads its cluster data,
-- finds that the barn still has animals (cluster data is intentionally untouched),
-- and re-creates the visual animals in the barn while they're also on pasture.
--- Hook AnimalClusterHusbandry.updateVisuals so RL's visual refresh (triggered
-- by animal buys, moves, age ticks, or any cluster modification) does not restore
-- the visuals of animals we have suppressed for grazing. RL's updateVisuals
-- iterates `nextUpdateClusters` and recreates a visual for any animal whose
-- `.id` is nil (our suppression sets it to nil), bypassing our suppress hook on
-- `PlaceableHusbandryAnimals.updateVisualAnimals`. This appended hook runs AFTER
-- RL finishes its updateVisuals and re-suppresses any of our pastured animals
-- that got recreated.
-- ---------------------------------------------------------------------------------------------------------
-- POULTRY LIMIT (blueprint docs/TPAB_RL_PoultryCap_Blueprint.md, review 2026-10-20 folded)
-- ---------------------------------------------------------------------------------------------------------

--- Realistic Livestock's cluster-husbandry class. RL's globals live in RL's OWN mod environment, so the plain
--- name is nil from here (field 2026-10-21: "poultry limit unavailable"). Reached through the mod's name like
--- other mods do (DashboardLive: FS25_precisionFarming.ExtendedSprayer); the plain name stays as a fallback.
function ToPastureAndBack_RL.getRLCluster()
    local env = FS25_RealisticLivestockRM
    if type(env) == "table" and type(env.RealisticLivestock_AnimalClusterHusbandry) == "table" then
        return env.RealisticLivestock_AnimalClusterHusbandry
    end
    if type(RealisticLivestock_AnimalClusterHusbandry) == "table" then
        return RealisticLivestock_AnimalClusterHusbandry
    end
    return nil
end

--- The chosen poultry cap as a number, or nil for "same as herd animals".
function ToPastureAndBack_RL.getPoultryCap()
    local id = ToPastureAndBack_RL.POULTRY_CAP_IDS[ToPastureAndBack_RL.settings.poultryCapIndex or 1]
    return tonumber(id)
end

--- True when this cluster husbandry holds poultry (LV's name test). Cached on the husbandry.
function ToPastureAndBack_RL.isPoultryHusbandry(ch)
    if ch == nil then return false end
    if ch.tpabrlIsPoultry ~= nil then return ch.tpabrlIsPoultry end
    local name = ch.animalTypeName
    if name == nil and ch.placeable ~= nil and ch.placeable.getAnimalTypeIndex ~= nil
        and g_currentMission ~= nil and g_currentMission.animalSystem ~= nil then
        local t = g_currentMission.animalSystem.types[ch.placeable:getAnimalTypeIndex()]
        name = t ~= nil and t.name or nil
    end
    if name == nil then return false end
    name = string.upper(tostring(name))
    local poultry = false
    if not ToPastureAndBack_RL.POULTRY_SKIP[name] then
        for _, word in ipairs(ToPastureAndBack_RL.POULTRY_WORDS) do
            if string.find(name, word, 1, true) ~= nil then poultry = true break end
        end
    end
    ch.tpabrlIsPoultry = poultry
    return poultry
end

--- Put RL's own visible-animals number back if a coop update was interrupted (an error inside RL's
--- routine). Calls are synchronous, so a swap still set outside a call is always stale (review S1).
function ToPastureAndBack_RL.restoreStalePoultrySwap(where)
    local prev = ToPastureAndBack_RL._poultrySwapPrev
    local swappedCap = ToPastureAndBack_RL._poultrySwapCap
    ToPastureAndBack_RL._poultrySwapPrev = nil
    ToPastureAndBack_RL._poultrySwapCap = nil
    if prev == nil then return end
    -- Only if RL still holds the number we put there: a slider change in RL's own dialog meanwhile wins
    -- (code review S-1).
    local R = ToPastureAndBack_RL.getRLCluster()
    if R ~= nil and R.MAX_HUSBANDRIES == swappedCap then
        R.MAX_HUSBANDRIES = prev
    end
    if not ToPastureAndBack_RL._poultrySwapWarned then
        ToPastureAndBack_RL._poultrySwapWarned = true
        Logging.warning("TPAB-RL: a coop visual update was interrupted; Realistic Livestock's visible animals (%s) restored (%s)",
            tostring(prev), tostring(where))
    end
end

--- Redraw every coop at the current poultry cap (Realistic Livestock's own refresh, VisualAnimalsDialog:onYes).
function ToPastureAndBack_RL.refreshCoopVisuals()
    local hs = g_currentMission ~= nil and g_currentMission.husbandrySystem or nil
    if hs == nil or hs.clusterHusbandries == nil then return end
    local n = 0
    for _, ch in ipairs(hs.clusterHusbandries) do
        if ToPastureAndBack_RL.isPoultryHusbandry(ch) and ch.placeable ~= nil then
            local spec = ch.placeable.spec_husbandryAnimals
            local cs = spec ~= nil and spec.clusterSystem or nil
            if cs ~= nil and cs.getAnimals ~= nil and ch.updateVisuals ~= nil then
                ch.nextUpdateClusters = cs:getAnimals()
                ch:updateVisuals(true)
                n = n + 1
            end
        end
    end
    dbgLog("TPAB-RL: poultry cap %s applied to %d coop(s)", tostring(ToPastureAndBack_RL.getPoultryCap() or "same"), n)
end

--- Settings callback for the poultry row.
function ToPastureAndBack_RL.onPoultryCapChanged(_, state)
    if state == nil or ToPastureAndBack_RL.POULTRY_CAP_IDS[state] == nil then return end
    ToPastureAndBack_RL.settings.poultryCapIndex = state
    ToPastureAndBack_RL.saveSettings()
    dbgLog("TPAB-RL: Poultry shown changed to %s", ToPastureAndBack_RL.POULTRY_CAP_IDS[state])
    ToPastureAndBack_RL.refreshCoopVisuals()
end

--- Lower Realistic Livestock's visible-animals number while a COOP is drawn, then put it back.
--- Installed on EVERY loadMap (review B1: RL re-sources its own overwrite each load and never calls the
--- function below it, so a once-only install would be dead from the second savegame on). Everything is
--- read through the globals at call time; stacked older copies pass straight through (cap >= MAX).
function ToPastureAndBack_RL.installPoultryCapHook()
    local rlCluster = ToPastureAndBack_RL.getRLCluster()
    if AnimalClusterHusbandry == nil or AnimalClusterHusbandry.updateVisuals == nil
        or rlCluster == nil or type(rlCluster.MAX_HUSBANDRIES) ~= "number" then
        Logging.warning("TPAB-RL: poultry limit unavailable (Realistic Livestock's visual cap not found), the Poultry shown row has no effect")
        return
    end
    -- Generation on the (persistent) base class: an older copy left in the chain passes straight through,
    -- so the current copy can treat any swap still set at its entry as stale (code review S-1).
    local myGen = (AnimalClusterHusbandry.tpabrlPoultryGen or 0) + 1
    AnimalClusterHusbandry.tpabrlPoultryGen = myGen
    AnimalClusterHusbandry.updateVisuals = Utils.overwrittenFunction(AnimalClusterHusbandry.updateVisuals,
        function(self, superFunc, ...)
            local T = ToPastureAndBack_RL
            local R = T ~= nil and T.getRLCluster() or nil
            if myGen ~= AnimalClusterHusbandry.tpabrlPoultryGen or T == nil or R == nil
                or type(R.MAX_HUSBANDRIES) ~= "number" then
                return superFunc(self, ...)
            end
            -- RL's routine never re-enters updateVisuals, so a swap still set here was interrupted.
            if T._poultrySwapPrev ~= nil then
                T.restoreStalePoultrySwap("visual update")
            end
            local isPoultry = T.isPoultryHusbandry(self)
            local cap = isPoultry and T.getPoultryCap() or nil
            if cap == nil or cap >= R.MAX_HUSBANDRIES then
                superFunc(self, ...)
            else
                local prev = R.MAX_HUSBANDRIES
                T._poultrySwapPrev = prev
                T._poultrySwapCap = cap
                R.MAX_HUSBANDRIES = cap
                superFunc(self, ...)
                R.MAX_HUSBANDRIES = prev
                T._poultrySwapPrev = nil
                T._poultrySwapCap = nil
            end
            -- One line per coop on its first COMPLETED draw (RL defers with visualUpdatePending while the
            -- husbandry is not ready; code review S-2). Proves the cap applies at load.
            if isPoultry and not self.tpabrlPoultryLogged and self.visualUpdatePending ~= true then
                self.tpabrlPoultryLogged = true
                dbgLog("TPAB-RL: coop first drawn: %s shown, poultry cap %s, Realistic Livestock max %s",
                    tostring(self.visualAnimalCount), tostring(cap or "same"), tostring(R.MAX_HUSBANDRIES))
            end
        end)
    -- A host save writes RL's number into its settings file (RealisticLivestock_PlaceableSystem.saveToXML,
    -- prepended by RL each load); put RL's own number back first if a swap was left behind (review S1).
    if PlaceableSystem ~= nil and PlaceableSystem.saveToXML ~= nil then
        PlaceableSystem.saveToXML = Utils.prependedFunction(PlaceableSystem.saveToXML, function(...)
            local T = ToPastureAndBack_RL
            if T ~= nil and T._poultrySwapPrev ~= nil then T.restoreStalePoultrySwap("save") end
        end)
    end
    dbgLog("TPAB-RL: poultry limit hook installed (cap %s, Realistic Livestock max %s)",
        tostring(ToPastureAndBack_RL.getPoultryCap() or "same"), tostring(rlCluster.MAX_HUSBANDRIES))
end

function ToPastureAndBack_RL.installRLUpdateVisualsHook()
    if AnimalClusterHusbandry == nil then
        Logging.warning("TPAB-RL: AnimalClusterHusbandry unavailable, RL updateVisuals hook not installed")
        return
    end

    AnimalClusterHusbandry.updateVisuals = Utils.appendedFunction(
        AnimalClusterHusbandry.updateVisuals,
        function(self, removeAll)
            -- Resolve the placeable that owns this cluster husbandry
            local placeable = self.placeable
            if placeable == nil and self.getPlaceable ~= nil then
                local ok, p = ToPastureAndBack_RL.fcall(self.getPlaceable, self)
                if ok then placeable = p end
            end
            if placeable == nil then return end

            local suppressData = ToPastureAndBack_RL.suppressedBarns[placeable]
            if suppressData == nil then return end

            local rlAnimals = suppressData.rlAnimals
            if rlAnimals == nil or #rlAnimals == 0 then return end

            -- Build the pastured-set lookup
            local pasturedSet = {}
            for _, animal in ipairs(rlAnimals) do
                pasturedSet[animal] = true
            end

            -- Walk animalIdToCluster and re-suppress any pastured animal that got recreated
            local resuppressed = 0
            if self.animalIdToCluster ~= nil then
                for slotIdx, animalMap in pairs(self.animalIdToCluster) do
                    if type(animalMap) == "table" then
                        local idsToRemove = {}
                        for animalId, animal in pairs(animalMap) do
                            if pasturedSet[animal] then
                                table.insert(idsToRemove, { animalId = animalId, animal = animal })
                            end
                        end
                        for _, entry in ipairs(idsToRemove) do
                            local husEngineId = self.husbandryIds and self.husbandryIds[slotIdx]
                            if husEngineId ~= nil then
                                ToPastureAndBack_RL.fcall(removeHusbandryAnimal, husEngineId, entry.animalId)
                                if entry.animal ~= nil and entry.animal.deleteVisual ~= nil then
                                    ToPastureAndBack_RL.fcall(entry.animal.deleteVisual, entry.animal)
                                end
                                if entry.animal ~= nil then
                                    entry.animal.id = nil
                                    entry.animal.idFull = nil
                                    entry.animal.visualAnimalIndex = nil
                                end
                                resuppressed = resuppressed + 1
                            end
                            animalMap[entry.animalId] = nil
                        end
                    end
                end
            end

            if resuppressed > 0 then
                self.visualAnimalCount = math.max(0, (self.visualAnimalCount or 0) - resuppressed)
                if self.husbandryIdsToVisualAnimalCount ~= nil then
                    -- Recount per-husbandry slots from animalIdToCluster
                    for husId, _ in pairs(self.husbandryIdsToVisualAnimalCount) do
                        self.husbandryIdsToVisualAnimalCount[husId] = 0
                    end
                    for slotIdx, animalMap in pairs(self.animalIdToCluster) do
                        local husId = self.husbandryIds and self.husbandryIds[slotIdx]
                        if husId ~= nil and type(animalMap) == "table" then
                            local count = 0
                            for _ in pairs(animalMap) do count = count + 1 end
                            self.husbandryIdsToVisualAnimalCount[husId] = count
                        end
                    end
                end
                dbgLog("TPAB-RL: Re-suppressed %d pasture animals after RL visual refresh (buy/move/etc on suppressed barn)",
                    resuppressed)
            end
        end
    )

    dbgLog("TPAB-RL: AnimalClusterHusbandry.updateVisuals hook installed (re-suppress guard)")
end


function ToPastureAndBack_RL.installSuppressHook()
    if PlaceableHusbandryAnimals == nil then
        Logging.warning("TPAB-RL: PlaceableHusbandryAnimals unavailable, suppress hook not installed")
        return
    end

    PlaceableHusbandryAnimals.updateVisualAnimals = Utils.overwrittenFunction(
        PlaceableHusbandryAnimals.updateVisualAnimals,
        function(self, superFunc, ...)
            -- If this barn is in our suppressed set, skip the visual update entirely
            if ToPastureAndBack_RL.suppressedBarns[self] ~= nil then
                dbgLog("TPAB-RL: Blocked updateVisualAnimals for suppressed barn %s",
                    self.getName and self:getName() or "?")
                return
            end
            return superFunc(self, ...)
        end
    )
    dbgLog("TPAB-RL: PlaceableHusbandryAnimals.updateVisualAnimals hook installed (suppress guard)")
end


-- Removed 2026-07-11 : the AnimalScreen barn-menu T integration was vanilla-TPAB-only,
-- RL owns the animal-screen flow so the hook could never fire for players. Intentional
-- divergence from vanilla TPAB, register in the parity registry (RL work plan item 0).

--- Re-roll a cap-bound floater (TPAB round-4 fix, ported 2026-06-05).
-- Remove + re-add re-runs the engine's async placement (~98% grounded per
-- roll, validated 18/18 in TPAB). RL-specific work: the RL Animal's stale
-- visualAnimal is cleared at remove time (RL mark events would otherwise
-- touch destroyed nodes, review nit 1), identity is remapped in
-- pastureAnimalLookup (the sampler's id source AND the HUD raycast hook's
-- id->Animal resolver), and the full Phase-3 visual treatment (coat tile,
-- createVisual ear tags, atlas/LOD post-pass) is rebuilt +15 frames after
-- the re-add via pendingRerollVisuals, the engine ignores texture writes
-- before the I3D loads. Remove-then-add atomic per animal; add-first would
-- fail on full husbandries.
-- @return tag string for the FLOATER log line
function ToPastureAndBack_RL.rerollFloater(session, husId, animalId, delta, ax, az, label)
    local key = tostring(husId) .. ":" .. tostring(animalId)
    local rd = (session.rerollData ~= nil) and session.rerollData[key] or nil
    if rd == nil then
        return " NO-REROLL-DATA"
    end
    -- Never re-roll an id whose re-add happened under 30 frames ago (it may
    -- not be placed yet; the suspect guard upstream is the primary guard).
    session.rerollFrame = session.rerollFrame or {}
    local fc = ToPastureAndBack_RL.frameCount or 0
    if session.rerollFrame[key] ~= nil and (fc - session.rerollFrame[key]) < 30 then
        return " REROLL-SKIPPED-PENDING"
    end
    local okDel = ToPastureAndBack_RL.fcall(removeHusbandryAnimal, husId, animalId)
    if not okDel then
        return " REROLL-REMOVE-FAILED"
    end
    -- The old engine visual is gone; clear the RL Animal's stale visualAnimal
    -- NOW so RL code paths (mark events etc.) no-op until the +15f rebuild
    -- repopulates it (deleteVisual is entityExists-guarded in RL).
    if rd.animal ~= nil and rd.animal.deleteVisual ~= nil then
        ToPastureAndBack_RL.fcall(rd.animal.deleteVisual, rd.animal)
    end
    local okAdd, newId = ToPastureAndBack_RL.fcall(addHusbandryAnimal, husId, rd.visIdx)
    if not okAdd or newId == nil or newId <= 0 then
        Logging.warning("TPAB-RL: REROLL-LOST hus=%d oldId=%d visIdx=%s (re-add failed after remove; one visual lost, the RL animal still returns to the barn on recall)",
            husId, animalId, tostring(rd.visIdx))
        session.rerollData[key] = nil
        local lkLost = ToPastureAndBack_RL.pastureAnimalLookup[husId]
        if lkLost ~= nil then lkLost[animalId] = nil end
        return " REROLL-LOST"
    end
    local newKey = tostring(husId) .. ":" .. tostring(newId)
    if rd.animal ~= nil then
        local lk = ToPastureAndBack_RL.pastureAnimalLookup[husId]
        if lk ~= nil then
            lk[animalId] = nil
            lk[newId] = rd.animal
        end
    else
        -- Fallback-spawn session: session.animalIds IS the sampler's id
        -- source (single husbandry there, no cross-husbandry id collision);
        -- in-place value swap is ipairs-safe.
        for i2, v in ipairs(session.animalIds or {}) do
            if v == animalId then
                session.animalIds[i2] = newId
                break
            end
        end
    end
    -- Tolerate newKey == key: the engine usually reuses the freed slot.
    if newKey ~= key then
        session.rerollData[newKey] = rd
        session.rerollData[key] = nil
        session.snappedAnimals[key] = nil
    end
    session.rerollFrame[newKey] = fc
    session.snappedAnimals[newKey] = { delta = delta, at = tostring(label) .. "-reroll", x = ax, z = az }
    if rd.animal ~= nil then
        ToPastureAndBack_RL.pendingRerollVisuals = ToPastureAndBack_RL.pendingRerollVisuals or {}
        table.insert(ToPastureAndBack_RL.pendingRerollVisuals,
            { session = session, husId = husId, animalId = newId, rd = rd, framesLeft = 15 })
    end
    dbgLog("TPAB-RL-FLOAT: [%s] REROLLED hus=%d %d->%d preDelta=%+.2f visIdx=%s",
        tostring(label), husId, animalId, newId, delta, tostring(rd.visIdx))
    return " REROLLED"
end

--- Apply the Phase-3 visual treatment to a re-rolled animal (mirrors
-- continueVisuals). Returns false ONLY when the root node has not resolved
-- yet, the queue retries once (+10f) then logs REROLL-VISUAL-LOST, RL's
-- VisualAnimal:load() would otherwise eat missing ear tags silently.
function ToPastureAndBack_RL.applyRerollVisual(e)
    local husId, animalId, rd = e.husId, e.animalId, e.rd
    if e.session ~= nil and e.session.spawnState ~= "active" then
        return true  -- session recalled/cleaned, drop silently
    end
    local okE, exists = ToPastureAndBack_RL.fcallNode(entityExists, husId)
    if not okE or not exists then
        return true  -- husbandry gone, drop silently
    end
    local okR, rootNode = ToPastureAndBack_RL.fcall(getAnimalRootNode, husId, animalId)
    if not okR or rootNode == nil or rootNode == 0 then
        return false  -- not resolved yet, caller retries once
    end
    if rd.tileU ~= nil and rd.tileV ~= nil then
        ToPastureAndBack_RL.fcall(setAnimalTextureTile, husId, animalId, rd.tileU, rd.tileV)
    end
    local animal = rd.animal
    if animal ~= nil and animal.createVisual ~= nil and ToPastureAndBack_RL.canCreateRLVisual(animal) then
        local ok2, err = ToPastureAndBack_RL.fcall(animal.createVisual, animal, husId, animalId)
        if ok2 then
            if rd.earTagColours ~= nil and animal.setVisualEarTagColours ~= nil then
                ToPastureAndBack_RL.fcall(animal.setVisualEarTagColours, animal,
                    rd.earTagColours.earTagLeft, rd.earTagColours.earTagLeft_text,
                    rd.earTagColours.earTagRight, rd.earTagColours.earTagRight_text)
            end
        else
            Logging.warning("TPAB-RL: reroll createVisual failed for hus=%d animal=%d: %s",
                husId, animalId, tostring(err))
        end
    end
    -- Atlas + dirt post-pass to all mesh/LOD nodes (mirrors Phase 3, which is
    -- production-validated in this same-call sequence). Watch-item: if test
    -- logs ever show default-texture LODs on rerolled animals, split this
    -- read into a +2f second tick per the two-pass rule.
    local ok4, sx, sy, sz, sw = ToPastureAndBack_RL.fcall(getAnimalShaderParameter, husId, animalId, "atlasInvSizeAndOffsetUV")
    if ok4 and sx ~= nil then
        I3DUtil.setShaderParameterRec(rootNode, "atlasInvSizeAndOffsetUV", sx, sy, sz, sw)
    end
    I3DUtil.setShaderParameterRec(rootNode, "dirt", 0.1, nil, nil, nil)
    dbgLog("TPAB-RL: reroll visuals applied for hus=%d animal=%d", husId, animalId)
    return true
end

function ToPastureAndBack_RL.processRerollVisualQueue()
    local q = ToPastureAndBack_RL.pendingRerollVisuals
    if q == nil or #q == 0 then return end
    local stillPending = {}
    local queueNow = ToPastureAndBack_RL.pendingRerollVisuals
    ToPastureAndBack_RL.pendingRerollVisuals = stillPending  -- swap first: a throw drops one entry instead of re-firing it every frame
    for _, e in ipairs(q) do
        e.framesLeft = e.framesLeft - 1
        if e.framesLeft > 0 then
            table.insert(stillPending, e)
        else
            local done = ToPastureAndBack_RL.applyRerollVisual(e)
            if not done then
                if not e.retried then
                    e.retried = true
                    e.framesLeft = 10
                    table.insert(stillPending, e)
                else
                    Logging.warning("TPAB-RL: REROLL-VISUAL-LOST hus=%d animal=%d (root node never resolved, ear tags missing)",
                        e.husId, e.animalId)
                end
            end
        end
    end
    ToPastureAndBack_RL.pendingRerollVisuals = stillPending
end

-- ============================================================================
-- Spawn-Y ground correction + diagnostics (sky-cow, 2026-06-04)
-- ----------------------------------------------------------------------------
-- Mirrors TPAB's round-4 fix: cap-bound floaters are removed + re-added at
-- t=10/45/120 (re-rolls the engine's async placement, ~98% grounded per
-- roll; validated 18/18 in TPAB). RL-specific: identity remapped in
-- pastureAnimalLookup, stale visualAnimal cleared at remove time, and the
-- ear-tag/coat/atlas treatment rebuilt +15 frames after the re-add via
-- pendingRerollVisuals (engine ignores texture writes pre-I3D-load, same
-- reason Phase 3 defers visuals). Suspect guard skips staging reads
-- ((0,0,0) or |delta|>100m). BORROWED placeable nav meshes are sampled but
-- NEVER corrected. Per-animal "ok" lines DEBUG-gated. Snap retained only as
-- fallback when re-roll data is missing or the remove fails.
-- ============================================================================
function ToPastureAndBack_RL.scheduleSpawnYDiag(session)
    if session == nil then return end
    ToPastureAndBack_RL.pendingSpawnYDiag = ToPastureAndBack_RL.pendingSpawnYDiag or {}
    table.insert(ToPastureAndBack_RL.pendingSpawnYDiag, { session = session, framesLeft = 10, label = "t=10f", correct = true })
    table.insert(ToPastureAndBack_RL.pendingSpawnYDiag, { session = session, framesLeft = 45, label = "t=45f", correct = true })
    table.insert(ToPastureAndBack_RL.pendingSpawnYDiag, { session = session, framesLeft = 120, label = "t=120f", correct = true })
    -- t=600f corrects too since 2026-06-07: on a 41m-delta field (Etruria
    -- Farmland 43) one of 140 pigs was still cap-bound at t=600 and stayed
    -- floating because this pass was verify-only. Same validated re-roll
    -- mechanism, one more swing for stragglers on extreme terrain.
    table.insert(ToPastureAndBack_RL.pendingSpawnYDiag, { session = session, framesLeft = 600, label = "t=600f", correct = true })
end

function ToPastureAndBack_RL.runSpawnYDiag(session, terrainNode, label, correct)
    local navKind = session.isPastureDestination and "BORROWED(placeable)" or "BUILT(contour)"
    local doCorrect = (correct == true) and not session.isPastureDestination
    session.snappedAnimals = session.snappedAnimals or {}
    local ppName = (session.pasturePoint ~= nil and session.pasturePoint.name) or "?"
    dbgLog("TPAB-RL-FLOAT: ===== [%s] session=%s dest='%s' navMesh=%s animals=%d correct=%s =====",
        tostring(label), tostring(session.id), tostring(ppName), navKind, #(session.animalIds or {}), tostring(doCorrect))
    local sampled, floaters, held, reverted, newFloaters = 0, 0, 0, 0, 0
    local snapped, suspectSkipped = 0, 0
    local rerolled, rerollLost, rerollSkipped = 0, 0, 0
    local atName = tostring(session.animalType)
    local husIds = { session.husId }
    for _, hid in ipairs(session.extraHusIds or {}) do
        table.insert(husIds, hid)
    end
    for cIdx, husId in ipairs(husIds) do
        local skip = false
        if husId == nil or husId == 0 then skip = true end
        if not skip then
            local okE, exists = ToPastureAndBack_RL.fcallNode(entityExists, husId)
            if not okE or not exists then skip = true end
        end
        if skip then
            dbgLog("TPAB-RL-FLOAT: [%s] chunk=%d husId=%s husbandry gone, skipped",
                tostring(label), cIdx, tostring(husId))
        else
            local ids = {}
            local lookup = ToPastureAndBack_RL.pastureAnimalLookup[husId]
            if lookup ~= nil then
                for aid in pairs(lookup) do
                    table.insert(ids, aid)
                end
                table.sort(ids)
            elseif cIdx == 1 then
                -- Fallback-spawn sessions (no RL animals) never populate
                -- pastureAnimalLookup; their ids live on session.animalIds
                -- against session.husId (review nit N6).
                ids = session.animalIds or {}
                dbgLog("TPAB-RL-FLOAT: [%s] lookup empty for hus=%s, sampling %d ids from session.animalIds",
                    tostring(label), tostring(husId), #ids)
            end
                for aIdx, animalId in ipairs(ids) do
                    local okR, rootNode = ToPastureAndBack_RL.fcall(getAnimalRootNode, husId, animalId)
                    if okR and rootNode ~= nil and rootNode ~= 0 then
                        local okW, ax, ay, az = ToPastureAndBack_RL.fcallNode(getWorldTranslation, rootNode)
                        local rdx, rdy, rdz = 999, 999, 999
                        local okRot, wrx, wry, wrz = ToPastureAndBack_RL.fcallNode(getWorldRotation, rootNode)
                        if okRot and wrx ~= nil and wry ~= nil and wrz ~= nil then
                            rdx, rdy, rdz = math.deg(wrx), math.deg(wry), math.deg(wrz)
                        end
                        if okW and ax ~= nil and ay ~= nil and az ~= nil then
                            local okG, groundY = ToPastureAndBack_RL.fcall(getTerrainHeightAtWorldPos, terrainNode, ax, 0, az)
                            if okG and groundY ~= nil then
                                local delta = ay - groundY
                                sampled = sampled + 1
                                local key = tostring(husId) .. ":" .. tostring(animalId)
                                local prior = session.snappedAnimals[key]
                                if (ax == 0 and ay == 0 and az == 0) or math.abs(delta) > 100 then
                                    -- Staging/suspect read: the engine has not placed
                                    -- this animal yet (fresh add or just re-rolled).
                                    -- NEVER correct on a suspect position; the next
                                    -- pass sees it placed (round-4 review nit N1).
                                    suspectSkipped = suspectSkipped + 1
                                    dbgLog("TPAB-RL-FLOAT: [%s] %s hus=%d chunk=%d animal=%d SUSPECT pos=(%.1f,%.2f,%.1f) deltaY=%+.2f, skipped",
                                        tostring(label), tostring(atName), husId, cIdx, animalId, ax, ay, az, delta)
                                elseif math.abs(delta) > 0.5 then
                                    floaters = floaters + 1
                                    local histTag
                                    if prior ~= nil then
                                        histTag = "was-corrected(" .. tostring(prior.at) .. ")"
                                        reverted = reverted + 1
                                    else
                                        histTag = "new-floater"
                                        newFloaters = newFloaters + 1
                                    end
                                    local actTag = ""
                                    if doCorrect then
                                        actTag = ToPastureAndBack_RL.rerollFloater(session, husId, animalId, delta, ax, az, label)
                                        if actTag == " REROLLED" then
                                            rerolled = rerolled + 1
                                        elseif actTag == " REROLL-LOST" then
                                            rerollLost = rerollLost + 1
                                        elseif actTag == " REROLL-SKIPPED-PENDING" then
                                            rerollSkipped = rerollSkipped + 1
                                        elseif actTag == " NO-REROLL-DATA" or actTag == " REROLL-REMOVE-FAILED" then
                                            -- Fallback: snap (holds only for idle animals,
                                            -- still better than nothing).
                                            local okS = ToPastureAndBack_RL.fcallNode(setWorldTranslation, rootNode, ax, groundY + 0.05, az)
                                            if okS then
                                                actTag = actTag .. " SNAPPED"
                                                snapped = snapped + 1
                                                session.snappedAnimals[key] = { delta = delta, at = tostring(label) .. "-snap", x = ax, z = az }
                                            end
                                        end
                                    end
                                    local moveTag = ""
                                    if prior ~= nil and prior.x ~= nil then
                                        moveTag = string.format(" moveXZ=%.1fm", math.sqrt((ax - prior.x)^2 + (az - prior.z)^2))
                                    end
                                    dbgLog("TPAB-RL-FLOAT: [%s] %s hus=%d chunk=%d animal=%d pos=(%.1f,%.2f,%.1f) groundY=%.2f deltaY=%+.2f worldRotDeg=(%.0f,%.0f,%.0f) FLOATER(%s)%s%s",
                                        tostring(label), tostring(atName), husId, cIdx, animalId, ax, ay, az, groundY, delta, rdx, rdy, rdz, histTag, actTag, moveTag)
                                else
                                    if prior ~= nil then
                                        held = held + 1
                                        local moveTag = ""
                                        if prior.x ~= nil then
                                            moveTag = string.format(" moveXZ=%.1fm", math.sqrt((ax - prior.x)^2 + (az - prior.z)^2))
                                        end
                                        dbgLog("TPAB-RL-FLOAT: [%s] %s hus=%d chunk=%d animal=%d deltaY=%+.2f held (corrected at %s, was %+.2f)%s",
                                            tostring(label), tostring(atName), husId, cIdx, animalId, delta, tostring(prior.at), prior.delta or -99, moveTag)
                                    else
                                        dbgLog("TPAB-RL-FLOAT: [%s] %s hus=%d chunk=%d animal=%d pos=(%.1f,%.2f,%.1f) groundY=%.2f deltaY=%+.2f worldRotDeg=(%.0f,%.0f,%.0f) ok",
                                            tostring(label), tostring(atName), husId, cIdx, animalId, ax, ay, az, groundY, delta, rdx, rdy, rdz)
                                    end
                                end
                            else
                                dbgLog("TPAB-RL-FLOAT: [%s] %s hus=%d chunk=%d animal=%d terrainHeight FAILED (ok=%s)",
                                    tostring(label), tostring(atName), husId, cIdx, animalId, tostring(okG))
                            end
                        else
                            dbgLog("TPAB-RL-FLOAT: [%s] %s hus=%d chunk=%d animal=%d getWorldTranslation FAILED (ok=%s)",
                                tostring(label), tostring(atName), husId, cIdx, animalId, tostring(okW))
                        end
                    else
                        dbgLog("TPAB-RL-FLOAT: [%s] %s hus=%d chunk=%d animal=%d getAnimalRootNode FAILED (ok=%s, node=%s)",
                            tostring(label), tostring(atName), husId, cIdx, animalId, tostring(okR), tostring(rootNode))
                    end
                end
        end
    end
    dbgLog("TPAB-RL-FLOAT: ===== [%s] session=%s SUMMARY sampled=%d floaters=%d rerolled=%d rerollLost=%d "
        .. "rerollSkipped=%d suspect=%d snapped=%d held=%d reverted=%d new=%d navMesh=%s contourDeltaY=%s =====",
        tostring(label), tostring(session.id), sampled, floaters, rerolled, rerollLost, rerollSkipped, suspectSkipped, snapped, held, reverted, newFloaters, navKind, tostring(session.contourDeltaY))
end

function ToPastureAndBack_RL.processSpawnYDiagQueue()
    local q = ToPastureAndBack_RL.pendingSpawnYDiag
    if q == nil or #q == 0 then return end
    local terrainNode = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    local stillPending = {}
    local queueNow = ToPastureAndBack_RL.pendingSpawnYDiag
    ToPastureAndBack_RL.pendingSpawnYDiag = stillPending  -- swap first: a throw drops one entry instead of re-firing it every frame
    for _, entry in ipairs(q) do
        entry.framesLeft = entry.framesLeft - 1
        if entry.framesLeft > 0 then
            table.insert(stillPending, entry)
        else
            local session = entry.session
            if session ~= nil and session.spawnState == "active" and terrainNode ~= nil then
                ToPastureAndBack_RL.runSpawnYDiag(session, terrainNode, entry.label, entry.correct)
            end
        end
    end
    ToPastureAndBack_RL.pendingSpawnYDiag = stillPending
end

function ToPastureAndBack_RL:update(dt)
    if ToPastureAndBack_RL._poultrySwapPrev ~= nil then ToPastureAndBack_RL.restoreStalePoultrySwap("update") end
    ToPastureAndBack_RL.processSpawnYDiagQueue()
    ToPastureAndBack_RL.processRerollVisualQueue()
    if not ToPastureAndBack_RL.initComplete and ToPastureAndBack_RL.clientSyncDeadline ~= nil then
        if ToPastureAndBack_RL.frameCount >= ToPastureAndBack_RL.clientSyncDeadline then
            ToPastureAndBack_RL.initComplete = true
            dbgLog("TPAB-RL: [Client] Init complete after sync grace period")
            -- 2026-05-26: single mandatory summary message after the sync
            -- window. Replaces the per-session "now grazing" spam the
            -- client previously received when joining a host with active
            -- sessions. Fires ONLY when there are active sessions; if the
            -- host has 0 herds out we stay silent (nothing useful to say).
            -- Count comes from the local grazingSessions table which by
            -- this point holds all sessions delivered via SyncRequestEvent.
            if ToPastureAndBack_RL.clientSyncInProgress then
                ToPastureAndBack_RL.clientSyncInProgress = false
                local activeCount = 0
                for _, gs in ipairs(ToPastureAndBack_RL.grazingSessions or {}) do
                    if ToPastureAndBack_RL.isLocalFarm(ToPastureAndBack_RL.farmOfSession(gs)) then activeCount = activeCount + 1 end
                end
                if activeCount > 0 then
                    local syncedMsg = string.format(
                        ToPastureAndBack_RL.textN("tpab_sync_complete", activeCount,
                            "%d herds on pasture. Press %s for details.",
                            "%d herd on pasture. Press %s for details."),
                        activeCount, ToPastureAndBack_RL.getBindingText("TPABRL_STATUS"))
                    ToPastureAndBack_RL.showModInitiatedMessage(syncedMsg)
                end
            end
        end
    end
    -- Always tick message timers, even before full init
    ToPastureAndBack_RL.updateMessages(dt)

    -- Show a one-time warning if RL is not installed
    if ToPastureAndBack_RL.rlMissing and not ToPastureAndBack_RL.rlWarningShown then
        if g_currentMission ~= nil and g_currentMission.hud ~= nil then
            local rlText = ToPastureAndBack_RL.locText("tpab_rl_missing",
                "To Pasture and Back (RL Edition) needs Realistic Livestock RM. Install and activate FS25_RealisticLivestockRM.")
            g_currentMission:showBlinkingWarning(rlText, ToPastureAndBack_RL.readDurationMs(rlText, 2000))
            ToPastureAndBack_RL.rlWarningShown = true
        end
        return
    end

    if not ToPastureAndBack_RL.initialized then return end

    -- Track frames for deferred init
    ToPastureAndBack_RL.frameCount = ToPastureAndBack_RL.frameCount + 1

    -- Deferred density map init
    if not ToPastureAndBack_RL.densityReady then
        if ToPastureAndBack_RL.frameCount >= ToPastureAndBack_RL.DENSITY_CHECK_DELAY then
            if ToPastureAndBack_RL.initDensityMap() then
                ToPastureAndBack_RL.densityReady = true
                dbgLog("TPAB-RL: Density map ready after %d frames", ToPastureAndBack_RL.frameCount)
            end
        end
    end

    -- Deferred barn cache init (placeables load by ~frame 300 on host, later on clients)
    if not ToPastureAndBack_RL.barnCacheReady then
        if ToPastureAndBack_RL.frameCount >= ToPastureAndBack_RL.BARN_SCAN_DELAY then
            ToPastureAndBack_RL.scanAllBarnTypes()

            -- On clients, placeables may not be replicated yet at frame 350.
            -- Retry periodically until placeables appear or we hit the retry limit.
            -- IMPORTANT: keep retrying even after finding SOME barns, because on
            -- maps with many placeables (e.g. Hof Bergmann) they load incrementally
            -- and an early scan may only catch the first few.
            local barnCount = 0
            for _, barns in pairs(ToPastureAndBack_RL.barnCache) do
                barnCount = barnCount + #barns
            end

            local isClient = (g_server == nil)
            local underRetryLimit = ToPastureAndBack_RL.barnScanRetries < ToPastureAndBack_RL.BARN_SCAN_MAX_RETRIES
            -- Client keeps retrying if: no barns yet, OR we haven't hit the minimum
            -- retry count, OR new barns appeared since the last scan (still loading).
            local shouldRetry = isClient and underRetryLimit and (
                barnCount == 0
                or ToPastureAndBack_RL.barnScanRetries < ToPastureAndBack_RL.BARN_SCAN_MIN_CLIENT_RETRIES
                or barnCount > ToPastureAndBack_RL.prevBarnCount
            )
            ToPastureAndBack_RL.prevBarnCount = barnCount

            if shouldRetry then
                ToPastureAndBack_RL.barnScanRetries = ToPastureAndBack_RL.barnScanRetries + 1
                -- Push the delay forward so we retry after BARN_SCAN_RETRY_INTERVAL frames
                ToPastureAndBack_RL.BARN_SCAN_DELAY = ToPastureAndBack_RL.frameCount + ToPastureAndBack_RL.BARN_SCAN_RETRY_INTERVAL
                dbgLog("TPAB-RL: [Client] Barn scan retry %d/%d, found %d barn(s) so far, next at frame %d",
                    ToPastureAndBack_RL.barnScanRetries, ToPastureAndBack_RL.BARN_SCAN_MAX_RETRIES,
                    barnCount, ToPastureAndBack_RL.BARN_SCAN_DELAY)
            else
                ToPastureAndBack_RL.barnCacheReady = true
                dbgLog("TPAB-RL: Barn cache initialized after %d frames", ToPastureAndBack_RL.frameCount)
                if g_server ~= nil or g_client == nil then
                    ToPastureAndBack_RL.initComplete = true
                end
                -- Probe farmland manager API (one-time diagnostic)
                ToPastureAndBack_RL.probeFarmlandManager()
                -- Reconstruct saved grazing sessions now that barns are scanned
                ToPastureAndBack_RL.reconstructSavedSessions()
                -- Clean up stale pasture points with no active session
                ToPastureAndBack_RL.cleanupStalePasturePoints()
                -- Process any events that arrived before barn cache was ready (client-side).
                -- This handles the case where the server broadcasts reconstructed sessions
                -- to a client that was still loading when the events arrived.
                if #ToPastureAndBack_RL.pendingEventQueue > 0 then
                    dbgLog("TPAB-RL: Processing %d queued event(s) received before barn scan",
                        #ToPastureAndBack_RL.pendingEventQueue)
                    for _, eventData in ipairs(ToPastureAndBack_RL.pendingEventQueue) do
                        ToPastureAndBack_RL.executeGrazingFromEvent(eventData)
                    end
                    ToPastureAndBack_RL.pendingEventQueue = {}
                end
                -- Client-side: request current grazing state from the server.
                -- After save/reload, the server reconstructs sessions before the client
                -- connects, so the client misses the initial broadcast. This sync request
                -- lets the client pull the current state once its barn cache is ready.
                if g_server == nil and g_client ~= nil then
                    dbgLog("TPAB-RL: [Client] Barn cache ready, requesting grazing state from server")
                    g_client:getServerConnection():sendEvent(SyncRequestEvent.new())
                    ToPastureAndBack_RL.clientSyncDeadline = ToPastureAndBack_RL.frameCount + 120
                    -- 2026-05-26: gate per-session showMessage calls in
                    -- executeGrazingFromEvent so the client doesn't spam
                    -- "X are now grazing on Farmland Y" for every session
                    -- the host syncs back. Cleared at init-complete below,
                    -- where a single summary message fires instead.
                    ToPastureAndBack_RL.clientSyncInProgress = true
                end
            end
        end
    end

    -- Process scheduled cache rescans (triggered by onPlaceableFinalized).
    if ToPastureAndBack_RL.pendingRescans ~= nil then
        local toClear = nil
        for atype, remaining in pairs(ToPastureAndBack_RL.pendingRescans) do
            remaining = remaining - 1
            if remaining <= 0 then
                dbgLog("TPAB-RL: Rescanning %s cache (triggered by new husbandry)", atype)
                ToPastureAndBack_RL.scanBarnsForType(atype)
                toClear = toClear or {}
                table.insert(toClear, atype)
            else
                ToPastureAndBack_RL.pendingRescans[atype] = remaining
            end
        end
        if toClear ~= nil then
            for _, at in ipairs(toClear) do
                ToPastureAndBack_RL.pendingRescans[at] = nil
            end
        end
    end

    -- Drive grazing session state machine
    if #ToPastureAndBack_RL.grazingSessions > 0 then
        ToPastureAndBack_RL.updateGrazingSessions(dt)
    end
end

function ToPastureAndBack_RL:deleteMap()
    if ToPastureAndBack_RL._poultrySwapPrev ~= nil then ToPastureAndBack_RL.restoreStalePoultrySwap("unload") end
    -- Drop our global action events and their bookkeeping, cert 2026-07-07 (K2).
    -- Runs BEFORE the rlMissing early-out: the input hook registers the
    -- events at player load even when the RL dependency is missing and our
    -- init never ran.
    if g_inputBinding ~= nil then
        ToPastureAndBack_RL.fcall(g_inputBinding.removeActionEventsByTarget, g_inputBinding, ToPastureAndBack_RL)
    end
    ToPastureAndBack_RL.globalActionEventIds = {}

    ToPastureAndBack_RL.teardownSettingsMenu()
    if KijbevHelp ~= nil and KijbevHelp.onDeleteMap ~= nil then
        KijbevHelp.onDeleteMap("TPABRL")
    end

    -- Nothing to clean up if RL was not loaded
    if ToPastureAndBack_RL.rlMissing then return end

    dbgLog("TPAB-RL: deleteMap called, cleaning up")

    -- During map unload, skip barn visual restore (engine is tearing down husbandries,
    -- addHusbandryAnimal will fail). Barn cluster data is untouched, so no restore needed.
    ToPastureAndBack_RL.mapUnloading = true

    -- Clean up all active grazing sessions
    for _, session in ipairs(ToPastureAndBack_RL.grazingSessions) do
        ToPastureAndBack_RL.cleanupSession(session)
    end
    ToPastureAndBack_RL.grazingSessions = {}

    ToPastureAndBack_RL.pasturePoints = {}
    ToPastureAndBack_RL.barnCache = {}
    ToPastureAndBack_RL.barnCacheReady = false
    ToPastureAndBack_RL.initComplete = false
    ToPastureAndBack_RL.clientSyncDeadline = nil
    ToPastureAndBack_RL.barnScanRetries = 0
    ToPastureAndBack_RL.prevBarnCount = 0
    ToPastureAndBack_RL.BARN_SCAN_DELAY = 350
    ToPastureAndBack_RL.suppressedBarns = {}
    ToPastureAndBack_RL.pendingReconstructions = nil
    ToPastureAndBack_RL.pendingEventQueue = {}
    ToPastureAndBack_RL.recentDropFarmlands = {}  -- cert 2026-07-07 (M1)
    ToPastureAndBack_RL.initialized = false
    ToPastureAndBack_RL.densityReady = false
    ToPastureAndBack_RL.frameCount = 0
    ToPastureAndBack_RL.densityMapId = nil
    ToPastureAndBack_RL.nextPastureId = 1
    ToPastureAndBack_RL.mapUnloading = false
    ToPastureAndBack_RL.forageReady = false
    ToPastureAndBack_RL.forageLayers = {}
    ToPastureAndBack_RL.cropLayersReady = false
    ToPastureAndBack_RL.cropLayers = {}
    ToPastureAndBack_RL.forageNameSet = {}
    ToPastureAndBack_RL.pastureAnimalLookup = {}

    -- Release fence template
    if ToPastureAndBack_RL.fenceTemplateRoot ~= nil then
        ToPastureAndBack_RL.fcallNode(delete, ToPastureAndBack_RL.fenceTemplateRoot)
        ToPastureAndBack_RL.fenceTemplateRoot = nil
    end
    ToPastureAndBack_RL.fenceTemplateLoaded = false
end

function ToPastureAndBack_RL.saveSavegame()
    ToPastureAndBack_RL.saveToXML()
    ToPastureAndBack_RL.saveSettings()
end


-- ============================================================================
-- Register as mod event listener
-- =====================

-- Durable barn position for a barnCache entry (proximity/distance only). Mirror of
-- TPAB's getBarnCachePos. Tier 1: live nav node, ONLY if it still exists (so
-- getWorldTranslation is never called on a stale id, which logs an engine "Unknown
-- entity id" Script error even under pcall). Tier 2: fence centroid (plain numbers,
-- never stale). Tier 3: placeable root node (durable). Returns x, z or nil. Pure
-- read, no side effects. Do NOT use where navNode is a NAV-MESH HANDLE
-- (createAnimalHusbandry / borrowed pasture nav mesh); those keep the raw navNode.
function ToPastureAndBack_RL.getBarnCachePos(entry)
    if entry == nil then return nil end
    local node = entry.navNode
    if node ~= nil and node ~= 0 then
        local okE, exists = ToPastureAndBack_RL.fcallNode(entityExists, node)
        if okE and exists then
            local ok, x, _, z = ToPastureAndBack_RL.fcallNode(getWorldTranslation, node)
            if ok and x ~= nil then return x, z end
        end
    end
    if entry.fenceCenterX ~= nil and entry.fenceCenterZ ~= nil then
        return entry.fenceCenterX, entry.fenceCenterZ
    end
    local pl = entry.placeable
    if pl ~= nil and pl.rootNode ~= nil and pl.rootNode ~= 0 then
        local okE, exists = ToPastureAndBack_RL.fcallNode(entityExists, pl.rootNode)
        if okE and exists then
            local ok, x, _, z = ToPastureAndBack_RL.fcallNode(getWorldTranslation, pl.rootNode)
            if ok and x ~= nil then return x, z end
        end
    end
    return nil
end

addModEventListener(ToPastureAndBack_RL)

-- Shared Kijbev help panel (scripts/lib/KijbevHelp.lua, listed before this script in modDesc).
-- Staged at script load; loadMap calls onLoadMap as the belt.
if KijbevHelp ~= nil and KijbevHelp.stage ~= nil then
    KijbevHelp.stage("TPABRL", dbgLog, ToPastureAndBack_RL.modDirectory, "FS25_ToPastureAndBack_RL")
end

dbgLog("ToPastureAndBack_RL: mod loaded, DEBUG=%s", tostring(ToPastureAndBack_RL.DEBUG))

-- ============================================================================
-- Hook the engine savegame write so our save runs alongside it.
-- addModEventListener auto-invokes loadMap/update/draw/keyEvent/mouseEvent/
-- deleteMap, but NOT saveSavegame in FS25. Original Phase 1 spec used
-- Mission00.saveSavegame as the hook target, which is the orchestrator the
-- engine calls when the player triggers a save (Esc -> Save Game) and during
-- autosave. We hook it via Utils.appendedFunction so the engine's save runs
-- first, then ours appends our XML next to the savegame.
-- ============================================================================

if Mission00 ~= nil and Mission00.saveSavegame ~= nil then
    Mission00.saveSavegame = Utils.appendedFunction(
        Mission00.saveSavegame,
        function(self)
            ToPastureAndBack_RL.saveSavegame()
        end)
    dbgLog("TPAB-RL: Hooked Mission00.saveSavegame for savegame persistence")
else
    Logging.warning("TPAB-RL: Mission00 not available, savegame persistence disabled")
end


-- ============================================================================
-- Rebindable global input hook, cert 2026-07-07 (K1). The engine calls
-- PlayerInputComponent.registerGlobalPlayerActionEvents inside an already-open
-- begin/endActionEventsModification block, at local player load (player
-- context, contextName nil) and on every vehicle action-event rebuild (vehicle
-- context), so an append there registers our five global actions in both
-- contexts without opening our own modification block. Its definition is
-- absent from the SDK source dump, hence the existence guard and the fallback
-- branch below (senior review 2026-07-07).
-- ============================================================================

if PlayerInputComponent ~= nil and type(PlayerInputComponent.registerGlobalPlayerActionEvents) == "function" then
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents,
        function(inputComponent, contextName)
            ToPastureAndBack_RL.registerGlobalActionEvents(contextName)
        end)
    dbgLog("TPAB-RL: Hooked PlayerInputComponent.registerGlobalPlayerActionEvents for global keybinds")
else
    -- Fallback per senior review: the primary hook point is missing (an engine
    -- update changed the player input plumbing). Append to the context owners'
    -- own registration paths instead, opening our own modification block since
    -- nobody opened one for us. One-time ungated warning so a field log tells
    -- us the primary hook was gone.
    Logging.warning("TPAB-RL: PlayerInputComponent.registerGlobalPlayerActionEvents not found, using fallback action event registration")

    local function tpabRegisterWithOwnBlock(contextName)
        if g_inputBinding == nil then return end
        ToPastureAndBack_RL.fcall(g_inputBinding.beginActionEventsModification, g_inputBinding, contextName)
        ToPastureAndBack_RL.fcall(ToPastureAndBack_RL.registerGlobalActionEvents, contextName)
        ToPastureAndBack_RL.fcall(g_inputBinding.endActionEventsModification, g_inputBinding)
    end

    if PlayerInputComponent ~= nil and type(PlayerInputComponent.registerActionEvents) == "function" then
        PlayerInputComponent.registerActionEvents = Utils.appendedFunction(
            PlayerInputComponent.registerActionEvents,
            function(...)
                tpabRegisterWithOwnBlock(PlayerInputComponent.INPUT_CONTEXT_NAME)
            end)
    end
    if Enterable ~= nil and type(Enterable.onRegisterActionEvents) == "function" then
        Enterable.onRegisterActionEvents = Utils.appendedFunction(
            Enterable.onRegisterActionEvents,
            function(...)
                tpabRegisterWithOwnBlock(Vehicle ~= nil and Vehicle.INPUT_CONTEXT_NAME or nil)
            end)
    end
end


-- ============================================================================
-- Species-specific minimum grazing age (2026-06-03)
-- ----------------------------------------------------------------------------
-- Pigs go out from 3 months: real outdoor units run weaners/growers from
-- 8-12 weeks, and the basegame dealer only sells pigs at 0 and 3 months, so a
-- flat 6-month gate made pig pasture runs impossible. All other species keep
-- the original 6-month minimum.
-- ============================================================================
function ToPastureAndBack_RL.getMinGrazingAge(animalType)
    if animalType ~= nil and string.upper(tostring(animalType)) == "PIG" then
        return 3
    end
    return 6
end

--- Placeable-flavored wrapper for call sites that have a husbandry placeable
-- but no animalType string in scope.
function ToPastureAndBack_RL.getMinGrazingAgeForPlaceable(placeable)
    local at = nil
    if placeable ~= nil and placeable.spec_husbandryAnimals ~= nil
            and placeable.spec_husbandryAnimals.animalType ~= nil then
        at = placeable.spec_husbandryAnimals.animalType.name
    end
    return ToPastureAndBack_RL.getMinGrazingAge(at)
end

-- ============================================================================
-- Growing-crop guard for grazers (2026-06-03)
-- ----------------------------------------------------------------------------
-- True when the sampled area is a STANDING non-forage crop: growing,
-- harvest-ready, or withered (state below the crop's cut state). Harvested
-- stubble (state >= cutState) does not count. Majority threshold (3 of 5
-- samples) guards against edge bleed from a neighboring field, mirroring the
-- forager check's CROP_MAJORITY_THRESHOLD.
-- ============================================================================
function ToPastureAndBack_RL.isGrowingCropAt(samplePoints)
    if not ToPastureAndBack_RL.cropLayersReady then return false end
    local cropCount, growingCount = 0, 0
    for _, pt in ipairs(samplePoints) do
        local state, cutState = ToPastureAndBack_RL.getCropState(pt[1], pt[2])
        if state ~= nil and cutState ~= nil then
            cropCount = cropCount + 1
            if state < cutState then
                growingCount = growingCount + 1
            end
        end
    end
    if cropCount > 0 then
        dbgLog("TPAB-RL: isGrowingCropAt: %d/%d samples on a crop, %d growing", cropCount, #samplePoints, growingCount)
    end
    local CROP_MAJORITY_THRESHOLD = 3
    if cropCount >= CROP_MAJORITY_THRESHOLD and growingCount >= math.ceil(cropCount / 2) then
        return true
    end
    return false
end
