--[[
    callbacks.lua

    Sprite setup, d3d_present render loop, mouse passthrough, and
    /bufftrack command handling.
]]--

local d3d = require('d3d8');
local ffi = require('ffi');
local assignmentTracker = require('trackers.assignment');
local curableTracker = require('trackers.curable');
local dispellableTracker = require('trackers.dispellable');
local matching = require('matching');
local config = require('config');
local GridGroup = require('gridgroup');

local sprite = ffi.new('ID3DXSprite*[1]');
if (ffi.C.D3DXCreateSprite(d3d.get_device(), sprite) == ffi.C.S_OK) then
    sprite = d3d.gc_safe_release(ffi.cast('ID3DXSprite*', sprite[0]));
else
    sprite = nil;
    Error('Failed to create sprite.');
end

local watchDebugEnabled = false;

--Preview Alerts (config.lua's Behavior tab checkbox, config.State.
--PreviewAlerts): synthetic rows for visual QA (does the scale/color/sound
--actually look right), NOT the primary way to create overrides anymore --
--that's the Cures tab's "Player-Specific Overrides" section (pick player
--+ debuff, Edit, no live alert or full-roster enumeration needed). This
--used to build one row per roster-member x CureMap-entry, which made the
--panel unusably long for anything bigger than a tiny party -- now it's
--just one baseline row per CureMap entry (the spell-wide default
--appearance) plus one row per (player,debuff) override that ACTUALLY
--exists (gSettings.CureOverrides is naturally short -- only configured
--pairs are in it at all), so the list stays proportional to how much has
--actually been configured, not to roster size x entry count.
local function BuildPreviewCuresAlerts()
    local alerts = T{};

    local baselineName = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    if (baselineName == nil) or (baselineName == '') then
        baselineName = 'Example';
    end

    for _,entry in ipairs(gSettings.CureMap) do
        alerts:append({
            TargetName = baselineName,
            StatusId = entry.StatusId,
            ActionType = entry.ActionType,
            ActionId = entry.ActionId,
            Label = assignmentTracker.GetActionLabel(entry.ActionType, entry.ActionId),
            --Entry-level ("spell specific") only, deliberately NOT looking
            --up a per-player override for baselineName here -- this row is
            --meant to show the DEFAULT appearance, even on the off chance
            --the local player happens to have their own override set.
            Scale = entry.Scale,
            Color = entry.Color,
            SoundEnabled = entry.SoundEnabled,
            SoundId = entry.SoundId,
        });
    end

    for _,ov in ipairs(gSettings.CureOverrides) do
        local entry;
        for _,e in ipairs(gSettings.CureMap) do
            if (e.StatusId == ov.StatusId) then
                entry = e;
                break;
            end
        end
        if entry then
            alerts:append({
                TargetName = ov.TargetName,
                StatusId = ov.StatusId,
                ActionType = entry.ActionType,
                ActionId = entry.ActionId,
                Label = assignmentTracker.GetActionLabel(entry.ActionType, entry.ActionId),
                --Same cascade as the real thing (trackers/curable.lua:Tick):
                --this override wins, falling back to the CureMap entry's
                --own spell-wide setting.
                Scale = ov.Scale or entry.Scale,
                Color = ov.Color or entry.Color,
                SoundEnabled = (ov.SoundEnabled ~= nil) and ov.SoundEnabled or entry.SoundEnabled,
                SoundId = ov.SoundId or entry.SoundId,
            });
        end
    end

    return alerts;
end

local function BuildPreviewWatchAlerts()
    local alerts = T{};
    for _,entry in ipairs(gSettings.EnemyBuffWatchList) do
        alerts:append({
            TargetName = 'Preview Enemy',
            Label = entry.Label,
            ElapsedSeconds = 0,
            ActionType = entry.ActionType,
            ActionId = entry.ActionId,
            --Entry-level ("per watched action") override, same shape as
            --Cures' CureMap-level tier -- see trackers/dispellable.lua:Tick.
            Scale = entry.Scale,
            Color = entry.Color,
            SoundEnabled = entry.SoundEnabled,
            SoundId = entry.SoundId,
        });
    end
    return alerts;
