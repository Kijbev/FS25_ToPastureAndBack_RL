-- Copyright (C) 2026 Kijbev
-- This file is part of FS25_ToPastureAndBack_RL (To Pasture And Back, RL edition).
-- Licensed under the GNU General Public License v3.0 or later.
-- See the LICENSE file shipped with this mod, or https://www.gnu.org/licenses/gpl-3.0.html
--[[
    SyncRequestEvent - Multiplayer event for TPAB state synchronization.
    Sent by a client after its barn cache is ready (~frame 350) to request
    the current grazing state from the server. The server responds by sending
    a SendToPastureEvent for each active session directly to the requesting
    client's connection.

    This solves the late-joining client problem: when the host saves and
    reloads, the server reconstructs sessions from XML at frame ~350.
    Clients that connect after this point miss the initial broadcast.
    By requesting a sync after their own init completes, they get the
    current state regardless of when they joined.
]]

SyncRequestEvent = {}
local SyncRequestEvent_mt = Class(SyncRequestEvent, Event)

InitEventClass(SyncRequestEvent, "SyncRequestEvent")

function SyncRequestEvent.emptyNew()
    local self = Event.new(SyncRequestEvent_mt)
    return self
end

function SyncRequestEvent.new()
    local self = SyncRequestEvent.emptyNew()
    return self
end

function SyncRequestEvent:writeStream(streamId, connection)
    -- No payload needed, the request itself is the signal
    streamWriteBool(streamId, true)
end

function SyncRequestEvent:readStream(streamId, connection)
    streamReadBool(streamId)  -- consume the placeholder
    self:run(connection)
end

function SyncRequestEvent:run(connection)
    if connection ~= nil and not connection:getIsServer() then
        -- Server received sync request from a client.
        -- Send the current grazing state directly to this client's connection.
        local sessions = ToPastureAndBack_RL.grazingSessions
        if sessions == nil or #sessions == 0 then
            ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] SyncRequestEvent from client, no active sessions to send")
            return
        end

        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] SyncRequestEvent from client, sending %d active session(s)", #sessions)
        for _, session in ipairs(sessions) do
            if session.spawnState ~= "done" then
                -- Build event data from the live session
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

                -- Send directly to the requesting client (not broadcast).
                -- When the client receives this SendToPastureEvent, its run()
                -- sees connection:getIsServer()==true and calls executeGrazingFromEvent().
                connection:sendEvent(SendToPastureEvent.new(eventData))
                ToPastureAndBack_RL.dbgLog("TPAB-RL: [Server] Sent session %s to requesting client", session.id)
            end
        end
        return
    end

    -- Client should never receive this event (it's client->server only)
    if connection ~= nil then
        ToPastureAndBack_RL.dbgLog("TPAB-RL: [Client] SyncRequestEvent received unexpectedly, ignoring")
    end
end
