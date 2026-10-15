--[[
    trackers/curable.lua

    §7.1 stretch goal: "can I cure this?" alert. Unlike trackers/assignment.lua
    this is NOT a persistent, user-declared assignment -- it's a pure live
    derivation, recomputed from scratch every tick:

        for each local-party member's currently active debuff status IDs,
        if that status ID is in gSettings.CureMap AND the LOCAL PLAYER's
        own main/sub job+level meets that entry's requirement, surface it.

    No duration/countdown, no early-loss correction pass needed -- since
    this reads live status presence every tick (via partystatus.lua, same
    mechanism trackers/assignment.lua uses for early-loss correction), a
    cured/expired debuff simply stops appearing the very next tick.

    Deliberately checks the LOCAL PLAYER's job/level only, never the
    affected party member's -- this alert answers "can I (the addon user)
    cure this", not "can this player cure themselves." (Locked design
    decision -- see planning notes.)

    Feeds the Cures panel (gCuresPanel -- see alertsgroup.lua's
    NewCuresPanel), rendered as one row per currently-active alert.
    SeedDefaults() (below) runs every Tick() call until it succeeds.
]]--

local partystatus = require('partystatus');
local matching = require('matching');
local assignmentTracker = require('trackers.assignment');

--[[
    Canonical FFXI job IDs -- fixed game data, not this project's convention
    and not expected to vary by server. Used to translate GetMainJob()/
    GetSubJob()'s numeric return into the 3-letter abbreviations CureMap
    entries are authored with (RequiredJob = "WHM", etc).
]]--
local JobAbbrById = {
    [1]='WAR', [2]='MNK', [3]='WHM', [4]='BLM', [5]='RDM', [6]='THF',
    [7]='PLD', [8]='DRK', [9]='BST', [10]='BRD', [11]='RNG', [12]='SAM',
    [13]='NIN', [14]='DRG', [15]='SMN', [16]='BLU', [17]='COR', [18]='PUP',
    [19]='DNC', [20]='SCH', [21]='GEO', [22]='RUN',
};

--One-time session warning guard for CanCure's job-check pcall -- see that
--function's comment.
local warnedCanCureFailure = false;

