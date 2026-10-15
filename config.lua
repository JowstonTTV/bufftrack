--[[
    config.lua

    ImGui window for BuffTrack -- a "Behavior" tab for thresholds/general
    settings/panel layout, and a "Buffs" tab that lists current buff
    assignments and lets you add/remove/edit them, plus "Cures" and
    "Watch" tabs for the §7.1/§7.2 alert panels' own settings. Uses
    ##-suffixed widget IDs throughout to avoid ID collisions between
    otherwise-identically-labeled controls across tabs.
]]--

local imgui = require('imgui');
local assignmentTracker = require('trackers.assignment');
local curableTracker = require('trackers.curable');
local dispellableTracker = require('trackers.dispellable');
local matching = require('matching');
local spellcosts = require('spellcosts');
local spellDescriptions = require('libs.spelldescriptions');
local sounds = require('libs.sounds');
local uiskin = require('libs.uiskin');
--Shared with uiskin's own theme (gold accent) rather than a separate
--hardcoded color, so section headers match the rest of the window's
--palette instead of clashing with it.
local header = uiskin.HeaderColor;

local config = {
    State = {
        IsOpen = { false },
        Selected = nil, --key of the selected assignment row, "ActionType:ActionId:TargetName"
        --Ephemeral master-checkbox display value, NOT a persisted setting --
        --clicking it bulk-writes FlashOnExpire to every current assignment
        --(assignmentTracker.SetFlashOnExpireAll) and is then forgotten;
        --entries can drift apart again afterward via their own checkboxes.
        MasterFlashOnExpire = { true },
        --Text input buffer for the Cures tab's "add an Erase-covered debuff"
        --row -- a debuff NAME ("Bio", "Dia"), resolved via
        --matching:FindDebuffStatus rather than asking the user to know/type
        --a raw status id.
        NewEraseDebuffName = { '' },
        --Buffs tab state: which spell is selected in the left-hand list
        --(nil = nothing selected yet), and the filter text for that list.
        SelectedBuff = nil,
        BuffsFilterText = { '' },
        --Entry Editor popup state (Alt-click a grid cell -- see
        --gridgroup.lua's HandleMouse). nil = popup closed. When open, holds
        --a working COPY of the cell's overrides (ActionType/ActionId/
        --TargetName/ColumnLabel identify which assignment; Scale/Color/
        --SoundEnabled/SoundId are edited here and only committed to
        --gSettings on "Apply", via assignmentTracker.SetEntryOverrides).
        EditingEntry = nil,
        --Testing aid (Behavior tab): when true, callbacks.lua's render
        --loop substitutes synthetic rows for the Cures/Watch panels --
        --visual QA (does Scale/Color/Sound look right), NOT the primary
        --way to CREATE overrides (see the Cures tab's Player-Specific
        --Overrides section for that). Session-only, NOT a persisted
        --gSettings field -- always starts off on reload/relog, so it can't
        --accidentally stay on and hide real alerts behind fake ones in a
        --future session.
        PreviewAlerts = { false },
        --Cures tab's "Add Override" picker (see DrawCuresTab) -- which
        --player/debuff are currently selected in the two dropdowns before
        --hitting Edit. nil = nothing picked yet in that dropdown.
        OverridePlayerName = nil,
        OverrideStatusId = nil,
        --Party tab state (see DrawPartyTab) -- which roster member is
        --currently selected (nil = none), and the two Add popups' state.
        --Popups are separate windows (same pattern as EditingEntry above),
        --so they can float independently of the main tabbed window.
        PartySelectedPlayer = nil,
        AddBuffsPopup = { Open = false, FilterText = { '' } },
        AddCuresPopup = { Open = false },
    },
};

--Packs an ImGui ColorEdit4 float4 ({r,g,b,a}, 0-1 each) into the same
--0xAARRGGBB uint32 shape Assignments[i].Color / resources/renderers/
--grid.lua's UnpackARGB expect.
local function Float4ToARGB(col)
    local function to255(v) return math.floor((v * 255) + 0.5); end
    return (to255(col[4]) * 0x1000000) + (to255(col[1]) * 0x10000) + (to255(col[2]) * 0x100) + to255(col[3]);
end

--Inverse of Float4ToARGB, for populating ColorEdit4 from a stored override.
local function ARGBToFloat4(argb)
    local a = bit.band(bit.rshift(argb, 24), 0xFF);
    local r = bit.band(bit.rshift(argb, 16), 0xFF);
    local g = bit.band(bit.rshift(argb, 8), 0xFF);
    local b = bit.band(argb, 0xFF);
    return { r / 255, g / 255, b / 255, a / 255 };
end

local function AssignmentKey(entry)
    return string.format('%s:%u:%s', entry.ActionType, entry.ActionId, entry.TargetName);
end

