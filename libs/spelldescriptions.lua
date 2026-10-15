--[[
    libs/spelldescriptions.lua

    Placeholder-friendly description text for the Buffs tab's detail pane.
    Empty on purpose -- config.lua falls back to a generic placeholder for
    anything not listed here. Filled in incrementally over time (wiki text,
    hand-written, whatever's convenient), keyed by "ActionType:ActionId"
    (same key convention as spellcosts.lua).

    Example once populated:
        ['Spell:33'] = 'Hastens the casting and recovery time of the target.', --Haste
]]--

local exports = T{
};

return exports;
