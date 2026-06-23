-- Follow logic: StartFollow(name) and registerEvents() for group/raid chat "follow".
-- Option C (chchain-style): module owns event registration and core behavior.
-- Used by lib/commands (cmd_follow) and botevents (follow.registerEvents only).

local mq = require('mq')
local state = require('lib.state')
local botmove = require('botmove')
local botpull = require('botpull')
local charinfo = require("plugin.charinfo")

local follow = {}

--- Stop follow and travel mode; clear movement state. No-op if neither is active.
---@param reason string|nil e.g. death, command, gui
---@return boolean true if follow or travel was cleared
function follow.StopFollow(reason)
    local rc = state.getRunconfig()
    local hadFollow = (rc.followid and rc.followid > 0) or (rc.followname and rc.followname ~= '')
    local wasTravelMode = rc.travelMode == true
    if not hadFollow and not wasTravelMode then return false end

    botmove.ClearFollowMovementState()
    rc.followid = 0
    rc.followname = ''
    rc.travelMode = false
    if wasTravelMode then
        local ok, bardtwist = pcall(require, 'lib.bardtwist')
        if ok and bardtwist and bardtwist.EnsureDefaultTwistRunning then
            bardtwist.EnsureDefaultTwistRunning()
        end
    end
    if reason == 'death' then
        printf('\aybobblebot:\ax\arFollow OFF (death)\ax')
    end
    return true
end

function follow.StartFollow(name)
    if not mq.TLO.Navigation.MeshLoaded() then
        mq.cmd('/echo No Mesh for this zone, cannot use CZFollow+!!')
        return false
    end
    local spawn = name and mq.TLO.Spawn('=' .. name)
    if not spawn then return end
    local rc = state.getRunconfig()
    local campSet = rc.campstatus or (rc.makecamp and (rc.makecamp.x or rc.makecamp.y or rc.makecamp.z))
    if campSet then botmove.MakeCamp('off') end
    botpull.DisablePull('follow')
    local followId = spawn.ID()
    if not followId then return end
    rc.followid = followId
    rc.followname = name
    rc.stucktimer = mq.gettime() + 60000
    printf('\aybobblebot:\ax\auFollowing\ax ON %s', spawn.CleanName())
end

--- Re-arm follow/travel after zone: invalidate stale spawn id, keep followname/travelMode, kick nav when ready.
function follow.ResumeAfterZone()
    local rc = state.getRunconfig()
    local active = (rc.followname and rc.followname ~= '') or rc.travelMode == true
    if not active then return end

    botmove.ClearFollowMovementState()
    rc.followid = 0
    rc.stucktimer = mq.gettime() + 60000
    botpull.DisablePull('follow')

    if rc.travelMode then
        local ok, bardtwist = pcall(require, 'lib.bardtwist')
        if ok and bardtwist and bardtwist.EnsureDefaultTwistRunning then
            bardtwist.EnsureDefaultTwistRunning()
        end
    end

    if mq.TLO.Navigation.MeshLoaded() and rc.followname and rc.followname ~= '' then
        local spawn = mq.TLO.Spawn('=' .. rc.followname)
        if spawn and spawn.ID() then
            rc.followid = spawn.ID()
            botmove.FollowCall()
        end
    end
end

local function event_FollowChat(line, speaker)
    if not charinfo.GetInfo(speaker) then return end
    follow.StartFollow(speaker)
end

function follow.registerEvents()
    mq.event('FollowChat', "#1# tells the #*#, 'follow#*#", event_FollowChat)
end

return follow
