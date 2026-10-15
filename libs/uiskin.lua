--[[
    libs/uiskin.lua

    Config window theme -- dark background with a warm gold accent,
    mirrored directly from XIUI's config.lua PushThemeStyles/PopThemeStyles
    (same palette, same ImGuiCol_*/ImGuiStyleVar_* set, same push/pop
    counts) rather than reinvented, per explicit instruction to match that
    look. Layout is NOT copied, only the color theme.

    This replaces an earlier, abandoned attempt at a custom PNG background
    (stretched fill + 4-piece frame overlay via draw_list:AddImage) -- that
    technique worked mechanically (confirmed working: background rendered),
    but the frame art didn't align with the actual widget layout and was
    dropped in favor of this pure color-theme approach instead. Job icon
    lookup (GetJobIcon/DrawInlineIcon) is unrelated to that abandoned
    background work and is kept -- still needed for the party-centric
    picker.
]]--

local exports = {};
local imgui = require('imgui');
local ffi = require('ffi');

--Palette -- identical values to XIUI's own (see header comment for why:
--explicit "just mirror this" instruction, not a reinterpretation).
local gold = { 0.957, 0.855, 0.592, 1.0 };           --#F4DA97 primary accent
local goldDark = { 0.765, 0.684, 0.474, 1.0 };       --#C3AE79 darker gold, hover
local goldDarker = { 0.573, 0.512, 0.355, 1.0 };     --#92835B even darker gold
local bgDark = { 0.051, 0.051, 0.051, 0.95 };        --#0D0D0D deep black background
local bgMedium = { 0.098, 0.090, 0.075, 1.0 };       --#191713 slightly warm dark
local bgLight = { 0.137, 0.125, 0.106, 1.0 };        --#23201B lighter warm dark
local bgLighter = { 0.176, 0.161, 0.137, 1.0 };      --#2D2923 highlight dark
local textLight = { 0.878, 0.855, 0.812, 1.0 };      --#E0DACF warm off-white text
local borderDark = { 0.3, 0.275, 0.235, 1.0 };       --#4D463C warm dark border

local tabActiveColor = { gold[1], gold[2], gold[3], 0.3 };
local headerActiveColor = { gold[1], gold[2], gold[3], 0.3 };

--Exposed so config.lua can reuse the exact accent color for
--imgui.TextColored(...) section headers, rather than keeping its own
--separate hardcoded orange -- one source of truth for "the accent color".
exports.HeaderColor = gold;
exports.TextColor = textLight;

--Every available job icon style (resources/jobs/<style>/<abbr>.png sets).
--Used by config.lua's Behavior tab picker -- dropped by accident when
--this file was rewritten from the background-image version to the
--pure-theme version (everything else in that rewrite was intentional;
--this one just got left out), which crashed the Behavior tab's Job Icon
--Style combo the moment it tried to iterate a nil list.
exports.JobIconStyles = { 'Classic', 'FFXI', 'FFXIV-1' };

