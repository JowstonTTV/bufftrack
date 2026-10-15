--[[
    panelbase.lua

    Shared drag/position/snap/bounds skeleton for every draggable panel in
    this addon (GridGroup, AlertsGroup, and eventually one per player-
    grouped window -- see the GridGroupBy='Player' stretch goal). Extracted
    after GridGroup and AlertsGroup had grown the exact same Position/
    AllowDrag/DragActive/DragPosition/GetBounds skeleton independently --
    pulled out now, before a third (and eventually Nth, for per-player
    windows) copy gets hand-duplicated.

    Every panel using this base registers itself into the global gPanels
    array at construction (see PanelBase.Init) so snap-to-align (see
    HandleDrag below) can check against every OTHER currently-registered
    panel, not one hardcoded named partner -- this is what lets snapping
    scale past exactly two panels once per-player windows exist.

    Usage: a concrete panel module (e.g. gridgroup.lua) does:
        local PanelBase = require('panelbase');
        local GridGroup = setmetatable({}, { __index = PanelBase });
        GridGroup.__index = GridGroup;

        function GridGroup:New(...)
            local o = setmetatable({}, GridGroup);
            PanelBase.Init(o, initialPosition, rendererInstance);
            ... subtype-specific setup ...
            return o;
        end

        function GridGroup:CommitPosition()
            gSettings.Position.X = self.Position.X;
            gSettings.Position.Y = self.Position.Y;
            settings.save();
        end

    A concrete panel MUST implement:
        self:CommitPosition() - writes self.Position back into gSettings
                              (wherever THIS panel's position lives -- a
                              fixed field for Grid/Alerts today, a
                              PlayerName-keyed table entry for per-player
                              windows later) and calls settings.save().
    A concrete panel's Renderer (passed to PanelBase.Init, stored as
    self.Renderer) MUST implement:
        :DragHitTest(position) -> boolean
        :DrawDragHandle(sprite, position)
    and MAY set .LastWidth/.LastHeight (read by GetBounds below; falls back
    to self.DefaultWidth/self.DefaultHeight, then 200/40, if unset).
]]--

local PanelBase = {};

--Every currently-registered panel, for snap-to-align (see HandleDrag) to
--check bounds against. Global (not module-local) since every
--panelbase.lua-based module shares one registry regardless of which file
--required panelbase.lua first.
gPanels = gPanels or {};

--Called by a concrete panel's own New(), AFTER setmetatable'ing the new
--instance onto the caller's class table (Init only populates fields, it
--doesn't set up inheritance itself -- see the Usage example above).
function PanelBase.Init(instance, initialPosition, renderer)
    instance.AllowDrag = false;
    instance.DragActive = false;
    instance.DragPosition = { 0, 0 };
    instance.Mouse = { X = -1, Y = -1 };
    instance.Position = { X = initialPosition.X, Y = initialPosition.Y };
    instance.Renderer = renderer;
    gPanels[#gPanels + 1] = instance;
    return instance;
end

--Removes a panel from gPanels. GridGroup/AlertsGroup never call this today
--(both live for the addon's whole session) -- the seam exists now rather
--than being retrofitted later, for when a per-player window needs to be
--torn down (that player left the roster).
function PanelBase:Unregister()
    for i,panel in ipairs(gPanels) do
        if (panel == self) then
            table.remove(gPanels, i);
            return;
        end
    end
end

--Current on-screen extent. Every panel previously duplicated this exact
--function under its own renderer field name (GridRenderer/AlertsRenderer
--specifically) -- self.Renderer is the one generic name every panel using
--this base now stores its renderer instance under, so this single
--implementation covers all of them.
function PanelBase:GetBounds()
    return {
        X = self.Position.X,
        Y = self.Position.Y,
        Width = self.Renderer.LastWidth or self.DefaultWidth or 200,
        Height = self.Renderer.LastHeight or self.DefaultHeight or 40,
    };
end

--Generic drag lifecycle: press-on-handle starts a drag, move updates
--Position live, release snaps (against every OTHER registered panel, if
--gSettings.SnapEnabled) then calls self:CommitPosition() -- see that
--method's required contract above. Returns true if this call consumed the
--mouse event, in which case the caller's own HandleMouse should stop
--(`if self:HandleDrag(e) then return; end`), matching the inline early
--`return`s GridGroup/AlertsGroup each used to have here individually.
function PanelBase:HandleDrag(e)
    if self.DragActive then
        self.Position.X = self.Position.X + (e.x - self.DragPosition[1]);
        self.Position.Y = self.Position.Y + (e.y - self.DragPosition[2]);
        self.DragPosition[1] = e.x;
        self.DragPosition[2] = e.y;
        if (e.message == 514) or (not self.AllowDrag) then
            self.DragActive = false;
            if (gSettings.SnapEnabled) then
                --Checked against EVERY other registered panel in turn,
                --re-fetching bounds each iteration so an earlier snap (say,
                --against panel A) is what a later check (against panel B)
                --actually snaps relative to, rather than each check running
                --independently off the pre-drag position and only the last
                --one winning outright. With exactly two panels (today's
                --Grid+Alerts case) this is identical to the old hardcoded
                --single-partner check; it only starts to matter once a
                --third-plus panel exists.
                for _,other in ipairs(gPanels) do
                    if (other ~= self) then
                        local snapX, snapY = SnapPosition(self:GetBounds(), other:GetBounds(), gSettings.SnapDistance);
                        self.Position.X = snapX;
                        self.Position.Y = snapY;
                    end
                end
            end
            self:CommitPosition();
        end
        return true;
    elseif (self.AllowDrag) and (e.message == 513) and self.Renderer:DragHitTest({X=e.x, Y=e.y}) then
        self.DragActive = true;
        self.DragPosition[1] = e.x;
        self.DragPosition[2] = e.y;
        self.MouseBlocked = true;
        e.blocked = true;
        return true;
    end
    return false;
end

--Common tail every HandleMouse ends with -- consumes the mouse-up event if
--an earlier click on THIS panel (Alt/Ctrl/Shift-click, or a drag-handle
--press) set MouseBlocked, so it doesn't also register as a click-through
--to the game world underneath.
function PanelBase:HandleMouseBlockedRelease(e)
    if (e.message == 514) and (self.MouseBlocked) then
        e.blocked = true;
        self.MouseBlocked = nil;
    end
end

return PanelBase;
