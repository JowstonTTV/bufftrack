--[[
    trackers/assignment.lua

    Core cast-matching for BuffTrack. This only cares about casts that
    match an existing entry in gSettings.Assignments (no auto-discovery of
    every cast a player lands).

    Matching is done by BUFF ID, not by the exact spell/ability that was
    assigned.  This matters for tiered spells (Protect/Protect II/.../V,
    Shell tiers, Regen tiers, etc.): every tier of the same buff occupies
    the same in-game status slot and shares one buff ID (you can't have
    Protect and Protect III active at once -- one always overwrites the
    other), so an assignment made against "Protect" should be satisfied by
    ANY tier landing on the target, not just an exact rank match. The
    assignment's stored ActionType/ActionId is kept purely for display
    (column label/icon/cost stay anchored to whichever tier was originally
    typed) -- it is no longer part of the cast-matching key.

    Scope of this section (see reference sheet section 9):
      - 0x028 cast-completion matching against assignments.
      - 0x29 Expired-message and Death-message handling.
      - 0x00D/0x00E render-flag death detection.
      - Mouse-driven deletion (Local.Delete / Local.DeleteColumn) processing.

    Deliberately deferred to a later "correction pass" section:
      - 0x076 party buff-icon early-loss correction (for non-self targets).
      - 0x63 sub-type-9 self buff-timer precision correction.
    Without those, a cell will simply run its locally-estimated countdown
    to completion even if the buff was dispelled/resisted-off early -- an
    acceptable gap for now, not a design change.
]]--

local durations = require('durations.include');
local actionPacket = require('actionpacket');
local partystatus = require('partystatus');
local mobSkillNames = require('libs.mobskills');

local actionMessages = T{
    Death   = T{ 6, 20, 113, 406, 605, 646 },
    Expired = T{ 206 },
    Applied = T{ 100, 115, 205, 230, 266, 280, 319, 420, 421, 424, 425, 667 },
};

--[[
    runtimeByKey[key] where key = "ActionType:ActionId:TargetName" -- this
    is the assignment's fixed IDENTITY (what shows in the UI, what gets
    removed by cbuff/cplayer), NOT what incoming casts are matched against.
        Local(table)          - Delete/DeleteColumn set by GridGroup on click.
        HasBeenApplied(bool)
        Expiration(number)    - os.clock() value.
        TotalDuration(number)
        LastAppliedAt(number) - os.clock() value from the most recent
                                RecordApplicationState call; used only to
                                gate CorrectEarlyLoss's race-condition
                                grace window, see that function's comment.
        ResolvedTargetId(number|nil) - current server ID for TargetName, refreshed each tick.
        BuffId(number)        - the buff ID actually being matched against incoming casts.
        ActionType(string)    - display-only.
        ActionId(number)      - display-only.
        TargetName(string)

    runtimeByBuffAndTarget[key] where key = "BuffId:TargetName" -- secondary
    index used ONLY for matching incoming casts (see HandleSpellComplete/
    HandleAbilityComplete). Points at the same state tables as runtimeByKey;
    always kept in sync with it.
]]--
local runtimeByKey = {};
local runtimeByBuffAndTarget = {};

local function BuildKey(actionType, actionId, targetName)
    return string.format('%s:%u:%s', actionType, actionId, targetName);
end

local function BuildBuffKey(buffId, targetName)
    return string.format('%u:%s', buffId, targetName);
end

