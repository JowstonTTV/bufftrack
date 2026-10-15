--[[
    resources/renderers/alerts.lua

    Simple text-row renderer for the reactive alert panels (§7.1 curable-
    debuff alerts, §7.2 dispellable-enemy-buff alerts). Deliberately NOT
    the textured bar/icon system resources/renderers/grid.lua uses -- alert
    rows have no meaningful "percent remaining" to fill: §7.1 is pure
    presence/absence (a debuff either is or isn't currently curable) and
    §7.2 counts UP with no known total duration. Just a header bar plus one
    text line per active alert.

    Cures and Watch are now two INDEPENDENT panels (see alertsgroup.lua's
    NewCuresPanel/NewWatchPanel), each owning its own renderer instance of
    this module -- so "section" language below refers to the ONE section a
    given instance draws, not two stacked ones sharing state. Per-row
    Scale/Color overrides work for both: Cures via CureOverrides +
    CureMap-level overrides (trackers/curable.lua), Watch via
    EnemyBuffWatchList-level overrides (trackers/dispellable.lua) -- see
    each tracker's Tick() for how those get attached to a row.
]]--

local gdi = require('gdifonts.include');
local ffi = require('ffi');

local vec_position = ffi.new('D3DXVECTOR2', { 0, 0 });
local vec_scale = ffi.new('D3DXVECTOR2', { 1, 1 });

local function CreateHitBox(x, y, width, height)
    return { MinX=x, MaxX=(x+width), MinY=y, MaxY=(y+height) };
end

--Layout constants, in unscaled pixels -- same convention as
--resources/renderers/grid.lua's Layout table.
local Layout = {
    Width = 220,
    HeaderHeight = 18,
    RowHeight = 16,
    Padding = 4,
    DragHandleSize = 10,
};

local SectionHeaderColor = 0xFF1C1C1C;
local OutlineColor = 0xFF000000;

local function CreateRect(fillColor, cornerRounding)
    return gdi:create_rect({ fill_color = fillColor, outline_color = OutlineColor, outline_width = 1, corner_rounding = cornerRounding or 0 }, true);
end

local renderer = {};

function renderer:New()
    local o = {};
    setmetatable(o, self);
    self.__index = self;
    o.RowLabels = {};
    o.HitBoxes = T{};
    return o;
end

function renderer:Destroy()
    self.RowLabels = {};
    self.SectionHeaderRects = nil;
    self.DragHandleRect = nil;
end

function renderer:Begin()
    self.HitBoxes = T{};
end

function renderer:End()
    --Nothing needed.
end

function renderer:GetOrCreateLabel(key)
    local label = self.RowLabels[key];
    if not label then
        label = gdi:create_object({ font_height = 11, font_color = 0xFFFFFFFF, font_alignment = gdi.Alignment.Left }, true);
        self.RowLabels[key] = label;
    end
    return label;
end

--Drops cached row-label objects for a section, from `from` to `to`
--(inclusive) -- same technique resources/renderers/grid.lua uses for
--removed columns: dropping the Lua reference lets gdifonts' own
--GC-driven cleanup actually hide it, since simply not calling render()
--this frame isn't sufficient on its own (these are persistent overlay
--objects, not a cleared-each-frame draw list). Also drops any cached
--Flash blink-state and group-divider rect for the same keys (see
--DrawSection's row loop) so a row that disappears doesn't leave stale
--state/objects behind.
function renderer:PruneRowLabels(keyPrefix, from, to)
    for i = from,to do
        local key = string.format('%s:%u', keyPrefix, i);
        self.RowLabels[key] = nil;
        if (self.BlinkState) then
            self.BlinkState[key] = nil;
        end
        if (self.DividerRects) then
            self.DividerRects[key] = nil;
        end
    end
end

--Same recipe as resources/renderers/grid.lua's DrawDragHandle -- kept
--separate (not shared) since the two renderers otherwise have no common
--base to hang a shared helper off of. `scale` is passed in by the caller
--(each of Cures/Watch is now its own panel with its own scale setting --
--see alertsgroup.lua's RenderTooltip -- rather than this module guessing
--which tracker-level scale applies).
function renderer:DrawDragHandle(sprite, position, scale)
    local size = Layout.DragHandleSize * scale;
    if not self.DragHandleRect then
        self.DragHandleRect = gdi:create_rect({
            width = size,
            height = size,
            corner_rounding = 2,
            fill_color = 0xC0B34700,
            outline_color = 0xFF000000,
            outline_width = 1,
        }, true);
    end
    local handleX = position.X;
    local handleY = math.max(position.Y - size, 0);
    self.DragHandleRect:set_width(size);
    self.DragHandleRect:set_height(size);
    self.DragHandleRect:set_position_x(handleX);
    self.DragHandleRect:set_position_y(handleY);
    self.DragHandleRect:render(sprite);
    self.DragHitBox = CreateHitBox(handleX, handleY, size, size);
end

--Draws one section (header bar + one line per row) -- entirely SKIPPED
--(no header, nothing) when rows is empty, per the reactive-panel design:
--an alert panel only exists on screen while it has something active.
--Returns (y, didDraw): didDraw isn't needed by DrawSingle below (there's
--only ever one section per panel now), kept for callers that want it.
function renderer:DrawSection(sprite, x, y, width, scale, keyPrefix, title, rows, formatRow, showEmpty)
    local lastCount = (self.LastRowCount and self.LastRowCount[keyPrefix]) or 0;

    if (#rows == 0) and (not showEmpty) then
        --Drop everything this section had cached -- header, and every row
        --label up to whatever the last-seen count was -- so nothing lingers
        --once the section has nothing to show. Only reached when the
        --owning panel's ShowEmpty flag is off (the default) -- see the
        --showEmpty branch below for the "keep the header visible"
        --alternative.
        if (lastCount > 0) then
            self:PruneRowLabels(keyPrefix, 1, lastCount);
        end
        if (self.SectionHeaderRects) then
            self.SectionHeaderRects[keyPrefix] = nil;
        end
        self.RowLabels[keyPrefix .. ':header'] = nil;
        if not self.LastRowCount then
            self.LastRowCount = {};
        end
        self.LastRowCount[keyPrefix] = 0;
        return y, false;
    end

    local headerHeight = Layout.HeaderHeight * scale;
    local padding = Layout.Padding * scale;

    if not self.SectionHeaderRects then
        self.SectionHeaderRects = {};
    end
    local headerRect = self.SectionHeaderRects[keyPrefix];
    if not headerRect then
        headerRect = CreateRect(SectionHeaderColor, 2);
        self.SectionHeaderRects[keyPrefix] = headerRect;
    end
    headerRect:set_width(width);
    headerRect:set_height(headerHeight);
    headerRect:set_position_x(x);
    headerRect:set_position_y(y);
    headerRect:render(sprite);

    local headerLabel = self:GetOrCreateLabel(keyPrefix .. ':header');
    headerLabel:set_font_height(11 * scale);
    headerLabel:set_font_color(0xFFFFFFFF);
    headerLabel:set_text(string.format('%s (%u)', title, #rows));
    headerLabel:set_position_x(x + padding);
    headerLabel:set_position_y(y + (2 * scale));
    headerLabel:render(sprite);

    local rowY = y + headerHeight;
    local previousTargetName = nil;
    for i,row in ipairs(rows) do
        --Per-row Scale/Color override, resolved by the owning tracker's
        --Tick() before the row ever reaches here (see this file's header
        --comment) -- nil falls back to the panel's own scale/default
        --color, same "explicit nil means inherit" convention used
        --everywhere else in this project.
        local rowScale = row.Scale or scale;
        local rowHeight = Layout.RowHeight * rowScale;
        local rowKey = string.format('%s:%u', keyPrefix, i);

        --Group divider (gSettings.CuresGroupDivider, Cures panel only --
        --Watch has no stable per-row "owner" to group by, see
        --initializer.lua's doc comment): a thin rule drawn at the TOP of
        --this row when it belongs to a different target than the row
        --before it. Relies on trackers/curable.lua's Tick() already
        --sorting rows by TargetName (see that function's own comment) so
        --same-target rows are adjacent -- this only has to compare
        --NEIGHBORS, not re-group anything itself. Skipped for the first
        --row (i==1) -- nothing above it to separate from.
        if (keyPrefix == 'cures') and (gSettings.CuresGroupDivider) and (i > 1) and (row.TargetName ~= previousTargetName) then
            if not self.DividerRects then
                self.DividerRects = {};
            end
            local divider = self.DividerRects[rowKey];
            if not divider then
                divider = gdi:create_rect({ fill_color = 0xFF4D463C, outline_width = 0 }, true);
                self.DividerRects[rowKey] = divider;
            end
            divider:set_width(width);
            divider:set_height(1);
            divider:set_position_x(x);
            divider:set_position_y(rowY);
            divider:render(sprite);
        elseif (self.DividerRects) then
            self.DividerRects[rowKey] = nil;
        end
        previousTargetName = row.TargetName;

        --Continuous pulse (row.Flash) -- same 0.2s on/off toggle
        --resources/renderers/grid.lua's Blink uses, but keyed by
        --row POSITION in this renderer's own self.BlinkState rather than a
        --persistent per-row object (alert rows are rebuilt fresh every
        --tick by the owning tracker, so there's no stable table to hang
        --state on the way grid.lua hangs Blink state off cell.Local).
        --Applied as alpha (masking row.Color/white's top byte to 0 on the
        --"off" half) rather than skipping the draw entirely, so the row's
        --hitbox/layout stay put and Alt-click keeps working mid-blink.
        local displayColor = row.Color or 0xFFFFFFFF;
        if (row.Flash) then
            if not self.BlinkState then
                self.BlinkState = {};
            end
            local blink = self.BlinkState[rowKey];
            if not blink then
                blink = { Visible = true, NextFrame = os.clock() + 0.2 };
                self.BlinkState[rowKey] = blink;
            elseif (os.clock() > blink.NextFrame) then
                blink.Visible = not blink.Visible;
                blink.NextFrame = os.clock() + 0.2;
            end
            if not blink.Visible then
                displayColor = bit.band(displayColor, 0x00FFFFFF); --alpha to 0, RGB unchanged
            end
        elseif (self.BlinkState) then
            self.BlinkState[rowKey] = nil; --stopped flashing -- don't carry stale toggle state
        end

        --Per-row job icon (gSettings.CuresShowJobIcon, Cures panel only).
        --Direct gTextureCache+sprite:Draw, NOT uiskin:DrawInlineIcon --
        --that helper is ImGui-only (uses imgui.GetWindowDrawList()), and
        --this is the GDI/D3D sprite overlay renderer, a completely
        --different rendering path -- mirrors
        --resources/renderers/grid.lua's own per-row icon technique
        --instead (added for its ByPlayer mode).
        local textStartX = x + padding;
        if (keyPrefix == 'cures') and (gSettings.CuresShowJobIcon) and (row.JobAbbr) then
            local icon = gTextureCache:GetTexture(string.format('jobs/%s/%s.png', gSettings.JobIconStyle or 'FFXI', string.lower(row.JobAbbr)));
            if (icon ~= nil) then
                local iconSize = rowHeight - 2;
                if (self.IconRect == nil) then
                    self.IconRect = ffi.new('RECT', { 0, 0, 0, 0 });
                end
                self.IconRect.right = icon.Width;
                self.IconRect.bottom = icon.Height;
                vec_scale.x = iconSize / icon.Width;
                vec_scale.y = iconSize / icon.Height;
                vec_position.x = x + padding;
                vec_position.y = rowY + ((rowHeight - iconSize) / 2);
                sprite:Draw(icon.Texture, self.IconRect, vec_scale, nil, 0.0, vec_position, 0xFFFFFFFF);
                textStartX = x + padding + iconSize + (padding / 2);
            end
        end

        local rowLabel = self:GetOrCreateLabel(rowKey);
        rowLabel:set_font_height(10 * rowScale);
        rowLabel:set_font_color(displayColor);
        rowLabel:set_text(formatRow(row));
        rowLabel:set_position_x(textStartX);
        rowLabel:set_position_y(rowY + (1 * rowScale));
        rowLabel:render(sprite);

        self.HitBoxes:append({ RowData = row, HitBox = CreateHitBox(x, rowY, width, rowHeight) });
        rowY = rowY + rowHeight;
    end

    --Row count shrank since last frame (an alert cleared) -- drop the
    --now-unused tail instead of leaving it cached forever. Also covers the
    --ShowEmpty "header stayed, rows dropped to 0" case, since that now
    --falls through to here instead of the early-return above.
    if (lastCount > #rows) then
        self:PruneRowLabels(keyPrefix, #rows + 1, lastCount);
    end
    if not self.LastRowCount then
        self.LastRowCount = {};
    end
    self.LastRowCount[keyPrefix] = #rows;

    return rowY, true;
end

--Row-level hit test, for Alt-click on a live alert row (see
--alertsgroup.lua's HandleMouse) -- mirrors resources/renderers/grid.lua's
--CellHitTest exactly, just against alert rows instead of grid cells.
--Returns the row data (as passed into DrawSection -- Cures rows carry
--TargetName/StatusId identity, Watch rows carry ActionType/ActionId) or
--nil.
function renderer:CellHitTest(position)
    for _,entry in ipairs(self.HitBoxes) do
        local box = entry.HitBox;
        if (position.X >= box.MinX) and (position.X <= box.MaxX) then
            if (position.Y >= box.MinY) and (position.Y <= box.MaxY) then
                return entry.RowData;
            end
        end
    end
    return nil;
end

--Exported (not local) so alertsgroup.lua's NewCuresPanel/NewWatchPanel
--factories can wire them in without duplicating the formatting logic.
--Erase-backed rows (row.ShowDebuffName, set by trackers/curable.lua's
--Tick) show "Player - Erase - Debuff" instead of the usual "Player: Spell"
---- Erase covers many different debuffs, so the spell name alone doesn't
--say which one a given row is for. Everything else keeps the original
--format, since Poisona/Paralyna/etc already imply their debuff.
function renderer.FormatCurable(row)
    if (row.ShowDebuffName) and (row.DebuffName) then
        return string.format('%s - %s - %s', row.TargetName, row.Label, row.DebuffName);
    end
    return string.format('%s: %s', row.TargetName, row.Label);
end

function renderer.FormatDispellable(row)
    return string.format('%s: %s (%us)', row.TargetName, row.Label, math.floor(row.ElapsedSeconds));
end

--One panel = one section now (Cures and Watch each own their own renderer
--instance -- see this file's header comment), so this is just DrawSection
--plus the bounds bookkeeping GetBounds() (panelbase.lua) reads afterward.
--Replaces the old two-section DrawAlerts orchestration.
function renderer:DrawSingle(sprite, position, keyPrefix, title, rows, formatRow, scale, showEmpty)
    local bottom = self:DrawSection(sprite, position.X, position.Y, Layout.Width * scale, scale, keyPrefix, title, rows, formatRow, showEmpty);
    self.LastWidth = Layout.Width * scale;
    self.LastHeight = bottom - position.Y;
end

function renderer:DragHitTest(position)
    local hitBox = self.DragHitBox;
    if hitBox then
        if (position.X >= hitBox.MinX) and (position.X <= hitBox.MaxX) then
            if (position.Y >= hitBox.MinY) and (position.Y <= hitBox.MaxY) then
                return true;
            end
        end
    end
    return false;
end

return renderer;
