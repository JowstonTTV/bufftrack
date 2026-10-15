--[[
    spellcosts.lua

    MP-cost lookup for tracked buffs, shown in the grid header next to each
    buff's icon/name. This is a BuffTrack-specific feature -- tTimers'
    duration library has no cost data at all.

    Baked-in now (libs/spellcosts_data.lua, sourced from a LandSandBoat
    spell_list.sql dump), NOT user-editable -- previously backed by
    gSettings.Costs with a config UI Costs tab for manual entry, removed in
    favor of this once real server data was available. Only Enhancing
    Magic is covered (see spellcosts_data.lua's header) -- a buff outside
    that set (a non-Enhancing spell, or an Ability) has no cost data and
    GetCost returns nil, same "nil means show a placeholder" contract as
    before.
]]--

local costData = require('libs.spellcosts_data');

local exports = {};

--Returns a number, or nil if this buff has no baked cost (non-Enhancing
--spell, an Ability, or genuinely just not in the source data) -- callers
--should show a placeholder ("--") rather than treat nil as zero.
function exports:GetCost(actionType, actionId)
    if (actionType ~= 'Spell') then
        return nil;
    end
    return costData[actionId];
end

return exports;
