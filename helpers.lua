--[[
    helpers.lua

    General-purpose helpers required at bootstrap (bufftrack.lua) --
    Error/Message chat output, resource-file path resolution, and
    SnapPosition (panel snap-to-align, see below).
]]--

local chat = require('chat');

function Error(text)
    local stripped = string.gsub(text, '$H', ''):gsub('$R', '');
    LogManager:Log(1, addon.name, stripped);
    local color = ('\30%c'):format(68);
    local highlighted = color .. string.gsub(text, '$H', '\30\01\30\02');
    highlighted = string.gsub(highlighted, '$R', '\30\01' .. color);
    print(chat.header(addon.name) .. highlighted .. '\30\01');
end

function GetFilePath(path)
    local potentialPaths = T{
        path,
        string.format('%sconfig/addons/%s/resources/%s', AshitaCore:GetInstallPath(), addon.name, path),
        string.format('%saddons/%s/resources/%s', AshitaCore:GetInstallPath(), addon.name, path),
    };

    for _,potentialPath in ipairs(potentialPaths) do
        if (potentialPath ~= '') and (ashita.fs.exists(potentialPath)) then
            return potentialPath;
        end
    end
end

function GetImagePath(image, default)
    if (string.sub(image, 1, 5) == 'ITEM:') then
        return image;
    end
    
    if (string.sub(image, 1, 7) == 'STATUS:') then
        return image;
    end
    
    local potentialPaths = T{
        image,
        string.format('%sconfig/addons/%s/resources/%s', AshitaCore:GetInstallPath(), addon.name, image),
        string.format('%saddons/%s/resources/%s', AshitaCore:GetInstallPath(), addon.name, image),
    };

    for _,path in ipairs(potentialPaths) do
        if (path ~= '') and (ashita.fs.exists(path)) then
            return path;
        end
    end

    return nil;
end

function Message(text)
    local stripped = string.gsub(text, '$H', ''):gsub('$R', '');
    LogManager:Log(5, addon.name, stripped);
    local color = ('\30%c'):format(106);
    local highlighted = color .. string.gsub(text, '$H', '\30\01\30\02');
    highlighted = string.gsub(highlighted, '$R', '\30\01' .. color);
    print(chat.header(addon.name) .. highlighted .. '\30\01');
end

function LoadFile_s(filePath)
    if (filePath == nil) then
        return nil;
    end
    
    if not ashita.fs.exists(filePath) then
        return nil;
    end

    local success, loadError = loadfile(filePath);
    if not success then
        Error(string.format('Failed to load resource file: $H%s', filePath));
        if type(loadError) == 'string' then
            Error(loadError);
        end
        return nil;
    end

    local result, output = pcall(success);
    if not result then
        Error(string.format('Failed to execute resource file: $H%s', filePath));
        if type(output) == 'string' then
            Error(output);
        end
        return nil;
    end

    return output;
end

--[[
    Snaps a moving panel's top-left position to the edges of another
    panel's bounds, when the gap between them is within `distance` pixels.
    Checks X and Y independently -- either, both, or neither axis may snap
    on a given call. Snap candidates per axis: aligned edges (left-to-left,
    right-to-right) and adjacency (left-to-right, right-to-left), same
    convention as OS-level window snapping. Shared by GridGroup and
    AlertsGroup (see gridgroup.lua/alertsgroup.lua's HandleMouse) rather
    than duplicated, since both need the identical check just against each
    other's bounds.

    myBounds/otherBounds(table) - { X, Y, Width, Height }, top-left + size.
    distance(number)            - max gap, in screen pixels, still "close".

    Returns the (possibly adjusted) X, Y for myBounds' top-left.
]]--
function SnapPosition(myBounds, otherBounds, distance)
    local x, y = myBounds.X, myBounds.Y;
    local myRight, myBottom = myBounds.X + myBounds.Width, myBounds.Y + myBounds.Height;
    local otherRight, otherBottom = otherBounds.X + otherBounds.Width, otherBounds.Y + otherBounds.Height;

    if (math.abs(myBounds.X - otherBounds.X) <= distance) then
        x = otherBounds.X;
    elseif (math.abs(myRight - otherBounds.X) <= distance) then
        x = otherBounds.X - myBounds.Width;
    elseif (math.abs(myBounds.X - otherRight) <= distance) then
        x = otherRight;
    elseif (math.abs(myRight - otherRight) <= distance) then
        x = otherRight - myBounds.Width;
    end

    if (math.abs(myBounds.Y - otherBounds.Y) <= distance) then
        y = otherBounds.Y;
    elseif (math.abs(myBottom - otherBounds.Y) <= distance) then
        y = otherBounds.Y - myBounds.Height;
    elseif (math.abs(myBounds.Y - otherBottom) <= distance) then
        y = otherBottom;
    elseif (math.abs(myBottom - otherBottom) <= distance) then
        y = otherBottom - myBounds.Height;
    end

    return x, y;
end