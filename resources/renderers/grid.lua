--[[
    resources/renderers/grid.lua

    BuffTrack's sole renderer. Header bars are rounded GDI rectangles
    (gdi:create_rect) showing the buff's status icon (via gTextureCache's
    STATUS: texture-cache convention), name, and MP cost; cell fills use
    vendored bar/outline PNG textures (clipped horizontally by
    percent-remaining, blended per state) rather than flat colored rects;
    tooltips use a font-object "background" sub-table for an auto-sized
    rounded box.

    Layout: columns = buffs (left to right, insertion order), rows =
    assigned players within a column (top to bottom, insertion order).
    Header row per column shows the icon/name/cost; each row below shows
    player name + remaining duration, cell fill tinted/sized by state.
]]--

local d3d = require('d3d8');
local ffi = require('ffi');
local gdi = require('gdifonts.include');
local spellcosts = require('spellcosts');

local function CreateHitBox(x, y, width, height)
    return { MinX=x, MaxX=(x+width), MinY=y, MaxY=(y+height) };
end

local function TimeToString(timer, showTenths)
    timer = math.max(timer, 0);
    if (timer >= 3600) then
        local h = math.floor(timer / 3600);
        local m = math.floor(math.fmod(timer, 3600) / 60);
        return string.format('%i:%02i', h, m);
    elseif (timer >= 60) then
        local m = math.floor(timer / 60);
        local s = math.floor(math.fmod(timer, 60));
        return string.format('%i:%02i', m, s);
    elseif (showTenths) then
        return string.format('%i.%i', math.floor(timer), math.floor(math.fmod(timer, 1) * 10));
    else
        return string.format('%i', math.floor(timer));
    end
end

--Layout constants, in unscaled pixels. ColumnGap gives visible separation
--between adjacent buff columns rather than columns touching edge to edge.
local Layout = {
    ColumnWidth = 130,
    ColumnGap = 6,
    HeaderHeight = 22,
    RowHeight = 22,
    Padding = 4,
    DragHandleSize = 10,
    IconSize = 16,
};

--Rect outline, applied to both header and cell rects so adjacent columns
--(and stacked rows) read as distinct bordered blocks even when their fill
--colors happen to match, rather than flat unbounded fills.
local OutlineColor = 0xFF000000;
local OutlineWidth = 1;

--There's no NotActive tint: percent=0 means the bar layer is simply
--skipped, leaving just the black outline frame -- an absent buff just
--reads as an empty slot, no separate color needed for it.
local HighColor = { A=0xFF, R=0x00, G=0xFF, B=0x00 };
local MiddleColor = { A=0xFF, R=0xFF, G=0xFF, B=0x00 };
local LowColor = { A=0xFF, R=0xFF, G=0x00, B=0x00 };
local HeaderColor = 0xFF1C1C1C;

--Linear interpolation per channel between two {A,R,G,B} tables.
local function BlendColor(startColor, endColor, percent)
    local a = math.min(255, math.ceil((startColor.A * (1 - percent)) + (endColor.A * percent)));
    local r = math.min(255, math.ceil((startColor.R * (1 - percent)) + (endColor.R * percent)));
    local g = math.min(255, math.ceil((startColor.G * (1 - percent)) + (endColor.G * percent)));
    local b = math.min(255, math.ceil((startColor.B * (1 - percent)) + (endColor.B * percent)));
    return d3d.D3DCOLOR_ARGB(a, r, g, b);
end

--blendT in 0-2: 0=full High, 1=full Middle, 2=full Low -- a three-color
--blend rather than a flat two-color switch.
--
--highOverride({A,R,G,B}|nil) - per-entry Color override (see
--Assignments[i].Color in initializer.lua), substituted for the module-level
--HighColor anchor when the row is in its "healthy" state. The Attention/
--expiring blend toward Middle/Low is intentionally unaffected -- overriding
--the whole gradient per-entry would make the universal "running out"
--warning colors mean different things cell to cell, which defeats their
--point.
local function GetBlendedColor(blendT, highOverride)
    local high = highOverride or HighColor;
    if (blendT <= 1) then
        return BlendColor(high, MiddleColor, blendT);
    else
        return BlendColor(MiddleColor, LowColor, blendT - 1);
    end