--Cache of "ActionType:ActionId" -> display name, since resource lookups don't change at runtime.
local labelCache = {};
local function GetActionLabel(actionType, actionId)
    local cacheKey = string.format('%s:%u', actionType, actionId);
    local cached = labelCache[cacheKey];
    if cached then
        return cached;
    end

    local label;
    if (actionType == 'Spell') then
        local res = AshitaCore:GetResourceManager():GetSpellById(actionId);
        label = res and res.Name[1] or string.format('Spell[%u]', actionId);
    elseif (actionType == 'Ability') then
        local res = AshitaCore:GetResourceManager():GetAbilityById(actionId + 512);
        label = res and res.Name[1] or string.format('Ability[%u]', actionId);
    elseif (actionType == 'MobSkill') then
        --libs/mobskills.lua, vendored from the server's own mob_skills.sql
        --(ground-truth data -- see that file's header), not a live
        --in-game resource-string guess.
        label = mobSkillNames[actionId] or string.format('MobSkill[%u]', actionId);
    else
        label = 'Unknown';
    end

    labelCache[cacheKey] = label;
    return label;
end

--Builds a Name->Id map for current party/alliance (indices 0-17 cover self + full alliance).
local function GetRoster()
    local roster = {};
    local party = AshitaCore:GetMemoryManager():GetParty();
    for i = 0,17 do
        if (party:GetMemberIsActive(i) == 1) then
            local name = party:GetMemberName(i);
            if (name ~= nil) and (name ~= '') then
                roster[name] = party:GetMemberServerId(i);
            end
        end
    end
    return roster;
end

--Like GetRoster, but also resolves each member's main job -- for the Party
--tab's job-icon roster list (config.lua's DrawPartyTab). Returns
--{ [name] = { ServerId=.., MainJob=<numeric job id> } }. GetMemberMainJob
--is a near-universally used Ashita v4 Party API (every party-list-style
--addon needs it), so lower-risk, but -- same convention as CanCure's own
--job lookups in trackers/curable.lua -- still unverified against this
--specific environment; confirm on first in-game test of the Party tab.
local function GetRosterWithJobs()
    local roster = {};
    local party = AshitaCore:GetMemoryManager():GetParty();
    for i = 0,17 do
        if (party:GetMemberIsActive(i) == 1) then
            local name = party:GetMemberName(i);
            if (name ~= nil) and (name ~= '') then
                roster[name] = { ServerId = party:GetMemberServerId(i), MainJob = party:GetMemberMainJob(i) };
            end
        end
    end
    return roster;
end

--Reverse lookup used when matching an incoming packet's numeric target ID back to a tracked name.
local function FindNameById(roster, id)
    for name,memberId in pairs(roster) do
        if (memberId == id) then
            return name;
        end
    end
    return nil;
end

local function UnindexState(state)
    runtimeByKey[BuildKey(state.ActionType, state.ActionId, state.TargetName)] = nil;
    runtimeByBuffAndTarget[BuildBuffKey(state.BuffId, state.TargetName)] = nil;
end

local function RemoveAssignment(actionType, actionId, targetName)
    for i,entry in ipairs(gSettings.Assignments) do
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) and (entry.TargetName == targetName) then
            table.remove(gSettings.Assignments, i);
            break;
        end
    end
    local state = runtimeByKey[BuildKey(actionType, actionId, targetName)];
    if state then
        UnindexState(state);
    end
    settings.save();
end

local function RemoveColumn(actionType, actionId)
    local i = 1;
    while (i <= #gSettings.Assignments) do
        local entry = gSettings.Assignments[i];
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) then
            local state = runtimeByKey[BuildKey(entry.ActionType, entry.ActionId, entry.TargetName)];
            if state then
                UnindexState(state);
            end
            table.remove(gSettings.Assignments, i);
        else
            i = i + 1;
        end
    end
    settings.save();
end

local function RemoveRow(targetName)
    local i = 1;
    while (i <= #gSettings.Assignments) do
        local entry = gSettings.Assignments[i];
        if (entry.TargetName == targetName) then
            local state = runtimeByKey[BuildKey(entry.ActionType, entry.ActionId, entry.TargetName)];
            if state then
                UnindexState(state);
            end
            table.remove(gSettings.Assignments, i);
        else
            i = i + 1;
        end
    end
    settings.save();
end

local function ClearAll()
    for i = #gSettings.Assignments,1,-1 do
        table.remove(gSettings.Assignments, i);
    end
    runtimeByKey = {};
    runtimeByBuffAndTarget = {};
    settings.save();
end

--Processes deletion flags set by GridGroup on the previous frame's cell data.
local function ProcessDeletions()
    --DeleteColumn entries first, since they invalidate several keys at once.
    for key,state in pairs(runtimeByKey) do
        if (state.Local.DeleteColumn) then
            RemoveColumn(state.ActionType, state.ActionId);
        end
    end
    for key,state in pairs(runtimeByKey) do
        if (state.Local.Delete) then
            RemoveAssignment(state.ActionType, state.ActionId, state.TargetName);
        end
    end
end

--Syncs runtimeByKey/runtimeByBuffAndTarget with gSettings.Assignments: adds
--runtime state for any assignment that doesn't have it yet (newly added via
--/bufftrack). Never removes entries here -- removal only happens via
--ProcessDeletions/RemoveAssignment/RemoveColumn/RemoveRow/ClearAll.
local function SyncAssignments()
    for _,entry in ipairs(gSettings.Assignments) do
        local key = BuildKey(entry.ActionType, entry.ActionId, entry.TargetName);
        if not runtimeByKey[key] then
            local state = {
                Local = T{},
                HasBeenApplied = false,
                Expiration = nil,
                TotalDuration = nil,
                LastAppliedAt = nil,
                ResolvedTargetId = nil,
                BuffId = entry.BuffId,
                ActionType = entry.ActionType,
                ActionId = entry.ActionId,
                TargetName = entry.TargetName,
                --nil (older saved assignments predating this field) defaults
                --to true, matching the always-on behavior before this existed.
                FlashOnExpire = (entry.FlashOnExpire ~= false),
                --Per-entry overrides (see initializer.lua's Assignments doc
                --comment); nil on any of these means "inherit the tracker-
                --level default", not "off" -- resolved at render/sound-fire
                --time (GridGroup, resources/renderers/grid.lua), not here.
                Scale = entry.Scale,
                Color = entry.Color,
                SoundEnabled = entry.SoundEnabled,
                SoundId = entry.SoundId,
            };
            runtimeByKey[key] = state;
            runtimeByBuffAndTarget[BuildBuffKey(entry.BuffId, entry.TargetName)] = state;
        end
    end