--Running counts of how many pushes ACTUALLY succeeded this call to
--PushTheme -- PopTheme pops exactly these counts, never a hardcoded
--number, so a partial failure (some colors/vars push fine, others don't)
--can never leave ImGui's style stack unbalanced. Module-level, not
--per-call-local, since PopTheme needs to read what PushTheme last wrote.
local pushedColorCount = 0;
local pushedVarCount = 0;

--Safe wrapper around a single PushStyleColor/PushStyleVar call -- the
--first reported crash was an UNWRAPPED call throwing straight out of
--PushTheme and unloading the whole addon; this can't happen again
--regardless of which specific enum/value turns out to be the problem.
--Prints the real error text ONCE PER DISTINCT LABEL (not once total) --
--the first version only ever reported the very first failure, so if
--several different pushes were failing for different reasons, only one
--was ever visible; this way each distinct failing push gets its own
--report, still capped so a systemic failure (e.g. every single push
--rejected) can't spam the chat log once per push every frame.
local warnedLabels = {};
local function TryPush(label, fn, a, b)
    local ok, err = pcall(fn, a, b);
    if (not ok) and (not warnedLabels[label]) then
        warnedLabels[label] = true;
        Error(string.format('BuffTrack: theme push failed for %s (%s) -- that element will use its default ImGui color/value instead of the theme.', label, tostring(err)));
    end
    return ok;
end

--Pushes the full theme -- MUST be paired with a PopTheme() call, always,
--even on an early-out path (same always-call-End() reasoning used
--elsewhere in this project for imgui.End()). Call this BEFORE
--SetNextWindowSize/Begin, same order XIUI's own DrawProfilesWindow/
--config window does it in.
function exports:PushTheme()
    pushedColorCount = 0;
    pushedVarCount = 0;

    --NOTE: ChildBg/FrameBg*/Header* are DELIBERATELY not themed. First
    --test of this theme broke the Buffs tab's spell list (list not
    --rendering, typing in the filter box doing nothing) -- those three
    --groups are exactly what Selectable (Header/HeaderHovered/
    --HeaderActive), InputText (FrameBg/FrameBgHovered/FrameBgActive), and
    --BeginChild (ChildBg, previously pushed fully transparent -- an
    --unusual value that could misbehave in a less-common binding's
    --scroll/clip handling) actually use, and the Buffs tab's list is built
    --from exactly those three widgets. Left at ImGui's own defaults rather
    --than guessed at a second time; everything else (window/tab/border/
    --text/button colors) keeps the theme.
    local colors = {
        { 'WindowBg', ImGuiCol_WindowBg, bgDark },
        { 'TitleBg', ImGuiCol_TitleBg, bgMedium }, { 'TitleBgActive', ImGuiCol_TitleBgActive, bgLight },
        { 'TitleBgCollapsed', ImGuiCol_TitleBgCollapsed, bgDark },
        { 'Border', ImGuiCol_Border, borderDark },
        { 'Text', ImGuiCol_Text, textLight }, { 'TextDisabled', ImGuiCol_TextDisabled, goldDark },
        { 'Button', ImGuiCol_Button, bgMedium }, { 'ButtonHovered', ImGuiCol_ButtonHovered, bgLight },
        { 'ButtonActive', ImGuiCol_ButtonActive, bgLighter }, { 'CheckMark', ImGuiCol_CheckMark, gold },
        { 'SliderGrab', ImGuiCol_SliderGrab, goldDark }, { 'SliderGrabActive', ImGuiCol_SliderGrabActive, gold },
        { 'ScrollbarBg', ImGuiCol_ScrollbarBg, bgMedium }, { 'ScrollbarGrab', ImGuiCol_ScrollbarGrab, bgLighter },
        { 'ScrollbarGrabHovered', ImGuiCol_ScrollbarGrabHovered, borderDark }, { 'ScrollbarGrabActive', ImGuiCol_ScrollbarGrabActive, goldDark },
        { 'Separator', ImGuiCol_Separator, borderDark }, { 'PopupBg', ImGuiCol_PopupBg, bgMedium },
        { 'Tab', ImGuiCol_Tab, bgMedium }, { 'TabHovered', ImGuiCol_TabHovered, bgLight },
        --Renamed in Dear ImGui v1.90.9 (TabActive->TabSelected,
        --TabUnfocused->TabDimmed, TabUnfocusedActive->TabDimmedSelected) --
        --confirmed via the official release notes, not a guess: these were
        --the exact 3 (and only 3) pushes that failed under the old names,
        --every other color succeeded on the first try.
        { 'TabSelected', ImGuiCol_TabSelected, tabActiveColor }, { 'TabDimmed', ImGuiCol_TabDimmed, bgDark },
        { 'TabDimmedSelected', ImGuiCol_TabDimmedSelected, bgMedium }, { 'ResizeGrip', ImGuiCol_ResizeGrip, goldDarker },
        { 'ResizeGripHovered', ImGuiCol_ResizeGripHovered, goldDark }, { 'ResizeGripActive', ImGuiCol_ResizeGripActive, gold },
    };
    for _,c in ipairs(colors) do
        if (TryPush('Color:' .. c[1], imgui.PushStyleColor, c[2], c[3])) then
            pushedColorCount = pushedColorCount + 1;
        end
    end

    local vars = {
        { 'WindowPadding', ImGuiStyleVar_WindowPadding, { 12, 12 } }, { 'FramePadding', ImGuiStyleVar_FramePadding, { 6, 4 } },
        { 'ItemSpacing', ImGuiStyleVar_ItemSpacing, { 8, 6 } }, { 'FrameRounding', ImGuiStyleVar_FrameRounding, 4.0 },
        { 'WindowRounding', ImGuiStyleVar_WindowRounding, 6.0 }, { 'ChildRounding', ImGuiStyleVar_ChildRounding, 4.0 },
        { 'PopupRounding', ImGuiStyleVar_PopupRounding, 4.0 }, { 'ScrollbarRounding', ImGuiStyleVar_ScrollbarRounding, 4.0 },
        { 'GrabRounding', ImGuiStyleVar_GrabRounding, 4.0 },
    };
    for _,v in ipairs(vars) do
        if (TryPush('Var:' .. v[1], imgui.PushStyleVar, v[2], v[3])) then
            pushedVarCount = pushedVarCount + 1;
        end
    end
