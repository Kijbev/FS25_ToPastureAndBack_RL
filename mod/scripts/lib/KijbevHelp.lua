-- =========================================================================
-- KijbevHelp, the cross-mod keybind help panel (docs: KijbevHelp_Blueprint.md)
--
-- ONE panel, listing the keybinds of EVERY Kijbev mod the player has installed,
-- grouped per mod. This exact file is EMBEDDED in every Kijbev mod, so owning
-- any one of them grants the feature and owning several must still produce ONE
-- panel.
--
-- BUMP OUR_VERSION ON EVERY EDIT TO THIS FILE.
-- =========================================================================

local OUR_VERSION = 27   -- v27 (2026-10-30): fixed rows in bright white like the glyph rows 
-- v26 (2026-10-19): American English in every text and comment

-- SHARED THROUGH THE REAL GLOBAL TABLE (2026-10-02). FS25 runs every mod's scripts in its own
-- environment: _G is that mod's env, whose metatable __index is the real global table. A plain
-- `KijbevHelp = ...` therefore landed in ONE mod's env, every mod ran its own copy and the version
-- election never saw the others (our log 2026-10-01: owner=TT AND owner=UBW for both modules,
-- and an ungated "no KJHELP_* input action" warning from the second copy on every map load).
-- The module table and its once-per-process flags now live in the real global table. Mods read
-- `KijbevHelp` through their env's __index, so they always reach the current table; nothing here
-- assigns the name into a mod env. An unexpected env shape falls back to _G (the old behavior).
local KJ_REALG = _G
do
    local mt = getmetatable(_G)
    if type(mt) == "table" and type(mt.__index) == "table" then KJ_REALG = mt.__index end
end

-- STAND DOWN HERE if an equal or newer copy already installed. This early return
-- is load bearing: every `function H.x` below is an UNCONDITIONAL assignment, so
-- without it the LAST LOADED copy wins the methods regardless of version, and a
-- v6 copy loading after a v8 copy would silently downgrade every function while
-- VERSION still reported 8 (senior review 2026-07-28, defect B1).
local prev = KJ_REALG.KijbevHelp
if prev ~= nil and (prev.VERSION or 0) >= OUR_VERSION then
    return
end
local H = { VERSION = OUR_VERSION }
KJ_REALG.KijbevHelp = H

-- Carry forward what an OLDER copy already accepted. Each mod calls stage() and
-- declare() straight after its own copy of this file and BEFORE the next mod's
-- copy loads, so replacing the table wholesale would drop the candidacy and the
-- declarations of every mod that already spoke.
if prev ~= nil then
    H._candidates = prev._candidates
    H._declared   = prev._declared
    H._hidden     = prev._hidden
    H.owner       = prev.owner
end

-- Captured at SCRIPT LOAD, the only moment g_currentModDirectory holds THIS
-- copy's path. With the early return above, the winner's directory is the one
-- that survives, so the backdrop texture always resolves.
local MOD_DIR = g_currentModDirectory or ""

H._candidates = H._candidates or {}
H._declared   = H._declared or {}
-- v20: prefixes a mod has asked to hide FOR THE CURRENT MISSION (a mod that switched itself
-- off, e.g. To Pasture And Back with Realistic Livestock loaded). Keyed prefix -> the mission
-- table at the time of the call, so a hide never survives into the next savegame even when no
-- deleteMap reaches this module.
H._hidden     = H._hidden or {}

H.PREFIXES = H.PREFIXES or {
    { prefix = "TT_",      title = "Torque & Terrain",         env = "FS25_TorqueAndTerrain" },
    { prefix = "TPABRL_",  title = "To Pasture And Back RL",   env = "FS25_ToPastureAndBack_RL" },
    { prefix = "TPAB_",    title = "To Pasture And Back",      env = "FS25_ToPastureAndBack" },
    { prefix = "LPR_",     title = "License Plate Randomizer", env = "FS25_LicensePlateRandomizer" },
    { prefix = "LV_",      title = "Livestock Visibility",     env = "FS25_LivestockVisibility" },
    { prefix = "UBW_",     title = "Unload Bale Wrap",         env = "FS25_UnloadBaleWrap" },
    { prefix = "MCA_",     title = "Mouse Click Actions",      env = "FS25_MouseClickActions" },
}

-- Short fallback lines, used until a mod ships its own kjhelp_about. Keep them
-- SHORT: this is a reminder, not a product description.
H.ABOUT = H.ABOUT or {
    ["TT_"]     = "Authentic weight, power and grip from each machine's own data, plus drivetrain controls.",
    ["TPAB_"]   = "Takes a herd from a barn out to a field or pasture and brings it home again.",
    ["TPABRL_"] = "The Realistic Livestock RM edition of To Pasture And Back, with each animal as an individual.",
    ["LPR_"]    = "Random plates in the format of the map's country, with a duplicate plate finder.",
    ["LV_"]     = "Raises the limit on how many animals a barn displays.",
    ["UBW_"]    = "Unloads wrap film from balers and wrappers so you can load a new color.",
    ["MCA_"]    = "Hold the key to free the cursor and click vehicle controls directly.",
}

-- CONDITIONAL notes: predicates, not text. A note renders only when it is TRUE,
-- so the panel never carries a caveat about a situation the player is not in.
H.NOTES = H.NOTES or {
    { prefix = "LV_",
      when = function()
          return g_modIsLoaded ~= nil
              and (g_modIsLoaded["FS25_ToPastureAndBack"] == true
                or g_modIsLoaded["FS25_ToPastureAndBack_RL"] == true)
      end,
      text = "Currently inactive: To Pasture And Back is active and owns the barn visuals." },
}

-- Stand-ins for Kijbev mods whose keys are raw keyEvent and which do not carry
-- this module yet. MCA holds R through keyEvent ON PURPOSE (registering an
-- action on R routed R away from ACTIVATE_OBJECT and broke barn menus, field
-- 2026-06-11), and LPR reads RCtrl+Period the same way. Those bindings cannot be
-- rebound and appear in no Controls menu, so a fixed string is the truthful
-- representation, and this panel is their only documentation in the game.
-- Always overridden by a live H.declare from the mod itself.
H.FALLBACK = H.FALLBACK or {
    ["FS25_MouseClickActions"] = {
        prefix = "MCA_", title = "Mouse Click Actions",
        rows = { { keys = "Hold R", lead = "Hold", caps = { "R" }, text = "to free the cursor for vehicle clickpoints" } },
    },
    ["FS25_LicensePlateRandomizer"] = {
        prefix = "LPR_", title = "License Plate Randomizer",
        rows = { { keys = "RCTRL + .", caps = { "RIGHT CTRL", "." }, text = "Duplicate plate finder" } },
    },
}