--[[
    Direct 1:1 status->cure mappings, per user-supplied data (unlike Erase,
    which covers many different debuffs generically and is opt-in only --
    see AddEraseEntry below). Status IDs per libs/bufftable.lua's
    statusEffects numbering.
        weakness=1, sleep=2, poison=3, paralysis=4, blindness=5, silence=6,
        petrification=7, disease=8, curse_i=9, curse_ii=20, plague=31

    RequiredJob/RequiredLevel are OPTIONAL -- omit both (as Cure below
    does) to mean "any job that currently knows this spell", checked live
    against the spell resource's own per-job LevelRequired array instead of
    one hand-picked job/level (see CanCure). Poisona/Paralyna/etc keep an
    explicit RequiredJob because they really are WHM-only spells in FFXI --
    a fixed check is correct and cheaper there. Cure needs the live check
    instead: it's castable by WHM/RDM/PLD/SCH/RUN/etc, each unlocking it at
    a different level, and enumerating every qualifying job by hand would
    be large and brittle for no benefit over just asking the spell resource.
]]--
local DefaultCureSpells = T{
    --Sleep listed first -- removed by the HP-restoration Cure line, any
    --job that knows it (see comment above). Matches the LOWEST tier
    --("Cure" itself, FuzzyFind's exact-match rule) purely as the
    --representative action/label shown in the alert -- CanCure's
    --eligibility check below doesn't care which tier, just whether the
    --player can cast this one. Position here only matters for FRESH
    --installs seeding in this order; ReorderSleepFirst below also moves it
    --to the front of an EXISTING gSettings.CureMap, per explicit request
    --to have it lead the Cures tab's list.
    { Name = 'Cure', StatusIds = T{2} },
    { Name = 'Poisona',  StatusIds = T{3},     RequiredJob = 'WHM', RequiredLevel = 6 },
    { Name = 'Paralyna', StatusIds = T{4},     RequiredJob = 'WHM', RequiredLevel = 9 },
    { Name = 'Blindna',  StatusIds = T{5},     RequiredJob = 'WHM', RequiredLevel = 14 },
    { Name = 'Silena',   StatusIds = T{6},     RequiredJob = 'WHM', RequiredLevel = 19 },
    { Name = 'Cursna',   StatusIds = T{9, 20}, RequiredJob = 'WHM', RequiredLevel = 29 },
    { Name = 'Viruna',   StatusIds = T{8, 31}, RequiredJob = 'WHM', RequiredLevel = 34 },
    { Name = 'Stona',    StatusIds = T{7},     RequiredJob = 'WHM', RequiredLevel = 39 },
};

--Session-local fast-path so a fully-seeded settings file doesn't re-check
--every default's name resolution every single tick -- gSettings.CureMapSeeded
--is the actual persisted guard (survives reloads); this just avoids the
--redundant loop within one play session once that flag is already true.
local seeded = false;

--Idempotent and safe to call every tick until it succeeds: if the spell
--resource manager isn't ready yet on an early tick, unresolved defaults are
--simply retried next tick, and CureMapSeeded is only set once every default
--resolved. Never re-adds a StatusId a user has since manually removed from
--gSettings.CureMap, since it only fills in ones currently missing.
local function SeedDefaults()
    if (seeded) or (gSettings.CureMapSeeded) then
        seeded = true;
        return;
    end

    local existingStatusIds = {};
    for _,entry in ipairs(gSettings.CureMap) do
        existingStatusIds[entry.StatusId] = true;
    end

    local allResolved = true;
    for _,default in ipairs(DefaultCureSpells) do
        local match = matching:FindAnySpell(default.Name);
        if match then
            for _,statusId in ipairs(default.StatusIds) do
                if not existingStatusIds[statusId] then
                    gSettings.CureMap:append({
                        StatusId = statusId,
                        ActionType = match.ActionType,
                        ActionId = match.ActionId,
                        RequiredJob = default.RequiredJob,
                        RequiredLevel = default.RequiredLevel,
                        Enabled = true,
                    });
                    existingStatusIds[statusId] = true;
                end
            end
        else
            allResolved = false; --resource manager not ready yet; retry next tick
        end
    end

    if allResolved then
        gSettings.CureMapSeeded = true;
        seeded = true;
        settings.save();
    end
end

--Session-local guard, same pattern as `seeded` above -- this only needs to
--run once per session (or not at all, once it's already first), not every
--tick.
local reorderedSleep = false;

--One-time fix-up for settings files that already seeded Sleep (StatusId 2)
--BEFORE it was moved to the front of DefaultCureSpells above -- reordering
--DefaultCureSpells only affects fresh seeds, not gSettings.CureMap arrays
--that already exist (array order = insertion order = display order, see
--initializer.lua's Assignments doc comment for the same convention). Idempotent:
--no-op if Sleep isn't present yet (SeedDefaults hasn't run, or the resource
--manager wasn't ready) or is already at index 1.
local function ReorderSleepFirst()
    if (reorderedSleep) then
        return;
    end
    reorderedSleep = true;

    for i,entry in ipairs(gSettings.CureMap) do
        if (entry.StatusId == 2) then
            if (i > 1) then
                table.remove(gSettings.CureMap, i);
                table.insert(gSettings.CureMap, 1, entry);
                settings.save();
            end
            return;
        end
    end
end

--True if the LOCAL PLAYER can currently cast entry's cure spell/ability.
--Two modes (see DefaultCureSpells' doc comment):
--  entry.RequiredJob set   -> fixed single-job/level gate (unchanged from
--                             before -- Poisona/Paralyna/etc).
--  entry.RequiredJob nil   -> "any job that knows this spell", checked live
--                             against the spell resource's own per-job
--                             LevelRequired array -- same technique
--                             matching.lua's ListBuffs already uses,
--                             CONFIRMED live there (LevelRequired[jobId+1],
--                             +1 offset, -1/0 = can't learn).
--Replaces an earlier HasSpell-based design -- could not confirm that API
--exists in Ashita v4 (unverified against actual API, per reference doc);
--GetMainJob/GetMainJobLevel/GetSubJob/GetSubJobLevel are near-universally
--used across Ashita v4 addons, so considered lower-risk, but still
--unverified against this specific environment -- confirm on first in-game
--test.
local function CanCure(entry)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then
        return false;
    end

    if (entry.RequiredJob) then
        local mainAbbr = JobAbbrById[player:GetMainJob()];
        local subAbbr = JobAbbrById[player:GetSubJob()];
        if (mainAbbr == entry.RequiredJob) and (player:GetMainJobLevel() >= entry.RequiredLevel) then
            return true;
        end
        if (subAbbr == entry.RequiredJob) and (player:GetSubJobLevel() >= entry.RequiredLevel) then
            return true;
        end
        return false;
    end

    local ok, canCast = pcall(function()
        local res = AshitaCore:GetResourceManager():GetSpellById(entry.ActionId);
        if (not res) or (not res.LevelRequired) then
            return false;
        end
        local mainJob, mainLevel = player:GetMainJob(), player:GetMainJobLevel();
        local subJob, subLevel = player:GetSubJob(), player:GetSubJobLevel();
        local mainReq = res.LevelRequired[mainJob + 1];
        local subReq = res.LevelRequired[subJob + 1];
        local mainOk = (mainReq) and (mainReq > 0) and (mainLevel >= mainReq);
        local subOk = (subReq) and (subReq > 0) and (subLevel >= subReq);
        return (mainOk == true) or (subOk == true);
    end);
    --Was silent on failure before -- if this pcall ever errors (a job id
    --edge case, e.g. subJob==0 with no sub equipped, or some other
    --indexing surprise this specific environment produces), it used to
    --just return "can't cure" with zero trace anywhere. One-time warning
    --now, so a real internal error is distinguishable from a genuine
    --"doesn't meet the level requirement" result -- reported symptom
    --(sub-job Cure not triggering the Sleep alert, main-job Cure working
    --fine) needs this to rule the error case in or out before chasing
    --anything else.
    if (not ok) and (not warnedCanCureFailure) then
        warnedCanCureFailure = true;
        Error(string.format('BuffTrack: CanCure job-check failed (%s) for action id %u -- treating as not curable. Run /bufftrack debugspell [name] to inspect that spell\'s LevelRequired data.', tostring(canCast), entry.ActionId));
    end
    return (ok) and (canCast == true);
end

--Adds a single opt-in CureMap entry (Erase or otherwise) via config UI/command.
--Returns true if added, false if this StatusId is already mapped.
local function AddCureEntry(statusId, actionType, actionId, requiredJob, requiredLevel)
    for _,entry in ipairs(gSettings.CureMap) do
        if (entry.StatusId == statusId) then
            return false;
        end
    end
    gSettings.CureMap:append({
        StatusId = statusId,
        ActionType = actionType,
        ActionId = actionId,
        RequiredJob = requiredJob,
        RequiredLevel = requiredLevel,
        Enabled = true,
    });
    settings.save();
    return true;
end

--Per-entry enable/disable (config.lua's Cures tab checkbox) -- replaces an
--earlier Remove-button design: disabling keeps the entry (job/level/spell
--already resolved) so re-enabling later doesn't require re-adding it from
--scratch, per explicit design decision.
local function SetCureEnabled(statusId, enabled)
    for _,entry in ipairs(gSettings.CureMap) do
        if (entry.StatusId == statusId) then
            entry.Enabled = enabled;
            settings.save();
            return true;
        end
    end
    return false;
end

--Removes a CureMap entry ENTIRELY (unlike SetCureEnabled's disable-but-keep)
---- for the Cures tab's per-entry Remove button. Needed for e.g. an
--Erase-covered debuff accidentally claiming a StatusId a dedicated cure
--(Poisona, or the Cure-line Sleep entry) should have had instead --
--SeedDefaults only ever fills in what's MISSING (see its own comment), so
--a wrongly-seeded or duplicate entry permanently blocks the correct one
--from ever being added until the wrong one is removed.
local function RemoveCureEntry(statusId)
    for i,entry in ipairs(gSettings.CureMap) do
        if (entry.StatusId == statusId) then
            table.remove(gSettings.CureMap, i);
            settings.save();
            return true;
        end
    end
    return false;
end

--Full reset: clears every CureMap entry and re-arms the one-time seeding
--guards (gSettings.CureMapSeeded, the session-local `seeded`/
--`reorderedSleep` locals above) so the NEXT Tick() reseeds fresh from
--DefaultCureSpells, exactly as if this were a brand-new install. Does NOT
--touch CureOverrides -- any per-player override for a StatusId that no
--longer exists in CureMap simply never matches anything in Tick()'s loop
--afterward (harmless orphaned data, not worth cleaning up automatically).
local function ResetCureMapToDefaults()
    gSettings.CureMap = T{};
    gSettings.CureMapSeeded = false;
    seeded = false;
    reorderedSleep = false;
    settings.save();
end

--Erase's own resolved (ActionType, ActionId), cached -- used by config.lua's
--"add an Erase-covered debuff" flow so the user only has to type a status
--ID, not resolve the spell name themselves each time.
local eraseAction;
local function GetEraseAction()
    if not eraseAction then
        local match = matching:FindAnySpell('Erase');
        if match then
            eraseAction = { ActionType = match.ActionType, ActionId = match.ActionId };
        end
    end
    return eraseAction;
end

local exports = {};
exports.AddCureEntry = AddCureEntry;
exports.SetCureEnabled = SetCureEnabled;
exports.RemoveCureEntry = RemoveCureEntry;
exports.ResetCureMapToDefaults = ResetCureMapToDefaults;
exports.GetEraseAction = GetEraseAction;
--Exported for the Party tab's job-icon roster list (config.lua's
--DrawPartyTab) -- same job-id->abbreviation table CanCure above already
--uses internally, just made available outside this file too rather than
--duplicating it.
exports.JobAbbrById = JobAbbrById;

--Finds a CureOverrides entry by (player,debuff) identity, or nil.
local function FindOverride(targetName, statusId)
    for i,entry in ipairs(gSettings.CureOverrides) do
        if (entry.TargetName == targetName) and (entry.StatusId == statusId) then
            return entry, i;
        end
    end
    return nil;
end
exports.FindOverride = FindOverride;

--Sets/updates/clears a per-(player,debuff) override (Alt-click on a live
--Cures alert row -- see alertsgroup.lua's HandleMouse + config.lua's Entry
--Editor). overrides is a table with any subset of Scale/Color/
--SoundEnabled/SoundId; an explicit nil clears that field back to
--"inherit". If every field ends up nil, the entry is removed entirely
--rather than kept around inert -- see initializer.lua's CureOverrides doc
--comment.
local function SetCureOverride(targetName, statusId, overrides)
    local existing, index = FindOverride(targetName, statusId);
    local hasAny = (overrides.Scale ~= nil) or (overrides.Color ~= nil) or (overrides.SoundEnabled ~= nil) or (overrides.SoundId ~= nil) or (overrides.Flash ~= nil);

    if not hasAny then
        if existing then
            table.remove(gSettings.CureOverrides, index);
            settings.save();
        end
        return;
    end

    if existing then
        existing.Scale = overrides.Scale;
        existing.Color = overrides.Color;
        existing.SoundEnabled = overrides.SoundEnabled;
        existing.SoundId = overrides.SoundId;
        existing.Flash = overrides.Flash;
    else
        gSettings.CureOverrides:append({
            TargetName = targetName,
            StatusId = statusId,
            Scale = overrides.Scale,
            Color = overrides.Color,
            SoundEnabled = overrides.SoundEnabled,
            SoundId = overrides.SoundId,
            Flash = overrides.Flash,
        });
    end
    settings.save();
end
exports.SetCureOverride = SetCureOverride;

--Every CureOverrides entry for one player -- for the Party tab's
--per-player detail view (config.lua's DrawPartyTab), same idea as
--trackers/assignment.lua's GetAssignmentsForPlayer.
local function GetOverridesForPlayer(targetName)
    local results = T{};
    for _,entry in ipairs(gSettings.CureOverrides) do
        if (entry.TargetName == targetName) then
            results:append(entry);
        end
    end
    return results;
end
exports.GetOverridesForPlayer = GetOverridesForPlayer;

--Ensures a (player,debuff) override ROW exists, even fully blank (all four
--fields nil) -- for the Party tab's Add Cures popup, where CHECKING a
--debuff means "start customizing this player's version of it", not "turn
--this debuff on for them" (see initializer.lua's CureOverrides doc
--comment: the debuff itself is already globally alerted-on via CureMap,
--an override only exists to customize one player's copy of it).
--SetCureOverride can't be reused for this -- passing all-nil overrides is
--how IT deletes a row, the opposite of what "just checked the box" means
--here. No-op if a row already exists (never resets an existing
--customization back to blank).
local function CreateBlankOverride(targetName, statusId)
    if (FindOverride(targetName, statusId)) then
        return false;
    end
    gSettings.CureOverrides:append({
        TargetName = targetName,
        StatusId = statusId,
        Scale = nil,
        Color = nil,
        SoundEnabled = nil,
        SoundId = nil,
        Flash = nil,
    });
    settings.save();
    return true;
end
exports.CreateBlankOverride = CreateBlankOverride;

--Sets/updates/clears a per-DEBUFF ("spell specific") override -- the
--tier BELOW CureOverrides in the resolution order (see initializer.lua's
--CureMap doc comment). Reachable directly from the Cures config tab's
--Edit button (see config.lua's EditCureMapEntry) -- no live alert needed,
--unlike the per-player tier. Same all-nil-means-remove-nothing-to-store
--convention as SetCureOverride, except there's nothing TO remove here --
--the CureMap entry itself always exists (it's the debuff mapping), so
--this just clears the four fields back to nil rather than deleting a row.
local function SetCureMapEntryOverrides(statusId, overrides)
    for _,entry in ipairs(gSettings.CureMap) do
        if (entry.StatusId == statusId) then
            entry.Scale = overrides.Scale;
            entry.Color = overrides.Color;
            entry.SoundEnabled = overrides.SoundEnabled;
            entry.SoundId = overrides.SoundId;
            entry.Flash = overrides.Flash;
            settings.save();
            return true;
        end
    end
    return false;
end
exports.SetCureMapEntryOverrides = SetCureMapEntryOverrides;

--Session-local edge-detection set for the audio cue: unlike
--trackers/dispellable.lua's activeByKey (a persistent table this file has
--no equivalent of -- curable.lua is fully recomputed from live status
--presence every tick, see the file header), so "newly appeared" has to be
--tracked separately here rather than reusing an existing identity. Keyed
--the same way alerts themselves are implicitly identified: TargetName+StatusId.
local previouslyActiveKeys = {};

--[[
    Returns an array of currently-active, currently-curable alerts:
        { TargetName(string), StatusId(number), ActionType(string),
          ActionId(number), Label(string) }
    Recomputed fully every call -- nothing persists between ticks.
]]--
function exports:Tick()
    SeedDefaults();
    ReorderSleepFirst();

    local alerts = T{};
    if (#gSettings.CureMap == 0) then
        previouslyActiveKeys = {};
        return alerts;
    end

    local roster = assignmentTracker.GetRosterWithJobs();
    local currentActiveKeys = {};
    for name,info in pairs(roster) do
        --hasData is false for anyone outside the local party (or self) --
        --see partystatus.lua's hard limitation notes. Alliance members
        --simply never produce alerts, by design (§7.1 scope decision).
        local ids, hasData = partystatus.GetStatusIds(info.ServerId);
        if hasData then
            for statusId,_ in pairs(ids) do
                for _,entry in ipairs(gSettings.CureMap) do
                    if (entry.StatusId == statusId) and (entry.Enabled ~= false) and CanCure(entry) then
                        local override = FindOverride(name, statusId);

                        --Erase covers many different debuffs generically, so the
                        --cure spell's name alone ("Erase") doesn't say WHICH
                        --debuff a row is for -- unlike Poisona/Paralyna/etc,
                        --where the spell name already implies the debuff. Flag
                        --Erase-backed rows so the renderer can append the
                        --debuff name (see resources/renderers/alerts.lua's
                        --FormatCurable). Compared by (ActionType, ActionId)
                        --against GetEraseAction's cached resolution rather
                        --than by label, so a renamed/localized spell can't
                        --break the match.
                        local erase = GetEraseAction();
                        local isErase = (erase ~= nil) and (entry.ActionType == erase.ActionType) and (entry.ActionId == erase.ActionId);

                        --Explicit if/elseif for the three-tier cascade, NOT
                        --the `cond and X or Y` idiom the previous version
                        --used for Flash -- that idiom silently breaks when X
                        --is `false`: an explicit override.Flash=false (or
                        --entry.Flash=false) would fall through to the NEXT
                        --tier instead of applying, since `true and false` is
                        --`false`, which then evaluates the `or` branch. Not
                        --a risk for Scale/Color (never legitimately `false`),
                        --but Sound already used explicit if/elseif for
                        --exactly this reason -- Flash now matches.
                        local rowScale = entry.Scale or gSettings.CuresScale;
                        if (override and override.Scale) then
                            rowScale = override.Scale;
                        end

                        local rowColor = entry.Color or gSettings.CuresColor;
                        if (override and override.Color) then
                            rowColor = override.Color;
                        end

                        local rowFlash;
                        if (override and override.Flash ~= nil) then
                            rowFlash = override.Flash;
                        elseif (entry.Flash ~= nil) then
                            rowFlash = entry.Flash;
                        else
                            rowFlash = gSettings.CuresFlash;
                        end

                        alerts:append({
                            TargetName = name,
                            StatusId = statusId,
                            ActionType = entry.ActionType,
                            ActionId = entry.ActionId,
                            Label = assignmentTracker.GetActionLabel(entry.ActionType, entry.ActionId),
                            --For the Cures tab's optional per-row job icon
                            --(gSettings.CuresShowJobIcon) -- nil if the job
                            --id didn't resolve to a known abbreviation,
                            --which the renderer/uiskin:GetJobIcon already
                            --treat as "skip the icon", same as everywhere
                            --else a job lookup can come back empty.
                            JobAbbr = JobAbbrById[info.MainJob],
                            --Debuff this row is actually for, shown after the
                            --cure name ONLY for Erase-backed rows (ShowDebuffName)
                            ---- see isErase above.
                            DebuffName = matching:GetDebuffName(statusId),
                            ShowDebuffName = isErase,
                            --Three-tier cascade for all four properties, same
                            --order: per-(player,debuff) override -> per-
                            --debuff ("spell specific", CureMap-level)
                            --override -> global Cures* tier (see
                            --initializer.lua's doc comments). Scale/Color
                            --STILL fall through to the renderer's own
                            --defaults (Layout scale / hardcoded white) if
                            --gSettings.CuresScale/CuresColor are themselves
                            --nil -- see resources/renderers/alerts.lua's
                            --DrawSection.
                            Scale = rowScale,
                            Color = rowColor,
                            --Continuous pulse while the row is shown -- not a
                            --grace-window blink like Grid's FlashOnExpire (no
                            --such window exists for a presence-based alert).
                            Flash = rowFlash,
                            --Not read by the renderer (Sound isn't a visual
                            --property) -- carried on the alert purely so
                            --config.lua's Entry Editor (opened via Alt-click
                            --on this live row) can show the currently-
                            --effective sound override, without a separate
                            --lookup.
                            SoundEnabled = (override and override.SoundEnabled ~= nil) and override.SoundEnabled or entry.SoundEnabled,
                            SoundId = (override and override.SoundId) or entry.SoundId,
                        });
                        local key = string.format('%s:%u', name, statusId);
                        currentActiveKeys[key] = true;
                        --Audio cue: fires only the tick this exact
                        --(player, debuff) pair FIRST becomes curable, not
                        --every tick it stays active -- same one-shot intent
                        --as trackers/dispellable.lua's new-alert firing
                        --point, just edge-detected against
                        --previouslyActiveKeys instead of a persistent table
                        --since this tracker has none. Same three-tier
                        --cascade as Scale/Color above: (player,debuff)
                        --override -> CureMap-level override ->
                        --gSettings.CuresSound.
                        if not previouslyActiveKeys[key] then
                            local soundEnabled;
                            local soundId;
                            if (override and override.SoundEnabled ~= nil) then
                                soundEnabled = override.SoundEnabled;
                                soundId = override.SoundId;
                            elseif (entry.SoundEnabled ~= nil) then
                                soundEnabled = entry.SoundEnabled;
                                soundId = entry.SoundId;
                            else
                                soundEnabled = gSettings.CuresSound and gSettings.CuresSound.Enabled;
                                soundId = gSettings.CuresSound and gSettings.CuresSound.SoundId;
                            end
                            if (soundEnabled) and (gSounds) then
                                gSounds:Play(soundId or (override and override.SoundId) or entry.SoundId);
                            end
                        end
                    end
                end
            end
        end
    end
    previouslyActiveKeys = currentActiveKeys;

    --Sorted by PlayerPriority (see initializer.lua's doc comment) descending,
    --tie-broken by TargetName ascending for a stable order between equal-
    --priority players. This ALSO fixes a latent ordering bug independent of
    --priority/grouping features: the roster loop above walks a plain Lua
    --table via pairs(), which has no guaranteed order at all -- without this
    --sort, row order (and therefore anything relying on "same target's rows
    --are adjacent", i.e. CuresGroupDivider) could jitter frame to frame even
    --with priority left at its 0 default for everyone.
    table.sort(alerts, function(a, b)
        local priorityA = gSettings.PlayerPriority[a.TargetName] or 0;
        local priorityB = gSettings.PlayerPriority[b.TargetName] or 0;
        if (priorityA ~= priorityB) then
            return priorityA > priorityB;
        end
        return a.TargetName < b.TargetName;
    end);

    return alerts;
end

return exports;
