-- =========================================================================
-- KijbevMessages, the shared message stack (2026-10-11)
--
-- Every Kijbev mod draws its own on-screen messages at the player's chosen position (lower third,
-- middle, top). Without this module two mods' messages at the same position landed on top of each
-- other. With it they stack the way the game's own WarningDisplay stacks its warnings:
--   * the NEWEST message takes the chosen spot;
--   * older messages from other mods move out of its way, never past the screen edge:
--     top and middle push older messages DOWN, the lower third pushes them UP (clear of the HUD);
--   * v3 (2026-10-14): messages stack WITHIN a mod too. Every message is its own block
--     (tag "<MOD>#<seq>"), kept in the mod's own list through M.push: a new message with the SAME
--     TOPIC replaces the older one (so "AWD on" and "AWD off" never stand together), at most
--     LINES_PER_MOD messages per mod (the oldest leaves first), each with its own reading time.
--     A topic defaults to the text itself, so pressing the same refused key twice refreshes one line;
--   * a live countdown is a message whose text is rebuilt every frame (entry.textFn);
--   * a moved message glides over SLIDE_MS instead of jumping, so it stays readable;
--   * every block reports its real extent (font size, HUD scale, line count, background box).
-- The game's own blinking warning (warning style "FS25 default") is not part of this stack; the
-- game stacks those itself in its own spot.
--
-- This exact file is EMBEDDED in every Kijbev mod. The newest copy installs itself into the real
-- global table; an equal or older copy stands down. BUMP OUR_VERSION ON EVERY EDIT TO THIS FILE.
-- =========================================================================

local OUR_VERSION = 5   -- v5 (2026-10-24): M.wrapLines, timed messages wrap at the game's warning measure

-- Shared through the REAL global table (each FS25 mod runs in its own environment whose
-- metatable __index is the real global table; see KijbevHelp.lua for the full story).
local KJ_REALG = _G
do
    local mt = getmetatable(_G)
    if type(mt) == "table" and type(mt.__index) == "table" then KJ_REALG = mt.__index end
end

local prev = KJ_REALG.KijbevMessages
if prev ~= nil and (prev.VERSION or 0) >= OUR_VERSION then
    return
end

local M = { VERSION = OUR_VERSION }
M._entries = (prev ~= nil and prev._entries) or {}   -- [tag] = entry, carried over from an older copy

M.GAP = 0.006        -- normalized screen height between two stacked messages
M.SLIDE_MS = 120     -- glide time when a message moves to make room
M.STALE_FRAMES = 2   -- an entry not drawn for this many frames has timed out and frees its space
M._frameNo = (prev ~= nil and prev._frameNo) or 0
M._lastNow = (prev ~= nil and prev._lastNow) or nil
M.LINES_PER_MOD = 3  -- messages one mod may show at once (2026-10-14); the oldest leaves first
M._seq = (prev ~= nil and prev._seq) or 0
M._subAt = (prev ~= nil and prev._subAt) or nil
M._sub = (prev ~= nil and prev._sub) or 0

--- The stack tag of one message: "<PREFIX>#<seq>", fixed for the message's life.
function M.blockTag(prefix, entry)
    if type(entry) ~= "table" then return tostring(prefix) end
    if entry._tag == nil then entry._tag = tostring(prefix) .. "#" .. tostring(entry.seq or 0) end
    return entry._tag
end

-- A message that leaves its list frees its stack slot AT ONCE (review 2026-10-14): left to the
-- stale pruning, its slot lingered two frames and every older block jumped out and glided back.
local function releaseEntry(e)
    if type(e) == "table" and e._tag ~= nil then M._entries[e._tag] = nil end
end

