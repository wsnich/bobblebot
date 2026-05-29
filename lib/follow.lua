-- Follow logic: StartFollow(name) and registerEvents() for group/raid chat "follow".
-- Option C (chchain-style): module owns event registration and core behavior.
-- Used by lib/commands (cmd_follow) and botevents (follow.registerEvents only).

local mq = require('mq')
local state = require('lib.state')
local botmove = require('botmove')
local botpull = require('botpull')
local charinfo = require("plugin.charinfo")

local follow = {}

function follow.StartFollow(name)
    if not mq.TLO.Navigation.MeshLoaded then
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
    printf('\ayCZBot:\ax\auFollowing\ax ON %s', spawn.CleanName())
end

local function event_FollowChat(line, speaker)
    if not charinfo.GetInfo(speaker) then return end
    follow.StartFollow(speaker)
end

function follow.registerEvents()
    mq.event('FollowChat', "#1# tells the #*#, 'follow#*#", event_FollowChat)
end

return follow