end

local function RefreshResolvedTargetIds(roster)
    for _,state in pairs(runtimeByKey) do
        state.ResolvedTargetId = roster[state.TargetName];
    end
end

--Early-loss correction: for anything we currently believe is active AND is
--inside local-party range (hasData=true -- see partystatus.lua), check
--whether its buff ID is ACTUALLY still present. If not, force-expire right
--now instead of waiting out the estimate. This is what makes an overriding
--debuff, an early dispel, a resisted-off effect, etc. get caught promptly
--regardless of the specific cause -- rather than hardcoding specific
--"debuff X cancels buff Y" pairs, which isn't something this project has
--an authoritative source for anyway.
--
--RecentApplicationGraceSeconds guards against a race with a JUST-landed
--(re)application: HandleSpellComplete/HandleAbilityComplete set a fresh
--Expiration the instant the action packet arrives, but the game client's
--own status-icon memory (what GetStatusIds reads) updates on a separate,
--not-guaranteed-synchronous path -- if this check ran on the very next
--tick and that memory hadn't caught up yet, it would see "buff id not
--present" and immediately force-expire the fresh application right back
--down to "now", undoing the recast within a single frame. Skipping the
--check for a short window after LastAppliedAt avoids that without
--weakening early-loss correction for anything that's actually been active
--for a while.
local RecentApplicationGraceSeconds = 2;
local function CorrectEarlyLoss()
    local now = os.clock();
    for _,state in pairs(runtimeByKey) do
        if (state.HasBeenApplied) and (state.Expiration ~= nil) and (state.Expiration > now) then
            if (now - (state.LastAppliedAt or 0)) >= RecentApplicationGraceSeconds then
                local ids, hasData = partystatus.GetStatusIds(state.ResolvedTargetId);
                if (hasData) and (not ids[state.BuffId]) then
                    state.Expiration = now;
                end
            end
        end
    end
end

local function RecordApplicationState(state, targetId, duration)
    state.HasBeenApplied = true;
    state.TotalDuration = duration;
    state.Expiration = os.clock() + duration;
    state.ResolvedTargetId = targetId;
    state.LastAppliedAt = os.clock();
end

local function ForceExpireByTargetId(targetId, buffId)
    for _,state in pairs(runtimeByKey) do
        if (state.ResolvedTargetId == targetId) then
            if (buffId == nil) or (state.BuffId == buffId) then
                state.Expiration = os.clock();
            end
        end
    end
end

--Looks up an assignment by the buff that actually landed, not by the exact
--spell/ability cast -- this is what makes tiered spells (any Protect rank,
--any Shell rank, etc.) satisfy an assignment made against any one tier.
local function HandleSpellComplete(packet, roster)
    for _,target in ipairs(packet.Targets) do
        for _,action in ipairs(target.Actions) do
            if (actionMessages.Applied:contains(action.Message)) then
                local targetName = FindNameById(roster, target.Id);
                if targetName then
                    local duration, buffId = durations:GetSpellDuration(packet.Id, target.Id);
                    if type(buffId) == 'table' then
                        buffId = buffId[1];
                    end
                    if (duration ~= nil) and (buffId ~= nil) then
                        local state = runtimeByBuffAndTarget[BuildBuffKey(buffId, targetName)];
                        if state then
                            RecordApplicationState(state, target.Id, duration);
                        end
                    end
                end
            end
        end
    end
end