--- Adds a message to a mod's own list (v3). entry = { text, remaining (ms), topic?, textFn?, ... }.
--- The topic defaults to the text. An older message with the same topic leaves the list, the new
--- one is appended as the newest, and the oldest leave until at most `cap` (LINES_PER_MOD) remain;
--- a live countdown (textFn) is the last to be pushed out, so a prompt stays while it can be answered.
--- Sets entry.seq (unique, for the block tag) and entry.stackAt (the stack order: posted time plus a
--- per-frame sub-counter, so messages posted in one frame keep their order).
function M.push(list, entry, cap)
    if type(list) ~= "table" or type(entry) ~= "table" then return entry end
    if entry.topic == nil then entry.topic = entry.text end
    for i = #list, 1, -1 do
        if list[i].topic == entry.topic then releaseEntry(table.remove(list, i)) end
    end
    M._seq = M._seq + 1
    entry.seq = M._seq
    entry.posted = entry.posted or g_time or 0
    if entry.posted ~= M._subAt then M._subAt, M._sub = entry.posted, 0 end
    M._sub = M._sub + 1
    entry.stackAt = entry.posted + M._sub * 0.0001
    table.insert(list, entry)
    local c = cap or M.LINES_PER_MOD
    while #list > c do
        local victim = 1
        for i = 1, #list - 1 do       -- the oldest that is not a live countdown (never the new one)
            if type(list[i].textFn) ~= "function" then victim = i break end
        end
        releaseEntry(table.remove(list, victim))
    end
    return entry
end

--- Removes every message with this topic (a countdown that was answered, a state that ended).
function M.dropTopic(list, topic)
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do
        if list[i].topic == topic then releaseEntry(table.remove(list, i)) end
    end
end

--- Counts every message down by dt (ms) and drops the expired ones.
function M.tick(list, dt)
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do
        local e = list[i]
        e.remaining = (e.remaining or 0) - (dt or 0)
        if e.remaining <= 0 then releaseEntry(table.remove(list, i)) end
    end
end

--- The text to draw for a message this frame: a countdown's live text, else its fixed text.
function M.textOf(entry)
    if type(entry) ~= "table" then return "" end
    if type(entry.textFn) == "function" then
        local secs = math.max(1, math.ceil((entry.remaining or 0) / 1000))
        local live = entry.textFn(secs)
        if type(live) == "string" then return live end
    end
    return entry.text or ""
end