-- v24 (2026-10-19): the fallback lines above (about lines, notes, fixed rows) were English only, so a
-- German or French player read English in the panel (GIANTS tester note on UBW v1.0.3.0). They are
-- the panel's own texts, not any mod's, so they are translated HERE, keyed by the English text and
-- the game language (g_languageShort, as TPAB reads it). A missing entry stays English.
H.L10N = {
    de = {
        ["Authentic weight, power and grip from each machine's own data, plus drivetrain controls."] =
            "Gewicht, Leistung und Traktion, authentisch aus den Daten jeder Maschine ermittelt, dazu Antriebssteuerung.",
        ["Takes a herd from a barn out to a field or pasture and brings it home again."] =
            "Bringt eine Herde vom Stall auf ein Feld oder eine Weide und wieder nach Hause.",
        ["The Realistic Livestock RM edition of To Pasture And Back, with each animal as an individual."] =
            "Die Realistic-Livestock-RM-Edition von To Pasture And Back, mit jedem Tier als Einzeltier.",
        ["Random plates in the format of the map's country, with a duplicate plate finder."] =
            "Zufällige Kennzeichen im Format des Landes der Karte, mit einem Duplikat-Kennzeichen-Finder.",
        ["Raises the limit on how many animals a barn displays."] =
            "Hebt die Grenze an, wie viele Tiere ein Stall anzeigt.",
        ["Unloads wrap film from balers and wrappers so you can load a new color."] =
            "Entlädt die Wickelfolie von Pressen und Wicklern, damit du eine neue Farbe laden kannst.",
        ["Hold the key to free the cursor and click vehicle controls directly."] =
            "Halte die Taste, um den Mauszeiger freizugeben und Fahrzeugbedienelemente direkt anzuklicken.",
        ["Currently inactive: To Pasture And Back is active and owns the barn visuals."] =
            "Derzeit inaktiv: To Pasture And Back ist aktiv und übernimmt die Darstellung der Stalltiere.",
        ["Hold R"] = "R halten",
        ["Hold"] = "Halte",
        ["to free the cursor for vehicle clickpoints"] = "gedrückt, um den Mauszeiger für Fahrzeug-Klickpunkte freizugeben",
        ["RCTRL + ."] = "STRG RECHTS + .",
        ["RIGHT CTRL"] = "STRG RECHTS",
        ["Duplicate plate finder"] = "Duplikat-Kennzeichen-Finder",
    },
    fr = {
        ["Authentic weight, power and grip from each machine's own data, plus drivetrain controls."] =
            "Poids, puissance et adhérence authentiques d'après les données de chaque machine, avec commandes de transmission.",
        ["Takes a herd from a barn out to a field or pasture and brings it home again."] =
            "Emmène un troupeau de l'étable vers un champ ou un pâturage, puis le ramène.",
        ["The Realistic Livestock RM edition of To Pasture And Back, with each animal as an individual."] =
            "L'édition Realistic Livestock RM de To Pasture And Back, où chaque animal est un individu.",
        ["Random plates in the format of the map's country, with a duplicate plate finder."] =
            "Plaques aléatoires au format du pays de la carte, avec un détecteur de plaques en double.",
        ["Raises the limit on how many animals a barn displays."] =
            "Relève la limite du nombre d'animaux qu'une étable affiche.",
        ["Unloads wrap film from balers and wrappers so you can load a new color."] =
            "Décharge le film d'enrubannage des presses et des enrubanneuses pour charger une nouvelle couleur.",
        ["Hold the key to free the cursor and click vehicle controls directly."] =
            "Maintenez la touche pour libérer le curseur et cliquer directement sur les commandes du véhicule.",
        ["Currently inactive: To Pasture And Back is active and owns the barn visuals."] =
            "Inactif pour le moment : To Pasture And Back est actif et gère l'affichage des animaux des étables.",
        ["Hold R"] = "Maintenir R",
        ["Hold"] = "Maintenez",
        ["to free the cursor for vehicle clickpoints"] = "pour libérer le curseur sur les points de clic du véhicule",
        ["RCTRL + ."] = "CTRL DROIT + .",
        ["RIGHT CTRL"] = "CTRL DROIT",
        ["Duplicate plate finder"] = "Détecteur de plaques en double",
    },
}

--- The panel's own fallback text in the game language; English when no entry exists.
local function tr(s)
    if type(s) ~= "string" then return s end
    local lang = type(g_languageShort) == "string" and g_languageShort or "en"
    local t = H.L10N[lang]
    local v = t ~= nil and t[s] or nil
    if type(v) == "string" and v ~= "" then return v end
    return s
end

--- Copy of a fixed row with its words in the game language.
local function trRow(d)
    local caps = d.caps
    if type(caps) == "table" then
        local c2 = {}
        for i, c in ipairs(caps) do c2[i] = tr(c) end
        caps = c2
    end
    return { keys = tr(d.keys), lead = tr(d.lead), caps = caps, text = tr(d.text) }
end

--- v20: a mod that switched itself off for this mission asks for its section to be hidden.
function H.hide(prefix)
    if type(prefix) ~= "string" or g_currentMission == nil then return end
    H._hidden[prefix] = g_currentMission
end

--- A mod declares rows whose binding is fixed in code.
function H.declare(prefix, title, env, rows)
    H._declared[prefix] = { title = title, env = env, rows = rows or {} }
end

--- Every embedding mod calls this ONCE at script load, and again from loadMap as
--- a belt. Idempotent.
local function elect()
    local bestTag, bestVer = nil, -1
    for t, c in pairs(H._candidates) do
        if c.version > bestVer or (c.version == bestVer and (bestTag == nil or t < bestTag)) then
            bestTag, bestVer = t, c.version
        end
    end
    H.owner = bestTag
end

function H.stage(tag, log, modDir, modName)
    H._candidates[tag] = { version = OUR_VERSION, log = log, dir = modDir or MOD_DIR, name = modName }
    elect()
    if H._sharedLogged ~= true then
        H._sharedLogged = true
        local c = H._candidates[tag]
        if c ~= nil and c.log ~= nil then c.log("%s: KJH: shared through the real global table=%s", tag, tostring(KJ_REALG ~= _G)) end
    end
end

local function log(fmt, ...)
    local c = H.owner ~= nil and H._candidates[H.owner] or nil
    -- Prefixed with the owning mod's tag: the owner's dbgLog adds none, so
    -- unprefixed lines are invisible to the project's triage grep.
    if c ~= nil and c.log ~= nil then c.log("%s: KJH: " .. fmt, H.owner, ...) end
