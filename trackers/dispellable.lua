--[[
    trackers/dispellable.lua

    §7.2 stretch goal: alert when an ENEMY casts a watch-listed spell/ability
    on itself. Ability-based, not mob-scoped -- any mob, anywhere, casting a
    listed spell/ability triggers it (gSettings.EnemyBuffWatchList).

    Detection reuses the existing 0x028 action-packet pipeline (see
    trackers/assignment.lua) -- "enemy" here just means "the caster is NOT
    currently in your party/alliance roster", nothing more specific.

    No duration data exists for enemy buffs, so unlike trackers/assignment.lua
    there's no countdown-to-zero. Per locked design:
        - No "wears off" detection -- FFXI doesn't send a chat message for
          that, so there's nothing to key off of.
        - Row timer counts UP from first detection instead.
        - Removed when an observed DISPEL message is seen (see
          RemovalActions below -- CONFIRMED live: Dispel = spell id 260,
          removal message 341) OR after MaxDurationSeconds as a safety
          fallback, whichever first.

    Feeds the Watch panel (gWatchPanel -- see alertsgroup.lua's
    NewWatchPanel), rendered as one row per currently-active alert.
]]--

local actionPacket = require('actionpacket');
local assignmentTracker = require('trackers.assignment');

local actionMessages = T{
    --Player spell/ability "landed" messages -- built from the same list
    --trackers/assignment.lua uses for player buff tracking.
    Applied = T{ 100, 115, 205, 230, 266, 280, 319, 420, 421, 424, 425, 667 },
    --Monster TP move "applied a status effect" messages. 186 CONFIRMED live
    --via /bufftrack watchdebug (Worker Crawler's Cocoon). 185/242 are kept
    --as untested extra candidates -- unconfirmed against a live capture on
    --this server, may not apply here; harmless to leave in (an id that
    --never actually occurs just never matches), but 186 is the one with
    --real confirmation.
    MobSkillApplied = T{ 186, 185, 242 },
};

--[[
    Removal-capable actions -- when one of these lands successfully on an
    enemy (message in its Messages set), clear that enemy's active watch
    alerts. CONFIRMED via /bufftrack watchdebug (second capture, corrects
    the first): Jowston casting Dispel on a Worker Crawler produced
    Type=4, Id(17bit)=Param(32bit)=260, message=341, at the exact moment
    the effect was removed. The earlier "Id=270, message=1" note below this
    file previously carried was WRONG -- apparently stale/misremembered
    data that was never actually re-verified against a live capture; this
    second capture is the one to trust (both 17-bit and 32-bit
    interpretations of the id agree on 260, the same cross-check that
    validated Cocoon's id=346 elsewhere in this project).

    Not exhaustive -- only Dispel (spell id 260 on this server) is
    confirmed. Erase or other removal methods would need their own
    /bufftrack watchdebug capture to add here.

    NOTE same limitation as before: removal matches by EnemyServerId only,
    not by which specific buff was removed -- clears every active alert on
    that enemy, since correlating to a specific watch-list ActionId would
    need a per-ability resulting-status-id map this project doesn't have.
]]--
local RemovalActions = T{
    { ActionType = 'Spell', ActionId = 260, Messages = T{ 341 } }, --Dispel, CONFIRMED live (id=260, msg=341 -- see comment above)
};

local function FindRemovalAction(actionType, actionId)
    for _,entry in ipairs(RemovalActions) do
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) then
            return entry;
        end
    end
    return nil;
end

local MaxDurationSeconds = 120;

--[[
    activeByKey[key] where key = "EnemyServerId:ActionId" -- separate
    watch-list entries on the same enemy get separate rows; the same
    watch-list entry recast on a DIFFERENT enemy also gets its own row.
        EnemyServerId(number)
        EnemyName(string)      - resolved once at detection time, cached (see ResolveEnemyName).
        ActionType(string)
        ActionId(number)
        Label(string)
        DetectedAt(number)     - os.clock() value; resets on re-cast.
]]--
local activeByKey = {};

local function BuildActiveKey(enemyServerId, actionId)
    return string.format('%u:%u', enemyServerId, actionId);
end

--[[
    Resolves a server id to its current entity index, then its name, via
    AshitaCore:GetMemoryManager():GetEntity():GetServerId(index). Only
    called once per NEWLY detected alert (see HandleApplied), not every
    frame, so the linear-scan fallback's cost is a non-issue in practice.
]]--
local function GetIndexFromId(id)
    local entMgr = AshitaCore:GetMemoryManager():GetEntity();

    --Shortcut for monsters/static npcs.
    if (bit.band(id, 0x1000000) ~= 0) then
        local index = bit.band(id, 0xFFF);
        if (index >= 0x900) then
            index = index - 0x100;
        end
        if (index < 0x900) and (entMgr:GetServerId(index) == id) then
            return index;
        end
    end

    for i = 1,0x8FF do
        if (entMgr:GetServerId(i) == id) then
            return i;
        end
    end

    return 0;
end

local function ResolveEnemyName(serverId)
    local index = GetIndexFromId(serverId);
    if (index == 0) then
        return nil;
    end
    local ok, entity = pcall(GetEntity, index);
    return (ok and entity) and entity.Name or nil;
end

local function FindWatchEntry(actionType, actionId)
    for _,entry in ipairs(gSettings.EnemyBuffWatchList) do
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) then
            return entry;
        end
    end
    return nil;