local abilityTypes = T{ 6, 14, 15 };
local function HandleAbilityComplete(packet, roster)
    for _,target in ipairs(packet.Targets) do
        for _,action in ipairs(target.Actions) do
            if (actionMessages.Applied:contains(action.Message)) then
                local targetName = FindNameById(roster, target.Id);
                if targetName then
                    local duration, buffId = durations:GetAbilityDuration(packet.Id, target.Id);
                    if type(buffId) == 'table' then
                        buffId = buffId[1];
                    end
                    if (duration ~= nil) and (buffId ~= nil) then
                        local state = runtimeByBuffAndTarget[BuildBuffKey(buffId, targetName)];
                        if state then
                            RecordApplicationState(state, target.Id, duration);
                        end
                    end
                end
            end
        end
    end
end

ashita.events.register('packet_in', 'bufftrack_handleincomingpacket', function (e)
    if (e.id == 0x028) then
        local packet = actionPacket:parse(e);
        local roster = GetRoster();

        --Only care about casts performed by someone currently in party/alliance range (or self).
        local casterName = FindNameById(roster, packet.UserId);
        if casterName then
            if (packet.Type == 4) then
                HandleSpellComplete(packet, roster);
            elseif (abilityTypes:contains(packet.Type)) then
                HandleAbilityComplete(packet, roster);
            end
        end
    end

    if (e.id == 0x29) then
        local messageId = bit.band(struct.unpack('H', e.data, 0x18 + 1), 0x7FFF);
        local targetId = struct.unpack('L', e.data, 0x08 + 1);

        if (actionMessages.Death:contains(messageId)) then
            ForceExpireByTargetId(targetId, nil);
        end

        if (actionMessages.Expired:contains(messageId)) then
            local buffId = struct.unpack('H', e.data, 0x0C + 1);
            ForceExpireByTargetId(targetId, buffId);
        end
    end
end);

--True if this exact (ActionType, ActionId, TargetName) is already assigned,
--OR if a different tier of the same underlying buff (same BuffId) is
--already assigned to this target -- since both would otherwise collide on
--the same runtimeByBuffAndTarget slot and only one could ever actually
--update.
local function IsDuplicate(actionType, actionId, buffId, targetName)
    if (runtimeByKey[BuildKey(actionType, actionId, targetName)] ~= nil) then
        return true;
    end
    return runtimeByBuffAndTarget[BuildBuffKey(buffId, targetName)] ~= nil;
end

local function AddAssignment(actionType, actionId, buffId, targetName)
    if IsDuplicate(actionType, actionId, buffId, targetName) then
        return false;
    end
    gSettings.Assignments:append({
        ActionType = actionType,
        ActionId = actionId,
        BuffId = buffId,
        TargetName = targetName,
        FlashOnExpire = true,
    });
    settings.save();
    return true;
end

--Sets FlashOnExpire on a single assignment (per-row checkbox in config.lua).
local function SetFlashOnExpire(actionType, actionId, targetName, value)
    for _,entry in ipairs(gSettings.Assignments) do
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) and (entry.TargetName == targetName) then
            entry.FlashOnExpire = value;
            break;
        end
    end
    local state = runtimeByKey[BuildKey(actionType, actionId, targetName)];
    if state then
        state.FlashOnExpire = value;
    end
    settings.save();
end

--Sets the per-entry Scale/Color/SoundEnabled/SoundId overrides (config.lua's
--Entry Editor popup, opened via Alt-click on a cell -- see gridgroup.lua's
--HandleMouse). overrides is a table with any subset of those four keys;
--an explicit nil value clears that override back to "inherit". Unlike
--SetFlashOnExpire this writes several fields at once since the popup
--edits them together as one "Apply".
local function SetEntryOverrides(actionType, actionId, targetName, overrides)
    for _,entry in ipairs(gSettings.Assignments) do
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) and (entry.TargetName == targetName) then
            entry.Scale = overrides.Scale;
            entry.Color = overrides.Color;
            entry.SoundEnabled = overrides.SoundEnabled;
            entry.SoundId = overrides.SoundId;
            break;
        end
    end
    local state = runtimeByKey[BuildKey(actionType, actionId, targetName)];
    if state then
        state.Scale = overrides.Scale;
        state.Color = overrides.Color;
        state.SoundEnabled = overrides.SoundEnabled;
        state.SoundId = overrides.SoundId;
    end
    settings.save();
end

