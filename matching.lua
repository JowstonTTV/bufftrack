--[[
    matching.lua

    Two jobs:
      1. Resolve a typed buff name (possibly misspelled) to a specific
         (ActionType, ActionId, BuffId, Label) -- the "buff index" is built
         lazily by probing the duration library across the full spell/ability
         ID range and keeping anything that returns a non-nil duration for
         a self-targeted probe. That's the signal used to know "this is a
         trackable buff."
      2. Resolve a typed player name to an exact name, restricted to a
         given candidate list (live roster for adding an assignment, or
         currently-assigned names for removing one).

    Matching strategy: exact match wins outright; otherwise prefix/substring
    match wins outright; otherwise fall back to Levenshtein edit distance
    with a threshold scaled to query length, since a fixed threshold is too
    strict for short names and too loose for long ones.  If more than one
    candidate ties for best score, treat it as ambiguous and let the caller
    decide how to report that (per design decision: print and reject, don't
    guess).
]]--

local durations = require('durations.include');
local buffTable = require('libs.bufftable');
local mobSkillNames = require('libs.mobskills');
local statusEffectNames = require('libs.statuseffects');

local function Normalize(s)
    return string.lower(s):gsub('%s+', '');
end

--Standard iterative Levenshtein distance.
local function Levenshtein(a, b)
    local la, lb = #a, #b;
    if (la == 0) then return lb; end
    if (lb == 0) then return la; end

    local prevRow = {};
    for j = 0,lb do
        prevRow[j] = j;
    end

    for i = 1,la do
        local currRow = { [0] = i };
        local ca = a:byte(i);
        for j = 1,lb do
            local cost = (ca == b:byte(j)) and 0 or 1;
            currRow[j] = math.min(
                prevRow[j] + 1,        --deletion
                currRow[j-1] + 1,      --insertion
                prevRow[j-1] + cost    --substitution
            );
        end
        prevRow = currRow;
    end

    return prevRow[lb];
end

--Threshold scales with query length: short queries need to match almost
--exactly (a 3-letter typo-riddled query is too ambiguous to guess), longer
--queries can tolerate a couple edits.
local function DistanceThreshold(len)
    if (len <= 4) then return 1; end
    if (len <= 8) then return 2; end
    return 3;
end