end

-- v21: THE PANEL CLEARS THE SCREEN WHILE IT IS OPEN (2026-10-13: it covered his
-- AgriWeather panel). It hides the game's HUD through the engine's own flag, the same call
-- the base game's camera modes use (VehicleCamera 830), and every Kijbev mod skips its own
-- drawing while KijbevHelp.isOpen. It restores the HUD ONLY if it was the one that hid it, so
-- a HUD the player hid with another tool stays hidden. Third-party HUDs are not reachable.
local function claimScreen(on)
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    if hud == nil or type(hud.setIsVisible) ~= "function" then return end
    if on then
        local visible = true
        if type(hud.getIsVisible) == "function" then visible = hud:getIsVisible() == true end
        if visible then
            hud:setIsVisible(false)
            H._hidHud = true
            log("HUD hidden while the panel is open")
        end
    elseif H._hidHud == true then
        H._hidHud = false
        hud:setIsVisible(true)
        log("HUD restored")
    end
end

-- ---------------------------------------------------------------------------
-- Layout. Two columns: sections flow left to right in pairs, wrap to a new row
-- that starts left bound, and each row advances by the TALLER of its two, so the
-- columns line up at the row top. Deliberately not balanced by height: balancing
-- moves a mod somewhere else as the installed set changes, and a reference is
-- only useful if the thing you want is where it was last time.
-- ---------------------------------------------------------------------------
local COL_W_MAX = 0.30     -- wrapping budget and hard ceiling, NOT the drawn width
local COL_W_MIN = 0.16     -- keeps a one-row mod from collapsing to a sliver
local COL_GAP   = 0.028
-- HARD CEILING. 2026-07-28: "the panel should NEVER grow wider, because else
-- it runs into TT's own weather info panel." The panel may SHRINK to its content
-- freely, but it may never exceed this, whatever the content is. Anything that
-- does not fit is trimmed, never accommodated.
local PANEL_W_MAX = COL_W_MAX * 2 + COL_GAP
local PAD       = 0.012
local ROW_H     = 0.028
local HEAD_H    = 0.034
local TITLE_H   = 0.040
local SUB_H     = 0.022
local SEC_GAP   = 0.010
local TXT_ROW   = 0.016
local TXT_HEAD  = 0.019
local TXT_TITLE = 0.026
local TXT_SUB   = 0.0135
local TXT_ABOUT = 0.0125   -- smaller than a keybind row on purpose: context, not content
local ABOUT_H   = 0.017
-- v15 (2026-09-13, from the seat): the close hint sits TOP RIGHT on the title
-- row, larger than a key row and in its own color, because at the bottom in row
-- style it "blends in and looks like part of another mod's keys". It is panel
-- chrome, not a mod's key, and it must never read as one.
-- v16 : the hint text is the panel's BLUE (the section-heading blue, no third
-- color on the panel) in regular weight, so it differs from the bold blue headings
-- and from the white rows; the key art stays white like every other key on the panel.
local TXT_CLOSE = 0.020
local CLOSE_H   = 0.026    -- key-art height for the hint, a hair under the title
local CLOSE_RGB = { 0.36, 0.75, 1.0, 1.0 }   -- the panel blue (section headings)
local CLOSE_GAP = 0.006    -- between the key art and the hint text
local GLYPH_W   = 0.07     -- width a two key combo takes ahead of the row text

--- Word wrap using the engine's own measurement, so it stays correct at any
--- resolution and after DE and FR expansion rather than at a guessed character count.
local function wrapText(text, size, maxW)
    local lines, cur = {}, ""
    if text == nil or text == "" then return lines end
    for word in string.gmatch(text, "%S+") do
        local try = (cur == "") and word or (cur .. " " .. word)
        -- No pcall in this file (TestRunner 0.9.21 PublicLuaCheck). getTextWidth is a
        -- documented Text Rendering binding; the symbol is checked and the RESULT is
        -- type-tested, which is what the old catch was really doing.
        local w = 0
        if getTextWidth ~= nil then
            local v = getTextWidth(size, try)
            if type(v) == "number" then w = v end
        end
        if w > maxW and cur ~= "" then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = try
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

--- Fit to ONE line by dropping whole WORDS. A keybind row is one line by design,
--- so this trims rather than wraps. Word boundaries only: a byte level cut would
--- split a multi byte character in the DE and FR locales.
-- v23: width a row's optional leading word takes before its key cap (word plus the
-- glyph's text gap, approximated by one space here since no glyph exists yet).
local function leadWidth(r)
    if type(r) ~= "table" or type(r.lead) ~= "string" or r.lead == "" then return 0 end
    return getTextWidth(TXT_ROW, r.lead .. " ")
end

local function fitOneLine(text, size, maxW)
    if text == nil or text == "" then return "" end
    local w = nil
    if getTextWidth ~= nil then w = getTextWidth(size, text) end
    if type(w) == "number" and w <= maxW then return text end
    local cur = ""
    for word in string.gmatch(text, "%S+") do
        local try = (cur == "") and word or (cur .. " " .. word)
        local w2 = nil
        if getTextWidth ~= nil then w2 = getTextWidth(size, try .. " ...") end
        if type(w2) ~= "number" then return text end
        if w2 > maxW then break end
        cur = try
    end
    if cur == "" then return text end
    return cur .. " ..."
end

local function sectionAboutLines(sec)
    if sec._aboutLines == nil then
        sec._aboutLines = wrapText(sec.about, TXT_ABOUT, COL_W_MAX - PAD)
        sec._noteLines  = wrapText(sec.note,  TXT_ABOUT, COL_W_MAX - PAD)
    end
    return sec._aboutLines, sec._noteLines
end