end

ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    config:Render();
    gCurableAlerts = curableTracker:Tick();
    gDispellableAlerts = dispellableTracker:Tick();

    --Preview substitutes what actually gets RENDERED below, but the real
    --Tick() calls above still run every frame regardless -- CureMapSeeded/
    --the sound edge-detection/etc all need to keep working normally in the
    --background, and a real alert firing its real sound while Preview
    --happens to also be on is fine (additive, not a conflict).
    local curesForRender = gCurableAlerts;
    local watchForRender = gDispellableAlerts;
    if (config.State.PreviewAlerts[1]) then
        curesForRender = BuildPreviewCuresAlerts();
        watchForRender = BuildPreviewWatchAlerts();
    end

    if (sprite == nil) or ((gSettings.HideWithPrimitives == true) and (AshitaCore:GetPrimitiveManager():GetVisible() == false)) then
        return;
    end

    sprite:Begin();
    if (gSettings.GridGroupBy == 'Player') then
        --One panel per player instead of the classic singleton -- see
        --gridgroup.lua's SyncPlayerPanels. Same tickData either way, each
        --panel filters to its own player internally (self.PlayerFilter).
        local tickData = assignmentTracker:Tick();
        local playerPanels = GridGroup.SyncPlayerPanels(tickData);
        for _,panel in ipairs(playerPanels) do
            panel:Render(sprite, tickData);
            panel:RenderTooltip(sprite);
        end
    else
        gPanel:Render(sprite, assignmentTracker:Tick());
        gPanel:RenderTooltip(sprite);
    end
    gCuresPanel:Render(sprite, curesForRender);
    gCuresPanel:RenderTooltip(sprite);
    gWatchPanel:Render(sprite, watchForRender);
    gWatchPanel:RenderTooltip(sprite);
    sprite:End();
end);

ashita.events.register('mouse', 'mouse_cb', function (e)
    if (gSettings.GridGroupBy == 'Player') then
        for _,panel in pairs(GridGroup.GetPlayerPanels()) do
            panel:HandleMouse(e);
        end
    else
        gPanel:HandleMouse(e);
    end
    gCuresPanel:HandleMouse(e);
    gWatchPanel:HandleMouse(e);
end);

