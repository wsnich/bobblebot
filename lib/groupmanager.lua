-- Raid/group formation: save/load raid config, group invites.
-- LoadRaid runs the full sequence with mq.delay() between steps (blocking).

local mq = require('mq')
local botconfig = require('lib.config')
local state = require('lib.state')

local M = {}

-- Do a single invite (one member).
local function doOneInvite(groupldr, raidmember, grptype)
    local myid = mq.TLO.Me.ID() or 0
    local groupldrspawnid = mq.TLO.Spawn('pc =' .. groupldr).ID() or 0
    local spawnid = mq.TLO.Spawn('pc =' .. raidmember).ID() or 0
    if (grptype == 'group' or spawnid > 0) and groupldrspawnid ~= myid then
        mq.cmdf('/rc %s /inv %s', groupldr, raidmember)
    elseif spawnid > 0 and groupldrspawnid == myid then
        mq.cmdf('/inv %s', raidmember)
    elseif grptype == 'raid' then
        printf("\ayCZBot:\ax\ar%s's\ax group member \ar%s\ax is not in the zone, skipping", groupldr, raidmember)
    end
end

function M.GroupInvite(groupldr, groupmembers, grptype)
    local myid = mq.TLO.Me.ID() or 0
    local groupldrspawnid = mq.TLO.Spawn('pc =' .. groupldr).ID() or 0
    for raidmember, _ in pairs(groupmembers) do
        doOneInvite(groupldr, raidmember, grptype)
    end
end

function M.SaveRaid(raidname)
    local raidmembers = mq.TLO.Raid.Members() or 0
    if raidmembers == 0 then
        printf('\ayCZBot:\ax Not in a raid, no raid to save')
        return
    end
    if not raidname or raidname == '' then
        printf('\ayCZBot:\ax Noname given, cant save raid (/cz raid save raidname)')
        return
    end
    printf('\ayCZBot:\ax saving raidconfig \ag%s\ax', raidname)
    local raidSnapshot = { leaders = {}, groups = {} }
    for i = 1, raidmembers do
        local raidmember = mq.TLO.Raid.Member(i)() or false
        local groupldr = mq.TLO.Raid.Member(i).GroupLeader() or false
        local groupnum = mq.TLO.Raid.Member(i).Group() or false
        if groupldr and raidmember and groupnum then
            raidSnapshot.leaders[groupnum] = raidmember
        elseif raidmember and groupnum then
            if not raidSnapshot.groups[groupnum] then
                raidSnapshot.groups[groupnum] = {}
                if not raidSnapshot.leaders[groupnum] then
                    raidSnapshot.leaders[groupnum] = raidmember
                end
            end
            raidSnapshot.groups[groupnum][raidmember] = raidmember
        end
    end
    botconfig.mutateCommon(function(common)
        if not common.raidlist then common.raidlist = {} end
        common.raidlist[raidname] = raidSnapshot
    end)
end

function M.LoadRaid(raidname)
    local comkeytable = botconfig.getCommon()
    if not comkeytable.raidlist or not comkeytable.raidlist[raidname] then
        printf('no raid named %s found on this pc', raidname)
        return
    end
    printf('\ayCZBot:\ax Loading raid setup \ag%s\ax', raidname)
    state.getRunconfig().statusMessage = string.format('Loading raid: %s', raidname)
    local raidmembers = mq.TLO.Raid.Members() or 0
    local myid = mq.TLO.Me.ID() or 0
    if raidmembers and raidmembers > 0 then mq.cmd('/raiddisband') end
    for disbanditer = 1, 12 do
        local groupldr = comkeytable.raidlist[raidname].leaders[disbanditer] or false
        if groupldr then
            mq.cmdf('/rc %s /squelch /multiline ; /disband ; /raiddisband', groupldr)
        end
        if comkeytable.raidlist[raidname].groups[disbanditer] then
            for raidmember, _ in pairs(comkeytable.raidlist[raidname].groups[disbanditer]) do
                mq.cmdf('/rc %s /squelch /multiline ; /disband ; /raiddisband', raidmember)
            end
        end
    end
    state.getRunconfig().statusMessage = string.format('Loading raid: %s (waiting after disband)', raidname)
    mq.delay(500)
    state.getRunconfig().statusMessage = string.format('Loading raid: %s (inviting)', raidname)
    local actions = {}
    for i = 1, 12 do
        local groupldr = comkeytable.raidlist[raidname].leaders[i] or false
        local groups = comkeytable.raidlist[raidname].groups[i] or {}
        if groupldr then
            for raidmember, _ in pairs(groups) do
                actions[#actions + 1] = { type = 'invite', groupldr = groupldr, raidmember = raidmember, grptype = 'raid' }
            end
            actions[#actions + 1] = { type = 'raidinv', groupldr = groupldr }
        end
    end
    for idx = 1, #actions do
        local a = actions[idx]
        if a.type == 'invite' then
            doOneInvite(a.groupldr, a.raidmember, a.grptype)
        elseif a.type == 'raidinv' then
            local groupldrspawnid = mq.TLO.Spawn('pc =' .. a.groupldr).ID() or 0
            if groupldrspawnid > 0 and groupldrspawnid ~= myid then
                mq.cmdf('/raidinv %s', a.groupldr)
            elseif groupldrspawnid ~= myid then
                printf('\ayCZBot:\axGroup Leader \ar%s is not in zone, skipping group', a.groupldr)
            end
        end
        mq.delay(50)
    end
    state.getRunconfig().statusMessage = ''
end

return M