--[[
    candidates(table) - array of { Label(string), ...anything else the caller wants preserved }
    query(string)
    Returns:
        match(table), nil          - unambiguous match found
        nil, candidateList(table)  - ambiguous or no match; candidateList
                                      holds the closest options (empty if
                                      truly nothing was close)
]]--
local function FuzzyFind(candidates, query)
    local normQuery = Normalize(query);

    --Exact match short-circuits everything.
    local exactMatches = T{};
    for _,c in ipairs(candidates) do
        if (Normalize(c.Label) == normQuery) then
            exactMatches:append(c);
        end
    end
    if (#exactMatches == 1) then
        return exactMatches[1], nil;
    elseif (#exactMatches > 1) then
        return nil, exactMatches;
    end

    --Prefix/substring match next.
    local substringMatches = T{};
    for _,c in ipairs(candidates) do
        local normLabel = Normalize(c.Label);
        if (normLabel:find(normQuery, 1, true)) then
            substringMatches:append(c);
        end
    end
    if (#substringMatches == 1) then
        return substringMatches[1], nil;
    elseif (#substringMatches > 1) then
        return nil, substringMatches;
    end

    --Fall back to edit distance.
    local threshold = DistanceThreshold(#normQuery);
    local best = T{};
    local bestDistance = threshold + 1;
    for _,c in ipairs(candidates) do
        local distance = Levenshtein(normQuery, Normalize(c.Label));
        if (distance <= threshold) then
            if (distance < bestDistance) then
                bestDistance = distance;
                best = T{ c };
            elseif (distance == bestDistance) then
                best:append(c);
            end
        end
    end

    if (#best == 1) then
        return best[1], nil;
    end
    return nil, best; --either empty (no match) or ambiguous (tie)
end

--Only exclude a candidate when bufftable EXPLICITLY classifies its buff id
--as a debuff (1). Absence from the table is treated as "unknown", not
--"debuff" -- an incomplete classification table should never suppress a
--genuinely assignable buff from ever showing up in fuzzy search.
local function IsKnownDebuff(buffId)
    return buffTable.statusEffects[buffId] == 1;
end

--[[
    Buff index -- built lazily on first use, then cached for the session.
    Probes every spell/ability ID against the duration library using the
    local player as a dummy target, purely to test "does this produce a
    duration" (existence check).  The actual duration used for a live
    assignment is always recalculated fresh, against the real target, at
    cast time in trackers/assignment.lua -- this probe value is discarded.
]]--
local buffIndex;
local function BuildBuffIndex()
    local index = T{};
    local myId = durations:GetDataTracker():GetPlayerId();

    for id = 1,1024 do
        local res = AshitaCore:GetResourceManager():GetSpellById(id);
        if (res) and (res.Name[1]) and (#res.Name[1] > 0) then
            local ok, duration, buffId = pcall(function() return durations:GetSpellDuration(id, myId); end);
            if (ok) and (duration ~= nil) then
                if type(buffId) == 'table' then
                    buffId = buffId[1];
                end
                --A nil BuffId here means the durations library returned a
                --duration without an identifiable buff id -- can't be
                --matched against incoming casts at all (see
                --trackers/assignment.lua's IsDuplicate/BuildBuffKey, which
                --require a real BuffId), so it can't be a trackable entry
                --regardless of what the duration probe found. Confirmed
                --live: an entry like this crashed config.lua's Buffs tab.
                if (buffId ~= nil) and (not IsKnownDebuff(buffId)) then
                    index:append({ Label = res.Name[1], ActionType = 'Spell', ActionId = id, BuffId = buffId });
                end
            end
        end
    end

    for id = 1,1024 do
        local res = AshitaCore:GetResourceManager():GetAbilityById(id + 512);
        if (res) and (res.Name[1]) and (#res.Name[1] > 0) then
            local ok, duration, buffId = pcall(function() return durations:GetAbilityDuration(id, myId); end);
            if (ok) and (duration ~= nil) then
                if type(buffId) == 'table' then
                    buffId = buffId[1];
                end
                if (buffId ~= nil) and (not IsKnownDebuff(buffId)) then
                    index:append({ Label = res.Name[1], ActionType = 'Ability', ActionId = id, BuffId = buffId });
                end
            end
        end
    end

    return index;
end

local function GetBuffIndex()
    if not buffIndex then
        buffIndex = BuildBuffIndex();
    end
    return buffIndex;
end

--[[
    Separate from the buff index above -- that one only includes spells
    that produce a duration-tracked status on the caster (a probe against
    the duration library), which excludes removal spells entirely (Poisona,
    Cursna, Erase, etc. don't apply a status to the caster, so they'd never
    show up there). This is a plain name index over every named spell
    resource, no duration filtering, for trackers/curable.lua's cure-spell
    resolution.
]]--
local anySpellIndex;
local function BuildAnySpellIndex()
    local index = T{};
    for id = 1,1024 do
        local res = AshitaCore:GetResourceManager():GetSpellById(id);
        if (res) and (res.Name[1]) and (#res.Name[1] > 0) then
            index:append({ Label = res.Name[1], ActionType = 'Spell', ActionId = id });
        end
    end
    return index;
end

local function GetAnySpellIndex()
    if not anySpellIndex then
        anySpellIndex = BuildAnySpellIndex();
    end
    return anySpellIndex;
end

--Same idea as BuildAnySpellIndex, for player-style abilities (GetAbilityById,
--the same resource lookup GetActionLabel's 'Ability' branch already uses) --
--used by trackers/dispellable.lua's watch-list add flow.
local anyAbilityIndex;
local function BuildAnyAbilityIndex()
    local index = T{};
    for id = 1,1024 do
        local res = AshitaCore:GetResourceManager():GetAbilityById(id + 512);
        if (res) and (res.Name[1]) and (#res.Name[1] > 0) then
            index:append({ Label = res.Name[1], ActionType = 'Ability', ActionId = id });
        end
    end
    return index;
end

local function GetAnyAbilityIndex()
    if not anyAbilityIndex then
        anyAbilityIndex = BuildAnyAbilityIndex();
    end
    return anyAbilityIndex;
end

--[[
    Monster TP moves/weaponskills -- resolved via libs/mobskills.lua, a
    table vendored from the actual server codebase's own mob_skills.sql
    (see that file's header). Ground-truth data, not a live in-game
    resource-string guess.
]]--
local anyMobSkillIndex;
local function BuildAnyMobSkillIndex()
    local index = T{};
    for id,name in pairs(mobSkillNames) do
        if (#name > 0) then
            index:append({ Label = name, ActionType = 'MobSkill', ActionId = id });
        end
    end
    return index;
end

local function GetAnyMobSkillIndex()
    if not anyMobSkillIndex then
        anyMobSkillIndex = BuildAnyMobSkillIndex();
    end
    return anyMobSkillIndex;
end

--[[
    Debuff status effect names -- libs/statuseffects.lua, sourced from
    libs/bufftable.lua's own statusEffects table (see that file's header on
    why the numbering is trusted). Used for trackers/curable.lua's "add an
    Erase-covered debuff" flow (by NAME instead of a raw status id) and for
    the Cures tab's display labels.
]]--
local statusEffectIndex;
local function BuildStatusEffectIndex()
    local index = T{};
    for id,name in pairs(statusEffectNames) do
        index:append({ Label = name, StatusId = id });
    end
    return index;
end

local function GetStatusEffectIndex()
    if not statusEffectIndex then
        statusEffectIndex = BuildStatusEffectIndex();
    end
    return statusEffectIndex;
end

local exports = {};

--Returns match(table: Label/ActionType/ActionId/BuffId), nil OR nil, candidateLabels(table of strings)
function exports:FindBuff(query)
    local match, candidates = FuzzyFind(GetBuffIndex(), query);
    if match then
        return match, nil;
    end
    local labels = T{};
    for _,c in ipairs(candidates) do
        labels:append(c.Label);
    end
    return nil, labels;
end

--Full catalog of trackable buffs (same index FindBuff searches), for the
--config UI's Buffs tab spell-picker list. Alphabetized by Label so the
--list has a stable, predictable order across frames (GetBuffIndex's own
--build order is just spell/ability resource ID order, which isn't
--alphabetical).
--
--ABILITIES ARE EXCLUDED from this list entirely, per explicit design
--decision -- the Buffs tab is scoped to spells only. (Job abilities are
--still trackable the old way, via /bufftrack [ability] [player], which
--goes through FindBuff/GetBuffIndex directly and isn't affected by this.)
--
--SPELLS are pruned to ones the local player can currently cast (main or
--sub job level meets the spell resource's LevelRequired array). CONFIRMED
--live via /bufftrack debugspell: LevelRequired IS indexable by job id, but
--with a +1 OFFSET from the canonical job id -- Haste's WHM(id 3)/40 showed
--up at index 4, RDM(id 5)/48 at index 6, both agreeing on the same +1 gap.
--An earlier version of this indexed by raw job id with no offset, which
--silently never filtered anything (every real value sat one slot over
--from where this code was looking). -1 is the "can't learn" sentinel
--(confirmed live: every other index read back -1), not 0 or nil.
function exports:ListBuffs()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local haveJobInfo, mainJob, mainLevel, subJob, subLevel = pcall(function()
        return player:GetMainJob(), player:GetMainJobLevel(), player:GetSubJob(), player:GetSubJobLevel();
    end);

    local list = T{};
    for _,c in ipairs(GetBuffIndex()) do
        if (c.ActionType == 'Spell') then
            local include = true;
            if (haveJobInfo) then
                local checkOk, canCast = pcall(function()
                    local res = AshitaCore:GetResourceManager():GetSpellById(c.ActionId);
                    if (not res) or (not res.LevelRequired) then
                        return true; --can't verify; don't hide it
                    end
                    local mainReq = res.LevelRequired[mainJob + 1];
                    local subReq = res.LevelRequired[subJob + 1];
                    local mainOk = (mainReq) and (mainReq > 0) and (mainLevel >= mainReq);
                    local subOk = (subReq) and (subReq > 0) and (subLevel >= subReq);
                    return (mainOk == true) or (subOk == true);
                end);
                include = (not checkOk) or (canCast ~= false);
            end
            if include then
                list:append(c);
            end
        end
    end

    table.sort(list, function(a, b) return a.Label < b.Label; end);
    return list;
end

--Returns match(table: Label/ActionType/ActionId), nil OR nil, candidateLabels(table of strings)
--Unlike FindBuff, not restricted to spells that apply a tracked status --
--see BuildAnySpellIndex's comment.
function exports:FindAnySpell(query)
    local match, candidates = FuzzyFind(GetAnySpellIndex(), query);
    if match then
        return match, nil;
    end
    local labels = T{};
    for _,c in ipairs(candidates) do
        labels:append(c.Label);
    end
    return nil, labels;
end

--Same shape, player-style abilities -- see BuildAnyAbilityIndex's comment.
function exports:FindAnyAbility(query)
    local match, candidates = FuzzyFind(GetAnyAbilityIndex(), query);
    if match then
        return match, nil;
    end
    local labels = T{};
    for _,c in ipairs(candidates) do
        labels:append(c.Label);
    end
    return nil, labels;
end

--Same shape, monster TP moves -- backed by libs/mobskills.lua's vendored
--server-side data (see BuildAnyMobSkillIndex's comment).
function exports:FindAnyMobSkill(query)
    local match, candidates = FuzzyFind(GetAnyMobSkillIndex(), query);
    if match then
        return match, nil;
    end
    local labels = T{};
    for _,c in ipairs(candidates) do
        labels:append(c.Label);
    end
    return nil, labels;
end

--Returns match(table: Label/StatusId), nil OR nil, candidateLabels(table of
--strings) -- resolves a typed debuff name ("Bio", "Paralysis") to its
--status id, backed by libs/statuseffects.lua.
function exports:FindDebuffStatus(query)
    local match, candidates = FuzzyFind(GetStatusEffectIndex(), query);
    if match then
        return match, nil;
    end
    local labels = T{};
    for _,c in ipairs(candidates) do
        labels:append(c.Label);
    end
    return nil, labels;
end

--Plain id->name lookup (no fuzzy matching), for display purposes -- Cures
--tab rows, etc. Falls back to "Status N" for anything not in
--libs/statuseffects.lua.
function exports:GetDebuffName(statusId)
    return statusEffectNames[statusId] or string.format('Status %u', statusId);
end

--roster(table) - Name->ServerId map, as returned by trackers.assignment's GetRoster().
--Returns matchName(string), nil OR nil, candidateNames(table of strings)
function exports:FindPlayer(query, roster)
    local candidates = T{};
    for name,_ in pairs(roster) do
        candidates:append({ Label = name });
    end
    local match, ambiguous = FuzzyFind(candidates, query);
    if match then
        return match.Label, nil;
    end
    local names = T{};
    for _,c in ipairs(ambiguous) do
        names:append(c.Label);
    end
    return nil, names;
end

--assignedNames(table) - array of strings, as returned by trackers.assignment's GetAssignedTargetNames().
--Same return shape as FindPlayer.
function exports:FindAssignedPlayer(query, assignedNames)
    local candidates = T{};
    for _,name in ipairs(assignedNames) do
        candidates:append({ Label = name });
    end
    local match, ambiguous = FuzzyFind(candidates, query);
    if match then
        return match.Label, nil;
    end
    local names = T{};
    for _,c in ipairs(ambiguous) do
        names:append(c.Label);
    end
    return nil, names;
end

--Same return shape as FindBuff, but restricted to buff/ability keys
--currently present in gSettings.Assignments -- used for cbuff removal so
--typing a partial name only ever matches something that actually exists
--to remove.
function exports:FindAssignedBuff(query)
    local seen = {};
    local candidates = T{};
    for _,entry in ipairs(gSettings.Assignments) do
        local key = string.format('%s:%u', entry.ActionType, entry.ActionId);
        if not seen[key] then
            seen[key] = true;
            local index = GetBuffIndex();
            for _,indexed in ipairs(index) do
                if (indexed.ActionType == entry.ActionType) and (indexed.ActionId == entry.ActionId) then
                    candidates:append(indexed);
                    break;
                end
            end
        end
    end
    local match, ambiguous = FuzzyFind(candidates, query);
    if match then
        return match, nil;
    end
    local labels = T{};
    for _,c in ipairs(ambiguous) do
        labels:append(c.Label);
    end
    return nil, labels;
end

return exports;