local function PrintUsage()
    print(chat.header('BuffTrack') .. chat.message('Command Descriptions:'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack') .. chat.message(' - Opens configuration menu.'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack [buff] [player]') .. chat.message(' - Assigns a buff to a party/alliance member.'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack cbuff [buff]') .. chat.message(' - Removes an entire buff column (all players).'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack cplayer [player]') .. chat.message(' - Removes an entire player row (all buffs).'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack watch [spell|ability|mobskill] [name]') .. chat.message(' - Adds an enemy-buff watch entry.'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack unwatch [name]') .. chat.message(' - Removes a watch entry.'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack watchdebug') .. chat.message(' - Toggles printing every enemy action seen (Type/Id/Param/Messages), for diagnosing watch entries that won\'t trigger.'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack debugspell [name]') .. chat.message(' - Prints the spell resource\'s raw LevelRequired field, for diagnosing the Buffs tab\'s job/level filter.'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack reposition') .. chat.message(' - Starts reposition mode for ALL THREE panels (Grid/Cures/Watch); drag any to move it.'));
    print(chat.header('BuffTrack') .. chat.color1(2, '/bufftrack lock') .. chat.message(' - Ends repositioning mode and saves all three panels\' positions.'));
end

local function PrintCandidates(label, candidates)
    if (#candidates == 0) then
        Error(string.format('No match found for $H%s$R.', label));
    else
        Error(string.format('$H%s$R is ambiguous. Closest matches:', label));
        for _,c in ipairs(candidates) do
            print(chat.header('BuffTrack') .. chat.message('  ' .. c));
        end
    end
end

local function HandleAdd(buffQuery, playerQuery)
    local buffMatch, buffCandidates = matching:FindBuff(buffQuery);
    if not buffMatch then
        PrintCandidates(buffQuery, buffCandidates);
        return;
    end

    local roster = assignmentTracker.GetRoster();
    local playerMatch, playerCandidates = matching:FindPlayer(playerQuery, roster);
    if not playerMatch then
        PrintCandidates(playerQuery, playerCandidates);
        return;
    end

    local added = assignmentTracker.AddAssignment(buffMatch.ActionType, buffMatch.ActionId, buffMatch.BuffId, playerMatch);
    if added then
        Message(string.format('Now tracking $H%s$R on $H%s$R.', buffMatch.Label, playerMatch));
    else
        Error(string.format('$H%s$R is already being tracked on $H%s$R.', buffMatch.Label, playerMatch));
    end
end

local function HandleClearBuff(buffQuery)
    local buffMatch, candidates = matching:FindAssignedBuff(buffQuery);
    if not buffMatch then
        PrintCandidates(buffQuery, candidates);
        return;
    end
    assignmentTracker.RemoveColumn(buffMatch.ActionType, buffMatch.ActionId);
    Message(string.format('Cleared all tracking for $H%s$R.', buffMatch.Label));
end

local function HandleClearPlayer(playerQuery)
    local assignedNames = assignmentTracker.GetAssignedTargetNames();
    local match, candidates = matching:FindAssignedPlayer(playerQuery, assignedNames);
    if not match then
        PrintCandidates(playerQuery, candidates);
        return;
    end
    assignmentTracker.RemoveRow(match);
    Message(string.format('Cleared all tracking for $H%s$R.', match));
end

--kindArg: 'spell', 'ability', or 'mobskill' (optional -- if omitted, tries
--spell then ability then mobskill, since most watch-list entries will be
--spells/abilities and this keeps the common case a one-word-shorter
--command).
local function HandleWatch(kindArg, nameQuery)
    local kind = kindArg and string.lower(kindArg);
    if (kind ~= 'spell') and (kind ~= 'ability') and (kind ~= 'mobskill') then
        --No explicit kind given -- kindArg was actually the start of the name.
        nameQuery = kindArg and (kindArg .. ' ' .. (nameQuery or '')) or nameQuery;
        kind = nil;
    end

    local match, candidates;
    if (kind == 'spell') then
        match, candidates = matching:FindAnySpell(nameQuery);
    elseif (kind == 'ability') then
        match, candidates = matching:FindAnyAbility(nameQuery);
    elseif (kind == 'mobskill') then
        match, candidates = matching:FindAnyMobSkill(nameQuery);
    else
        --Spell is DELIBERATELY EXCLUDED from the default (no-kind-given)
        --search entirely -- not just deprioritized. Watch only ever cares
        --about what an ENEMY casts on itself; Blue Magic spells sharing a
        --name with the ability/mobskill version they're learned from (e.g.
        --Cocoon) are pure noise here, since enemies never cast the player
        --Spell version. MobSkill is tried before Ability, matching the
        --earlier fix's same reasoning for MobSkill-vs-Spell collisions.
        --Explicit /bufftrack watch spell [name] still works exactly as
        --before, for the rare case the spell version is genuinely wanted
        --(e.g. testing, or a non-BLU spell with no ability/mobskill
        --namesake at all).
        match, candidates = matching:FindAnyMobSkill(nameQuery);
        if not match then
            match, candidates = matching:FindAnyAbility(nameQuery);
        end
    end

    if not match then
        PrintCandidates(nameQuery, candidates or T{});
        return;
    end

    local added = dispellableTracker.AddWatch(match.ActionType, match.ActionId, match.Label);
    if added then
        Message(string.format('Now watching for $H%s$R cast by enemies.', match.Label));
    else
        Error(string.format('$H%s$R is already on the watch list.', match.Label));
    end
end

local function HandleUnwatch(nameQuery)
    local candidates = T{};
    for _,entry in ipairs(gSettings.EnemyBuffWatchList) do
        candidates:append({ Label = entry.Label, ActionType = entry.ActionType, ActionId = entry.ActionId });
    end
    local FuzzyMatchWatch = function()
        --matching.lua's fuzzy strategy isn't exposed as a generic "match
        --against this candidate list" call, so this does the simple case
        --directly: exact label match first, then substring -- the watch
        --list is expected to stay short, so no edit-distance fallback is
        --needed.
        local q = string.lower(nameQuery);
        for _,c in ipairs(candidates) do
            if (string.lower(c.Label) == q) then
                return c;
            end
        end
        local matches = T{};
        for _,c in ipairs(candidates) do
            if (string.lower(c.Label):find(q, 1, true)) then
                matches:append(c);
            end
        end
        if (#matches == 1) then
            return matches[1];
        end
        return nil, matches;
    end;

    local match, ambiguous = FuzzyMatchWatch();
    if not match then
        local labels = T{};
        for _,c in ipairs(ambiguous or T{}) do
            labels:append(c.Label);
        end
        PrintCandidates(nameQuery, labels);
        return;
    end

    dispellableTracker.RemoveWatch(match.ActionType, match.ActionId);
    Message(string.format('Removed $H%s$R from the watch list.', match.Label));
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or string.lower(args[1]) ~= '/bufftrack') then
        return;
    end
    e.blocked = true;

    if (#args == 1) then
        config:Show();
        return;
    end

    local sub = string.lower(args[2]);

    if (sub == 'reposition') then
        gPanel.AllowDrag = true;
        gCuresPanel.AllowDrag = true;
        gWatchPanel.AllowDrag = true;
        for _,panel in pairs(GridGroup.GetPlayerPanels()) do
            panel.AllowDrag = true;
        end
        return;
    end

    if (sub == 'lock') then
        gPanel.AllowDrag = false;
        gCuresPanel.AllowDrag = false;
        gWatchPanel.AllowDrag = false;
        --Usually redundant (HandleMouse already commits position to
        --gSettings on mouse-up while dragging), but harmless insurance in
        --case /bufftrack lock is typed before releasing the mouse.
        gPanel:CommitPosition();
        gCuresPanel:CommitPosition();
        gWatchPanel:CommitPosition();
        for _,panel in pairs(GridGroup.GetPlayerPanels()) do
            panel.AllowDrag = false;
            panel:CommitPosition();
        end
        return;
    end

    if (sub == 'cbuff') then
        if (#args >= 3) then
            HandleClearBuff(args[3]);
        else
            PrintUsage();
        end
        return;
    end

    if (sub == 'cplayer') then
        if (#args >= 3) then
            HandleClearPlayer(args[3]);
        else
            PrintUsage();
        end
        return;
    end

    if (sub == 'watch') then
        if (#args >= 3) then
            HandleWatch(args[3], args[4]);
        else
            PrintUsage();
        end
        return;
    end

    if (sub == 'unwatch') then
        if (#args >= 3) then
            HandleUnwatch(args[3]);
        else
            PrintUsage();
        end
        return;
    end

    if (sub == 'watchdebug') then
        watchDebugEnabled = not watchDebugEnabled;
        dispellableTracker.SetDebug(watchDebugEnabled);
        Message(string.format('Watch debug capture %s.', watchDebugEnabled and 'ON' or 'OFF'));
        return;
    end

    if (sub == 'debugspell') then
        --Diagnostic for the Buffs tab's job/level filter: prints exactly
        --what Ashita's spell resource actually exposes for LevelRequired,
        --rather than continuing to guess at its shape. See
        --matching.lua:ListBuffs for where the guess currently lives.
        if (#args < 3) then
            PrintUsage();
            return;
        end
        local nameQuery = args[3];
        local match, candidates = matching:FindAnySpell(nameQuery);
        if not match then
            PrintCandidates(nameQuery, candidates or T{});
            return;
        end
        local res = AshitaCore:GetResourceManager():GetSpellById(match.ActionId);
        if not res then
            Error(string.format('No resource found for %s (id %u).', match.Label, match.ActionId));
            return;
        end
        print(chat.header('BuffTrack') .. chat.message(string.format('[debugspell] %s (id %u)', match.Label, match.ActionId)));
        local lr = res.LevelRequired;
        print(chat.header('BuffTrack') .. chat.message(string.format('  LevelRequired type: %s', type(lr))));
        --Try actual indexed access regardless of type() -- Ashita's
        --structures are often userdata with a metatable providing
        --array-style access, so type()~='table' doesn't necessarily mean
        --lr[i] fails. This is the actual operation ListBuffs relies on.
        for i = 0,25 do
            local ok, v = pcall(function () return lr[i]; end);
            if (ok) then
                if (v ~= nil) then
                    print(chat.header('BuffTrack') .. chat.message(string.format('  [%u] = %s', i, tostring(v))));
                end
            else
                print(chat.header('BuffTrack') .. chat.message(string.format('  [%u] indexing ERROR: %s', i, tostring(v))));
                break;
            end
        end
        return;
    end

    --Anything else is treated as [buff] [player] for adding an assignment.
    if (#args >= 3) then
        HandleAdd(args[2], args[3]);
    else
        PrintUsage();
    end
end);
