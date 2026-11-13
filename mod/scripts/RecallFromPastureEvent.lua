-- Copyright (C) 2026 Kijbev
-- This file is part of FS25_ToPastureAndBack_RL (To Pasture And Back, RL edition).
-- Licensed under the GNU General Public License v3.0 or later.
-- See the LICENSE file shipped with this mod, or https://www.gnu.org/licenses/gpl-3.0.html
--[[
    RecallFromPastureEvent - Multiplayer event for TPAB-RL grazing session recall.
    Sent when a player recalls herds (RCtrl+K), curfew triggers at 22:00, or
    move-herd recalls a single session to set up a pickup.

    Two flags distinguish the message flow:
    - suppressMessage: when true, the per-session "your herd is back at <barn>"
      notification is silenced (used by curfew + move-herd to avoid spamming).
    - isCurfewFlow: when true AND suppressMessage AND count>0, the herdsman
      umbrella message ("The herdsman has returned all animals from pasture
      for the night.") is shown on every peer. Set by the 22:00 curfew flow
      only. Move-herd uses suppressMessage=true, isCurfewFlow=false so it can
      show its own composite "picked up from pasture" message.

    Server broadcasts to all clients so each independently restores barn
    visuals and destroys the pasture husbandry.
]]

RecallFromPastureEvent = {}
local RecallFromPastureEvent_mt = Class(RecallFromPastureEvent, Event)

InitEventClass(RecallFromPastureEvent, "RecallFromPastureEvent")

function RecallFromPastureEvent.emptyNew()
    local self = Event.new(RecallFromPastureEvent_mt)
    return self
end

function RecallFromPastureEvent.new(sessionIds, suppressMessage, isCurfewFlow, keepBarnSuppressed)
    local self = RecallFromPastureEvent.emptyNew()
    self.sessionIds = sessionIds  -- comma-separated string of session IDs, or "ALL"
    self.suppressMessage = suppressMessage == true  -- default false
    self.isCurfewFlow = isCurfewFlow == true        -- default false
    self.keepBarnSuppressed = keepBarnSuppressed == true  -- relocate: don't refill barn
    return self
end

function RecallFromPastureEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.sessionIds)
    streamWriteBool(streamId, self.suppressMessage)
    streamWriteBool(streamId, self.isCurfewFlow)
    streamWriteBool(streamId, self.keepBarnSuppressed)
end

function RecallFromPastureEvent:readStream(streamId, connection)
    self.sessionIds = streamReadString(streamId)
    self.suppressMessage = streamReadBool(streamId)
    self.isCurfewFlow = streamReadBool(streamId)
    self.keepBarnSuppressed = streamReadBool(streamId)
    self:run(connection)
end

function RecallFromPastureEvent:run(connection)
    if connection ~= nil and not connection:getIsServer() then
        -- Server received from a client: execute locally and broadcast
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] RecallFromPastureEvent from client, executing + broadcasting (isCurfew=%s)",
            tostring(self.isCurfewFlow))
        -- Own-farm rule on the server (2026-10-11): a client recalls only its own farm's herds.
        local ids = self.sessionIds
        if ToPastureAndBack_RL.filterIdsForConnection ~= nil then
            ids = ToPastureAndBack_RL.filterIdsForConnection(self.sessionIds, connection)
            if ids ~= self.sessionIds then
                ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] recall narrowed to the sender's farm: '%s' -> '%s'", tostring(self.sessionIds), tostring(ids))
            end
            if ids == "" then return end
        end
        g_server:broadcastEvent(RecallFromPastureEvent.new(ids, self.suppressMessage, self.isCurfewFlow, self.keepBarnSuppressed))
        ToPastureAndBack_RL.executeRecallFromEvent(ids, self.suppressMessage, self.isCurfewFlow, self.keepBarnSuppressed)
        return
    end

    if connection ~= nil then
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Client] RecallFromPastureEvent received, recalling: %s (suppressMsg=%s, isCurfew=%s)",
            self.sessionIds, tostring(self.suppressMessage), tostring(self.isCurfewFlow))
    else
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server-local] RecallFromPastureEvent executing, recalling: %s (suppressMsg=%s, isCurfew=%s)",
            self.sessionIds, tostring(self.suppressMessage), tostring(self.isCurfewFlow))
    end
    ToPastureAndBack_RL.executeRecallFromEvent(self.sessionIds, self.suppressMessage, self.isCurfewFlow, self.keepBarnSuppressed)
end