--Reorders gSettings.Assignments in place -- array position IS display
--order already (GridGroup:Render and Tick() below both walk the array in
--order to build columns/rows, unchanged by anything here), so "explicit
--order control" just means letting the user move an entry within that
--same array rather than introducing a separate ordering field to keep in
--sync with it. direction is -1 (move up/earlier) or 1 (move down/later);
--a no-op at either end of the list rather than wrapping.
local function MoveAssignment(actionType, actionId, targetName, direction)
    local index;
    for i,entry in ipairs(gSettings.Assignments) do
        if (entry.ActionType == actionType) and (entry.ActionId == actionId) and (entry.TargetName == targetName) then
            index = i;
            break;
        end
    end
    if not index then
        return;
    end
    local target = index + direction;
    if (target < 1) or (target > #gSettings.Assignments) then
        return;
    end
    gSettings.Assignments[index], gSettings.Assignments[target] = gSettings.Assignments[target], gSettings.Assignments[index];
    settings.save();
end

--One-shot bulk action (config.lua's master checkbox): sets FlashOnExpire on
--every current assignment. Deliberately NOT a persisted global setting --
--just a convenience that writes the same value to every entry at once;
--entries can drift apart again afterward via the per-row checkbox.
local function SetFlashOnExpireAll(value)
    for _,entry in ipairs(gSettings.Assignments) do
        entry.FlashOnExpire = value;
    end
    for _,state in pairs(runtimeByKey) do
        state.FlashOnExpire = value;
    end
    settings.save();
end

--Distinct TargetNames currently present across all assignments, for cplayer
--fuzzy matching -- deliberately independent of the live roster, since a
--player being removed via /bufftrack cplayer may have already left
--party/alliance.
local function GetAssignedTargetNames()
    local seen = {};
    local names = T{};
    for _,entry in ipairs(gSettings.Assignments) do
        if not seen[entry.TargetName] then
            seen[entry.TargetName] = true;
            names:append(entry.TargetName);
        end
    end
    return names;
end

--Every assignment entry for one player, in display order (array order,
--same convention MoveAssignment/Tick already use) -- for the Party tab's
--per-player detail view (config.lua's DrawPartyTab).
local function GetAssignmentsForPlayer(targetName)
    local results = T{};
    for _,entry in ipairs(gSettings.Assignments) do
        if (entry.TargetName == targetName) then
            results:append(entry);
        end
    end
    return results;
end

local exports = {};

exports.RemoveAssignment = RemoveAssignment;
exports.RemoveColumn = RemoveColumn;
exports.RemoveRow = RemoveRow;
exports.AddAssignment = AddAssignment;
exports.SetFlashOnExpire = SetFlashOnExpire;
exports.SetFlashOnExpireAll = SetFlashOnExpireAll;
exports.SetEntryOverrides = SetEntryOverrides;
exports.MoveAssignment = MoveAssignment;
exports.IsDuplicate = IsDuplicate;
exports.GetAssignedTargetNames = GetAssignedTargetNames;
exports.GetAssignmentsForPlayer = GetAssignmentsForPlayer;

--Sets a player's Cures-panel sort priority (see initializer.lua's
--PlayerPriority doc comment). 0 removes the entry entirely rather than
--storing an explicit 0 -- keeps the settings table free of dead "never
--customized" rows, same tidiness convention SetCureOverride/etc already
--follow for their own all-default case.
local function SetPlayerPriority(targetName, priority)
    if (priority == nil) or (priority == 0) then
        gSettings.PlayerPriority[targetName] = nil;
    else
        gSettings.PlayerPriority[targetName] = priority;
    end
    settings.save();
end
exports.SetPlayerPriority = SetPlayerPriority;
exports.GetRoster = GetRoster;
exports.GetRosterWithJobs = GetRosterWithJobs;
exports.GetActionLabel = GetActionLabel;
exports.ClearAll = ClearAll;

function exports:Tick()
    ProcessDeletions();
    SyncAssignments();
    local roster = GetRoster();
    RefreshResolvedTargetIds(roster);
    CorrectEarlyLoss();

    local tickData = T{};
    for _,entry in ipairs(gSettings.Assignments) do
        local key = BuildKey(entry.ActionType, entry.ActionId, entry.TargetName);
        local state = runtimeByKey[key];
        tickData:append({
            ActionType = state.ActionType,
            ActionId = state.ActionId,
            BuffId = state.BuffId,
            ColumnLabel = GetActionLabel(state.ActionType, state.ActionId),
            TargetName = state.TargetName,
            HasBeenApplied = state.HasBeenApplied,
            Expiration = state.Expiration,
            TotalDuration = state.TotalDuration,
            FlashOnExpire = state.FlashOnExpire,
            Scale = state.Scale,
            Color = state.Color,
            SoundEnabled = state.SoundEnabled,
            SoundId = state.SoundId,
            Local = state.Local,
        });
    end
    return tickData;
end

return exports;
