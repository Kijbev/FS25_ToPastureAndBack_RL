-- Copyright (C) 2026 Kijbev
-- This file is part of FS25_ToPastureAndBack_RL (To Pasture And Back, RL edition).
-- Licensed under the GNU General Public License v3.0 or later.
-- See the LICENSE file shipped with this mod, or https://www.gnu.org/licenses/gpl-3.0.html
--[[
    PendingBarnLockEvent - Multiplayer event for TPAB pending-grazing barn locks.

    Sent when a player adds (lock=true) or removes (lock=false) a pending
    grazing for a given barn. All peers track these locks so the second
    player who opens the AnimalScreen for the same barn gets rejected at
    the source rather than racing to RCtrl+G.

    Lifecycle:
    - Lock broadcast when startPendingGrazingForBarn succeeds locally
    - Unlock broadcast when clearPendingGrazings runs (RCtrl+N cancel)
    - Lock auto-released by all peers in executeGrazingFromEvent when the
      pending becomes an active grazing session (the session takes over as
      authoritative state, its barnPlaceable match handles duplicate sends).

    The barn is identified by world (X, Z) coordinates of its husbandry
    navigationNode, rounded to the nearest meter for a stable cross-peer key.

    2026-06-23: a LOCK may carry an optional fieldOrigin (the pasture the herd
    was relocated FROM). The server stashes it with the lock so that, if the
    pocketing player disconnects, the server re-deploys the herd back to that
    field instead of just restoring it to the barn. Barn pickups carry no
    fieldOrigin and restore to the barn on disconnect.
]]

PendingBarnLockEvent = {}
local PendingBarnLockEvent_mt = Class(PendingBarnLockEvent, Event)

InitEventClass(PendingBarnLockEvent, "PendingBarnLockEvent")

function PendingBarnLockEvent.emptyNew()
    local self = Event.new(PendingBarnLockEvent_mt)
    return self
end

function PendingBarnLockEvent.new(barnX, barnZ, barnName, playerName, isLock, fieldOrigin)
    local self = PendingBarnLockEvent.emptyNew()
    self.barnX = barnX or 0
    self.barnZ = barnZ or 0
    self.barnName = barnName or ""
    self.playerName = playerName or ""
    self.isLock = isLock == true
    -- Only a lock carries a fieldOrigin, and only for a field relocate.
    if self.isLock and type(fieldOrigin) == "table" and fieldOrigin.x ~= nil then
        self.fieldOrigin = fieldOrigin
    else
        self.fieldOrigin = nil
    end
    return self
end

function PendingBarnLockEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.barnX)
    streamWriteFloat32(streamId, self.barnZ)
    streamWriteString(streamId, self.barnName)
    streamWriteString(streamId, self.playerName)
    streamWriteBool(streamId, self.isLock)
    local fo = self.fieldOrigin
    if fo ~= nil then
        streamWriteBool(streamId, true)
        streamWriteString(streamId, fo.animalType or "")
        streamWriteFloat32(streamId, fo.x or 0)
        streamWriteFloat32(streamId, fo.y or 0)
        streamWriteFloat32(streamId, fo.z or 0)
        streamWriteFloat32(streamId, fo.radius or 0)
        streamWriteInt32(streamId, fo.farmlandId or 0)
        streamWriteInt32(streamId, fo.animalCount or 0)
        streamWriteInt32(streamId, fo.animalAge or 36)
        streamWriteBool(streamId, fo.isPastureDestination or false)
        streamWriteString(streamId, fo.pastureDestName or "")
        local contour = fo.fieldContour
        if type(contour) == "table" then
            streamWriteInt32(streamId, #contour)
            for _, cp in ipairs(contour) do
                streamWriteFloat32(streamId, cp.x)
                streamWriteFloat32(streamId, cp.z)
            end
        else
            streamWriteInt32(streamId, 0)
        end
    else
        streamWriteBool(streamId, false)
    end
end

function PendingBarnLockEvent:readStream(streamId, connection)
    self.barnX = streamReadFloat32(streamId)
    self.barnZ = streamReadFloat32(streamId)
    self.barnName = streamReadString(streamId)
    self.playerName = streamReadString(streamId)
    self.isLock = streamReadBool(streamId)
    if streamReadBool(streamId) then
        local fo = {}
        local at = streamReadString(streamId)
        fo.animalType = (at ~= "") and at or nil
        fo.x = streamReadFloat32(streamId)
        fo.y = streamReadFloat32(streamId)
        fo.z = streamReadFloat32(streamId)
        fo.radius = streamReadFloat32(streamId)
        fo.farmlandId = streamReadInt32(streamId)
        fo.animalCount = streamReadInt32(streamId)
        fo.animalAge = streamReadInt32(streamId)
        fo.isPastureDestination = streamReadBool(streamId)
        local pdn = streamReadString(streamId)
        fo.pastureDestName = (pdn ~= "") and pdn or nil
        local cc = streamReadInt32(streamId)
        if cc > 0 then
            fo.fieldContour = {}
            for i = 1, cc do
                local cx = streamReadFloat32(streamId)
                local cz = streamReadFloat32(streamId)
                table.insert(fo.fieldContour, { x = cx, z = cz })
            end
        end
        self.fieldOrigin = fo
    else
        self.fieldOrigin = nil
    end
    self:run(connection)
end

function PendingBarnLockEvent:run(connection)
    if connection ~= nil and not connection:getIsServer() then
        -- Server received from a client: execute locally and broadcast to all clients
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] PendingBarnLockEvent from client (lock=%s) for %s by %s",
            tostring(self.isLock), self.barnName, self.playerName)
        g_server:broadcastEvent(PendingBarnLockEvent.new(self.barnX, self.barnZ, self.barnName, self.playerName, self.isLock, self.fieldOrigin))
        ToPastureAndBack_RL.applyPendingBarnLock(self.barnX, self.barnZ, self.barnName, self.playerName, self.isLock, self.fieldOrigin)
        return
    end

    if connection ~= nil then
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Client] PendingBarnLockEvent received (lock=%s) for %s by %s",
            tostring(self.isLock), self.barnName, self.playerName)
    else
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server-local] PendingBarnLockEvent executing (lock=%s) for %s by %s",
            tostring(self.isLock), self.barnName, self.playerName)
    end
    ToPastureAndBack_RL.applyPendingBarnLock(self.barnX, self.barnZ, self.barnName, self.playerName, self.isLock, self.fieldOrigin)
end
