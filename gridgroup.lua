--[[
    GridGroup owns mouse interaction (drag-to-reposition, Shift/Ctrl-click
    removal), turns raw tracker data into render-ready state, and delegates
    actual drawing to the grid renderer.

    Reads gSettings directly and live wherever possible (Enabled,
    UseTooltips, Scale, AttentionThreshold/Grace) rather than caching a
    snapshot -- an earlier version cached a copy in self.Settings that only
    refreshed on a forced UpdateSettings call, which silently broke the
    config UI's Enabled/UseTooltips/Scale controls (their writes to
    gSettings never reached the stale cache). Position is the one
    exception: it needs a live *working* copy during an active drag, so it
    keeps its own small piece of state (self.Position), synced from
    gSettings.Position and only written back on drag release.

    Column order = order buffs were first assigned; row order within a
    column = order players were assigned to it (or, in GridGroupBy='Player'
    mode, order buffs were assigned to that player) -- both preserved by
    walking gSettings.Assignments in array order, reorderable via
    trackers/assignment.lua's MoveAssignment.

    Click semantics:
      Alt-click a cell   -> open the Entry Editor (Scale/Color/Sound/Flash
                            overrides for that one assignment).
      Shift-click a cell -> remove that one assignment (this buff, this player).
      Ctrl-click a cell  -> click-to-cast, IGNORING current state (even if
                            Active with time left) -- see TryClickCast.
                            Replaces an earlier Ctrl-click="remove the
                            entire column" binding, removed to make room
                            for this (no replacement binding assigned --
                            Shift-click single-cell removal and the Buffs
                            tab's Remove controls remain for bulk cleanup).
      Plain click a cell -> click-to-cast, ONLY when NotActive -- see
                            TryClickCast. Both click-to-cast bindings are
                            no-ops unless gSettings.GridClickToCast is on.
]]--

local d3d = require('d3d8');
local ffi = require('ffi');
ffi.cdef [[
    int16_t GetKeyState(int32_t vkey);
]]
local function IsControlPressed()
    return (bit.band(ffi.C.GetKeyState(0x11), 0x8000) ~= 0);
end
local function IsShiftPressed()
    return (bit.band(ffi.C.GetKeyState(0x10), 0x8000) ~= 0);
end
local function IsAltPressed()
    return (bit.band(ffi.C.GetKeyState(0x12), 0x8000) ~= 0); --VK_MENU
end

--Forward reference to config.lua, for the Alt-click Entry Editor popup
--(see HandleMouse below). Safe despite initializer.lua requiring
--'gridgroup' before callbacks.lua requires 'config' -- config.lua doesn't
--require gridgroup.lua back, so there's no real cycle, just an earlier
--load point for config.lua than before.
local config = require('config');

local PanelBase = require('panelbase');

