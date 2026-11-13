-- Copyright (C) 2026 Kijbev
-- This file is part of FS25_ToPastureAndBack_RL (To Pasture And Back, RL edition).
-- Licensed under the GNU General Public License v3.0 or later.
-- See the LICENSE file shipped with this mod, or https://www.gnu.org/licenses/gpl-3.0.html
--[[
    RemovePasturePointEvent - Multiplayer event for TPAB pasture point removal.
    Sent when a player removes a pasture marker (RCtrl+H) or removes all (RCtrl+N, the cancel action).
    Server broadcasts to all clients so each removes the matching point(s).
]]

RemovePasturePointEvent = {}
local RemovePasturePointEvent_mt = Class(RemovePasturePointEvent, Event)

InitEventClass(RemovePasturePointEvent, "RemovePasturePointEvent")

function RemovePasturePointEvent.emptyNew()
    local self = Event.new(RemovePasturePointEvent_mt)
    return self
end

--- Create a new event.
-- @param pasturePointId number ID of the point to remove, or -1 for "remove all"
function RemovePasturePointEvent.new(pasturePointId)
    local self = RemovePasturePointEvent.emptyNew()
    self.pasturePointId = pasturePointId
    return self
end

function RemovePasturePointEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.pasturePointId)
end

function RemovePasturePointEvent:readStream(streamId, connection)
    self.pasturePointId = streamReadInt32(streamId)
    self:run(connection)
end

function RemovePasturePointEvent:run(connection)
    -- No code path in this version sends this event (recall uses RecallFromPastureEvent), so every
    -- peer ignores it (sweep 2026-10-27). It stays registered so the event list, and with it the
    -- network ids of the other events, is unchanged between versions.
    ToPastureAndBack_RL.dbgLog("TPAB-RL: RemovePasturePointEvent ignored (pointId=%s), no sender in this version", tostring(self.pasturePointId))
    if true then return end
    if connection ~= nil and not connection:getIsServer() then
        -- Server received from a client: execute locally and broadcast
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] RemovePasturePointEvent from client, executing + broadcasting (pointId=%d)", self.pasturePointId)
        -- Own-farm rule on the server (2026-10-11): a client calls back only its own farm's herds.
        local farmId = ToPastureAndBack_RL.farmIdForConnection ~= nil and ToPastureAndBack_RL.farmIdForConnection(connection) or nil
        if farmId ~= nil then
            local function pointFarm(pointId)
                for _, session in ipairs(ToPastureAndBack_RL.grazingSessions or {}) do
                    if session.pasturePoint ~= nil and session.pasturePoint.id == pointId then
                        return ToPastureAndBack_RL.farmOfSession(session)
                    end
                end
                return nil
            end
            if self.pasturePointId == -1 then
                local own, all = {}, true
                for _, session in ipairs(ToPastureAndBack_RL.grazingSessions or {}) do
                    if ToPastureAndBack_RL.farmOfSession(session) == farmId then
                        if session.pasturePoint ~= nil and session.pasturePoint.id ~= nil then table.insert(own, session.pasturePoint.id) end
                    else
                        all = false
                    end
                end
                if not all then
                    ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] call back all narrowed to the sender's farm: %d point(s)", #own)
                    for _, pid in ipairs(own) do
                        g_server:broadcastEvent(RemovePasturePointEvent.new(pid))
                        ToPastureAndBack_RL.executeRemovePastureFromEvent(pid)
                    end
                    return
                end
            else
                local pf = pointFarm(self.pasturePointId)
                if pf ~= nil and pf ~= farmId then
                    ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] call back of point %d refused, it belongs to farm %s", self.pasturePointId, tostring(pf))
                    return
                end
            end
        end
        g_server:broadcastEvent(RemovePasturePointEvent.new(self.pasturePointId))
        ToPastureAndBack_RL.executeRemovePastureFromEvent(self.pasturePointId)
        return
    end

    if connection ~= nil then
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Client] RemovePasturePointEvent received (pointId=%d)", self.pasturePointId)
    else
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server-local] RemovePasturePointEvent executing (pointId=%d)", self.pasturePointId)
    end
    ToPastureAndBack_RL.executeRemovePastureFromEvent(self.pasturePointId)
end