--- Natural width of a section: the widest thing it actually draws. Columns were
--- a FIXED 0.30 each, which left a gap down the middle and a margin on the right
--- whenever the content was narrower (2026-07-28: "the panel is too wide
--- overall, and the middle shows a lot of blank space"). Measured once per open
--- and cached, since draw runs every frame and this cannot change while open.
local function sectionWidth(sec)
    if sec._width == nil then
        local function tw(size, text)
            if text == nil or text == "" then return 0 end
            local w = nil
            if getTextWidth ~= nil then w = getTextWidth(size, text) end
            if type(w) == "number" then return w end
            return 0
        end
        local widest = tw(TXT_HEAD, sec.title)
        local aboutLines, noteLines = sectionAboutLines(sec)
        for _, ln in ipairs(aboutLines) do widest = math.max(widest, PAD + tw(TXT_ABOUT, ln)) end
        for _, ln in ipairs(noteLines)  do widest = math.max(widest, PAD + tw(TXT_ABOUT, ln)) end
        for _, r in ipairs(sec.rows) do
            if r.action ~= nil or r.caps ~= nil then
                -- Glyph rows carry the key art ahead of the text; GLYPH_W is the
                -- allowance a two key combo needs.
                widest = math.max(widest, PAD + GLYPH_W + tw(TXT_ROW, r.text))
            else
                widest = math.max(widest, PAD + tw(TXT_ROW,
                    string.format("%s   %s", r.keys or "?", r.text or "")))
            end
        end
        sec._width = math.max(COL_W_MIN, math.min(COL_W_MAX, widest + PAD))
    end
    return sec._width
end

local function sectionHeight(sec)
    local aboutLines, noteLines = sectionAboutLines(sec)
    return HEAD_H + (#aboutLines + #noteLines) * ABOUT_H + #sec.rows * ROW_H + SEC_GAP
end

-- ---------------------------------------------------------------------------
-- Collection. LIVE from the input system, never a hand maintained table for a
-- REBINDABLE key, so a user rebind or a controller mapping displays truthfully.
-- ---------------------------------------------------------------------------
-- v20: a family shows only when its mod is LOADED and has not hidden itself. The input
-- registry holds the actions of every INSTALLED mod, loaded or not (our log 2026-10-13: a
-- To Pasture And Back RL section with that mod disabled in the savegame).
local function familyActive(fam)
    if H._hidden[fam.prefix] ~= nil and H._hidden[fam.prefix] == g_currentMission then return false end
    if fam.env ~= nil and type(g_modIsLoaded) == "table" and g_modIsLoaded[fam.env] ~= true then return false end
    return true
end

local function collectSections()
    local sections = {}
    local reg = g_inputBinding ~= nil and g_inputBinding.nameActions or nil
    if type(reg) ~= "table" then
        if not H._warnedNoReg then
            H._warnedNoReg = true
            Logging.warning("KJH: g_inputBinding.nameActions unavailable, the help panel can show nothing.")
        end
        return sections
    end

    -- Fallbacks merged into a LOCAL view, NEVER into H._declared. That table is
    -- process global and survives a return to the menu, so writing fallbacks into
    -- it made a mod loaded in the PREVIOUS savegame keep its section in the next
    -- one, listing keys that do nothing. Merging BEFORE the prefix loop also fixes
    -- a first open versus second open content difference (review B4).
    local declared = {}
    for prefix, dec in pairs(H._declared) do
        declared[prefix] = dec
    end
    if g_modIsLoaded ~= nil then
        for modName, fb in pairs(H.FALLBACK) do
            if g_modIsLoaded[modName] == true and declared[fb.prefix] == nil then
                declared[fb.prefix] = { title = fb.title, rows = fb.rows }
            end
        end
    end

    local seenPrefix = {}
    for _, fam in ipairs(H.PREFIXES) do
        local rows = {}
        for name, _ in pairs(reg) do
            if type(name) == "string" and name:sub(1, #fam.prefix) == fam.prefix then
                -- CROSS MOD TEXT. Mod l10n is NOT global: the owning mod's rows
                -- resolve and every other mod's row printed its raw action name
                -- (field 2026-07-28). getText takes an optional custom environment,
                -- which is why the registry carries one. Falls back to the raw name
                -- so a wrong env can never blank a row.
                local key = "input_" .. name
                local text = name
                if g_i18n ~= nil then
                    local t = g_i18n:getText(key, fam.env)
                    if type(t) == "string" and t ~= "" and t ~= key then
                        text = t
                    else
                        local t2 = g_i18n:getText(key)
                        if type(t2) == "string" and t2 ~= "" and t2 ~= key then
                            text = t2
                        end
                    end
                end
                rows[#rows + 1] = { action = name, text = text }
            end
        end
        local dec = declared[fam.prefix]
        if dec ~= nil then
            for _, d0 in ipairs(dec.rows) do
                local d = trRow(d0)
                rows[#rows + 1] = { action = nil, keys = d.keys, lead = d.lead, caps = d.caps, text = d.text }
            end
        end
        -- v18: the mod's OWN kjhelp_about only. g_i18n:getText(key, env) falls through to
        -- the globally registered text when env does not define the key, and every mod's
        -- l10n lands globally too, so the first mod that shipped a kjhelp_about (TT) had its
        -- line printed under EVERY other mod (our screenshot 2026-09-30). The per-mod table
        -- g_i18n.modEnvironments[modName].texts is withheld from gameSource (I18N.lua is not
        -- in the SDK zip); two third-party mods read it this way. Every step is nil-guarded
        -- and an unexpected shape falls back to H.ABOUT, which can never be another mod's line.
        local about, aboutSrc = nil, "fallback"
        local envs = g_i18n ~= nil and g_i18n.modEnvironments or nil
        local menv = type(envs) == "table" and envs[fam.env] or nil
        local texts = type(menv) == "table" and menv.texts or nil
        if type(texts) == "table" then
            local t = texts["kjhelp_about"]
            if type(t) == "string" and t ~= "" then about, aboutSrc = t, "own" end
        end
        if about == nil then about = tr(H.ABOUT[fam.prefix]) end
        log("about '%s' from %s (modEnvironments %s)", fam.prefix, aboutSrc, type(envs) == "table" and "readable" or "absent")
        local note = nil
        for _, n in ipairs(H.NOTES) do
            if n.prefix == fam.prefix then
                if type(n.when) == "function" and n.when() == true then note = tr(n.text) end
            end
        end
        if not familyActive(fam) then
            seenPrefix[fam.prefix] = true   -- also keeps its declared rows out of the leftover pass
        elseif #rows > 0 then
            table.sort(rows, function(a, b)
                return (a.action or ("zzz" .. (a.keys or ""))) < (b.action or ("zzz" .. (b.keys or "")))
            end)
            for _, r in ipairs(rows) do
                -- Trim to the column. Two column layout with unmeasured row text ran
                -- the longest string straight into the right hand column.
                local budget = (r.action ~= nil or r.caps ~= nil) and (COL_W_MAX - PAD - GLYPH_W) or (COL_W_MAX - PAD)
                budget = budget - leadWidth(r)
                r.text = fitOneLine(r.text, TXT_ROW, budget)
            end
            seenPrefix[fam.prefix] = true
            sections[#sections + 1] = { title = fam.title, rows = rows, about = about, note = note }
        end
    end

    -- Declared families whose prefix is not in the registry at all. Keyed on
    -- PREFIX, never on a title string compare, so a typo cannot produce a silent
    -- duplicate section. Sorted, so section order cannot change between opens.
    local leftover = {}
    for prefix, dec in pairs(declared) do
        if not seenPrefix[prefix] and #dec.rows > 0 then leftover[#leftover + 1] = prefix end
    end
    table.sort(leftover)
    for _, prefix in ipairs(leftover) do
        local dec = declared[prefix]
        local rows = {}
        for _, d0 in ipairs(dec.rows) do
            local d = trRow(d0)
            rows[#rows + 1] = { action = nil, keys = d.keys, lead = d.lead, caps = d.caps,
                text = fitOneLine(d.text, TXT_ROW, COL_W_MAX - PAD - GLYPH_W - leadWidth(d)) }
        end
        sections[#sections + 1] = { title = dec.title, rows = rows, about = tr(H.ABOUT[prefix]), note = nil }
    end
    return sections
end

-- ---------------------------------------------------------------------------
-- Toggle. Registered from the engine's OWN global player action event pass, so
-- it lands in the live input context. Registering once at loadMap creates an
-- event that exists and is unreachable (field 2026-07-28).
-- ---------------------------------------------------------------------------
function H.registerToggle(contextName)
    if g_inputBinding == nil or InputAction == nil then return end
    local okRm = g_inputBinding.removeActionEventsByTarget ~= nil
    if okRm then g_inputBinding:removeActionEventsByTarget(H) end
    if not okRm and not H._warnedNoRemove then
        H._warnedNoRemove = true
        Logging.warning("KJH: removeActionEventsByTarget failed, toggle events may accumulate on each rebuild.")
    end
    local n = 0
    for name, _ in pairs(InputAction) do
        if type(name) == "string" and name:sub(1, 7) == "KJHELP_" then
            local valid, id = nil, nil
            if g_inputBinding.registerActionEvent ~= nil then
                valid, id = g_inputBinding:registerActionEvent(InputAction[name], H, H.onToggle,
                    false, true, false, true)
            end
            if valid == true and id ~= nil then
                n = n + 1
                -- House rule: our mods never add anything to the vanilla F1 panel.
                if g_inputBinding.setActionEventTextVisibility ~= nil then
                    g_inputBinding:setActionEventTextVisibility(id, false)
                end
            end
        end
    end
    if n ~= H._lastCount then
        H._lastCount = n
        log("toggle registered on %d action(s), owner=%s, context=%s",
            n, tostring(H.owner), tostring(contextName))
        if n == 0 then
            Logging.warning("KJH: no KJHELP_* input action found, the help panel has no key.")
        end
    end
end

-- The install guard lives on ITS OWN GLOBAL, not on H. H is REPLACED wholesale
-- when a newer copy loads, which would drop H._hooked and install a SECOND hook
-- whose closure captured the now dead table. That dead module's owner is still
-- set, so it would keep registering a parallel set of events the live module can
-- never remove (review B2). The closure therefore resolves the CURRENT global on
-- every call and captures nothing.
-- Guarded on WHICH CLASS carries the hook, not on a flag (review 2026-10-02): a flag that outlived a
-- reload of the base classes would leave the fresh class unhooked and report success.
if PlayerInputComponent ~= nil and KJ_REALG.KijbevHelpHookedClass ~= PlayerInputComponent then
    KJ_REALG.KijbevHelpHookedClass = PlayerInputComponent
    if PlayerInputComponent ~= nil and type(PlayerInputComponent.registerGlobalPlayerActionEvents) == "function" then
        PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
            PlayerInputComponent.registerGlobalPlayerActionEvents,
            function(inputComponent, contextName)
                local G = KJ_REALG.KijbevHelp
                if G ~= nil and G.owner ~= nil and G.registerToggle ~= nil then
                    G.registerToggle(contextName)
                end
            end)
        KJ_REALG.KijbevHelpHookOk = true
    else
        KJ_REALG.KijbevHelpHookOk = false
        Logging.warning("KJH: PlayerInputComponent.registerGlobalPlayerActionEvents missing, falling back to a one-shot registration.")
    end
end
H._hookOk = KJ_REALG.KijbevHelpHookOk

function H.onToggle()
    -- DEBOUNCE. With several Kijbev mods installed there are several KJHELP_*
    -- actions, all defaulting to the same key and all registered by the winner, so
    -- ONE press can dispatch N times. An even N would cancel itself out and the
    -- panel would never appear. This makes N dispatches behave as one for any N,
    -- which retires the blueprint's open engine question about duplicate action
    -- names as a CORRECTNESS dependency (review B3).
    local now = (g_currentMission ~= nil and g_currentMission.time) or 0
    if H._lastToggleMs ~= nil and now >= H._lastToggleMs and (now - H._lastToggleMs) < 250 then
        return
    end
    H._lastToggleMs = now

    H.isOpen = not H.isOpen
    if H.isOpen then
        H._sections = collectSections()
        H._drewSinceOpen = false
        local rows = 0
        for _, s in ipairs(H._sections) do rows = rows + #s.rows end
        log("panel OPEN, %d section(s), %d row(s)", #H._sections, rows)
        claimScreen(true)
    else
        claimScreen(false)
        -- Opened and closed without ever reaching draw: the owning mod is not
        -- calling KijbevHelp.draw(tag), or returns before it. Two builds failed
        -- exactly this way in silence.
        if H._drewSinceOpen ~= true and not H._warnedNoDraw then
            H._warnedNoDraw = true
            Logging.warning("KJH: panel opened and closed without drawing. Owner '%s' is not calling KijbevHelp.draw(tag) from its draw(), or returns before it.", tostring(H.owner))
        end
        H.releaseGlyphs()
    end
end

function H.releaseGlyphs()
    if H._glyphs ~= nil then
        for _, g in ipairs(H._glyphs) do
            if g.delete ~= nil then g:delete() end
        end
    end
    H._glyphs = nil
    if H._fixedGlyphs ~= nil then
        for _, g in ipairs(H._fixedGlyphs) do
            if g.delete ~= nil then g:delete() end
        end
    end
    H._fixedGlyphs = nil
end

-- v22: FIXED KEYS DRAWN IN THE SAME KEY ART (2026-10-13: "Hold R" stood out as plain
-- text). A fixed binding has no input action, so the engine cannot resolve a glyph for it.
-- The same InputGlyphElement is used and its key names are filled in directly: its draw()
-- renders keyNames through the very ButtonOverlay the engine uses for keyboard glyphs
-- (InputGlyphElement.lua draw, hasKeyNames branch), so the caps look identical. Returns nil
-- (plain text fallback) if the element lacks the fields that path reads.
local function fixedGlyphFor(i, caps, text)
    H._fixedGlyphs = H._fixedGlyphs or {}
    local g = H._fixedGlyphs[i]
    if g == nil then
        if H._fixedGlyphBroken or InputGlyphElement == nil or InputGlyphElement.new == nil
                or g_inputDisplayManager == nil then
            return nil
        end
        H._fixedGlyphBroken = true   -- latch before construction, cleared when usable
        local made = InputGlyphElement.new(g_inputDisplayManager, ROW_H * 0.75, ROW_H * 0.75)
        if made == nil or made.draw == nil or made.setPosition == nil or made.keyboardOverlay == nil
                or type(made.keyNames) ~= "table" or type(made.actionNames) ~= "table" then
            return nil
        end
        H._fixedGlyphBroken = nil
        g = made
        g.isLeftAligned = true
        H._fixedGlyphs[i] = g
    end
    if g._kjhText ~= text then
        g._kjhText = text
        g.actionNames = { "KJH_FIXED" }
        g.keyNames = { KJH_FIXED = caps }
        g.hasKeyNames = true
        g.hasButtonOverlays = false
        g.actionText = text
        g.actionTextSize = TXT_ROW   -- same text size the action rows pass to setAction
        if g.updateDisplayText ~= nil then g:updateDisplayText() end
    end
    return g
end

local function glyphFor(i, action, text)
    H._glyphs = H._glyphs or {}
    local g = H._glyphs[i]
    if g == nil then
        if InputGlyphElement == nil or g_inputDisplayManager == nil then
            if not H._warnedNoGlyph then
                H._warnedNoGlyph = true
                Logging.warning("KJH: InputGlyphElement unavailable, rows render without key glyphs.")
            end
            return nil
        end
        if InputGlyphElement.new == nil then
            if not H._warnedNoGlyph then
                H._warnedNoGlyph = true
                Logging.warning("KJH: InputGlyphElement.new missing, rows render as plain text.")
            end
            return nil
        end
        -- LATCH BEFORE THE CONSTRUCTION (code review S3): a throw in the constructor must not
        -- leave this retrying on every draw frame. Cleared once the element is usable.
        local prevWarned = H._warnedNoGlyph
        H._warnedNoGlyph = true
        local made = InputGlyphElement.new(g_inputDisplayManager, ROW_H * 0.75, ROW_H * 0.75)
        if made ~= nil then H._warnedNoGlyph = prevWarned end
        -- VALIDATE THE WHOLE METHOD SET HERE, ONCE (TestRunner 0.9.21 conversion): the draw
        -- path below then calls setAction, setPosition and draw directly. Checking the API at
        -- creation is the compliant replacement for catching on every frame, and it fails the
        -- glyph once instead of logging per frame if a patch changes the element.
        if made ~= nil and (made.setAction == nil or made.setPosition == nil or made.draw == nil) then
            made = nil
        end
        if made == nil then
            if not H._warnedNoGlyph then
                H._warnedNoGlyph = true
                Logging.warning("KJH: InputGlyphElement.new failed, rows render without key glyphs.")
            end
            return nil
        end
        g = made
        -- Left align. The default is RIGHT aligned inside the element's own box and
        -- FS25 exposes no setter (only the GUI subclass reads it, from XML), so the
        -- field is set directly. Without it a combo draws left of its row origin.
        g.isLeftAligned = true
        H._glyphs[i] = g
    end
    -- setAction is NOT cheap to repeat: it reaches into the input display manager,
    -- which is withheld from the readable source so its cost is unknown. Every base
    -- game consumer calls it ONCE at creation, never per frame. Rebinds stay safe
    -- because glyphs are released on close and a rebind can only happen while closed.
    if g._kjhAction ~= action or g._kjhText ~= text then
        g._kjhAction, g._kjhText = action, text
        g:setAction(action, text, TXT_ROW)
    end
    return g
end

function H.draw(tag)
    if not H.isOpen or tag ~= H.owner then return end
    -- SET BEFORE ANY EARLY RETURN (v12, pre-build review). Reaching this line
    -- already proves the owner is calling draw, which is the only thing
    -- _drewSinceOpen is evidence of. It used to sit below the gates, so opening
    -- and closing the panel while the HUD was hidden, or while the shop was up,
    -- tripped onToggle's ungated "owner is not calling KijbevHelp.draw" warning
    -- and accused the owning mod of a defect it does not have. Giants grep the
    -- log for Warning, so that is a cert risk as well as a false lead.
    H._drewSinceOpen = true
    -- v21: keep the HUD hidden while open. Something else (a camera mode, a screenshot tool)
    -- may switch it back on; the panel then re-asserts instead of being drawn over.
    if H._hidHud == true and g_currentMission ~= nil and g_currentMission.hud ~= nil
            and g_currentMission.hud.getIsVisible ~= nil and g_currentMission.hud:getIsVisible() then
        g_currentMission.hud:setIsVisible(false)
    end
    -- No ESC handling of its own, so without this the panel stays on screen over
    -- the pause menu and the shop with no way to dismiss it from there.
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then return end
    -- v12: THE PLAYER HID THE HUD, SO HIDE. Screenshot tools such as
    -- FS25_additionalGameSettings toggle the ENGINE'S OWN flag,
    -- g_currentMission.hud:setIsVisible(state), and the base game's own camera
    -- modes use it too (VehicleCamera 830). Asking the same question the engine
    -- already answers makes this panel compatible with every HUD-hiding mod,
    -- present and future, without naming one of them. A detection list would
    -- need a new entry every time somebody ships another screenshot tool.
    if H._hidHud ~= true and g_currentMission ~= nil and g_currentMission.hud ~= nil
            and g_currentMission.hud.getIsVisible ~= nil
            and not g_currentMission.hud:getIsVisible() then
        return
    end

    local secs = H._sections or {}
    if #secs == 0 then
        -- NEVER return silently here. Two builds did nothing and said nothing, and
        -- this is that exact shape: the key fires, nothing renders, and the player
        -- reports that the panel does not open.
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(1, 1, 1, 1)
        setTextBold(true)
        renderText(0.5, 0.5, TXT_HEAD,
            g_i18n ~= nil and g_i18n:getText("kjhelp_empty") or "No Kijbev mod keybinds found")
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
        return
    end

    local bodyH = 0
    -- Each COLUMN is as wide as its widest section, and the PANEL is the sum. The
    -- left column keeps the odd numbered sections and the right the even ones, so
    -- the reading order is unchanged; only the empty space goes.
    local colW = { COL_W_MIN, 0 }
    for i = 1, #secs, 2 do
        local a = sectionHeight(secs[i])
        local b = (secs[i + 1] ~= nil) and sectionHeight(secs[i + 1]) or 0
        bodyH = bodyH + math.max(a, b)
        colW[1] = math.max(colW[1], sectionWidth(secs[i]))
        if secs[i + 1] ~= nil then colW[2] = math.max(colW[2], sectionWidth(secs[i + 1])) end
    end
    local title = g_i18n ~= nil and g_i18n:getText("kjhelp_title") or "Unified Kijbev Modding Help Panel"
    local subtitle = g_i18n ~= nil and g_i18n:getText("kjhelp_subtitle")
        or "Keyboard shortcuts for every installed Kijbev mod"
    local titleW = 0
    if getTextWidth ~= nil then
        local wT = getTextWidth(TXT_TITLE, title)
        if type(wT) == "number" then titleW = wT end
    end
    -- Close hint (v14 footer row, moved to the title row in v15). The owner's own
    -- KJHELP_* action drawn as key art (so a rebind is reflected) followed by the
    -- close text, bold, larger, amber. Resolved HERE because its width shares the
    -- title row and the title budget must leave room for it.
    local closeAction = nil
    if InputAction ~= nil then
        closeAction = InputAction["KJHELP_" .. tostring(H.owner)]
        if closeAction == nil then
            for name, v in pairs(InputAction) do
                if type(name) == "string" and name:sub(1, 7) == "KJHELP_" then closeAction = v break end
            end
        end
    end
    local closeText = g_i18n ~= nil and g_i18n:getText("kjhelp_close") or "kjhelp_close"
    if type(closeText) ~= "string" or closeText == "" or closeText == "kjhelp_close" then
        closeText = "opens/closes this panel"
    end
    local closeGlyph = nil
    if closeAction ~= nil and InputGlyphElement ~= nil and InputGlyphElement.new ~= nil
            and g_inputDisplayManager ~= nil then
        if H._closeGlyph == nil and H._closeGlyphTried ~= true then
            H._closeGlyphTried = true
            local made = InputGlyphElement.new(g_inputDisplayManager, CLOSE_H, CLOSE_H)
            if made ~= nil and (made.setAction == nil or made.setPosition == nil or made.draw == nil
                    or made.getGlyphWidth == nil) then
                made = nil
            end
            if made ~= nil then
                made.isLeftAligned = true
                H._closeGlyph = made
            else
                Logging.warning("KJH: close-hint glyph unavailable, the hint renders as plain text.")
            end
        end
        closeGlyph = H._closeGlyph
        if closeGlyph ~= nil then
            local sig = tostring(closeAction) .. "|" .. closeText
            if H._closeSig ~= sig then
                -- Key art only (nil text): the text is rendered by this file, in its
                -- own weight and color, which the element cannot do separately.
                closeGlyph:setAction(closeAction, nil, TXT_CLOSE)
                H._closeSig = sig
            end
        end
    end
    local closePlain = nil
    if closeGlyph == nil then
        closePlain = g_i18n ~= nil and g_i18n:getText("kjhelp_close_plain") or "kjhelp_close_plain"
        if type(closePlain) ~= "string" or closePlain == "" or closePlain == "kjhelp_close_plain" then
            closePlain = "Press the same key again to close this panel"
        end
    end
    local hintW, hintTextW = 0, 0
    if getTextWidth ~= nil then
        setTextBold(false)
        if closeGlyph ~= nil then
            local gw = closeGlyph:getGlyphWidth()
            local tw = getTextWidth(TXT_CLOSE, closeText)
            hintTextW = type(tw) == "number" and tw or 0
            hintW = (type(gw) == "number" and gw or 0) + CLOSE_GAP + hintTextW
        else
            local tw = getTextWidth(TXT_CLOSE, closePlain)
            hintTextW = type(tw) == "number" and tw or 0
            hintW = hintTextW
        end
    end

    local panelW = colW[1] + ((colW[2] > 0) and (COL_GAP + colW[2]) or 0)
    -- The title row may widen a NARROW panel so neither the title nor the close
    -- hint is clipped, but nothing may push past the ceiling. Beyond it the TITLE
    -- is trimmed instead; the hint is never trimmed, it is the way out.
    panelW = math.min(math.max(panelW, titleW + PAD + hintW), PANEL_W_MAX)
    title = fitOneLine(title, TXT_TITLE, math.max(panelW - hintW - PAD, 0.04))
    subtitle = fitOneLine(subtitle, TXT_SUB, panelW)
    local h = TITLE_H + SUB_H + bodyH + PAD
    local left = 0.5 - panelW * 0.5
    -- Top anchor once the stack is taller than the screen: centering an oversized
    -- panel cuts BOTH the title and the last section.
    local top = math.min(0.5 + h * 0.5, 0.98)

    if H._bg == nil and H._bgTried ~= true then
        H._bgTried = true
        local c = H.owner ~= nil and H._candidates[H.owner] or nil
        local dir = c ~= nil and c.dir or ""
        local ov = nil
        if createImageOverlay ~= nil then ov = createImageOverlay(dir .. "hud/kjh_white.dds") end
        if ov ~= nil and ov ~= 0 then
            H._bg = ov
        else
            Logging.warning("KJH: backdrop texture failed to load, panel draws without one")
        end
    end
    if H._bg ~= nil then
        setOverlayColor(H._bg, 0, 0, 0, 0.78)
        renderOverlay(H._bg, left - PAD, top - h, panelW + PAD * 2, h)
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    renderText(left, top - TITLE_H * 0.72, TXT_TITLE, title)
    setTextBold(false)
    -- Close hint, top right, on the title row: white key art, then the text in the
    -- panel blue, regular weight, right-aligned to the panel edge.
    -- v17: TEXT STATE IS SET AFTER THE GLYPH DRAW, NOT BEFORE. The engine's glyph
    -- element renders its own key labels and leaves alignment LEFT and color white
    -- behind it, so a state set before draw() is gone by renderText: v16 painted the
    -- hint left-aligned FROM the panel's right edge, outside the panel, in white
    -- (our screenshot 2026-09-13). Text state is global; set it at the call.
    if closeGlyph ~= nil then
        closeGlyph:setPosition(left + panelW - hintW, top - TITLE_H * 0.86)
        closeGlyph:draw()
    end
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextBold(false)
    setTextColor(CLOSE_RGB[1], CLOSE_RGB[2], CLOSE_RGB[3], CLOSE_RGB[4])
    if closeGlyph ~= nil then
        renderText(left + panelW, top - TITLE_H * 0.72, TXT_CLOSE, closeText)
    elseif closePlain ~= nil then
        renderText(left + panelW, top - TITLE_H * 0.72, TXT_CLOSE, closePlain)
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    -- Subtitle. our call 2026-07-28: do NOT tell players they can rebind keys,
    -- they know. DO say what this actually is, because "help panel" oversells it:
    -- it is a keyboard shortcut overview for the installed Kijbev mods, nothing
    -- more, and naming that honestly is better than implying it explains the mods.
    setTextColor(0.66, 0.66, 0.66, 1)
    renderText(left, top - TITLE_H - SUB_H * 0.62, TXT_SUB, subtitle)
    setTextColor(1, 1, 1, 1)

    local rowTop = top - TITLE_H - SUB_H
    local gi = 0
    local fgi = 0   -- v22: fixed-key rows, own glyph cache index
    for i = 1, #secs, 2 do
        local tallest = 0
        for col = 0, 1 do
            local sec = secs[i + col]
            if sec ~= nil then
                local x = left + ((col == 1) and (colW[1] + COL_GAP) or 0)
                local cy = rowTop
                setTextBold(true)
                setTextColor(0.36, 0.75, 1, 1)
                renderText(x, cy - HEAD_H * 0.7, TXT_HEAD, sec.title)
                setTextBold(false)
                cy = cy - HEAD_H
                local aboutLines, noteLines = sectionAboutLines(sec)
                for _, ln in ipairs(aboutLines) do
                    setTextColor(0.72, 0.72, 0.72, 1)
                    renderText(x + PAD, cy - ABOUT_H * 0.75, TXT_ABOUT, ln)
                    cy = cy - ABOUT_H
                end
                for _, ln in ipairs(noteLines) do
                    -- Amber: a note only appears when it is TRUE and the player very
                    -- likely wants to know about it.
                    setTextColor(1, 0.78, 0.32, 1)
                    renderText(x + PAD, cy - ABOUT_H * 0.75, TXT_ABOUT, ln)
                    cy = cy - ABOUT_H
                end
                setTextColor(1, 1, 1, 1)
                for _, r in ipairs(sec.rows) do
                    local fg = nil
                    if r.action == nil and type(r.caps) == "table" then
                        fgi = fgi + 1
                        fg = fixedGlyphFor(fgi, r.caps, r.text)
                    end
                    if fg ~= nil then
                        -- v23: an optional leading word ("Hold") before the key cap, drawn
                        -- exactly as the glyph draws its own text (InputGlyphElement
                        -- drawActionText: same size, color, bold, baseline posY + size/2),
                        -- with the glyph's own text gap between the word and the cap.
                        local gx, gy = x + PAD, cy - ROW_H * 0.85
                        if type(r.lead) == "string" and r.lead ~= "" then
                            setTextAlignment(RenderText.ALIGN_LEFT)
                            setTextBold(fg.bold == true)
                            setTextColor(unpack(fg.color or { 1, 1, 1, 1 }))
                            renderText(gx, gy + TXT_ROW * 0.5, TXT_ROW, r.lead)
                            gx = gx + getTextWidth(TXT_ROW, r.lead) + (fg.textOffsetX or 0)
                            setTextBold(false)
                            setTextColor(1, 1, 1, 1)
                        end
                        fg:setPosition(gx, gy)
                        fg:draw()
                    elseif r.action == nil then
                        -- Fixed binding, no engine glyph exists for it. Bright white like the
                        -- glyph rows' text (v27, 2026-10-30: the gray read as a lesser row).
                        setTextColor(1, 1, 1, 1)
                        renderText(x + PAD, cy - ROW_H * 0.8, TXT_ROW,
                            string.format("%s   %s", r.keys or "?", r.text or ""))   -- "Hold R   to free..." reads right
                        setTextColor(1, 1, 1, 1)
                    else
                        gi = gi + 1
                        local g = glyphFor(gi, r.action, r.text)
                        if g ~= nil then
                            -- Methods were validated at creation (glyphFor), so these are
                            -- direct calls; glyphFor returns nil when the element cannot
                            -- serve, which is the only failure this path can now see.
                            g:setPosition(x + PAD, cy - ROW_H * 0.85)
                            g:draw()
                        else
                            -- Show the action NAME as well: a description with no key
                            -- at all reads as a bug.
                            setTextColor(0.8, 0.8, 0.8, 1)
                            renderText(x + PAD, cy - ROW_H * 0.8, TXT_ROW,
                                string.format("%s   %s", r.action, r.text or ""))
                            setTextColor(1, 1, 1, 1)
                        end
                    end
                    cy = cy - ROW_H
                end
                tallest = math.max(tallest, sectionHeight(sec))
            end
        end
        rowTop = rowTop - tallest
    end
    -- (v14's footer close row lived here; v15 moved the hint to the title row above.)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

--- Called from the owning mod's loadMap. Safe to call from every copy.
function H.onLoadMap(tag)
    if H.owner == nil then
        Logging.warning("KJH: onLoadMap('%s') with NO owner staged. A sourceFile ORDER problem in modDesc.xml is the usual cause.", tostring(tag))
        return
    end
    if tag ~= H.owner then return end
    log("owner=%s, engine hook=%s", tostring(H.owner), tostring(H._hookOk))
    if not H._hookOk then
        H.registerToggle("loadMap-fallback")
    end
end

--- Called from EVERY embedding mod's deleteMap. The shared table outlives the mission (it lives
--- in the real global table), so each mod leaves at its own deleteMap and the next mission elects
--- afresh; a mod not chosen for the next savegame is then never the owner.
function H.onDeleteMap(tag)
    local wasOwner = (tag == H.owner)
    H._candidates[tag] = nil
    elect()
    if not wasOwner then return end
    H.isOpen = false
    H._hidHud = false   -- the mission and its HUD are going away; nothing to restore
    H.releaseGlyphs()
    if H._bg ~= nil and delete ~= nil then delete(H._bg) end
    H._bg = nil
    H._bgTried = nil
    H._sections = nil
    -- _lastCount is a LOG DEDUPE counter, not state. Left set, the "toggle
    -- registered" line, the only proof the toggle is reachable, is suppressed for
    -- every savegame after the first in a session.
    H._lastCount = nil
    H._lastToggleMs = nil
    H._drewSinceOpen = nil
    H._warnedNoReg = nil
    H._warnedNoGlyph = nil
    H._warnedNoRemove = nil
    -- _warnedNoDraw is deliberately NOT reset: it is a code shape problem, not a
    -- per map one, and re-warning every map would be spam.
end