--Shared Enabled-checkbox + sound-dropdown control, used by the Behavior tab
--(GridSound), Cures tab (CuresSound), Watch tab (WatchSound), and the Entry
--Editor popup (per-entry override). Takes get/set closures rather than a
--direct table reference so the same drawing code works whether the target
--is a gSettings sub-table (GridSound.Enabled) or a plain field on a working
--copy (the Entry Editor's e.SoundEnabled).
local function DrawSoundPicker(idSuffix, getEnabled, setEnabled, getSoundId, setSoundId)
    local enabledBuffer = { getEnabled() };
    if imgui.Checkbox('Play Sound##BuffTrackSoundEnabled' .. idSuffix, enabledBuffer) then
        setEnabled(enabledBuffer[1]);
    end

    --Dropdown + Preview are always visible, regardless of the Enabled
    --checkbox above -- picking and auditioning a sound BEFORE turning the
    --cue on is the point of a preview button; gating either behind Enabled
    --would mean enabling the cue just to hear/choose a sound first.
    imgui.SameLine();
    local currentId = getSoundId();
    imgui.SetNextItemWidth(140);
    if imgui.BeginCombo('##BuffTrackSoundPicker' .. idSuffix, sounds:GetLabel(currentId)) then
        for _,s in ipairs(sounds.Available) do
            if imgui.Selectable(string.format('%s##BuffTrackSoundOption%s%s', s.label, idSuffix, s.id), (s.id == currentId)) then
                setSoundId(s.id);
            end
        end
        imgui.EndCombo();
    end

    imgui.SameLine();
    if imgui.Button('Preview##BuffTrackSoundPreview' .. idSuffix) then
        if (gSounds) then
            gSounds:Play(getSoundId());
        end
    end
end

function config:DrawBehaviorTab()
    --Lazy require, not file-top-level -- gridgroup.lua already requires
    --'config' at ITS top level (for the Entry Editor forward reference),
    --so a top-level require('gridgroup') here would be a genuine circular
    --require and could return an incomplete module depending on which file
    --loads first. By the time this function actually RUNS (a render
    --frame), gridgroup.lua has long since finished loading and this just
    --returns the cached module, same as any other require.
    local GridGroup = require('gridgroup');
    if imgui.BeginTabItem('Behavior##BuffTrackConfigBehaviorTab') then
        imgui.TextColored(header, 'Attention Threshold');
        imgui.ShowHelp('Seconds of remaining duration at which a cell switches from Active to Attention.');
        local buffer = { gSettings.AttentionThreshold };
        if (imgui.SliderFloat('##BuffTrackAttentionThreshold', buffer, 1, 60, '%.0f', ImGuiSliderFlags_AlwaysClamp)) then
            gSettings.AttentionThreshold = buffer[1];
            settings.save();
        end

        imgui.TextColored(header, 'Attention Grace');
        imgui.ShowHelp('Seconds a cell stays in the Attention state after a buff actually expires, before dropping to Not Active.');
        buffer = { gSettings.AttentionGrace };
        if (imgui.SliderFloat('##BuffTrackAttentionGrace', buffer, 1, 60, '%.0f', ImGuiSliderFlags_AlwaysClamp)) then
            gSettings.AttentionGrace = buffer[1];
            settings.save();
        end

        imgui.TextColored(header, 'Draw Scale');
        imgui.ShowHelp('Each tracker scales independently. Individual cells in the grid can be scaled further via Alt-click.');
        buffer = { gSettings.GridScale };
        if (imgui.SliderFloat('Grid##BuffTrackGridScale', buffer, 0.5, 3, '%.2f', ImGuiSliderFlags_AlwaysClamp)) then
            gSettings.GridScale = buffer[1];
            settings.save();
        end
        buffer = { gSettings.CuresScale };
        if (imgui.SliderFloat('Cures##BuffTrackCuresScale', buffer, 0.5, 3, '%.2f', ImGuiSliderFlags_AlwaysClamp)) then
            gSettings.CuresScale = buffer[1];
            settings.save();
        end
        buffer = { gSettings.WatchScale };
        if (imgui.SliderFloat('Watch##BuffTrackWatchScale', buffer, 0.5, 3, '%.2f', ImGuiSliderFlags_AlwaysClamp)) then
            gSettings.WatchScale = buffer[1];
            settings.save();
        end

        imgui.TextColored(header, 'Panel Lock');
        --Mirrors the /bufftrack reposition + /bufftrack lock chat commands
        --exactly (all three panels lock/unlock together, same as those
        --commands already did) -- this is just a UI front-end for the same
        --AllowDrag flip, not a new setting. Session-only (same as those
        --commands), not persisted -- all three panels always start locked
        --on login regardless of how they were left last session.
        local locked = not gPanel.AllowDrag;
        local lockBuffer = { locked };
        if imgui.Checkbox('Lock Panels##BuffTrackConfig_LockPanels', lockBuffer) then
            local newLocked = lockBuffer[1];
            gPanel.AllowDrag = not newLocked;
            gCuresPanel.AllowDrag = not newLocked;
            gWatchPanel.AllowDrag = not newLocked;
            for _,panel in pairs(GridGroup.GetPlayerPanels()) do
                panel.AllowDrag = not newLocked;
                if newLocked then
                    panel:CommitPosition();
                end
            end
            if newLocked then
                --Usually redundant (HandleMouse already commits position on
                --mouse-up while dragging), but harmless insurance in case
                --this is unchecked mid-drag -- same reasoning /bufftrack
                --lock's own insurance write already had.
                gPanel:CommitPosition();
                gCuresPanel:CommitPosition();
                gWatchPanel:CommitPosition();
            end
        end
        imgui.ShowHelp('Unchecked = all panels (Grid/Cures/Watch, plus any active per-player panels) can be dragged (same as /bufftrack reposition). Checked = positions are fixed (same as /bufftrack lock).');

        imgui.TextColored(header, 'Preview Alerts');
        imgui.Checkbox('Show All Alert Rows##BuffTrackConfig_PreviewAlerts', self.State.PreviewAlerts);
        imgui.ShowHelp('Visual check only -- shows one baseline row per Cures/Watch entry, plus one row per player-specific override that actually exists, so you can see what Scale/Color/Sound settings actually look like without waiting for a real debuff or enemy buff. To CREATE a new player-specific override, use the Cures tab\'s "Player-Specific Overrides" section instead of this -- it doesn\'t require Preview or a live alert either. Turns off automatically on relog; real alerts keep working normally underneath.');

        imgui.TextColored(header, 'Panel Alignment');
        local snapBuffer = { gSettings.SnapEnabled };
        if imgui.Checkbox('Snap Panels When Close##BuffTrackConfig_SnapEnabled', snapBuffer) then
            gSettings.SnapEnabled = snapBuffer[1];
            settings.save();
        end
        imgui.ShowHelp('While repositioning (/bufftrack reposition), releasing a panel near another one\'s edge snaps them into alignment. Checked against ALL other panels (Grid/Cures/Watch), not just one fixed partner.');
        if (gSettings.SnapEnabled) then
            buffer = { gSettings.SnapDistance };
            if (imgui.SliderFloat('Snap Distance##BuffTrackSnapDistance', buffer, 2, 40, '%.0f px', ImGuiSliderFlags_AlwaysClamp)) then
                gSettings.SnapDistance = buffer[1];
                settings.save();
            end
        end

        imgui.TextColored(header, 'Audio Cues');
        imgui.ShowHelp('Volume applies to every sound this addon plays, across all three trackers. Cures/Watch each have their own enable+sound picker on their own tabs; this one is for the Grid (plays when a cell enters the Attention state).');
        buffer = { gSettings.AlarmVolume };
        if imgui.SliderFloat('Volume##BuffTrackAlarmVolume', buffer, 0, 100, '%.0f', ImGuiSliderFlags_AlwaysClamp) then
            gSettings.AlarmVolume = buffer[1];
            settings.save();
        end
        DrawSoundPicker('Grid',
            function() return gSettings.GridSound.Enabled; end,
            function(v) gSettings.GridSound.Enabled = v; settings.save(); end,
            function() return gSettings.GridSound.SoundId; end,
            function(v) gSettings.GridSound.SoundId = v; settings.save(); end);

        imgui.TextColored(header, 'General');
        local buffer2 = { gSettings.Enabled };
        if (imgui.Checkbox('Enabled##BuffTrackConfig_Enabled', buffer2)) then
            gSettings.Enabled = buffer2[1];
            settings.save();
        end
        imgui.ShowHelp('If not enabled, the grid won\'t be drawn at all.');

        buffer2 = { gSettings.UseTooltips };
        if (imgui.Checkbox('Show Tooltips##BuffTrackConfig_UseTooltips', buffer2)) then
            gSettings.UseTooltips = buffer2[1];
            settings.save();
        end
        imgui.ShowHelp('When enabled, hovering a cell will show a tooltip if available.');

        buffer2 = { gSettings.ShowTenths };
        if (imgui.Checkbox('Show Tenths of a Second##BuffTrackConfig_ShowTenths', buffer2)) then
            gSettings.ShowTenths = buffer2[1];
            settings.save();
        end
        imgui.ShowHelp('When enabled, durations under a minute show a decimal (e.g. "45.3" instead of "45").');

        buffer2 = { gSettings.HideWithPrimitives };
        if (imgui.Checkbox('Hide With Primitives##BuffTrackConfig_HideWithPrimitives', buffer2)) then
            gSettings.HideWithPrimitives = buffer2[1];
            settings.save();
        end
        imgui.ShowHelp('When enabled, BuffTrack won\'t be drawn while Ashita\'s primitive manager is hidden.');

        imgui.TextColored(header, 'Grid Layout');
        local groupByBuff = (gSettings.GridGroupBy ~= 'Player');
        if imgui.RadioButton('By Buff##BuffTrackGroupByBuff', groupByBuff) then
            gSettings.GridGroupBy = 'Buff';
            settings.save();
        end
        imgui.SameLine();
        if imgui.RadioButton('By Player##BuffTrackGroupByPlayer', not groupByBuff) then
            gSettings.GridGroupBy = 'Player';
            settings.save();
        end
        imgui.ShowHelp('By Buff: one panel, columns=buffs, rows=players. By Player: a separate, independently movable panel per player, listing just their own tracked buffs as rows (one column). Both modes share the same Grid Scale/Sound settings above -- per-entry overrides (Alt-click a cell) are what carries "this one matters more" in either mode. Switching tears down and rebuilds the current panel set.');

        imgui.TextColored(header, 'Click to Cast');
        local clickCastBuffer = { gSettings.GridClickToCast };
        if imgui.Checkbox('Enable Click-to-Cast##BuffTrackConfig_GridClickToCast', clickCastBuffer) then
            gSettings.GridClickToCast = clickCastBuffer[1];
            settings.save();
        end
        imgui.ShowHelp('Click a Grid cell to cast that buff on that player. Plain click: only casts when the buff is NOT currently active. Ctrl+click: casts regardless of current state (even if still active). Alt+click (Entry Editor) and Shift+click (remove) are unchanged. Hovering a cell shows a highlight while this is on. Off by default -- a misclick here is a real cast, not a cosmetic change. Sends a normal /ma command through the game\'s own command queue, same as typing it yourself or clicking a macro.');

        imgui.TextColored(header, 'Job Icon Style');
        imgui.ShowHelp('Which resources/jobs/ set to pull job icons from, for the party-centric picker.');
        imgui.SetNextItemWidth(160);
        if imgui.BeginCombo('##BuffTrackJobIconStylePick', gSettings.JobIconStyle or 'FFXI') then
            for _,styleName in ipairs(uiskin.JobIconStyles) do
                if imgui.Selectable(string.format('%s##BuffTrackJobIconStyleOption%s', styleName, styleName), (gSettings.JobIconStyle == styleName)) then
                    gSettings.JobIconStyle = styleName;
                    settings.save();
                end
            end
            imgui.EndCombo();
        end
        --Small live preview so a style pick doesn't require leaving this
        --tab to check it against the (not-yet-built) party picker --
        --best-effort: a missing/failed texture just shows nothing rather
        --than an error, same as every other uiskin lookup.
        local previewIcon = uiskin:GetJobIcon('WAR', gSettings.JobIconStyle);
        if (previewIcon) then
            imgui.SameLine();
            uiskin:DrawInlineIcon(previewIcon.Texture, 32, 32);
        end

        imgui.EndTabItem();
    end
end

--Fixed FALLBACK sizes (unscaled px) -- used only if the live avail-size
--query below fails (defensive; see GetAvailSize). Also still used for the
--FlashColumnWidth checkbox-offset math, which stays a constant regardless
--of window size (the checkbox column doesn't need to scale, just stay
--aligned).
local BuffsListWidthFallback = 200;
local BuffsDetailWidthFallback = 300;
local BuffsPaneGap = 8;
local BuffsPickerHeightFallback = 220;
local AssignmentsHeightFallback = 200;
local FlashColumnWidth = 40;
--Up/Dn buttons (item 3, per-entry manual reordering -- see
--trackers/assignment.lua's MoveAssignment). Array position IS display
--order already, so these just let the user move a row within
--gSettings.Assignments directly, no separate ordering field involved.
local MoveColumnWidth = 76;

--[[
    GetContentRegionAvail() is the modern Dear ImGui replacement for
    GetWindowContentRegionWidth() (which crashed the addon when tried here
    previously -- that call was removed from the ImGui version Ashita
    ships). This binding is confirmed to be on a modern-enough ImGui to
    have ImGuiSelectableFlags_AllowOverlap (added 1.90, already used
    elsewhere in this file successfully), so GetContentRegionAvail (present
    since 1.70) should be solid -- but still pcall-wrapped defensively, so
    a bad assumption degrades to the old fixed sizes instead of crashing.
]]--
local function GetAvailSize(fallbackWidth, fallbackHeight)
    local ok, availX, availY = pcall(imgui.GetContentRegionAvail);
    if (ok) and (type(availX) == 'number') and (availX > 0) then
        local h = (type(availY) == 'number') and (availY > 0) and availY or fallbackHeight;
        return availX, h;
    end
    return fallbackWidth, fallbackHeight;
end

function config:DrawBuffsTab()
    if imgui.BeginTabItem('Buffs##BuffTrackConfigBuffsTab') then
        local state = self.State;

        --Query once per frame: total space left in the tab, used to split
        --between the picker row (list+detail) and the assignments panel
        --below it, and between the list/detail panes themselves. Falls
        --back to the old fixed sizes if the query fails (see GetAvailSize).
        local availW, availH = GetAvailSize(BuffsListWidthFallback + BuffsPaneGap + BuffsDetailWidthFallback, BuffsPickerHeightFallback + AssignmentsHeightFallback + 90);

        --~150px reserved for the filter box, both separators, the "Current
        --Assignments" header/help, the Flash-All row, and the Remove
        --buttons -- everything in this tab that isn't one of the three
        --scrollable children. (Was 110 -- too tight once the theme's
        --WindowPadding/ItemSpacing/FramePadding vars added extra space
        --between rows; the Remove Selected/Remove All row was landing
        --just past the bottom of the tab, needing a few scroll ticks to
        --reach even after resizing the window, since resizing doesn't
        --change this FIXED reservation.) Split what's left 55/45 between
        --the picker and the assignments list, each with a floor so a tiny
        --window doesn't collapse either one to nothing.
        local reservedHeight = 150;
        local splittable = math.max(availH - reservedHeight, 200);
        local pickerHeight = math.max(160, math.floor(splittable * 0.55));
        local assignmentsHeight = math.max(120, splittable - pickerHeight);

        local listWidth = math.max(150, math.floor(availW * 0.32));
        local detailWidth = math.max(200, availW - listWidth - BuffsPaneGap);
        local totalWidth = listWidth + BuffsPaneGap + detailWidth;

        --Left pane: every trackable buff (spell/ability), filterable by name.
        imgui.BeginGroup();
        imgui.SetNextItemWidth(listWidth);
        imgui.InputText('##BuffTrackBuffsFilter', state.BuffsFilterText, 64);
        imgui.BeginChild('##BuffTrackBuffsListPanel', { listWidth, pickerHeight }, ImGuiChildFlags_None);
        local filter = string.lower(state.BuffsFilterText[1] or '');
        for _,buff in ipairs(matching:ListBuffs()) do
            if (#filter == 0) or (string.lower(buff.Label):find(filter, 1, true)) then
                local isSelected = (state.SelectedBuff ~= nil) and (state.SelectedBuff.ActionType == buff.ActionType) and (state.SelectedBuff.ActionId == buff.ActionId);
                if imgui.Selectable(string.format('%s##BuffTrackBuffPick%s%u', buff.Label, buff.ActionType, buff.ActionId), isSelected) then
                    state.SelectedBuff = buff;
                end
            end
        end
        imgui.EndChild();
        imgui.EndGroup();

        imgui.SameLine();

        --Right pane: selected buff's details + a checkbox per current
        --party/alliance member to toggle tracking for them.
        imgui.BeginGroup();
        imgui.BeginChild('##BuffTrackBuffsDetailPanel', { detailWidth, pickerHeight }, ImGuiChildFlags_None);
        local buff = state.SelectedBuff;
        if not buff then
            imgui.Text('Select a buff on the left to configure tracking.');
        else
            imgui.TextColored(header, buff.Label);

            --Read-only now -- MP cost is baked in from server data (see
            --spellcosts.lua/libs/spellcosts_data.lua), no more manual entry
            --UI/Costs tab. nil (a buff outside the baked Enhancing Magic
            --set) shows "--", same placeholder convention the grid header
            --already used.
            local cost = spellcosts:GetCost(buff.ActionType, buff.ActionId);
            imgui.Text(string.format('MP Cost: %s', cost and tostring(cost) or '--'));

            --Placeholder-friendly -- libs/spelldescriptions.lua is empty by
            --default and filled in incrementally; anything not yet written
            --falls back to this generic line rather than showing nothing.
            local descKey = string.format('%s:%u', buff.ActionType, buff.ActionId);
            imgui.TextWrapped(spellDescriptions[descKey] or 'No description available yet.');

            imgui.Separator();
            imgui.TextColored(header, 'Party Members');
            local roster = assignmentTracker.GetRoster();
            local names = T{};
            for name,_ in pairs(roster) do
                names:append(name);
            end
            --Sorted for a stable row order across frames -- pairs() iteration
            --order over the roster table isn't guaranteed consistent.
            table.sort(names);

            if (#names == 0) then
                imgui.Text('No party/alliance members found.');
            else
                for _,name in ipairs(names) do
                    local assigned = assignmentTracker.IsDuplicate(buff.ActionType, buff.ActionId, buff.BuffId, name);
                    local buffer = { assigned };
                    if imgui.Checkbox(string.format('%s##BuffTrackBuffAssign%s', name, name), buffer) then
                        if buffer[1] then
                            assignmentTracker.AddAssignment(buff.ActionType, buff.ActionId, buff.BuffId, name);
                        else
                            assignmentTracker.RemoveAssignment(buff.ActionType, buff.ActionId, name);
                        end
                    end
                end
            end
        end
        imgui.EndChild();
        imgui.EndGroup();

        imgui.Separator();
        self:DrawAssignmentsPanel(totalWidth, assignmentsHeight);

        imgui.EndTabItem();
    end
end

--Full-width panel (merged in below the Buffs tab's picker, no longer its
--own tab) listing every current assignment, with per-row FlashOnExpire
--checkboxes and a master bulk toggle. Adding is done via the picker above
--(or /bufftrack [buff] [player]) -- this panel is browse/remove only, same
--as before. width/height come from DrawBuffsTab's live avail-size split so
--this panel always lines up with the picker row above it and scales with
--the window.
function config:DrawAssignmentsPanel(width, height)
    imgui.TextColored(header, 'Current Assignments');
    imgui.ShowHelp('Double-click a row, or select it and press Remove Selected, to stop tracking it. Up/Dn reorders the row -- this is the display order used everywhere (which column/row appears first).');

    local state = self.State;
    local removeEntry;
    local selectedEntry;
    local selectableWidth = math.max(width - FlashColumnWidth - MoveColumnWidth, 50);
    local checkboxOffset = selectableWidth + 8;
    local moveOffset = checkboxOffset + FlashColumnWidth;

    imgui.Text('Flash On Expire (All)');
    imgui.ShowHelp('One-click bulk toggle: sets Flash On Expire for every assignment below to match. Not a persisted setting itself -- rows can be adjusted individually afterward.');
    imgui.SameLine(checkboxOffset);
    if imgui.Checkbox('##BuffTrackMasterFlashOnExpire', state.MasterFlashOnExpire) then
        assignmentTracker.SetFlashOnExpireAll(state.MasterFlashOnExpire[1]);
    end

    imgui.BeginChild('##BuffTrackAssignmentsPanel', { width, height }, ImGuiChildFlags_None);
    for _,entry in ipairs(gSettings.Assignments) do
        local key = AssignmentKey(entry);
        local label = string.format('%s -- %s', assignmentTracker.GetActionLabel(entry.ActionType, entry.ActionId), entry.TargetName);
        local isSelected = (state.Selected == key);
        --Fixed-width Selectable (not the default full-stretch) so its
        --hit-region stops short of the checkbox column instead of
        --sitting underneath it.
        if imgui.Selectable(string.format('%s##%s', label, key), isSelected, ImGuiSelectableFlags_AllowOverlap, { selectableWidth, 0 }) then
            state.Selected = key;
            selectedEntry = entry;
        elseif isSelected then
            selectedEntry = entry;
        end

        if (imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0)) then
            removeEntry = entry;
        end

        --Same fixed offset as the master checkbox above -- lands in the
        --same column every row regardless of this row's label length.
        imgui.SameLine(checkboxOffset);
        local flashBuffer = { entry.FlashOnExpire ~= false };
        if imgui.Checkbox(string.format('##Flash%s', key), flashBuffer) then
            assignmentTracker.SetFlashOnExpire(entry.ActionType, entry.ActionId, entry.TargetName, flashBuffer[1]);
        end

        --Reorders gSettings.Assignments directly (see MoveAssignment's
        --comment) -- mutating mid-ipairs-loop here is a swap, not an
        --insert/remove, so the array stays the same length; worst case is
        --one frame where the just-swapped neighbor renders out of order
        --before self-correcting next frame, which isn't worth deferring
        --the action to a post-loop pass to avoid.
        imgui.SameLine(moveOffset);
        if imgui.Button(string.format('Up##BuffTrackMoveUp%s', key)) then
            assignmentTracker.MoveAssignment(entry.ActionType, entry.ActionId, entry.TargetName, -1);
        end
        imgui.SameLine();
        if imgui.Button(string.format('Dn##BuffTrackMoveDn%s', key)) then
            assignmentTracker.MoveAssignment(entry.ActionType, entry.ActionId, entry.TargetName, 1);
        end
    end
    imgui.EndChild();

    if (imgui.Button('Remove Selected##BuffTrackRemoveSelected')) and selectedEntry then
        assignmentTracker.RemoveAssignment(selectedEntry.ActionType, selectedEntry.ActionId, selectedEntry.TargetName);
        state.Selected = nil;
    end
    imgui.SameLine();
    if imgui.Button('Remove All##BuffTrackRemoveAll') then
        assignmentTracker.ClearAll();
        state.Selected = nil;
    end
    if (removeEntry) then
        assignmentTracker.RemoveAssignment(removeEntry.ActionType, removeEntry.ActionId, removeEntry.TargetName);
        if (state.Selected == AssignmentKey(removeEntry)) then
            state.Selected = nil;
        end
    end
end

function config:DrawCuresTab()
    if imgui.BeginTabItem('Cures##BuffTrackConfigCuresTab') then
        imgui.TextColored(header, 'Curable Debuffs');
        imgui.ShowHelp('Debuffs BuffTrack will alert on when active on a local party member AND you can currently cure them (job/level check). Poisona/Paralyna/Blindna/Silena/Cursna/Viruna/Stona are seeded automatically. Erase covers many debuffs generically, so it is opt-in only -- add specific debuffs below. Uncheck to disable an entry without losing it.');

        if imgui.Button('Reset to Defaults##BuffTrackCuresReset') then
            curableTracker.ResetCureMapToDefaults();
        end
        imgui.ShowHelp('Clears the ENTIRE Curable Debuffs list below (including anything you added yourself, like Erase-covered debuffs) and reseeds fresh from scratch. Use this if a manually-added entry ever ends up occupying a status id a dedicated cure (like Poisona, or Sleep/Cure) should have had instead -- seeding only ever fills in what\'s MISSING, so a wrongly-added entry otherwise blocks the correct one from ever appearing. Does not touch Player-Specific Overrides below.');

        DrawSoundPicker('Cures',
            function() return gSettings.CuresSound.Enabled; end,
            function(v) gSettings.CuresSound.Enabled = v; settings.save(); end,
            function() return gSettings.CuresSound.SoundId; end,
            function(v) gSettings.CuresSound.SoundId = v; settings.save(); end);
        imgui.ShowHelp('Plays once per (player, debuff) pair the moment it first becomes curable -- not every tick it stays active.');

        local showEmptyBuffer = { gSettings.CuresShowEmpty };
        if imgui.Checkbox('Show Panel When Empty##BuffTrackConfig_CuresShowEmpty', showEmptyBuffer) then
            gSettings.CuresShowEmpty = showEmptyBuffer[1];
            settings.save();
        end
        imgui.ShowHelp('When enabled, the Cures panel stays visible (showing a 0 count) even with nothing active, instead of disappearing entirely.');

        --Additive display aids on top of the already-working plain list
        --(see initializer.lua's CuresGroupDivider/ShowJobIcon doc comment) --
        --both off by default.
        local dividerBuffer = { gSettings.CuresGroupDivider };
        if imgui.Checkbox('Group Divider##BuffTrackConfig_CuresGroupDivider', dividerBuffer) then
            gSettings.CuresGroupDivider = dividerBuffer[1];
            settings.save();
        end
        imgui.ShowHelp('Draws a thin rule between rows whenever the target changes, so multiple players\' rows cluster visually without needing a full grouped layout. Rows are already sorted by player (and by Player Priority, see the Party tab) underneath, so this is purely visual.');

        local jobIconBuffer = { gSettings.CuresShowJobIcon };
        if imgui.Checkbox('Show Job Icon##BuffTrackConfig_CuresShowJobIcon', jobIconBuffer) then
            gSettings.CuresShowJobIcon = jobIconBuffer[1];
            settings.save();
        end
        imgui.ShowHelp('Shows each row\'s job icon (same style set as the Job Icon Style setting on the Behavior tab) before the text.');

        --Global (outermost) tier for Color/Flash -- see initializer.lua's
        --CuresColor/CuresFlash doc comment. First layer applied; a
        --per-spell (CureMap Edit button) or per-player-per-spell
        --(Player-Specific Overrides below) setting always wins over this
        --when one exists.
        imgui.TextColored(header, 'Default Color');
        local useGlobalColor = { gSettings.CuresColor ~= nil };
        if imgui.Checkbox('Override##BuffTrackConfig_CuresColorOverride', useGlobalColor) then
            if useGlobalColor[1] then
                gSettings.CuresColor = gSettings.CuresColor or 0xFFFFFFFF;
            else
                gSettings.CuresColor = nil;
            end
            settings.save();
        end
        if (gSettings.CuresColor ~= nil) then
            local colorBuffer = ARGBToFloat4(gSettings.CuresColor);
            if imgui.ColorEdit4('##BuffTrackConfig_CuresColor', colorBuffer) then
                gSettings.CuresColor = Float4ToARGB(colorBuffer);
                settings.save();
            end
            imgui.ShowHelp('Row text color for any Cures alert without a more specific (per-spell or per-player) color set. Unchecked = the renderer\'s own default (white).');
        end

        imgui.TextColored(header, 'Default Flash');
        local flashBuffer = { gSettings.CuresFlash };
        if imgui.Checkbox('Pulse while shown##BuffTrackConfig_CuresFlash', flashBuffer) then
            gSettings.CuresFlash = flashBuffer[1];
            settings.save();
        end
        imgui.ShowHelp('Continuous pulse for any Cures alert without a more specific (per-spell or per-player) Flash setting.');

        --Bounded height, NOT {0,0} ("fill all remaining space") -- this
        --child used to be the last thing in the tab, so filling everything
        --left was fine; now Player-Specific Overrides + the Add row + Add
        --Erase-Covered Debuff all come AFTER it, and a fill-everything
        --child leaves literally nothing for them regardless of window
        --size (that's the bug this replaces -- see GetAvailSize's own
        --comment for why a live query beats a fixed guess). Reserves
        --~230px for everything below (that section's header/help + its
        --list + its Add row, plus the Erase-add row) and gives the rest to
        --this list, floored so a tiny window doesn't collapse it to
        --nothing -- it scrolls internally past that floor instead.
        local availW, availH = GetAvailSize(400, 500);
        local cureListHeight = math.max(availH - 230, 100);

        imgui.BeginChild('##BuffTrackCuresPanel', { 0, cureListHeight }, ImGuiChildFlags_None);
        local removeStatusId;
        for _,entry in ipairs(gSettings.CureMap) do
            local debuffName = matching:GetDebuffName(entry.StatusId);
            local cureLabel = assignmentTracker.GetActionLabel(entry.ActionType, entry.ActionId);
            local enabledBuffer = { entry.Enabled ~= false };
            if imgui.Checkbox(string.format('##BuffTrackCureEnabled%u', entry.StatusId), enabledBuffer) then
                curableTracker.SetCureEnabled(entry.StatusId, enabledBuffer[1]);
            end
            imgui.SameLine();
            --entry.RequiredJob/RequiredLevel are nil for "any job that knows
            --this spell" entries (see trackers/curable.lua's
            --DefaultCureSpells/CanCure) -- Cure/Sleep being the first of
            --these, string.format's %u crashed here on the nil
            --RequiredLevel before this check existed.
            if (entry.RequiredJob) then
                imgui.Text(string.format('%s -- %s (%s Lv.%u)', debuffName, cureLabel, entry.RequiredJob, entry.RequiredLevel));
            else
                imgui.Text(string.format('%s -- %s (Any Job)', debuffName, cureLabel));
            end
            imgui.SameLine();
            if imgui.Button(string.format('Edit##BuffTrackCureMapEdit%u', entry.StatusId)) then
                self:EditCureMapEntry(entry, debuffName);
            end
            imgui.SameLine();
            if imgui.Button(string.format('Remove##BuffTrackCureMapRemove%u', entry.StatusId)) then
                removeStatusId = entry.StatusId;
            end
        end
        imgui.EndChild();
        if (removeStatusId) then
            curableTracker.RemoveCureEntry(removeStatusId);
        end

        imgui.TextColored(header, 'Player-Specific Overrides');
        imgui.ShowHelp('Overrides ONE player\'s alert for ONE debuff -- on top of the spell-wide settings above (e.g. your tank\'s Paralyze is an alarm, everyone else\'s Paralyze stays default). Reachable directly here, no live alert or Preview needed. This list only shows overrides that actually exist, so it stays short regardless of roster size.');
        if (#gSettings.CureOverrides == 0) then
            imgui.Text('No player-specific overrides set yet.');
        else
            for _,ov in ipairs(gSettings.CureOverrides) do
                local debuffName = matching:GetDebuffName(ov.StatusId);
                imgui.Text(string.format('%s -- %s', ov.TargetName, debuffName));
                imgui.SameLine();
                if imgui.Button(string.format('Edit##BuffTrackCureOverrideEdit%s%u', ov.TargetName, ov.StatusId)) then
                    self:EditCureEntry({ TargetName = ov.TargetName, StatusId = ov.StatusId, Label = debuffName, Scale = ov.Scale, Color = ov.Color, SoundEnabled = ov.SoundEnabled, SoundId = ov.SoundId });
                end
                imgui.SameLine();
                if imgui.Button(string.format('Remove##BuffTrackCureOverrideRemove%s%u', ov.TargetName, ov.StatusId)) then
                    curableTracker.SetCureOverride(ov.TargetName, ov.StatusId, {});
                end
            end
        end

        imgui.Text('Add:');
        imgui.SameLine();
        local roster = assignmentTracker.GetRoster();
        local names = T{};
        for name,_ in pairs(roster) do
            names:append(name);
        end
        table.sort(names);
        imgui.SetNextItemWidth(140);
        if imgui.BeginCombo('##BuffTrackOverridePlayerPick', self.State.OverridePlayerName or 'Player...') then
            for _,name in ipairs(names) do
                if imgui.Selectable(string.format('%s##BuffTrackOverridePlayerOption%s', name, name), (self.State.OverridePlayerName == name)) then
                    self.State.OverridePlayerName = name;
                end
            end
            imgui.EndCombo();
        end
        imgui.SameLine();
        local currentDebuffLabel = self.State.OverrideStatusId and matching:GetDebuffName(self.State.OverrideStatusId) or 'Debuff...';
        imgui.SetNextItemWidth(140);
        if imgui.BeginCombo('##BuffTrackOverrideDebuffPick', currentDebuffLabel) then
            for _,entry in ipairs(gSettings.CureMap) do
                local dName = matching:GetDebuffName(entry.StatusId);
                if imgui.Selectable(string.format('%s##BuffTrackOverrideDebuffOption%u', dName, entry.StatusId), (self.State.OverrideStatusId == entry.StatusId)) then
                    self.State.OverrideStatusId = entry.StatusId;
                end
            end
            imgui.EndCombo();
        end
        imgui.SameLine();
        if imgui.Button('Edit##BuffTrackAddCureOverride') then
            if (self.State.OverridePlayerName) and (self.State.OverrideStatusId) then
                --Pre-fills from any override that ALREADY exists for this
                --exact pair (harmless if none does -- Scale/Color/etc just
                --come back nil, same as a brand-new entry) rather than
                --always opening blank.
                local existing = curableTracker.FindOverride(self.State.OverridePlayerName, self.State.OverrideStatusId);
                self:EditCureEntry({
                    TargetName = self.State.OverridePlayerName,
                    StatusId = self.State.OverrideStatusId,
                    Label = matching:GetDebuffName(self.State.OverrideStatusId),
                    Scale = existing and existing.Scale,
                    Color = existing and existing.Color,
                    SoundEnabled = existing and existing.SoundEnabled,
                    SoundId = existing and existing.SoundId,
                });
            end
        end

        imgui.TextColored(header, 'Add Erase-Covered Debuff');
        imgui.ShowHelp('Erase removes many different debuffs (Bio, Dia, Gravity, Flash, Addle, Slow, elemental debuffs, attribute-down effects, etc) but NOT Poison/Paralyze/Blind/Silence/Curse/Disease/Petrify, which have their own dedicated spells above. Type the debuff\'s name.');
        imgui.SetNextItemWidth(160);
        imgui.InputText('##BuffTrackNewEraseDebuffName', self.State.NewEraseDebuffName, 32);
        imgui.SameLine();
        if imgui.Button('Add##BuffTrackAddEraseCure') then
            local query = self.State.NewEraseDebuffName[1];
            if (query ~= nil) and (#query > 0) then
                local match, candidates = matching:FindDebuffStatus(query);
                local erase = curableTracker.GetEraseAction();
                if match and erase then
                    if curableTracker.AddCureEntry(match.StatusId, erase.ActionType, erase.ActionId, 'WHM', 32) then
                        self.State.NewEraseDebuffName[1] = '';
                    else
                        Error(string.format('%s is already mapped.', match.Label));
                    end
                elseif (not match) then
                    if (#candidates > 0) then
                        Error(string.format('"%s" is ambiguous: %s', query, table.concat(candidates, ', ')));
                    else
                        Error(string.format('No debuff found matching "%s".', query));
                    end
                end
            end
        end

        imgui.EndTabItem();
    end
end

function config:DrawWatchTab()
    if imgui.BeginTabItem('Watch##BuffTrackConfigWatchTab') then
        imgui.TextColored(header, 'Enemy Buff Watch List');
        imgui.ShowHelp('Alerts when ANY enemy casts one of these on itself. Add via /bufftrack watch [spell|ability] [name]; remove below or via /bufftrack unwatch [name]. No curated default -- entirely user-managed.');

        DrawSoundPicker('Watch',
            function() return gSettings.WatchSound.Enabled; end,
            function(v) gSettings.WatchSound.Enabled = v; settings.save(); end,
            function() return gSettings.WatchSound.SoundId; end,
            function(v) gSettings.WatchSound.SoundId = v; settings.save(); end);
        imgui.ShowHelp('Plays once when a watched action is first detected -- not on a recast of an already-active alert.');

        local showEmptyBuffer = { gSettings.WatchShowEmpty };
        if imgui.Checkbox('Show Panel When Empty##BuffTrackConfig_WatchShowEmpty', showEmptyBuffer) then
            gSettings.WatchShowEmpty = showEmptyBuffer[1];
            settings.save();
        end
        imgui.ShowHelp('When enabled, the Watch panel stays visible (showing a 0 count) even with nothing active, instead of disappearing entirely.');

        local removeEntry;
        imgui.BeginChild('##BuffTrackWatchPanel', { 0, 0 }, ImGuiChildFlags_None);
        if (#gSettings.EnemyBuffWatchList == 0) then
            imgui.Text('Nothing watched yet -- use /bufftrack watch [spell|ability] [name].');
        else
            for _,entry in ipairs(gSettings.EnemyBuffWatchList) do
                imgui.Text(string.format('%s (%s)', entry.Label, entry.ActionType));
                imgui.SameLine();
                if imgui.Button(string.format('Edit##BuffTrackWatchEdit%s%u', entry.ActionType, entry.ActionId)) then
                    self:EditWatchEntry(entry);
                end
                imgui.SameLine();
                if imgui.Button(string.format('Remove##BuffTrackWatchRemove%s%u', entry.ActionType, entry.ActionId)) then
                    removeEntry = entry;
                end
            end
        end
        imgui.EndChild();
        if (removeEntry) then
            dispellableTracker.RemoveWatch(removeEntry.ActionType, removeEntry.ActionId);
        end

        imgui.EndTabItem();
    end
end

--Party-centric alternate setup (additive -- the spell-first Buffs tab
--above is unchanged and stays the primary flow). Left pane: roster with
--job icons: right pane: the SELECTED player's assigned buffs + Cures
--overrides, each with its own "Add" button that opens a separate popup
--(RenderAddBuffsPopup/RenderAddCuresPopup below) rather than listing the
--full catalog inline -- an inline full catalog here would make this pane
--very long (explicit reasoning from planning: "another layer to the UI"
--instead).
function config:DrawPartyTab()
    if imgui.BeginTabItem('Party##BuffTrackConfigPartyTab') then
        local state = self.State;
        local availW, availH = GetAvailSize(BuffsListWidthFallback + BuffsPaneGap + BuffsDetailWidthFallback, BuffsPickerHeightFallback);
        local listWidth = math.max(150, math.floor(availW * 0.32));
        local detailWidth = math.max(200, availW - listWidth - BuffsPaneGap);

        --Left pane: roster, job icon + name, sorted for a stable row order
        --(pairs() iteration order over the roster table isn't guaranteed).
        imgui.BeginGroup();
        imgui.BeginChild('##BuffTrackPartyListPanel', { listWidth, availH }, ImGuiChildFlags_None);
        local roster = assignmentTracker.GetRosterWithJobs();
        local names = T{};
        for name,_ in pairs(roster) do
            names:append(name);
        end
        table.sort(names);
        if (#names == 0) then
            imgui.Text('No party/alliance members found.');
        else
            for _,name in ipairs(names) do
                local jobAbbr = curableTracker.JobAbbrById[roster[name].MainJob];
                local icon = jobAbbr and uiskin:GetJobIcon(jobAbbr);
                if (icon) then
                    uiskin:DrawInlineIcon(icon.Texture, 20, 20);
                    imgui.SameLine();
                end
                if imgui.Selectable(string.format('%s##BuffTrackPartyPick%s', name, name), (state.PartySelectedPlayer == name)) then
                    state.PartySelectedPlayer = name;
                end
            end
        end
        imgui.EndChild();
        imgui.EndGroup();

        imgui.SameLine();

        --Right pane: selected player's assigned buffs + Cures overrides,
        --each list short (only what's actually assigned/overridden, see
        --GetAssignmentsForPlayer/GetOverridesForPlayer) with its own Add
        --button opening the matching popup.
        imgui.BeginGroup();
        imgui.BeginChild('##BuffTrackPartyDetailPanel', { detailWidth, availH }, ImGuiChildFlags_None);
        local player = state.PartySelectedPlayer;
        if (player == nil) then
            imgui.Text('Select a party member on the left.');
        else
            imgui.TextColored(header, player);

            --Cures panel sort priority (see initializer.lua's
            --PlayerPriority doc comment) -- purely per-player, no party-
            --subgroup concept. Higher sorts first; 0 (the default) stores
            --nothing.
            local priorityBuffer = { gSettings.PlayerPriority[player] or 0 };
            imgui.SetNextItemWidth(120);
            if imgui.SliderInt('Priority##BuffTrackPartyPriority', priorityBuffer, 0, 10, '%d', ImGuiSliderFlags_AlwaysClamp) then
                assignmentTracker.SetPlayerPriority(player, priorityBuffer[1]);
            end
            imgui.ShowHelp('Higher = sorts nearer the top of the Cures panel, regardless of which debuff they currently have. 0 = no priority (sorted alphabetically among other 0s).');

            imgui.TextColored(header, 'Assigned Buffs');
            local assignments = assignmentTracker.GetAssignmentsForPlayer(player);
            if (#assignments == 0) then
                imgui.Text('None assigned yet.');
            else
                for _,entry in ipairs(assignments) do
                    local label = assignmentTracker.GetActionLabel(entry.ActionType, entry.ActionId);
                    imgui.Text(label);
                    imgui.SameLine();
                    if imgui.Button(string.format('Edit##BuffTrackPartyBuffEdit%s%u', entry.ActionType, entry.ActionId)) then
                        self:EditEntry({
                            ActionType = entry.ActionType, ActionId = entry.ActionId, TargetName = entry.TargetName,
                            ColumnLabel = label, Scale = entry.Scale, Color = entry.Color,
                            SoundEnabled = entry.SoundEnabled, SoundId = entry.SoundId,
                        });
                    end
                    imgui.SameLine();
                    if imgui.Button(string.format('Remove##BuffTrackPartyBuffRemove%s%u', entry.ActionType, entry.ActionId)) then
                        assignmentTracker.RemoveAssignment(entry.ActionType, entry.ActionId, entry.TargetName);
                    end
                end
            end
            if imgui.Button('Add Buffs##BuffTrackPartyAddBuffs') then
                state.AddBuffsPopup.Open = true;
            end

            imgui.Separator();
            imgui.TextColored(header, 'Cures Overrides');
            local overrides = curableTracker.GetOverridesForPlayer(player);
            if (#overrides == 0) then
                imgui.Text('None yet.');
            else
                for _,ov in ipairs(overrides) do
                    local debuffName = matching:GetDebuffName(ov.StatusId);
                    imgui.Text(debuffName);
                    imgui.SameLine();
                    if imgui.Button(string.format('Edit##BuffTrackPartyCureEdit%u', ov.StatusId)) then
                        self:EditCureEntry({ TargetName = ov.TargetName, StatusId = ov.StatusId, Label = debuffName, Scale = ov.Scale, Color = ov.Color, Flash = ov.Flash, SoundEnabled = ov.SoundEnabled, SoundId = ov.SoundId });
                    end
                    imgui.SameLine();
                    if imgui.Button(string.format('Remove##BuffTrackPartyCureRemove%u', ov.StatusId)) then
                        curableTracker.SetCureOverride(ov.TargetName, ov.StatusId, {});
                    end
                end
            end
            if imgui.Button('Add Cures##BuffTrackPartyAddCures') then
                state.AddCuresPopup.Open = true;
            end
        end
        imgui.EndChild();
        imgui.EndGroup();

        imgui.EndTabItem();
    end
end

--Opens the Entry Editor popup for one Grid cell (Alt-click -- see
--gridgroup.lua's HandleMouse). `cell` is the cellData table
--resources/renderers/grid.lua's CellHitTest returns: carries ActionType/
--ActionId/TargetName/ColumnLabel (identity) plus whatever Scale/Color/
--SoundEnabled/SoundId overrides are currently in effect. Takes a working
--COPY of the override fields -- nothing is written to gSettings until
--"Apply" (see RenderEntryEditor), so closing without applying discards
--in-progress edits.
function config:EditEntry(cell)
    self.State.EditingEntry = {
        Kind = 'Grid',
        ActionType = cell.ActionType,
        ActionId = cell.ActionId,
        TargetName = cell.TargetName,
        ColumnLabel = cell.ColumnLabel,
        Scale = cell.Scale,
        Color = cell.Color,
        SoundEnabled = cell.SoundEnabled,
        SoundId = cell.SoundId,
    };
end

--Same idea as EditEntry above, but for a live Cures alert row (Alt-click --
--see alertsgroup.lua's HandleMouse). `row` is what
--trackers/curable.lua:Tick() built for this alert -- TargetName/StatusId
--are the identity SetCureOverride keys on; Scale/Color/SoundEnabled/
--SoundId reflect whatever CureOverrides entry (if any) is currently in
--effect. RenderEntryEditor branches on Kind to route Apply to the right
--tracker and to know which tracker-level setting (GridSound vs
--CuresSound) "inherit" falls back to.
function config:EditCureEntry(row)
    self.State.EditingEntry = {
        Kind = 'Cure',
        TargetName = row.TargetName,
        StatusId = row.StatusId,
        ColumnLabel = row.Label,
        Scale = row.Scale,
        Color = row.Color,
        Flash = row.Flash,
        SoundEnabled = row.SoundEnabled,
        SoundId = row.SoundId,
    };
end

--Per-DEBUFF ("spell specific") override -- reachable directly from the
--Cures tab's Edit button, no live alert required (see
--trackers/curable.lua's SetCureMapEntryOverrides + initializer.lua's
--CureMap doc comment for the resolution order this sits at). `debuffName`
--is passed in rather than re-resolved here since the Cures tab already has
--it on hand for the row label.
function config:EditCureMapEntry(entry, debuffName)
    self.State.EditingEntry = {
        Kind = 'CureMapEntry',
        StatusId = entry.StatusId,
        ColumnLabel = debuffName,
        TargetName = 'All Players',
        Scale = entry.Scale,
        Color = entry.Color,
        Flash = entry.Flash,
        SoundEnabled = entry.SoundEnabled,
        SoundId = entry.SoundId,
    };
end

--Per-watched-action override -- Watch's only override tier (no player axis
--exists, see trackers/dispellable.lua's SetWatchEntryOverrides). Reachable
--both from the Watch tab's Edit button AND Alt-click on a live Watch row
--(alertsgroup.lua's Spec.EditRow for the Watch panel) -- `row`/`entry` have
--the same shape (ActionType/ActionId/Label + current overrides) either way.
function config:EditWatchEntry(entry)
    self.State.EditingEntry = {
        Kind = 'WatchEntry',
        ActionType = entry.ActionType,
        ActionId = entry.ActionId,
        ColumnLabel = entry.Label,
        TargetName = 'Any Enemy',
        Scale = entry.Scale,
        Color = entry.Color,
        Flash = entry.Flash,
        SoundEnabled = entry.SoundEnabled,
        SoundId = entry.SoundId,
    };
end

--Small always-on-top popup window, separate from the main tabbed config
--window (it needs to be open even while that window is closed, and
--anchoring it as a tab would lose the "pops up right where you clicked"
--immediacy Alt-click is going for).
function config:RenderEntryEditor()
    local e = self.State.EditingEntry;
    if not e then
        return;
    end

    local isOpen = { true };
    imgui.SetNextWindowSize({ 280, 0 }, ImGuiCond_FirstUseEver);
    if imgui.Begin(string.format('%s -- %s##BuffTrackEntryEditor', e.ColumnLabel, e.TargetName), isOpen, ImGuiWindowFlags_AlwaysAutoResize) then
        --Which tracker-level default this entry's "inherit" falls back to
        --depends on Kind (see EditEntry/EditCureEntry/EditCureMapEntry/
        --EditWatchEntry above).
        local defaultScale = gSettings.GridScale;
        local defaultSound = gSettings.GridSound;
        if (e.Kind == 'Cure') or (e.Kind == 'CureMapEntry') then
            defaultScale = gSettings.CuresScale;
            defaultSound = gSettings.CuresSound;
        elseif (e.Kind == 'WatchEntry') then
            defaultScale = gSettings.WatchScale;
            defaultSound = gSettings.WatchSound;
        end

        imgui.TextColored(header, 'Scale');
        local useScale = { e.Scale ~= nil };
        if imgui.Checkbox('Override##BuffTrackEntryScaleOverride', useScale) then
            e.Scale = useScale[1] and (e.Scale or defaultScale) or nil;
        end
        if (e.Scale ~= nil) then
            local buffer = { e.Scale };
            if imgui.SliderFloat('##BuffTrackEntryScale', buffer, 0.5, 3, '%.2f', ImGuiSliderFlags_AlwaysClamp) then
                e.Scale = buffer[1];
            end
        end

        imgui.TextColored(header, 'Color');
        local useColor = { e.Color ~= nil };
        if imgui.Checkbox('Override##BuffTrackEntryColorOverride', useColor) then
            e.Color = useColor[1] and (e.Color or 0xFF00FF00) or nil;
        end
        if (e.Color ~= nil) then
            local colorBuffer = ARGBToFloat4(e.Color);
            if imgui.ColorEdit4('##BuffTrackEntryColor', colorBuffer) then
                e.Color = Float4ToARGB(colorBuffer);
            end
            imgui.ShowHelp('Replaces this cell\'s "healthy" green -- the Attention/expiring warning colors still apply as normal.');
        end

        --Flash doesn't apply to Grid entries -- those already have their
        --own separate FlashOnExpire concept (the post-expiry grace-window
        --blink, set via the Assignments panel checkbox, not this popup).
        --A continuous "grab attention while shown" pulse is specific to
        --Cures/Watch's presence-based alerts, which have no expiry grace
        --window to piggyback on.
        if (e.Kind ~= 'Grid') then
            imgui.TextColored(header, 'Flash');
            local useFlash = { e.Flash ~= nil };
            if imgui.Checkbox('Override##BuffTrackEntryFlashOverride', useFlash) then
                e.Flash = useFlash[1] or nil;
            end
            if (e.Flash ~= nil) then
                local flashBuffer = { e.Flash };
                if imgui.Checkbox('Pulse while shown##BuffTrackEntryFlashToggle', flashBuffer) then
                    e.Flash = flashBuffer[1];
                end
            end
        end

        imgui.TextColored(header, 'Sound');
        local useSound = { e.SoundEnabled ~= nil };
        if imgui.Checkbox('Override##BuffTrackEntrySoundOverride', useSound) then
            if useSound[1] then
                e.SoundEnabled = true;
                e.SoundId = e.SoundId or defaultSound.SoundId;
            else
                e.SoundEnabled = nil;
                e.SoundId = nil;
            end
        end
        if (e.SoundEnabled ~= nil) then
            DrawSoundPicker('EntryEditor',
                function() return e.SoundEnabled; end,
                function(v) e.SoundEnabled = v; end,
                function() return e.SoundId or defaultSound.SoundId; end,
                function(v) e.SoundId = v; end);
        end

        imgui.Separator();
        if imgui.Button('Apply##BuffTrackEntryEditorApply') then
            local overrides = { Scale = e.Scale, Color = e.Color, Flash = e.Flash, SoundEnabled = e.SoundEnabled, SoundId = e.SoundId };
            if (e.Kind == 'Cure') then
                curableTracker.SetCureOverride(e.TargetName, e.StatusId, overrides);
            elseif (e.Kind == 'CureMapEntry') then
                curableTracker.SetCureMapEntryOverrides(e.StatusId, overrides);
            elseif (e.Kind == 'WatchEntry') then
                dispellableTracker.SetWatchEntryOverrides(e.ActionType, e.ActionId, overrides);
            else
                assignmentTracker.SetEntryOverrides(e.ActionType, e.ActionId, e.TargetName, overrides);
            end
        end
        imgui.SameLine();
        if imgui.Button('Close##BuffTrackEntryEditorClose') then
            isOpen[1] = false;
        end
    end
    imgui.End();

    if not isOpen[1] then
        self.State.EditingEntry = nil;
    end
end

--Add Buffs popup (Party tab's "Add Buffs" button) -- full spell catalog
--as a plain checkbox list, scoped to state.PartySelectedPlayer. Checkbox
--state IS AddAssignment/RemoveAssignment directly (same clean on/off
--semantics DrawBuffsTab's per-player checkboxes already use, just with
--the two axes swapped -- player fixed by context, buff toggled per row).
function config:RenderAddBuffsPopup()
    local popup = self.State.AddBuffsPopup;
    if (not popup.Open) then
        return;
    end
    local player = self.State.PartySelectedPlayer;
    if (player == nil) then
        popup.Open = false;
        return;
    end

    local isOpen = { true };
    imgui.SetNextWindowSize({ 260, 400 }, ImGuiCond_FirstUseEver);
    if imgui.Begin(string.format('Add Buffs -- %s##BuffTrackAddBuffsPopup', player), isOpen, ImGuiWindowFlags_None) then
        imgui.SetNextItemWidth(-1);
        imgui.InputText('##BuffTrackAddBuffsFilter', popup.FilterText, 64);
        imgui.BeginChild('##BuffTrackAddBuffsList', { 0, 0 }, ImGuiChildFlags_None);
        local filter = string.lower(popup.FilterText[1] or '');
        for _,buff in ipairs(matching:ListBuffs()) do
            if (#filter == 0) or (string.lower(buff.Label):find(filter, 1, true)) then
                local assigned = assignmentTracker.IsDuplicate(buff.ActionType, buff.ActionId, buff.BuffId, player);
                local buffer = { assigned };
                if imgui.Checkbox(string.format('%s##BuffTrackAddBuffsCheck%s%u', buff.Label, buff.ActionType, buff.ActionId), buffer) then
                    if buffer[1] then
                        assignmentTracker.AddAssignment(buff.ActionType, buff.ActionId, buff.BuffId, player);
                    else
                        assignmentTracker.RemoveAssignment(buff.ActionType, buff.ActionId, player);
                    end
                end
            end
        end
        imgui.EndChild();
    end
    imgui.End();

    if (not isOpen[1]) then
        popup.Open = false;
    end
end

--Add Cures popup (Party tab's "Add Cures" button) -- CureMap catalog as a
--checkbox list, scoped to state.PartySelectedPlayer. Checkbox semantics
--differ from Add Buffs' on purpose (see initializer.lua's CureOverrides
--doc comment + the planning discussion this came out of): checking does
--NOT mean "this debuff applies to them" (it already does, globally, via
--CureMap) -- it means "start customizing THIS player's version of it",
--so checking creates a blank override row (CreateBlankOverride) that then
--shows up in the Party tab's right pane ready for Edit, rather than
--opening the Entry Editor immediately. Unchecking removes the override
--row entirely (SetCureOverride with no fields set).
function config:RenderAddCuresPopup()
    local popup = self.State.AddCuresPopup;
    if (not popup.Open) then
        return;
    end
    local player = self.State.PartySelectedPlayer;
    if (player == nil) then
        popup.Open = false;
        return;
    end

    local isOpen = { true };
    imgui.SetNextWindowSize({ 260, 400 }, ImGuiCond_FirstUseEver);
    if imgui.Begin(string.format('Add Cures -- %s##BuffTrackAddCuresPopup', player), isOpen, ImGuiWindowFlags_None) then
        imgui.BeginChild('##BuffTrackAddCuresList', { 0, 0 }, ImGuiChildFlags_None);
        for _,entry in ipairs(gSettings.CureMap) do
            local debuffName = matching:GetDebuffName(entry.StatusId);
            local hasOverride = (curableTracker.FindOverride(player, entry.StatusId) ~= nil);
            local buffer = { hasOverride };
            if imgui.Checkbox(string.format('%s##BuffTrackAddCuresCheck%u', debuffName, entry.StatusId), buffer) then
                if buffer[1] then
                    curableTracker.CreateBlankOverride(player, entry.StatusId);
                else
                    curableTracker.SetCureOverride(player, entry.StatusId, {});
                end
            end
        end
        imgui.EndChild();
    end
    imgui.End();

    if (not isOpen[1]) then
        popup.Open = false;
    end
end

function config:Render()
    self:RenderEntryEditor();
    self:RenderAddBuffsPopup();
    self:RenderAddCuresPopup();
    local state = self.State;
    if (state.IsOpen[1]) then
        --Dark+gold theme, mirrored from XIUI's config.lua (see
        --libs/uiskin.lua's header comment) -- replaces an earlier,
        --abandoned attempt at a custom PNG background (worked mechanically
        --but the frame art didn't align with the actual widget layout).
        --PushTheme() is called BEFORE SetNextWindowSize/Begin, same order
        --the reference addon uses; PopTheme() is called unconditionally
        --after End(), same always-call reasoning as End() itself below.
        uiskin:PushTheme();

        imgui.SetNextWindowSize({ 540, 560 }, ImGuiCond_FirstUseEver);
        --Begin() MUST always be paired with End(), even when Begin()
        --returns false (collapsed window, fully clipped, etc) -- only the
        --CONTENTS are conditional on the return value. This was previously
        --nested inside the `if Begin(...) then` block, so a collapsed
        --window skipped End() entirely -- exactly what ImGui's own
        --"missing End()" assertion reports. RenderEntryEditor's popup
        --above already had this right; fixed here to match.
        if (imgui.Begin(string.format('%s v%s Configuration', addon.name, addon.version), state.IsOpen, ImGuiWindowFlags_None)) then
            if imgui.BeginTabBar('##BuffTrackConfigTabBar', ImGuiTabBarFlags_NoCloseWithMiddleMouseButton) then
                self:DrawBehaviorTab();
                self:DrawBuffsTab();
                self:DrawPartyTab();
                self:DrawCuresTab();
                self:DrawWatchTab();
                imgui.EndTabBar();
            end
        end
        imgui.End();
        uiskin:PopTheme();
    end
end

function config:Show()
    self.State.IsOpen[1] = true;
end

return config;