--- Where to draw this mod's message block this frame.
-- tag      the mod's short tag ("TT", "UBW", "TPAB", ...), one block per tag
-- anchor   "lower", "middle" or "top" (the player's position setting)
-- baseY    the normalized y of that anchor for the block's FIRST text baseline
-- above    extent of the block above its first baseline (text plus background box)
-- below    extent below its first baseline (further lines plus the box under the last line)
-- postedAt when this message was posted (g_time at the time); a new value means a new message
-- Returns the y for the block's first baseline. Lines further down are drawn below it as before.
function M.place(tag, anchor, baseY, above, below, postedAt)
    local now = g_time or 0
    -- Frames are counted by g_time changing: every mod draws at the same g_time within one frame.
    -- Pruning by frames, not wall time, so a long frame (autosave, loading a vehicle) cannot drop
    -- the other mods' entries and snap a message onto another (review 2026-10-11).
    if now ~= M._lastNow then
        M._lastNow = now
        M._frameNo = M._frameNo + 1
    end
    local e = M._entries[tag]
    if e == nil then
        e = {}
        M._entries[tag] = e
    end
    if e.postedAt ~= (postedAt or 0) or e.anchor ~= anchor then
        e.y = nil    -- a new message (or a moved anchor) starts where it belongs, no slide
    end
    e.anchor, e.baseY, e.above, e.below, e.postedAt, e.frame = anchor, baseY, above or 0, below or 0, postedAt or 0, M._frameNo

    local list = {}
    for t, x in pairs(M._entries) do
        if M._frameNo - (x.frame or -1e9) > M.STALE_FRAMES then
            M._entries[t] = nil
        elseif x.anchor == anchor then
            table.insert(list, { tag = t, e = x })
        end
    end
    -- newest first; ties broken by tag so every copy and every frame agree on the order
    table.sort(list, function(a, b)
        if a.e.postedAt ~= b.e.postedAt then return a.e.postedAt > b.e.postedAt end
        return a.tag < b.tag
    end)

    local up = (anchor == "lower")
    local target = baseY
    local cur = list[1] ~= nil and list[1].e.baseY or baseY
    for i, item in ipairs(list) do
        if i > 1 then
            local newer = list[i - 1].e
            if up then
                cur = cur + newer.above + M.GAP + item.e.below
            else
                cur = cur - newer.below - M.GAP - item.e.above
            end
        end
        if item.tag == tag then
            target = cur
            break
        end
    end

    local last = e.lastDrawAt or now
    e.lastDrawAt = now
    if e.y == nil then
        e.y = target
    else
        local k = 1
        -- about 95 percent of the way in SLIDE_MS whatever the frame rate
        if M.SLIDE_MS > 0 then k = 1 - math.exp(-math.max(0, now - last) * 3 / M.SLIDE_MS) end
        e.y = e.y + (target - e.y) * k
        if math.abs(target - e.y) < 0.0005 then e.y = target end
    end
    return e.y
end

--- Frees a mod's space at once (optional; an entry not drawn for STALE_FRAMES frees itself).
function M.release(tag)
    M._entries[tag] = nil
end

--- The block extent for a message drawn with the Kijbev message style: centered bold text of the
--- given font size, `lines` lines spaced `lineSpacing` apart, with or without a background box.
function M.extent(fontSize, lines, lineSpacing)
    local n = math.max(1, lines or 1)
    local ls = lineSpacing or fontSize * 1.4
    return fontSize * 1.07, (n - 1) * ls + fontSize * 0.28
end

--- v5 (2026-10-24, Kijbev Mod Standard 1.8): the wrap width for a TIMED message at this font size.
--- The game's own warning wraps 16 px text at 600 px (WarningDisplay.lua 55-56). Scaling that with the
--- font keeps the same number of characters per line at every message size and HUD scale (about 60 to 70),
--- the reading measure. Converted from height units (font size) to width units by the screen aspect,
--- and never wider than 0.9 of the screen. Persistent panels do NOT use this; they are laid out by hand.
M.WRAP_PX = 600
M.WRAP_TEXT_PX = 16
function M.wrapWidth(fontSize)
    local sw, sh = g_screenWidth, g_screenHeight
    local hOverW = (type(sw) == "number" and type(sh) == "number" and sw > 0) and (sh / sw) or (9 / 16)
    return math.min(0.9, (fontSize or 0.02) * (M.WRAP_PX / M.WRAP_TEXT_PX) * hOverW)
end

--- v5: split a timed message into the lines to draw. Hand-set breaks (\n) stay, empty lines are dropped,
--- each line breaks at word boundaries at M.wrapWidth(fontSize). A line's leading spaces (an indented
--- list row) are kept on its continuation lines too. Measured with getTextWidth in the CALLER'S current
--- text state, so call it after setTextBold, exactly where the lines are drawn.
--- @return table lines (at least one entry when the text has any visible character)
function M.wrapLines(text, fontSize)
    local lines = {}
    if type(text) ~= "string" then return lines end
    local maxW = M.wrapWidth(fontSize)
    local canMeasure = type(getTextWidth) == "function"
    for srcLine in string.gmatch(text .. "\n", "(.-)\n") do
        if string.find(srcLine, "%S") ~= nil then
            local indent = string.match(srcLine, "^%s*") or ""
            local cur = nil
            for word in string.gmatch(srcLine, "%S+") do
                local trial = (cur == nil) and (indent .. word) or (cur .. " " .. word)
                if cur ~= nil and canMeasure and getTextWidth(fontSize, trial) > maxW then
                    table.insert(lines, cur)
                    cur = indent .. word
                else
                    cur = trial
                end
            end
            if cur ~= nil then table.insert(lines, cur) end
        end
    end
    return lines
end

KJ_REALG.KijbevMessages = M
