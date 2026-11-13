-- Copyright (C) 2026 Kijbev
-- This file is part of FS25_ToPastureAndBack_RL (To Pasture And Back, RL edition).
-- Licensed under the GNU General Public License v3.0 or later.
-- See the LICENSE file shipped with this mod, or https://www.gnu.org/licenses/gpl-3.0.html
--[[
    SendToPastureEvent - Multiplayer event for TPAB grazing session creation.
    Sent when a player confirms a grazing destination (RCtrl+G after validation).
    Server broadcasts to all clients so each independently spawns the visual herd.
]]

SendToPastureEvent = {}
local SendToPastureEvent_mt = Class(SendToPastureEvent, Event)

InitEventClass(SendToPastureEvent, "SendToPastureEvent")

function SendToPastureEvent.emptyNew()
    local self = Event.new(SendToPastureEvent_mt)
    return self
end

function SendToPastureEvent.new(data)
    local self = SendToPastureEvent.emptyNew()
    self.data = data
    return self
end

function SendToPastureEvent:writeStream(streamId, connection)
    -- Barn identification (position-based, barns have no stable network ID)
    streamWriteFloat32(streamId, self.data.barnWorldX)
    streamWriteFloat32(streamId, self.data.barnWorldZ)
    streamWriteString(streamId, self.data.barnName)
    -- Destination
    streamWriteFloat32(streamId, self.data.destX)
    streamWriteFloat32(streamId, self.data.destZ)
    streamWriteFloat32(streamId, self.data.destY)
    streamWriteFloat32(streamId, self.data.fieldRadius)
    -- Polygonal contour (farmland-conforming boundary)
    local contour = self.data.fieldContour
    if contour ~= nil then
        streamWriteInt32(streamId, #contour)
        for _, cp in ipairs(contour) do
            streamWriteFloat32(streamId, cp.x)
            streamWriteFloat32(streamId, cp.z)
        end
    else
        streamWriteInt32(streamId, 0)
    end
    -- Animal info
    streamWriteString(streamId, self.data.animalType)
    streamWriteInt32(streamId, self.data.animalCount)
    streamWriteInt32(streamId, self.data.animalAge)
    streamWriteFloat32(streamId, self.data.durationHours)
    -- Session metadata
    streamWriteInt32(streamId, self.data.farmlandId)
    streamWriteString(streamId, self.data.sessionId)
    streamWriteInt32(streamId, self.data.pasturePointId)
    streamWriteString(streamId, self.data.pasturePointName)
    streamWriteBool(streamId, self.data.isPastureDestination or false)
    if self.data.isPastureDestination then
        streamWriteString(streamId, self.data.pastureDestName or "")
    end
    -- Batch info (mixed-herd umbrella message gating).
    -- Without this, clients have data.batchInfo == nil and fall through to the
    -- per-session message instead of "Your mixed herd is now grazing".
    if self.data.batchInfo ~= nil then
        streamWriteBool(streamId, true)
        streamWriteUInt8(streamId, self.data.batchInfo.size or 1)
        streamWriteUInt8(streamId, self.data.batchInfo.index or 1)
        streamWriteBool(streamId, self.data.batchInfo.isMixed or false)
        streamWriteBool(streamId, self.data.batchInfo.isLast or false)
    else
        streamWriteBool(streamId, false)
    end
    -- 2026-06-22: suppress the young-kept message on field relocates / cancel re-deploys.
    -- Must be serialized; otherwise the client rebuilds data from the wire without it and
    -- shows the message while the host (inline) does not (host/client message divergence).
    streamWriteBool(streamId, self.data.suppressYoungKept or false)
end

function SendToPastureEvent:readStream(streamId, connection)
    self.data = {}
    self.data.barnWorldX = streamReadFloat32(streamId)
    self.data.barnWorldZ = streamReadFloat32(streamId)
    self.data.barnName = streamReadString(streamId)
    self.data.destX = streamReadFloat32(streamId)
    self.data.destZ = streamReadFloat32(streamId)
    self.data.destY = streamReadFloat32(streamId)
    self.data.fieldRadius = streamReadFloat32(streamId)
    -- Polygonal contour
    local contourCount = streamReadInt32(streamId)
    if contourCount > 0 then
        self.data.fieldContour = {}
        for i = 1, contourCount do
            local cx = streamReadFloat32(streamId)
            local cz = streamReadFloat32(streamId)
            table.insert(self.data.fieldContour, { x = cx, z = cz })
        end
    else
        self.data.fieldContour = nil
    end
    self.data.animalType = streamReadString(streamId)
    self.data.animalCount = streamReadInt32(streamId)
    self.data.animalAge = streamReadInt32(streamId)
    self.data.durationHours = streamReadFloat32(streamId)
    self.data.farmlandId = streamReadInt32(streamId)
    self.data.sessionId = streamReadString(streamId)
    self.data.pasturePointId = streamReadInt32(streamId)
    self.data.pasturePointName = streamReadString(streamId)
    self.data.isPastureDestination = streamReadBool(streamId)
    if self.data.isPastureDestination then
        self.data.pastureDestName = streamReadString(streamId)
    end
    -- Batch info (mixed-herd umbrella message gating)
    if streamReadBool(streamId) then
        self.data.batchInfo = {
            size = streamReadUInt8(streamId),
            index = streamReadUInt8(streamId),
            isMixed = streamReadBool(streamId),
            isLast = streamReadBool(streamId),
        }
    end
    self.data.suppressYoungKept = streamReadBool(streamId)

    self:run(connection)
end

function SendToPastureEvent:run(connection)
    -- connection == nil: called directly from server-side sendEvent (local execution)
    -- connection:getIsServer() == false: server received from a client via network
    -- connection:getIsServer() == true: client received from the server via network

    if connection ~= nil and not connection:getIsServer() then
        -- Server received from a client: execute locally and broadcast to all clients
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] SendToPastureEvent from client, executing + broadcasting")
        g_server:broadcastEvent(SendToPastureEvent.new(self.data))
        ToPastureAndBack_RL.executeGrazingFromEvent(self.data)
        return
    end

    -- Either local server execution (connection==nil) or client receiving broadcast
    if connection ~= nil then
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Client] SendToPastureEvent received, executing for session %s", self.data.sessionId)
    else
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server-local] SendToPastureEvent executing for session %s", self.data.sessionId)
    end
    ToPastureAndBack_RL.executeGrazingFromEvent(self.data)
end
