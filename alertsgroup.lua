--[[
    alertsgroup.lua

    Analog of gridgroup.lua for the reactive alert panels -- §7.1 curable-
    debuff alerts and §7.2 dispellable-enemy-buff alerts. Originally one
    shared panel with two stacked sections; now two fully INDEPENDENT
    panels (their own position, scale, show-empty flag, sound settings --
    see initializer.lua's CuresPosition/WatchPosition/CuresScale/
    WatchScale/CuresShowEmpty/WatchShowEmpty/CuresSound/WatchSound), each
    an instance of this ONE generic class rather than two separate files --
    the only thing that differs between a Cures panel and a Watch panel is
    the handful of values captured in `Spec` at construction (see
    NewCuresPanel/NewWatchPanel at the bottom).

    Much simpler than GridGroup: alert rows are pure derived data
    recomputed fresh every tick by trackers/curable.lua and
    trackers/dispellable.lua -- nothing here is click-to-delete (both
    trackers already handle their own removal/expiry). The interactions
    this module owns are drag-to-reposition (same technique as GridGroup,
    via panelbase.lua) and Alt-click-to-edit (opens config.lua's Entry
    Editor for that specific row's per-entry overrides).
]]--

local ffi = require('ffi');
ffi.cdef [[
    int16_t GetKeyState(int32_t vkey);
]]
local function IsAltPressed()
    return (bit.band(ffi.C.GetKeyState(0x12), 0x8000) ~= 0); --VK_MENU
end

--Forward reference to config.lua, for the Alt-click Entry Editor popup
--(see HandleMouse below). Same safe-despite-load-order reasoning as
--gridgroup.lua's identical forward reference.
local config = require('config');

local PanelBase = require('panelbase');
local rendererModule = require('resources.renderers.alerts');

local AlertsGroup = setmetatable({}, { __index = PanelBase });
AlertsGroup.__index = AlertsGroup;

--[[
    spec(table) - everything that differs between a Cures panel and a
    Watch panel:
        KeyPrefix(string)       - 'cures' | 'watch', passed straight
                                   through to the renderer (row-label /
                                   hit-box cache keys).
        Title(string)           - header bar text, e.g. 'Cures Available'.
        PositionField(string)   - gSettings field this panel's position
                                   lives in ('CuresPosition'/'WatchPosition').
        ScaleSettingKey(string) - gSettings field for this panel's scale
                                   ('CuresScale'/'WatchScale').
        ShowEmptyKey(string)    - gSettings field for this panel's
                                   show-empty-header flag
                                   ('CuresShowEmpty'/'WatchShowEmpty').
        FormatRow(function)     - row -> display string (renderer.
                                   FormatCurable/FormatDispellable).
        EditRow(function)       - row -> (opens the Entry Editor for it),
                                   called on Alt-click. config:EditCureEntry
                                   for Cures, config:EditWatchEntry for
                                   Watch.
]]--
function AlertsGroup:New(spec, newSettings)
    local o = setmetatable({}, AlertsGroup);

    local renderer = rendererModule:New();
    o.AlertsRenderer = renderer;
    o.Spec = spec;
    PanelBase.Init(o, newSettings[spec.PositionField], renderer);
    o.DefaultWidth = 220;
    o.DefaultHeight = 20;

    return o;
end

--Required by PanelBase:HandleDrag on release -- writes THIS panel's
--Position into wherever it actually lives in gSettings (Spec.PositionField)
--and persists it.
function AlertsGroup:CommitPosition()
    gSettings[self.Spec.PositionField].X = self.Position.X;
    gSettings[self.Spec.PositionField].Y = self.Position.Y;
    settings.save();
end

--Same pattern as GridGroup:UpdateSettings -- only Position needs resyncing
--on a character-change settings swap.
function AlertsGroup:UpdateSettings(newSettings)
    self.Position.X = newSettings[self.Spec.PositionField].X;
    self.Position.Y = newSettings[self.Spec.PositionField].Y;
end

function AlertsGroup:HandleMouse(e)
    self.Mouse.X = e.x;
    self.Mouse.Y = e.y;

    if self:HandleDrag(e) then
        return;
    end

    --Alt-click a live row to open its Entry Editor -- works for both
    --Cures (per-(player,debuff) + per-debuff overrides) and Watch
    --(per-watched-action overrides) now, via Spec.EditRow, which each
    --factory below wires to the right config.lua function.
    if (e.message == 513) and (IsAltPressed()) then
        local row = self.AlertsRenderer:CellHitTest({X=self.Mouse.X, Y=self.Mouse.Y});
        if row then
            self.Spec.EditRow(row);
            e.blocked = true;
            self.MouseBlocked = true;
            return;
        end
    end

    self:HandleMouseBlockedRelease(e);
end

--alerts(table) - array from the owning tracker's Tick() (or
--callbacks.lua's Preview substitute) -- see trackers/curable.lua /
--trackers/dispellable.lua for the row shape.
function AlertsGroup:Render(sprite, alerts)
    if (gSettings.Enabled == false) then
        return;
    end
    local scale = gSettings[self.Spec.ScaleSettingKey];
    local showEmpty = gSettings[self.Spec.ShowEmptyKey];

    self.AlertsRenderer:Begin();
    self.AlertsRenderer:DrawSingle(sprite, self.Position, self.Spec.KeyPrefix, self.Spec.Title, alerts, self.Spec.FormatRow, scale, showEmpty);
    self.AlertsRenderer:End();
end

function AlertsGroup:RenderTooltip(sprite)
    if (self.AllowDrag) then
        self.AlertsRenderer:DrawDragHandle(sprite, self.Position, gSettings[self.Spec.ScaleSettingKey]);
    end
end

--Factories -- the only two ways this class is ever actually instantiated
--(see initializer.lua). Keeps Spec construction (and the config.lua
--EditRow wiring) out of initializer.lua, which just wants an already-built
--panel back.
function AlertsGroup.NewCuresPanel(newSettings)
    return AlertsGroup:New({
        KeyPrefix = 'cures',
        Title = 'Cures Available',
        PositionField = 'CuresPosition',
        ScaleSettingKey = 'CuresScale',
        ShowEmptyKey = 'CuresShowEmpty',
        FormatRow = rendererModule.FormatCurable,
        EditRow = function(row) config:EditCureEntry(row); end,
    }, newSettings);
end

function AlertsGroup.NewWatchPanel(newSettings)
    return AlertsGroup:New({
        KeyPrefix = 'watch',
        Title = 'Enemy Buffs',
        PositionField = 'WatchPosition',
        ScaleSettingKey = 'WatchScale',
        ShowEmptyKey = 'WatchShowEmpty',
        FormatRow = rendererModule.FormatDispellable,
        EditRow = function(row) config:EditWatchEntry(row); end,
    }, newSettings);
end

return AlertsGroup;