end

--[[
    Debug capture mode -- toggled via /bufftrack watchdebug (see
    callbacks.lua). Prints EVERY action from a non-party caster, regardless
    of watch-list membership, Type, or message -- including every action's
    message id, since MobSkillApplied above was itself found this way, not
    from a documented source. Also shows both candidate ID interpretations
    side by side:
        Id(17bit)    - what actionpacket.lua/HandleApplied actually matches
                       against today (proven correct for Type 4 spells).
        Param(32bit) - the same underlying bits read as one 32-bit value
                       instead, for cross-checking a new id against both
                       interpretations before trusting either.
]]--
local debugWatch = false;
local function SetDebug(enabled)
    debugWatch = enabled;
end

local function ResolveDisplayName(serverId, reverseRoster)
    local partyName = reverseRoster[serverId];
    if partyName then
        return partyName;
    end
    return ResolveEnemyName(serverId) or string.format('Unknown[%u]', serverId);
end

--Re-added after the previous cleanup removed 0x29 visibility entirely --
--message=1 on Dispel's own 0x028 packet was inferred from chat-log timing
--during a test where 0x29 wasn't being printed at all, not a confirmed
--correlation. Printing both channels together now so the next real dispel
--either confirms message=1 or reveals the actual trigger is a separate
--0x29 packet instead. Uses reverseRoster too (not just enemy resolution)
--since a 0x29 target could in principle be a party member.
local function PrintDebugMessage(e, reverseRoster)
    local messageId = bit.band(struct.unpack('H', e.data, 0x18 + 1), 0x7FFF);
    local targetId = struct.unpack('L', e.data, 0x08 + 1);
    local buffId = struct.unpack('H', e.data, 0x0C + 1);
    local targetName = ResolveDisplayName(targetId, reverseRoster);
    print(chat.header('BuffTrack') .. chat.message(string.format(
        '[watchdebug] 0x29 target=%s MessageId=%u BuffId=%u',
        targetName, messageId, buffId
    )));
end

--One line per TARGET (not lumped together) so an AOE with different
--messages per target doesn't blur which message belongs to which. Prints
--for both directions now -- an enemy acting (Cocoon) and a PARTY MEMBER
--acting on an enemy (Dispel) -- see the broadened gate below; the original
--enemy-caster-only version missed Dispel entirely since Jowston, the
--caster, is a party member.
local function PrintDebugAction(packet, e, reverseRoster)
    local raw32 = ashita.bits.unpack_be(e.data_raw, 0, 86, 32);
    local casterName = ResolveDisplayName(packet.UserId, reverseRoster);
    for _,target in ipairs(packet.Targets) do
        local targetName = ResolveDisplayName(target.Id, reverseRoster);
        local messages = T{};
        for _,action in ipairs(target.Actions) do
            messages:append(action.Message);
        end
        print(chat.header('BuffTrack') .. chat.message(string.format(
            '[watchdebug] %s -> %s -- Type=%u Id(17bit)=%u Param(32bit)=%u Messages=[%s]',
            casterName, targetName, packet.Type, packet.Id, raw32, table.concat(messages, ',')
        )));
    end
end

--Builds the set of current party/alliance server ids, so "is this caster an
--enemy" is just "absent from this set" -- reuses the roster assignment.lua
--already builds, no separate lookup needed.
local function BuildMemberIdSet(roster)
    local ids = {};
    for _,serverId in pairs(roster) do
        ids[serverId] = true;
    end
    return ids;
