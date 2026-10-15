--[[
    libs/spellcosts_data.lua

    Baked-in MP costs for Enhancing Magic spells, sourced from a
    LandSandBoat spell_list.sql dump (server-authoritative data, not
    guessed/placeholder). Only Enhancing Magic (skill=34 in that table) is
    included -- BuffTrack only tracks buff-type spells, and Enhancing is by
    far the dominant category among them; other skills (Healing, Divine,
    etc) were left out rather than pulled in wholesale for spells this
    project doesn't track anyway.

    Keyed by raw spell ID (number), not the "Spell:%u" string convention
    the rest of this project uses -- spellcosts.lua builds that key at
    lookup time so this table stays a flat, easy-to-diff list.

    NOTE: id 894 (refresh_iii) is 0 in the source data -- reproduced as-is
    rather than assumed to be an error, but flagging it since 0 MP for a
    spell is unusual; worth a second look if it turns out wrong in-game.

    To regenerate/extend this list from a newer spell_list.sql dump: filter
    rows where the `skill` column is @SKILL_ENHANCING (or literal 34), and
    take (spellid, mpCost).
]]--

return {
    [43] = 9,     --protect
    [44] = 28,    --protect_ii
    [45] = 46,    --protect_iii
    [46] = 65,    --protect_iv
    [47] = 84,    --protect_v
    [48] = 18,    --shell
    [49] = 37,    --shell_ii
    [50] = 56,    --shell_iii
    [51] = 75,    --shell_iv
    [52] = 93,    --shell_v
    [53] = 20,    --blink
    [54] = 29,    --stoneskin
    [55] = 12,    --aquaveil
    [57] = 40,    --haste
    [60] = 6,     --barfire
    [61] = 6,     --barblizzard
    [62] = 6,     --baraero
    [63] = 6,     --barstone
    [64] = 6,     --barthunder
    [65] = 6,     --barwater
    [66] = 12,    --barfira
    [67] = 12,    --barblizzara
    [68] = 12,    --baraera
    [69] = 12,    --barstonra
    [70] = 12,    --barthundra
    [71] = 12,    --barwatera
    [72] = 7,     --barsleep
    [73] = 9,     --barpoison
    [74] = 11,    --barparalyze
    [75] = 13,    --barblind
    [76] = 15,    --barsilence
    [77] = 20,    --barpetrify
    [78] = 25,    --barvirus
    [81] = 125,   --recall-jugner
    [82] = 125,   --recall-pashh
    [83] = 125,   --recall-meriph
    [84] = 30,    --baramnesia
    [85] = 60,    --baramnesra
    [86] = 14,    --barsleepra
    [87] = 18,    --barpoisonra
    [88] = 22,    --barparalyzra
    [89] = 26,    --barblindra
    [90] = 30,    --barsilencera
    [91] = 40,    --barpetra
    [92] = 50,    --barvira
    [96] = 48,    --auspice
    [97] = 24,    --reprisal
    [99] = 30,    --sandstorm
    [100] = 12,   --enfire
    [101] = 12,   --enblizzard
    [102] = 12,   --enaero
    [103] = 12,   --enstone
    [104] = 12,   --enthunder
    [105] = 12,   --enwater
    [106] = 21,   --phalanx
    [107] = 42,   --phalanx_ii
    [108] = 15,   --regen
    [109] = 40,   --refresh
    [110] = 36,   --regen_ii
    [111] = 64,   --regen_iii
    [113] = 30,   --rainstorm
    [114] = 30,   --windstorm
    [115] = 30,   --firestorm
    [116] = 30,   --hailstorm
    [117] = 30,   --thunderstorm
    [118] = 30,   --voidstorm
    [119] = 30,   --aurorastorm
    [120] = 100,  --teleport-yhoat
    [121] = 100,  --teleport-altep
    [122] = 75,   --teleport-holla
    [123] = 75,   --teleport-dem
    [124] = 75,   --teleport-mea
    [125] = 9,    --protectra
    [126] = 28,   --protectra_ii
    [127] = 46,   --protectra_iii
    [128] = 65,   --protectra_iv
    [129] = 84,   --protectra_v
    [130] = 18,   --shellra
    [131] = 37,   --shellra_ii
    [132] = 56,   --shellra_iii
    [133] = 75,   --shellra_iv
    [134] = 93,   --shellra_v
    [136] = 15,   --invisible
    [137] = 12,   --sneak
    [138] = 10,   --deodorize
    [139] = 100,  --teleport-vahzl
    [143] = 18,   --erase
    [241] = 150,  --retrace
    [249] = 8,    --blaze_spikes
    [250] = 16,   --ice_spikes
    [251] = 24,   --shock_spikes
    [261] = 100,  --warp
    [262] = 150,  --warp_ii
    [263] = 125,  --escape
    [308] = 21,   --animus_augeo
    [309] = 21,   --animus_minuo
    [312] = 24,   --enfire_ii
    [313] = 24,   --enblizzard_ii
    [314] = 24,   --enaero_ii
    [315] = 24,   --enstone_ii
    [316] = 24,   --enthunder_ii
    [317] = 24,   --enwater_ii
    [358] = 80,   --hastega
    [473] = 60,   --refresh_ii
    [476] = 18,   --crusade
    [477] = 82,   --regen_iv
    [478] = 1,    --embrava
    [479] = 36,   --boost-str
    [480] = 36,   --boost-dex
    [481] = 36,   --boost-vit
    [482] = 36,   --boost-agi
    [483] = 36,   --boost-int
    [484] = 36,   --boost-mnd
    [485] = 36,   --boost-chr
    [486] = 36,   --gain-str
    [487] = 36,   --gain-dex
    [488] = 36,   --gain-vit
    [489] = 36,   --gain-agi
    [490] = 36,   --gain-int
    [491] = 36,   --gain-mnd
    [492] = 36,   --gain-chr
    [493] = 36,   --temper
    [495] = 50,   --adloquium
    [504] = 100,  --regen_v
    [511] = 80,   --haste_ii
    [840] = 48,   --foil
    [845] = 40,   --flurry
    [846] = 80,   --flurry_ii
    [857] = 60,   --sandstorm_ii
    [858] = 60,   --rainstorm_ii
    [859] = 60,   --windstorm_ii
    [860] = 60,   --firestorm_ii
    [861] = 60,   --hailstorm_ii
    [862] = 60,   --thunderstorm_ii
    [863] = 60,   --voidstorm_ii
    [864] = 60,   --aurorastorm_ii
    [894] = 0,    --refresh_iii -- see header comment, reproduced as-is
    [895] = 72,   --temper_ii
};
