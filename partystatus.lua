--[[
    partystatus.lua

    Real-time status-icon reading for early-loss correction, ported from
    focustarget.lua's get_status_ids (used elsewhere in this environment).
    Without this, an assignment's cell just counts its locally-estimated
    duration down to zero even if the buff actually disappeared early --
    dispelled, resisted off, overwritten by something else occupying the
    same status slot, whatever the cause. This reads what's ACTUALLY on the
    target right now, so BuffTrack can catch that immediately instead of
    waiting out a stale estimate.

    HARD LIMITATION, not fixable from an addon: FFXI only sends status-icon
    data to your client for your own local party (5 members), never for the
    rest of an alliance. GetStatusIds returns an empty set for anyone
    outside your local party -- callers should treat "empty" as "no
    correction data available" and fall back to the pure countdown, not as
    "this target has no buffs."
]]--

local durations = require('durations.include');

--Returns (ids, hasData). ids is a set ({[statusId]=true, ...}) of currently
--active status ids for the given server id. hasData is true only when we
--actually found real data for this target (self, or present in the local
--party's status-icon memory block) -- an empty `ids` with hasData=true
--genuinely means "no active statuses right now", which is different from
--hasData=false ("out of local-party range, we have no idea"). Callers must
--check hasData before treating an absent buff as confirmed missing, or
--every out-of-party assignment would falsely force-expire immediately.
local function GetStatusIds(serverId)
    local ids = {};
    if (serverId == nil) or (serverId == 0) then
        return ids, false;
    end

    local myId = durations:GetDataTracker():GetPlayerId();
    if (serverId == myId) then
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if (player == nil) then
            return ids, false;
        end
        local icons = player:GetStatusIcons();
        for j = 0,31 do
            local v = icons[j + 1];
            if (v ~= nil) and (v ~= 255) and (v > 0) then
                ids[v] = true;
            end
        end
        return ids, true;
    end

    local base_ptr = AshitaCore:GetPointerManager():Get('party.statusicons');
    if (base_ptr == nil) or (base_ptr == 0) then
        return ids, false;
    end
    base_ptr = ashita.memory.read_uint32(base_ptr);
    if (base_ptr == 0) then
        return ids, false;
    end

    for i = 0,4 do
        local member_ptr = base_ptr + (0x30 * i);
        local player_id = ashita.memory.read_uint32(member_ptr);
        if (player_id == serverId) then
            for j = 0,31 do
                local high_bits = ashita.memory.read_uint8(member_ptr + 8 + math.floor(j / 4));
                local shift = math.fmod(j, 4) * 2;
                high_bits = bit.lshift(bit.band(bit.rshift(high_bits, shift), 0x03), 8);
                local low_bits = ashita.memory.read_uint8(member_ptr + 16 + j);
                local id = high_bits + low_bits;
                if (id ~= 255) and (id > 0) then
                    ids[id] = true;
                end
            end
            return ids, true;
        end
    end

    return ids, false; --out of local-party range: no data, NOT "confirmed empty"
end

local exports = {};
exports.GetStatusIds = GetStatusIds;
return exports;