end

local function HandleApplied(packet, memberIds)
    --Only "buffs enemies cast on THEMSELVES" -- per locked scope, not
    --enemy-cast debuffs landing on players (that's a different, unrelated
    --thing this project doesn't track).
    for _,target in ipairs(packet.Targets) do
        if (target.Id == packet.UserId) and (not memberIds[packet.UserId]) then
            local watchType, appliedMessages;
            if (packet.Type == 4) then
                watchType = 'Spell';
                appliedMessages = actionMessages.Applied;
            elseif (packet.Type == 11) then
                --Monster TP move/weaponskill. CONFIRMED live via
                --/bufftrack watchdebug: a Worker Crawler's Cocoon produced
                --Type=11, Id(17bit)=Param(32bit)=346 (matching
                --libs/mobskills.lua's mob_skill_id-sourced numbering
                --exactly), message=186. packet.Id's 17-bit extraction is
                --therefore confirmed correct for this real case -- no
                --further ID-interpretation ambiguity for values in this
                --range.
                watchType = 'MobSkill';
                appliedMessages = actionMessages.MobSkillApplied;
            else
                watchType = 'Ability';
                appliedMessages = actionMessages.Applied;
            end
            local entry = FindWatchEntry(watchType, packet.Id);
            if entry then
                for _,action in ipairs(target.Actions) do
                    if (appliedMessages:contains(action.Message)) then
                        local key = BuildActiveKey(packet.UserId, packet.Id);
                        local existing = activeByKey[key];
                        if existing then
                            existing.DetectedAt = os.clock(); --recast: restart the count-up
                        else
                            activeByKey[key] = {
                                EnemyServerId = packet.UserId,
                                EnemyName = ResolveEnemyName(packet.UserId) or string.format('Unknown[%u]', packet.UserId),
                                ActionType = entry.ActionType,
                                ActionId = entry.ActionId,
                                Label = entry.Label,
                                DetectedAt = os.clock(),
                            };
                            --Audio cue fires exactly here -- the moment a
                            --brand-new watch alert is created, not on a
                            --recast of an already-active one (the
                            --`existing` branch above deliberately doesn't
                            --touch sound). Per-watched-action override (if
                            --set on this entry) takes priority over
                            --gSettings.WatchSound, same "explicit nil means
                            --inherit" convention as everywhere else in this
                            --project. Nil-guarded on both gSettings.WatchSound
                            --and gSounds -- see gridgroup.lua's identical
                            --guard comment.
                            local soundEnabled = (entry.SoundEnabled ~= nil) and entry.SoundEnabled or (gSettings.WatchSound and gSettings.WatchSound.Enabled);
                            if (soundEnabled) and (gSounds) then
                                gSounds:Play(entry.SoundId or (gSettings.WatchSound and gSettings.WatchSound.SoundId));
                            end
                        end
                    end
                end
            end
        end
    end
end

--Player-ability packet types (6/14/15), same list assignment.lua uses --
--covers player-style abilities only, per this file's header note on scope.
local abilityTypes = T{ 6, 14, 15 };

--Whatever ANY action's watch-relevant "kind" would be for this packet.Type
--(shared by HandleApplied's own branch and this one, so the two can't
--silently drift apart).
local function ActionKindForType(packetType)
    if (packetType == 4) then
        return 'Spell';
    elseif (packetType == 11) then
        return 'MobSkill';
    elseif (abilityTypes:contains(packetType)) then
        return 'Ability';
    end
    return nil;
end

local function HandleRemoval(packet, memberIds)
    local removalEntry = FindRemovalAction(ActionKindForType(packet.Type), packet.Id);
    if not removalEntry then
        return;
    end
    for _,target in ipairs(packet.Targets) do
        if (not memberIds[target.Id]) then --only clearing enemy targets' alerts
            for _,action in ipairs(target.Actions) do
                if (removalEntry.Messages:contains(action.Message)) then
                    for key,alert in pairs(activeByKey) do
                        if (alert.EnemyServerId == target.Id) then
                            activeByKey[key] = nil;
                        end
                    end
                end
            end
        end
    end
end

ashita.events.register('packet_in', 'bufftrack_dispellable_handleincomingpacket', function (e)
    if (e.id == 0x028) then
        if (not debugWatch) and (#gSettings.EnemyBuffWatchList == 0) and (next(activeByKey) == nil) then
            return; --nothing to match or clear, and not debugging; skip the parse entirely
        end
        local packet = actionPacket:parse(e);
        local roster = assignmentTracker.GetRoster();
        local memberIds = BuildMemberIdSet(roster);

        if (debugWatch) then
            local casterIsEnemy = not memberIds[packet.UserId];
            local hasEnemyTarget = false;
            for _,target in ipairs(packet.Targets) do
                if not memberIds[target.Id] then
                    hasEnemyTarget = true;
                    break;
                end
            end
            --Broadened from "caster is an enemy" (which missed Dispel --
            --Jowston, the caster, IS a party member; only the target was
            --the enemy) to "either side involves a non-party entity".
            if (casterIsEnemy) or (hasEnemyTarget) then
                local reverseRoster = {};
                for name,serverId in pairs(roster) do
                    reverseRoster[serverId] = name;
                end
                PrintDebugAction(packet, e, reverseRoster);
            end
        end

        if (packet.Type == 4) or (packet.Type == 11) or (abilityTypes:contains(packet.Type)) then
            HandleApplied(packet, memberIds);
        end
        HandleRemoval(packet, memberIds);
    end

    if (e.id == 0x29) and (debugWatch) then
        local roster = assignmentTracker.GetRoster();
        local reverseRoster = {};
        for name,serverId in pairs(roster) do
            reverseRoster[serverId] = name;
        end
        PrintDebugMessage(e, reverseRoster);
    end
end);

--Adds a watch-list entry. Returns true if added, false if already present.
local function AddWatch(actionType, actionId, label)
    if FindWatchEntry(actionType, actionId) then
        return false;
    end
    gSettings.EnemyBuffWatchList:append({
        ActionType = actionType,
        ActionId = actionId,
        Label = label,
    });
    settings.save();
    return true;
end

local function RemoveWatch(actionType, actionId)
    for i,entry in ipairs(gSettings.EnemyBuffWatchList) do
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) then
            table.remove(gSettings.EnemyBuffWatchList, i);
            settings.save();
            return true;
        end
    end
    return false;
end

local exports = {};
exports.AddWatch = AddWatch;
exports.RemoveWatch = RemoveWatch;
exports.SetDebug = SetDebug;

--Sets/updates/clears a per-watched-action display override (Cures'
--CureMap-level tier's counterpart for Watch -- no player axis exists here
--at all, so this IS Watch's finest granularity, not a middle tier).
--Reachable directly from the Watch config tab's Edit button (see
--config.lua's EditWatchEntry) and from Alt-click on a live Watch row (see
--alertsgroup.lua's HandleMouse) alike.
local function SetWatchEntryOverrides(actionType, actionId, overrides)
    local entry = FindWatchEntry(actionType, actionId);
    if not entry then
        return false;
    end
    entry.Scale = overrides.Scale;
    entry.Color = overrides.Color;
    entry.SoundEnabled = overrides.SoundEnabled;
    entry.SoundId = overrides.SoundId;
    entry.Flash = overrides.Flash;
    settings.save();
    return true;
end
exports.SetWatchEntryOverrides = SetWatchEntryOverrides;

--[[
    Returns an array of currently-active alerts:
        { TargetName(string), Label(string), ElapsedSeconds(number),
          ActionType(string), ActionId(number) }
    Also expires anything past MaxDurationSeconds (the safety fallback --
    see file header) before returning.
]]--
function exports:Tick()
    local now = os.clock();
    for key,alert in pairs(activeByKey) do
        if (now - alert.DetectedAt >= MaxDurationSeconds) then
            activeByKey[key] = nil;
        end
    end

    local alerts = T{};
    for _,alert in pairs(activeByKey) do
        --Re-resolved fresh each tick (not cached at creation time in
        --activeByKey) so an override set/changed WHILE the alert is
        --already showing takes effect immediately, same live-read
        --convention used throughout this project rather than a stale
        --snapshot.
        local entry = FindWatchEntry(alert.ActionType, alert.ActionId);
        alerts:append({
            TargetName = alert.EnemyName,
            Label = alert.Label,
            ElapsedSeconds = now - alert.DetectedAt,
            ActionType = alert.ActionType,
            ActionId = alert.ActionId,
            Scale = entry and entry.Scale,
            Color = entry and entry.Color,
            Flash = entry and entry.Flash,
        });
    end
    return alerts;
end

return exports;