end

--Unpacks a 0xAARRGGBB uint32 (config.lua's ImGui ColorEdit4 round-trips
--through this same packing, see Float4ToARGB/ARGBToFloat4 there) into the
--{A,R,G,B} 0-255 table shape BlendColor/GetBlendedColor expect.
local function UnpackARGB(argb)
    return {
        A = bit.band(bit.rshift(argb, 24), 0xFF),
        R = bit.band(bit.rshift(argb, 16), 0xFF),
        G = bit.band(bit.rshift(argb, 8), 0xFF),
        B = bit.band(argb, 0xFF),
    };
end

local renderer = {};

function renderer:New()
    local o = {};
    setmetatable(o, self);
    self.__index = self;
    o.HitBoxes = T{};
    o.HeaderLabels = {};

    --Reuses the vendored bar/outline assets in resources/skins/grid/assets/.
    --Outline is tinted black as a background frame; Bar is tinted per-state
    --and clipped horizontally to represent percent remaining.
    o.Bar = gTextureCache:GetTexture('skins/grid/assets/bar_windower.png');
    o.Outline = gTextureCache:GetTexture('skins/grid/assets/outline_windower.png');
    if (o.Bar == nil) or (o.Outline == nil) then
        Error('BuffTrack: failed to load bar/outline textures; cells will render without a fill.');
    else
        o.BarRect = ffi.new('RECT', { 0, 0, o.Bar.Width, o.Bar.Height });
        o.OutlineRect = ffi.new('RECT', { 0, 0, o.Outline.Width, o.Outline.Height });
    end

    return o;
end

function renderer:Destroy()
    self.HeaderLabels = {};
    self.DragHandleRect = nil;
end

function renderer:Begin()
    --Nothing needed; objects are created lazily and rendered manually below.
end

function renderer:End()
    --Nothing needed.
end

function renderer:GetOrCreateHeaderLabel(key)
    local label = self.HeaderLabels[key];
    if not label then
        label = gdi:create_object({ font_height = 12, font_color = 0xFFFFFFFF, font_alignment = gdi.Alignment.Left }, true);
        self.HeaderLabels[key] = label;
    end
    return label;
end

local function CreateRect(fillColor, cornerRounding)
    return gdi:create_rect({ fill_color = fillColor, outline_color = OutlineColor, outline_width = OutlineWidth, corner_rounding = cornerRounding or 0 }, true);
end

local vec_position = ffi.new('D3DXVECTOR2', { 0, 0 });
local vec_scale = ffi.new('D3DXVECTOR2', { 1, 1 });

--Draws the outline (black-tinted background frame) and, if percent > 0, the
--bar clipped to that percent and tinted with color (BarRect.right clipped
--to a fraction of the source texture's width, then scaled up to the
--destination size).
function renderer:DrawBar(sprite, x, y, width, height, percent, color)
    if (self.Outline == nil) or (self.Bar == nil) then
        return;
    end

    vec_scale.x = width / self.Outline.Width;
    vec_scale.y = height / self.Outline.Height;
    vec_position.x = x;
    vec_position.y = y;
    sprite:Draw(self.Outline.Texture, self.OutlineRect, vec_scale, nil, 0.0, vec_position, 0xFF000000);

    if (percent > 0) then
        self.BarRect.right = math.max(1, math.floor(percent * self.Bar.Width));
        vec_scale.x = width / self.Bar.Width;
        vec_scale.y = height / self.Bar.Height;
        sprite:Draw(self.Bar.Texture, self.BarRect, vec_scale, nil, 0.0, vec_position, color);
    end
end