end

--Pops EXACTLY as many as PushTheme actually pushed this time -- never a
--hardcoded count -- so a partial push failure can't unbalance ImGui's
--style stack (which a mismatched Pop count would, likely surfacing as an
--even more confusing downstream error later in the same session).
function exports:PopTheme()
    if (pushedVarCount > 0) then
        imgui.PopStyleVar(pushedVarCount);
    end
    if (pushedColorCount > 0) then
        imgui.PopStyleColor(pushedColorCount);
    end
end

--Texture loads are cached by gTextureCache itself (keyed by path); this is
--just a safe wrapper so a missing file degrades to "draw nothing" rather
--than erroring.
local function LoadTexture(path)
    local ok, texture = pcall(function() return gTextureCache:GetTexture(path); end);
    if (ok) then
        return texture;
    end
    return nil;
end

--Converts a raw D3D texture handle into the numeric texture id
--draw_list:AddImage expects -- confirmed technique, sourced from a real
--working reference addon (see DrawInlineIcon's comment).
local function ToTextureId(textureHandle)
    if (textureHandle == nil) then
        return nil;
    end
    local ok, id = pcall(function() return tonumber(ffi.cast('uint32_t', textureHandle)); end);
    if (ok) then
        return id;
    end
    return nil;
end

--Job icon for the current gSettings.JobIconStyle (or an explicit override,
--for a style picker's own preview). jobAbbr is the 3-letter code (e.g.
--'WAR') -- files are lowercase (resources/jobs/<style>/war.png etc), so
--this lowercases for the lookup. Returns nil if the job/style/file
--doesn't resolve to anything -- callers should skip drawing an icon
--rather than treat nil as an error.
function exports:GetJobIcon(jobAbbr, styleOverride)
    if (jobAbbr == nil) then
        return nil;
    end
    local style = styleOverride or gSettings.JobIconStyle or 'FFXI';
    return LoadTexture(string.format('jobs/%s/%s.png', style, string.lower(jobAbbr)));
end

--Draws an arbitrary loaded texture inline in normal ImGui widget flow --
--e.g. `imgui.SameLine(); uiskin:DrawInlineIcon(tex, 32, 32);`. Uses
--draw_list:AddImage (a pure draw primitive, absolute screen coordinates,
--confirmed working via a real reference addon -- see this file's header
--comment) rather than imgui.Image (which turned out to be the wrong
--function entirely during the abandoned background-art attempt: wrong
--arg count, wrong texture-id format, and it silently misbehaves with
--ImGui's layout cursor in a way AddImage doesn't). Manually advances the
--layout cursor afterward (via a same-sized Dummy) so subsequent
--SameLine()/normal layout calls behave as if a regular widget had been
--drawn, since AddImage itself never touches layout on its own.
function exports:DrawInlineIcon(texture, width, height)
    if (texture == nil) then
        return;
    end
    local id = ToTextureId(texture);
    if (id == nil) then
        return;
    end
    local ok, screenX, screenY = pcall(imgui.GetCursorScreenPos);
    if (not ok) or (type(screenX) ~= 'number') then
        return;
    end
    pcall(function()
        local draw_list = imgui.GetWindowDrawList();
        draw_list:AddImage(id, { screenX, screenY }, { screenX + width, screenY + height }, { 0, 0 }, { 1, 1 }, IM_COL32_WHITE);
    end);
    pcall(imgui.Dummy, { width, height });
end

return exports;