--[[
    Renderer contract this module expects from resources/renderers/grid.lua:

    New() -> instance
    Destroy()
    Begin() / End()
    DrawGrid(sprite, position, columns, hoveredIdentity)
        columns(table) - ordered array of:
            Key(string)   - "ActionType:ActionId", e.g. "Spell:57"
            Label(string) - display name, e.g. "Haste"
            Rows(table)   - ordered array of cellData (see below)
        hoveredIdentity(table|nil) - { ActionType, ActionId, TargetName } of
            the cell under the cursor, for click-to-cast's hover highlight
            (gSettings.GridClickToCast) -- nil draws no highlight at all
            (either nothing's hovered, or the feature is off).
    DrawTooltip(sprite, position, cellData)
    DragHitTest(position) -> boolean
    CellHitTest(position) -> cellData or nil

    cellData
        TargetName(string)
        State(string)         - "Active" | "Attention" | "NotActive"
        Duration(number)      - seconds remaining; may be <= 0
        Percent(number)       - bar fill fraction, 0-1
        BlendT(number)        - 0-2; color blend position (0=High/green, 1=Middle/yellow, 2=Low/red)
        Blink(boolean)        - true during the post-expiry grace window
        FlashOnExpire(boolean) - if false, renderer shows a steady full bar
                                 instead of toggling it during Blink
        TotalDuration(number) - seconds, for percent-based bar rendering if wanted
        Local(table)          - Delete(boolean, reserved)

    The renderer reads gSettings.GridScale/gSettings.ShowTenths directly
    (same live-read approach as everything else here) rather than taking a
    settings snapshot at construction time.
]]--
local GridGroup = setmetatable({}, { __index = PanelBase });
GridGroup.__index = GridGroup;

--Registry of per-player panels for GridGroupBy='Player' mode (see
--SyncPlayerPanels below) -- module-level, not global, since only this
--file's own functions and (via GetPlayerPanels) callbacks.lua's mouse
--handler need it. Keyed by player name; one panel per name currently
--assigned at least one buff, created/destroyed on the fly as that changes.

--Seconds-per-stage before crossing AttentionThreshold during which the bar
--eases through the warning colors, rather than snapping instantly --
--green->yellow, then yellow->red, one window length per stage.
local BlendWindow = 15;

local playerPanelsByName = {};

function GridGroup:New(newSettings)
    local o = setmetatable({}, GridGroup);

    local renderer = require('resources.renderers.grid');
    --Kept under its old name too (rather than renaming every self.GridRenderer
    --call site below to self.Renderer) -- both point at the exact same
    --instance; self.Renderer is only what PanelBase's inherited GetBounds/
    --HandleDrag read, everything specific to this module still reads
    --self.GridRenderer as before.
    o.GridRenderer = renderer:New();
    PanelBase.Init(o, newSettings.Position, o.GridRenderer);

    return o;
end

--Factory for a per-player panel (GridGroupBy='Player' -- see
--SyncPlayerPanels). o.PlayerFilter being non-nil is what Render() below
--checks to switch column-building modes -- everything else (renderer,
--drag, snap, Alt-click editing) is identical to the classic singleton
--panel, inherited from the exact same GridGroup class.
function GridGroup.NewPlayerPanel(playerName)
    local o = setmetatable({}, GridGroup);

    local renderer = require('resources.renderers.grid');
    o.GridRenderer = renderer:New();
    o.PlayerFilter = playerName;

    if not gSettings.PlayerPositions[playerName] then
        --Staggers newly-created panels diagonally down-right of the main
        --Grid panel so they don't all spawn stacked exactly on top of each
        --other -- a starting point, not a final layout; drag (with snap,
        --if enabled) to arrange from there.
        local index = 0;
        for _ in pairs(playerPanelsByName) do index = index + 1; end
        gSettings.PlayerPositions[playerName] = { X = gSettings.Position.X + 260, Y = gSettings.Position.Y + (index * 130) };
        settings.save();
    end
    PanelBase.Init(o, gSettings.PlayerPositions[playerName], o.GridRenderer);

    return o;
end

--Called every frame (from callbacks.lua's d3d_present, only while
--GridGroupBy=='Player') with the SAME tickData the classic singleton
--would otherwise consume. Creates a panel for any player newly seen with
--at least one assignment, tears down (PanelBase:Unregister, so it also
--drops out of snap-to-align's gPanels) any panel for a player no longer
--assigned anything. Returns an alphabetically-ordered array for
--Render/RenderTooltip -- order doesn't matter functionally, just keeps
--frame-to-frame panel iteration order stable rather than Lua's
--unspecified pairs() order.
function GridGroup.SyncPlayerPanels(tickData)
    local namesSeen = {};
    for _,entry in ipairs(tickData) do
        if (entry.Local.Delete ~= true) and (entry.Local.DeleteColumn ~= true) then
            namesSeen[entry.TargetName] = true;
        end
    end

    for name,_ in pairs(namesSeen) do
        if not playerPanelsByName[name] then
            playerPanelsByName[name] = GridGroup.NewPlayerPanel(name);
        end
    end

    for name,panel in pairs(playerPanelsByName) do
        if not namesSeen[name] then
            panel:Unregister();
            playerPanelsByName[name] = nil;
        end
    end

    local names = T{};
    for name,_ in pairs(playerPanelsByName) do
        names:append(name);
    end
    table.sort(names);

    local ordered = T{};
    for _,name in ipairs(names) do
        ordered:append(playerPanelsByName[name]);
    end
    return ordered;
end

--For callbacks.lua's mouse handler, which needs to route events to
--whatever player panels currently exist without waiting for the next
--Render call to (re)compute that list.
function GridGroup.GetPlayerPanels()
    return playerPanelsByName;
end

--Tears down every player panel (PanelBase:Unregister included), for a
--character-change settings swap (see initializer.lua's UpdateSettings) --
--the OLD character's tracked players are meaningless for whoever's now
--logged in, so SyncPlayerPanels should rebuild from scratch next frame
--rather than keep stale panels (or panels positioned from the old
--gSettings.PlayerPositions, which UpdateSettings below doesn't otherwise
--resync).
function GridGroup.ResetPlayerPanels()
    for name,panel in pairs(playerPanelsByName) do
        panel:Unregister();
        playerPanelsByName[name] = nil;
    end
end

--Required by PanelBase:HandleDrag on release -- writes THIS panel's
--Position into wherever it actually lives in gSettings. For the classic
--singleton (PlayerFilter==nil) that's the fixed Position field; for a
--per-player panel it's gSettings.PlayerPositions[PlayerFilter].
function GridGroup:CommitPosition()
    if (self.PlayerFilter) then
        if not gSettings.PlayerPositions[self.PlayerFilter] then
            gSettings.PlayerPositions[self.PlayerFilter] = {};
        end
        gSettings.PlayerPositions[self.PlayerFilter].X = self.Position.X;
        gSettings.PlayerPositions[self.PlayerFilter].Y = self.Position.Y;
    else
        gSettings.Position.X = self.Position.X;
        gSettings.Position.Y = self.Position.Y;
    end
    settings.save();
end

--Called when settings.register swaps gSettings out for a new table
--(character change). Only meaningful for the classic singleton -- per-
--player panels are torn down wholesale by ResetPlayerPanels instead (see
--initializer.lua's UpdateSettings, which calls both), since the whole
--PLAYER SET is different for a different character, not just their saved
--positions.
function GridGroup:UpdateSettings(newSettings)
    if not self.PlayerFilter then
        self.Position.X = newSettings.Position.X;
        self.Position.Y = newSettings.Position.Y;
    end
end

--Click-to-cast (gSettings.GridClickToCast -- off by default, see
--initializer.lua). forceIgnoreState=true (Ctrl-click) casts regardless of
--cell.State; false (plain click) only fires when cell.State=='NotActive',
--so an accidental plain click can't interrupt/waste a buff that's still
--mostly up. Sends `/ma "<spell>" <target>` via Ashita's own sanctioned
--command queue (AshitaCore:GetChatManager():QueueCommand) -- the SAME
--pathway a typed command or a macro uses, not a raw outgoing packet (see
--initializer.lua's GridClickToCast comment for why that distinction
--matters in this project specifically). QueueCommand(delayTicks, command)
---- near-universally used across Ashita v4 addons, so lower-risk, but
--still unverified against this specific environment; confirm on first
--in-game test.
--
--A short per-entry cooldown (cell.Local.LastCastAttempt, the same
--persistent per-assignment table Delete/SoundFired/etc already live on)
--guards against a literal double-click queueing the command twice --
--doesn't prevent rapid clicks across DIFFERENT cells, only repeats on the
--SAME one.
local ClickCastCooldown = 1.5;
function GridGroup:TryClickCast(cell, forceIgnoreState)
    if (not gSettings.GridClickToCast) then
        return;
    end
    if (not forceIgnoreState) and (cell.State ~= 'NotActive') then
        return;
    end

    local now = os.clock();
    if (cell.Local.LastCastAttempt) and ((now - cell.Local.LastCastAttempt) < ClickCastCooldown) then
        return;
    end
    cell.Local.LastCastAttempt = now;

    --cell.ColumnLabel is already the resolved display name (e.g. "Haste")
    ---- same field the header/tooltip already show, no separate lookup
    --needed. Quoted since multi-word spell names need it for /ma to parse
    --correctly.
    local command = string.format('/ma "%s" %s', cell.ColumnLabel, cell.TargetName);
    AshitaCore:GetChatManager():QueueCommand(1, command);
end

function GridGroup:HandleMouse(e)
    self.Mouse.X = e.x;
    self.Mouse.Y = e.y;

    if self:HandleDrag(e) then
        return;
    end

    if (e.message == 513) then
        if (IsAltPressed()) then
            --Opens config.lua's Entry Editor popup for this cell's exact
            --assignment (Scale/Color/SoundEnabled/SoundId overrides) --
            --checked before Ctrl/Shift below since Alt-click is a distinct
            --third action, not a delete variant.
            local cell = self.GridRenderer:CellHitTest({X=self.Mouse.X, Y=self.Mouse.Y});
            if cell then
                config:EditEntry(cell);
                e.blocked = true;
                self.MouseBlocked = true;
                return;
            end
        elseif (IsControlPressed()) then
            --Click-to-cast, ignoring current state entirely (see
            --TryClickCast) -- repurposed from the old "delete entire
            --column" binding, see this file's header comment. Gated on
            --gSettings.GridClickToCast HERE, not just inside TryClickCast --
            --otherwise a Ctrl-click on a cell would still consume/block the
            --event even with the feature off, when it should fall through
            --exactly like clicking empty space (no binding at all).
            if (gSettings.GridClickToCast) then
                local cell = self.GridRenderer:CellHitTest({X=self.Mouse.X, Y=self.Mouse.Y});
                if cell then
                    self:TryClickCast(cell, true);
                    e.blocked = true;
                    self.MouseBlocked = true;
                    return;
                end
            end
        elseif (IsShiftPressed()) then
            local cell = self.GridRenderer:CellHitTest({X=self.Mouse.X, Y=self.Mouse.Y});
            if cell then
                cell.Local.Delete = true;
                e.blocked = true;
                self.MouseBlocked = true;
                return;
            end
        else
            --Plain click, no modifier -- click-to-cast, but ONLY when
            --NotActive (see TryClickCast). Was previously unbound/no-op on
            --a cell; same gating reasoning as the Ctrl-click branch above
            --applies here -- checked BEFORE hit-testing/blocking, not just
            --inside TryClickCast, so a plain click with the feature off
            --passes through untouched exactly as it always has.
            if (gSettings.GridClickToCast) then
                local cell = self.GridRenderer:CellHitTest({X=self.Mouse.X, Y=self.Mouse.Y});
                if cell then
                    self:TryClickCast(cell, false);
                    e.blocked = true;
                    self.MouseBlocked = true;
                    return;
                end
            end
        end
    end

    self:HandleMouseBlockedRelease(e);
end

--[[
    tickData(table) - flat array from trackers/assignment.lua:Tick(), one
    entry per assignment, each carrying at least:
        ActionType, ActionId, BuffId, ColumnLabel, TargetName,
        HasBeenApplied(boolean), Expiration(number|nil), TotalDuration(number|nil),
        Local(table) - Delete/DeleteColumn reserved, same object identity
                       across ticks so click-driven removal flags persist
                       until processed.
]]--
function GridGroup:Render(sprite, tickData)
    if (gSettings.Enabled == false) then
        return;
    end
    --Safety net: which set of panels actually gets Render() called each
    --frame is decided by callbacks.lua's own GridGroupBy branch, but this
    --guards against both ending up rendered if that branching is ever
    --wrong (e.g. a stray leftover panel mid-mode-switch).
    if (self.PlayerFilter) and (gSettings.GridGroupBy ~= 'Player') then
        return;
    end
    if (not self.PlayerFilter) and (gSettings.GridGroupBy == 'Player') then
        return;
    end

    local now = os.clock();
    local threshold = gSettings.AttentionThreshold;
    local grace = gSettings.AttentionGrace;

    local columnOrder = T{};
    local columnsByKey = {};

    for _,entry in ipairs(tickData) do
        if (entry.Local.Delete ~= true) and (entry.Local.DeleteColumn ~= true) then
         if (not self.PlayerFilter) or (entry.TargetName == self.PlayerFilter) then
            --Two grouping modes share this exact loop body (see
            --initializer.lua's GridGroupBy comment):
            --  ByBuff (PlayerFilter==nil, the classic singleton): one
            --    column PER BUFF, one row per player who has it.
            --  ByPlayer (PlayerFilter==a name, one panel per player): one
            --    column -- always just this panel's own player, since a
            --    per-player panel only ever shows ITS player -- one row
            --    per buff they're assigned.
            local key, label;
            if (self.PlayerFilter) then
                key = self.PlayerFilter;
                label = self.PlayerFilter;
            else
                key = string.format('%s:%u', entry.ActionType, entry.ActionId);
                label = entry.ColumnLabel;
            end
            local column = columnsByKey[key];
            if not column then
                column = {
                    Key = key,
                    Label = label,
                    --A ByPlayer column holds rows for POTENTIALLY several
                    --different buffs, so there's no single ActionType/
                    --ActionId/BuffId to show a header icon or MP cost for --
                    --left nil, which resources/renderers/grid.lua's DrawGrid
                    --already treats as "skip the icon"/"skip the cost" (see
                    --that file's own guards). ByBuff keeps today's behavior
                    --exactly.
                    ActionType = (not self.PlayerFilter) and entry.ActionType or nil,
                    ActionId = (not self.PlayerFilter) and entry.ActionId or nil,
                    BuffId = (not self.PlayerFilter) and entry.BuffId or nil,
                    Rows = T{},
                };
                columnsByKey[key] = column;
                columnOrder:append(column);
            end

            local remaining = 0;
            local state = 'NotActive';
            local percent = 0;
            --BlendT ranges 0-2: 0 = full High(green), 1 = full Middle(yellow),
            --2 = full Low(red). The renderer blends High->Middle across 0-1
            --and Middle->Low across 1-2, a three-color blend rather than a
            --flat two-color green/red switch.
            local blendT = 0;
            local blink = false;
            if (entry.HasBeenApplied) and (entry.Expiration ~= nil) then
                remaining = entry.Expiration - now;
                if (remaining > threshold) then
                    state = 'Active';
                    percent = remaining / entry.TotalDuration;
                    if (remaining <= (threshold + BlendWindow)) then
                        --Yellow->red stage: last BlendWindow seconds before the threshold.
                        blendT = 1 + ((threshold + BlendWindow - remaining) / BlendWindow);
                    elseif (remaining <= (threshold + (BlendWindow * 2))) then
                        --Green->yellow stage: the BlendWindow seconds before that.
                        blendT = (threshold + (BlendWindow * 2) - remaining) / BlendWindow;
                    end
                elseif (remaining > (grace * -1)) then
                    state = 'Attention';
                    blendT = 2;
                    if (remaining > 0) then
                        percent = remaining / entry.TotalDuration;
                    else
                        --Actually expired, within the grace window -- a full,
                        --blinking bar reads as a clearer "needs attention now"
                        --signal than a sliver about to vanish into NotActive
                        --anyway.
                        percent = 1;
                        blink = true;
                    end
                else
                    state = 'NotActive';
                    percent = 0;
                end
            end

            --Audio cue on entering Attention, edge-triggered off
            --entry.Local (the persistent per-assignment table -- same one
            --Delete/DeleteColumn/BlinkVisible already live on) so a held
            --Attention state fires once, not every frame; resets the
            --moment it leaves Attention so the NEXT Attention entry (a
            --recast that ran out again) fires again. Per-entry
            --SoundEnabled/SoundId (Alt-click override, see config.lua's
            --Entry Editor) take priority over the tracker-level
            --gSettings.GridSound default -- explicit nil means "inherit",
            --not "off".
            if (state == 'Attention') then
                if not entry.Local.SoundFired then
                    entry.Local.SoundFired = true;
                    --Defensive nil-guards on gSettings.GridSound/gSounds --
                    --added after a reported error at the exact moment a
                    --sound fired; unconfirmed root cause, but this class of
                    --unguarded index/call is the most likely candidate and
                    --costs nothing to harden regardless.
                    local soundEnabled = (entry.SoundEnabled ~= nil) and entry.SoundEnabled or (gSettings.GridSound and gSettings.GridSound.Enabled);
                    if (soundEnabled) and (gSounds) then
                        gSounds:Play(entry.SoundId or (gSettings.GridSound and gSettings.GridSound.SoundId));
                    end
                end
            else
                entry.Local.SoundFired = nil;
            end

            column.Rows:append({
                TargetName = entry.TargetName,
                ColumnLabel = entry.ColumnLabel,
                --Identity fields, absent from cellData before now -- added
                --so Alt-click (see HandleMouse) can resolve exactly which
                --assignment a hit-tested cell belongs to and hand it to
                --config.lua's Entry Editor / assignmentTracker.SetEntryOverrides.
                ActionType = entry.ActionType,
                ActionId = entry.ActionId,
                State = state,
                Duration = remaining,
                Percent = percent,
                BlendT = math.min(math.max(blendT, 0), 2),
                Blink = blink,
                FlashOnExpire = entry.FlashOnExpire,
                TotalDuration = entry.TotalDuration,
                --Per-entry overrides, nil = inherit GridScale/default color/
                --GridSound (see resources/renderers/grid.lua's DrawGrid for
                --how Scale/Color are consumed).
                Scale = entry.Scale,
                Color = entry.Color,
                SoundEnabled = entry.SoundEnabled,
                SoundId = entry.SoundId,
                Local = entry.Local,
                --Icon identity for the per-row icon ByPlayer mode draws
                --(see resources/renderers/grid.lua's DrawGrid) -- ByBuff
                --mode already shows this at the column header instead
                --(column.BuffId above), so the renderer only draws this
                --per-row when column.BuffId is nil (i.e. ByPlayer).
                BuffId = entry.BuffId,
                RowLabel = self.PlayerFilter and entry.ColumnLabel or nil,
            });
         end
        end
    end

    --Hover highlight for click-to-cast (gSettings.GridClickToCast) -- only
    --computed/shown when the feature is actually on, so there's no visual
    --suggestion of clickability when clicking wouldn't do anything. Uses
    --the PREVIOUS frame's hitboxes (CellHitTest reads self.HitBoxes, which
    --this frame's DrawGrid call below hasn't rebuilt yet) -- one frame
    --stale, same precision this project's click-handling itself already
    --runs on via the same CellHitTest call, so not a new category of lag.
    local hoveredIdentity = nil;
    if (gSettings.GridClickToCast) then
        local hovered = self.GridRenderer:CellHitTest({X=self.Mouse.X, Y=self.Mouse.Y});
        if (hovered) then
            hoveredIdentity = { ActionType = hovered.ActionType, ActionId = hovered.ActionId, TargetName = hovered.TargetName };
        end
    end

    self.GridRenderer:Begin();
    self.GridRenderer:DrawGrid(sprite, self.Position, columnOrder, hoveredIdentity);
    self.GridRenderer:End();
end

function GridGroup:RenderTooltip(sprite)
    if (self.AllowDrag) then
        self.GridRenderer:DrawDragHandle(sprite, self.Position);
    end
    if (gSettings.UseTooltips) then
        local cell = self.GridRenderer:CellHitTest({X=self.Mouse.X, Y=self.Mouse.Y});
        if cell then
            self.GridRenderer:DrawTooltip(sprite, { X = self.Mouse.X, Y = self.Mouse.Y }, cell);
            return true;
        end
    end
end

return GridGroup;