function renderer:DrawDragHandle(sprite, position)
    local scale = gSettings.GridScale;
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
    --Placed just above the grid's top-left corner, flush with the left
    --edge rather than offset further left -- at the default Position
    --(X=0), subtracting size from X would push the handle off-screen
    --entirely, making it permanently unclickable.
    local handleX = position.X;
    local handleY = math.max(position.Y - size, 0);
    self.DragHandleRect:set_width(size);
    self.DragHandleRect:set_height(size);
    self.DragHandleRect:set_position_x(handleX);
    self.DragHandleRect:set_position_y(handleY);
    self.DragHandleRect:render(sprite);
    self.DragHitBox = CreateHitBox(handleX, handleY, size, size);
end

--[[
    columns(table) - ordered array of { Key, Label, Rows(array of cellData) }
    cellData - { TargetName, State, Duration, TotalDuration, Local }
    hoveredIdentity(table|nil) - { ActionType, ActionId, TargetName } of the
        cell under the cursor, for click-to-cast's hover highlight (see
        gridgroup.lua's Render) -- compared by VALUE against each cell
        rather than by reference, since cell tables are rebuilt fresh every
        frame from tickData and never share object identity with whatever
        CellHitTest returned from the previous frame's hitboxes.
]]--
function renderer:DrawGrid(sprite, position, columns, hoveredIdentity)
    self.HitBoxes = T{};
    local hoverDrawnThisFrame = false;
    --headerHeight/padding stay tied to the tracker-level GridScale only --
    --the header represents the BUFF, not a specific player's priority, so
    --it doesn't grow just because one row in the column is oversized. Column
    --WIDTH is different: it used to be fixed at GridScale regardless of any
    --row's own Scale override, which is exactly the bug where an oversized
    --row's wider text overflowed a column still sized for the baseline --
    --now each column widens to fit whichever of its own rows needs the most
    --room (see the per-column columnScale computation below), so
    --neighboring rows in the SAME column still share one width (no internal
    --misalignment), but different COLUMNS are free to differ in width from
    --each other now, which they weren't before.
    local scale = gSettings.GridScale;
    local headerHeight = Layout.HeaderHeight * scale;
    local padding = Layout.Padding * scale;
    local showTenths = gSettings.ShowTenths;

    local seenKeys = {};
    --Tracks the tallest column's total height this frame, for GetBounds()
    --(see gridgroup.lua) -- can't be computed in advance since it now
    --depends on each row's own possibly-overridden Scale.
    local tallestColumnHeight = headerHeight;
    --Running X-offset, not indexed off `i` -- columns no longer share one
    --uniform colStride now that width varies per column (see columnScale
    --above), so this has to accumulate the same way rowY already does.
    local colX = position.X;
    local totalWidth = 0;

    for i,column in ipairs(columns) do
        seenKeys[column.Key] = true;

        --This column's own width: at least the tracker-level scale, but
        --widened further if any row in it carries a LARGER Scale override --
        --the actual fix for the overflow bug (see this function's header
        --comment).
        local columnScale = scale;
        for _,cell in ipairs(column.Rows) do
            if (cell.Scale) and (cell.Scale > columnScale) then
                columnScale = cell.Scale;
            end
        end
        local colWidth = Layout.ColumnWidth * columnScale;
        local colY = position.Y;

        if not self.HeaderRects then
            self.HeaderRects = {};
        end
        local headerRect = self.HeaderRects[column.Key];
        if not headerRect then
            headerRect = CreateRect(HeaderColor, 2);
            self.HeaderRects[column.Key] = headerRect;
        end
        headerRect:set_width(colWidth);
        headerRect:set_height(headerHeight);
        headerRect:set_position_x(colX);
        headerRect:set_position_y(colY);
        headerRect:render(sprite);

        --Icon: status icon index is just the buff ID, resolved through
        --gTextureCache.
        local iconSize = Layout.IconSize * scale;
        local textStartX = colX + padding;
        if (column.BuffId ~= nil) and (column.BuffId > 0) then
            local icon = gTextureCache:GetTexture(string.format('STATUS:%u', column.BuffId));
            if (icon ~= nil) then
                if (self.IconRect == nil) then
                    self.IconRect = ffi.new('RECT', { 0, 0, 0, 0 });
                end
                self.IconRect.right = icon.Width;
                self.IconRect.bottom = icon.Height;
                vec_scale.x = iconSize / icon.Width;
                vec_scale.y = iconSize / icon.Height;
                vec_position.x = colX + padding;
                vec_position.y = colY + ((headerHeight - iconSize) / 2);
                sprite:Draw(icon.Texture, self.IconRect, vec_scale, nil, 0.0, vec_position, 0xFFFFFFFF);
                textStartX = colX + padding + iconSize + (padding / 2);
            end
        end

        local headerLabel = self:GetOrCreateHeaderLabel(column.Key);
        headerLabel:set_font_height(12 * scale);
        headerLabel:set_text(column.Label);
        --Left-aligned (anchors at the text's left edge) rather than
        --centered, since a centered label would sit awkwardly relative to
        --an icon that's only on the left side.
        headerLabel:set_font_alignment(gdi.Alignment.Left);
        headerLabel:set_position_x(textStartX);
        headerLabel:set_position_y(colY + (2 * scale));
        headerLabel:render(sprite);

        --MP cost: sourced from spellcosts.lua's baked-in Enhancing Magic
        --data (see libs/spellcosts_data.lua); shows "--" for anything
        --outside that set rather than guessing.
        if not self.CostLabels then
            self.CostLabels = {};
        end
        local costLabel = self.CostLabels[column.Key];
        if not costLabel then
            costLabel = gdi:create_object({ font_height = 9, font_color = 0xFFC0C0C0, font_alignment = gdi.Alignment.Right }, true);
            self.CostLabels[column.Key] = costLabel;
        end
        local cost = column.ActionType and spellcosts:GetCost(column.ActionType, column.ActionId) or nil;
        costLabel:set_font_height(9 * scale);
        costLabel:set_text(string.format('MP %s', cost and tostring(cost) or '--'));
        costLabel:set_position_x(colX + colWidth - padding);
        costLabel:set_position_y(colY + headerHeight - (11 * scale));
        costLabel:render(sprite);

        --Running Y-offset, not indexed off `j` -- each row can have its
        --own Scale (cell.Scale override or the column-wide `scale`
        --fallback), so row heights are no longer uniform within a column
        --and must accumulate rather than multiply.
        local rowY = colY + headerHeight;
        for j,cell in ipairs(column.Rows) do
            local cellScale = cell.Scale or scale;
            local rowHeight = Layout.RowHeight * cellScale;
            local cellPadding = Layout.Padding * cellScale;

            --The color argument only matters when Percent > 0 (DrawBar
            --skips the bar layer entirely otherwise, which is how
            --NotActive's "just an empty black frame" look happens).
            --BlendT eases continuously through Active's green, warning
            --yellow, and Attention's red, rather than snapping between
            --states. cell.Color (per-entry override, see initializer.lua)
            --replaces the green "healthy" anchor only -- see
            --GetBlendedColor's comment for why the warning blend itself
            --isn't overridden.
            local barColor = GetBlendedColor(cell.BlendT, cell.Color and UnpackARGB(cell.Color) or nil);
            local barPercent = cell.Percent;

            if (cell.Blink) and (cell.FlashOnExpire ~= false) then
                --0.2s on/off toggle, applied here to the "just expired,
                --still in the attention grace window" case.
                if (cell.Local.BlinkVisible == nil) then
                    cell.Local.BlinkVisible = true;
                    cell.Local.BlinkNextFrame = os.clock() + 0.2;
                elseif (os.clock() > cell.Local.BlinkNextFrame) then
                    cell.Local.BlinkVisible = not cell.Local.BlinkVisible;
                    cell.Local.BlinkNextFrame = os.clock() + 0.2;
                end
                if not cell.Local.BlinkVisible then
                    barPercent = 0;
                end
            else
                --FlashOnExpire=false: leave barPercent at cell.Percent (a
                --steady full bar during the grace window, per Blink's own
                --percent=1 assignment in gridgroup.lua) -- shown, just not
                --toggling on/off.
                cell.Local.BlinkVisible = nil;
                cell.Local.BlinkNextFrame = nil;
            end

            self:DrawBar(sprite, colX, rowY, colWidth, rowHeight, barPercent, barColor);

            --Per-row icon, ONLY when the column itself has no single icon
            --to show (column.BuffId==nil -- ByPlayer mode, see
            --gridgroup.lua's Render, where a column can hold several
            --different buffs so there's no one icon for the header). ByBuff
            --mode already shows this buff's icon once at the column header
            --instead, so this never double-draws it there.
            local nameStartX = colX + cellPadding;
            if (column.BuffId == nil) and (cell.BuffId ~= nil) and (cell.BuffId > 0) then
                local rowIconSize = Layout.IconSize * cellScale;
                local icon = gTextureCache:GetTexture(string.format('STATUS:%u', cell.BuffId));
                if (icon ~= nil) then
                    if (self.IconRect == nil) then
                        self.IconRect = ffi.new('RECT', { 0, 0, 0, 0 });
                    end
                    self.IconRect.right = icon.Width;
                    self.IconRect.bottom = icon.Height;
                    vec_scale.x = rowIconSize / icon.Width;
                    vec_scale.y = rowIconSize / icon.Height;
                    vec_position.x = colX + cellPadding;
                    vec_position.y = rowY + ((rowHeight - rowIconSize) / 2);
                    sprite:Draw(icon.Texture, self.IconRect, vec_scale, nil, 0.0, vec_position, 0xFFFFFFFF);
                    nameStartX = colX + cellPadding + rowIconSize + (cellPadding / 2);
                end
            end

            if (cell.Local.NameLabel == nil) then
                cell.Local.NameLabel = gdi:create_object({ font_height = 11, font_color = 0xFFFFFFFF }, true);
            end
            local nameLabel = cell.Local.NameLabel;
            nameLabel:set_font_height(11 * cellScale);
            --RowLabel (ByPlayer mode: the buff's name, since the column
            --header already shows the player) falls back to TargetName
            --(ByBuff mode, unchanged) when nil -- see gridgroup.lua's
            --Render for which mode sets which.
            nameLabel:set_text(cell.RowLabel or cell.TargetName);
            nameLabel:set_position_x(nameStartX);
            nameLabel:set_position_y(rowY + (2 * cellScale));
            nameLabel:render(sprite);

            if (cell.Local.DurationLabel == nil) then
                cell.Local.DurationLabel = gdi:create_object({ font_height = 11, font_color = 0xFFFFFFFF, font_alignment = gdi.Alignment.Right }, true);
            end
            local durationLabel = cell.Local.DurationLabel;
            durationLabel:set_font_height(11 * cellScale);
            durationLabel:set_text(TimeToString(cell.Duration, showTenths));
            --Right alignment (font_alignment=2) anchors position_x to the
            --text's RIGHT edge -- so this needs to be the cell's right edge
            --(inset by padding), not the same left-side anchor the name
            --label uses. Using the same anchor for both was the bug that
            --put the duration immediately left of the name instead of on
            --the opposite side of the cell.
            durationLabel:set_position_x(colX + colWidth - cellPadding);
            durationLabel:set_position_y(rowY + (2 * cellScale));
            durationLabel:render(sprite);

            --Hover highlight (click-to-cast, see gridgroup.lua) -- a
            --subtle translucent overlay with a gold outline (the config
            --theme's accent color) on top of everything else in the
            --cell, drawn only for the ONE cell matching hoveredIdentity
            --(nil whenever the feature's off or nothing's hovered, so
            --this never draws unless clicking would actually do
            --something).
            if (hoveredIdentity) and (cell.ActionType == hoveredIdentity.ActionType) and (cell.ActionId == hoveredIdentity.ActionId) and (cell.TargetName == hoveredIdentity.TargetName) then
                if (not self.HoverRect) then
                    self.HoverRect = gdi:create_rect({ fill_color = 0x28FFFFFF, outline_color = 0xFFF4DA97, outline_width = 1, corner_rounding = 2 }, true);
                end
                self.HoverRect:set_width(colWidth);
                self.HoverRect:set_height(rowHeight);
                self.HoverRect:set_position_x(colX);
                self.HoverRect:set_position_y(rowY);
                self.HoverRect:render(sprite);
                hoverDrawnThisFrame = true;
            end

            self.HitBoxes:append({ CellData = cell, HitBox = CreateHitBox(colX, rowY, colWidth, rowHeight) });
            rowY = rowY + rowHeight;
        end

        tallestColumnHeight = math.max(tallestColumnHeight, rowY - colY);
        colX = colX + colWidth + (Layout.ColumnGap * scale);
        totalWidth = totalWidth + colWidth + (Layout.ColumnGap * scale);
    end

    --Panel footprint this frame, for GridGroup:GetBounds() (see
    --gridgroup.lua) -- includes the trailing ColumnGap, harmless slack for
    --a snap-distance check. Summed per-column now (widths vary) instead of
    --#columns*colStride (which assumed a uniform width).
    self.LastWidth = totalWidth;
    self.LastHeight = tallestColumnHeight;

    --Drop the cached hover rect whenever nothing was highlighted this
    --frame -- same reasoning as every other "stopped being drawn" object in
    --this project's persistent GDI overlay system (see
    --resources/renderers/alerts.lua's PruneRowLabels): just not calling
    --render() isn't enough to hide a persistent overlay object, dropping the
    --Lua reference is what actually lets it go away.
    if (not hoverDrawnThisFrame) then
        self.HoverRect = nil;
    end

    --Drop cached header objects for columns that no longer exist, so removed
    --buffs don't linger as orphaned GDI objects indefinitely.
    if (self.HeaderRects) then
        for key,_ in pairs(self.HeaderRects) do
            if not seenKeys[key] then
                self.HeaderRects[key] = nil;
                self.HeaderLabels[key] = nil;
                if (self.CostLabels) then
                    self.CostLabels[key] = nil;
                end
            end
        end
    end
end

-- (DrawTooltip below also reads gSettings.GridScale.)
function renderer:DrawTooltip(sprite, position, cellData)
    --A font object with a linked `background` sub-table, which
    --fontobject.lua auto-sizes and positions to fit whatever text is set on
    --it each frame (bgOverlap padding, its own outline) -- no manual rect
    --sizing needed on our end.
    if not self.TooltipLabel then
        self.TooltipLabel = gdi:create_object({
            font_height = 10,
            font_family = 'Consolas',
            font_color = 0xFFFFFFFF,
            background = {
                visible = true,
                corner_rounding = 3,
                outline_width = 2,
                outline_color = 0xFF000000,
                fill_color = 0xFF000000,
            },
        }, true);
    end

    local scale = gSettings.GridScale;
    local remainingText = TimeToString(cellData.Duration, true);
    local totalText = cellData.TotalDuration and TimeToString(cellData.TotalDuration, false) or '--';
    local text = string.format('%s -- %s: %s / %s', cellData.ColumnLabel, cellData.TargetName, remainingText, totalText);

    self.TooltipLabel:set_font_height(10 * scale);
    self.TooltipLabel:set_text(text);
    self.TooltipLabel:set_position_x(position.X);
    self.TooltipLabel:set_position_y(position.Y + (12 * scale));
    self.TooltipLabel:render(sprite);
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

function renderer:CellHitTest(position)
    for _,entry in ipairs(self.HitBoxes) do
        local hitBox = entry.HitBox;
        if (position.X >= hitBox.MinX) and (position.X <= hitBox.MaxX) then
            if (position.Y >= hitBox.MinY) and (position.Y <= hitBox.MaxY) then
                return entry.CellData;
            end
        end
    end
    return nil;
end

return renderer;
