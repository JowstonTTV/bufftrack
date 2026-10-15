--[[
    Initializes BuffTrack's globals and settings.
]]--

--Initialize Globals..
chat = require('chat');
gTextureCache    = require('texturecache');
settings         = require('settings');

--[[
    Assignments(table) - Array of assignment entries.  Order is insertion
    order, which also determines column display order (columns are unique
    by ActionType+ActionId; a column's rows are further ordered by the
    order their entries appear in this array). Reorderable via
    trackers/assignment.lua's MoveAssignment (Up/Dn buttons, Buffs tab).

    Assignment entry:
        ActionType(string) - "Spell" or "Ability".
        ActionId(number)   - Spell or ability resource ID.
        BuffId(number)     - Status effect ID this assignment expects to see
                              applied.  Resolved via the duration library at
                              assignment time (see matching.lua, not yet
                              written).
        TargetName(string) - Party/alliance member name at time of
                              assignment.  Re-resolved against the live
                              party list each tick; not a stored server ID,
                              since a character's server ID isn't known
                              until they're actually seen in your
                              party/alliance/zone.
        FlashOnExpire(bool) - Per-entry: whether the post-expiry grace-window
                              cell blinks (see resources/renderers/grid.lua).
                              Defaults to true on new assignments; missing on
                              entries saved before this field existed, which
                              is treated the same as true (see
                              trackers/assignment.lua's SyncAssignments).
        Scale(number|nil)    - Per-entry cell size override. nil (the
                              default) inherits GridScale below. Set via
                              Alt-click on a cell (see gridgroup.lua's
                              HandleMouse + config.lua's Entry Editor popup).
        Color(number|nil)    - Per-entry ARGB override for the cell's
                              "healthy"/Active-state color (the Attention/
                              expiring blend toward yellow/red is unaffected).
                              nil inherits the renderer's default green.
        SoundEnabled(bool|nil) - Per-entry override for whether this cell
                              plays a sound on entering the Attention state.
                              nil inherits gSettings.GridSound.Enabled.
        SoundId(string|nil)  - Per-entry sound choice (libs/sounds.lua's
                              Available ids), nil inherits GridSound.SoundId.

    CureMap(table) - Array of curable-debuff entries (see trackers/curable.lua).
    Entry:
        StatusId(number)      - Debuff status-effect ID (see libs/bufftable.lua's
                                 statusEffects for the game's numbering).
        ActionType(string)    - Always "Spell" for now (Poisona/Cursna/Erase/etc).
        ActionId(number)      - The curing spell's resource ID.
        RequiredJob(string)   - 3-letter job abbreviation, e.g. "WHM".
        RequiredLevel(number) - Minimum job level to cast the cure.
        Enabled(bool)         - Per-entry on/off (Cures tab checkbox).
                                 Disabled entries are kept, not removed, so
                                 re-enabling doesn't require re-adding.
        Scale/Color/SoundEnabled/SoundId - Per-DEBUFF display overrides
                                 ("spell specific settings" -- e.g. Paralyze
                                 alerts are always louder than Blind alerts,
                                 for EVERY player, not just one). nil
                                 inherits CuresScale/CuresColor/CuresSound
                                 (the GLOBAL Cures tier -- see those fields
                                 below). Set via the Edit button next to
                                 each entry on the Cures config tab (see
                                 trackers/curable.lua's
                                 SetCureMapEntryOverrides) -- unlike
                                 CureOverrides below, this needs no live
                                 alert to exist first, since the entry is
                                 already sitting right there in the tab.
                                 Sits BELOW CureOverrides in the resolution
                                 order: a specific player's override (if any)
                                 wins over this debuff-wide one, which in
                                 turn wins over the global Cures tier.
        Flash(bool|nil)        - Continuous pulse while the alert row is
                                 shown (see resources/renderers/alerts.lua's
                                 DrawSection) -- distinct from Grid's
                                 FlashOnExpire, which blinks only during the
                                 post-expiry grace window; Cures/Watch alerts
                                 have no such window, they simply exist or
                                 don't. nil inherits CuresFlash (the global
                                 tier, see below). Same resolution tier as
                                 the rest of this line.
    Populated two ways: 7 direct-mapping entries (Poisona/Paralyna/Blindna/
    Silena/Stona/Viruna/Cursna) are seeded automatically the first time the
    game's spell resources are available (see trackers/curable.lua's
    SeedDefaults) -- CureMapSeeded below guards this so it only ever runs
    once and a user-removed default entry doesn't silently come back.
    Erase-based entries are opt-in only, added one at a time via the config
    UI (Erase covers many different debuffs generically -- auto-populating
    all of them would be overwhelming, per design decision).

    EnemyBuffWatchList(table) - Array of §7.2 watch-list entries (see
    trackers/dispellable.lua). User-managed only, no curated default.
    Entry:
        ActionType(string) - "Spell" or "Ability". NOTE: covers only spells
                              and player-style abilities (same action-packet
                              types/resource lookups already proven
                              elsewhere in this project) -- genuine monster
                              TP moves/weaponskills use a different
                              action-packet Type and a different resource
                              lookup that nothing here has verified yet;
                              unbuilt groundwork, not yet supported.
        ActionId(number)   - Spell or ability resource ID.
        Label(string)      - Display name, captured at add time.
        Scale/Color/SoundEnabled/SoundId/Flash - Per-watched-action display
                              overrides (no player axis exists for Watch --
                              enemies are anonymous/transient, confirmed
                              design decision -- so this is the finest
                              granularity Watch gets, same shape as Cures'
                              CureMap-level tier above, Flash included). nil
                              inherits WatchScale/default color/WatchSound/
                              false. Set via the Edit button on the Watch
                              config tab (see trackers/dispellable.lua's
                              SetWatchEntryOverrides).

    CureOverrides(table) - Array of per-(player,debuff) display overrides
    for §7.1 alerts (see trackers/curable.lua). Unlike CureMap (which is
    per-DEBUFF -- "what cures Paralyze, for everyone"), this is per-
    (player,debuff) pair -- "MY TANK's Paralyze specifically should be an
    alarm, everyone else's a normal notice". Set via Alt-click on a live
    Cures alert row (see the Cures panel's HandleMouse + config.lua's Entry
    Editor) -- including a Preview Alerts row (config.lua's Behavior tab),
    which now covers every roster member x every CureMap entry precisely so
    this doesn't require waiting for a real debuff to land first. An entry
    only exists here while at least one of its four fields is non-nil --
    SetCureOverride deletes the entry entirely once all four go back to
    nil, rather than leaving an inert all-nil row behind. Three-tier
    resolution order, same for Scale/Color/Sound/Flash: this (if present)
    beats the CureMap-level override, which beats the global Cures* tier
    (CuresScale/CuresColor/CuresSound/CuresFlash) below.
    Entry:
        TargetName(string)     - Same re-resolved-live convention as
                                  Assignments[i].TargetName.
        StatusId(number)       - Debuff status-effect ID (same numbering as
                                  CureMap[i].StatusId).
        Scale(number|nil)      - nil inherits CureMap[i].Scale, then CuresScale.
        Color(number|nil)      - nil inherits CureMap[i].Color, then
                                  CuresColor, then the alerts renderer's
                                  hardcoded default (white) if THAT is also nil.
        SoundEnabled(bool|nil) - nil inherits CureMap[i].SoundEnabled, then
                                  gSettings.CuresSound.Enabled.
        SoundId(string|nil)    - nil inherits CureMap[i].SoundId, then
                                  CuresSound.SoundId.
        Flash(bool|nil)        - nil inherits CureMap[i].Flash, then CuresFlash.

    CuresPosition/WatchPosition(table) - Top-left of the Cures panel (§7.1
    alerts) and the Watch panel (§7.2 alerts) respectively -- two
    INDEPENDENT panels as of this settings generation (previously one
    shared "Alerts panel" holding both sections stacked -- split apart so
    each can be positioned, scaled, and configured on its own). Migrated
    from the old shared AlertsPosition below.

    PlayerPriority(table) - Name -> number, higher sorts first. Purely
    per-player, no party-subgroup concept at all (explicit decision -- you
    can't target another alliance group's members with cures anyway, so
    grouping by party subgroup was never meaningful here). Used to sort
    the Cures panel's alert rows (see trackers/curable.lua's Tick) so a
    given player's rows cluster together in a stable, predictable order
    even without any per-(player,debuff) override set up for them --
    "Highland always sorts near the top" without needing a CureOverrides
    entry for every debuff they might get hit with. Missing/unset = 0.
    Set via the Party tab (config.lua's DrawPartyTab).
]]--
local baseX = 0;
local baseY = 250;

gDefaultSettings = T{
    Assignments = T{
        --Empty by default; populated via /bufftrack.
    },
    CureMap = T{
        --Empty by default; see trackers/curable.lua's SeedDefaults -- filled
        --in with the 7 direct-mapping cures the first time it can resolve
        --spell resources, then left alone (see CureMapSeeded).
    },
    CureMapSeeded = false,
    EnemyBuffWatchList = T{
        --Empty by default; user-managed via /bufftrack watch, no curated
        --default (see trackers/dispellable.lua).
    },
    CureOverrides = T{
        --Empty by default; see trackers/curable.lua's SetCureOverride.
    },
    Position = T{ X=baseX, Y=baseY },
    CuresPosition = T{ X=baseX, Y=baseY + 150 },
    WatchPosition = T{ X=baseX, Y=baseY + 250 },
    --Per-player panel positions for GridGroupBy='Player' (see
    --gridgroup.lua's NewPlayerPanel/SyncPlayerPanels), keyed by player
    --name (same re-resolved-live convention as Assignments[i].TargetName --
    --not a stored server ID). Empty by default; a panel gets its starting
    --position auto-generated (staggered from the main Grid panel) the
    --first time that player is seen, then remembers wherever it's dragged
    --to from there.
    PlayerPositions = {},
    --Name -> number, higher sorts first (see doc comment above). Empty by
    --default; missing entry treated as priority 0.
    PlayerPriority = {},
    --Per-tracker draw scale, replacing the old single `Scale` field (see
    --migration below). Grid = trackers/assignment.lua's panel; Cures/Watch
    --= the now-independent Cures/Watch panels. Further per-entry overrides
    --exist on top of these three (see Assignments/CureMap/
    --EnemyBuffWatchList/CureOverrides above) -- nil at any override tier
    --means "inherit the next tier down".
    GridScale = 1,
    CuresScale = 1,
    WatchScale = 1,
    Enabled = true,
    UseTooltips = true,
    HideWithPrimitives = true,
    ShowTenths = true,
    --Snap-to-align between ANY two of the three panels (Grid/Cures/Watch --
    --see panelbase.lua's gPanels registry, which every panel using it
    --registers into regardless of how many panels end up existing).
    --Checked only on drag release, not live during the drag.
    SnapEnabled = false,
    SnapDistance = 12,
    --When false (default), a panel with zero active rows draws nothing at
    --all (see resources/renderers/alerts.lua's DrawSection). When true,
    --it still draws its header ("Cures Available (0)") as a running-
    --confirmation display. Split into two independent flags now that
    --Cures/Watch are separate panels -- migrated from the old shared
    --ShowEmptySections below.
    CuresShowEmpty = false,
    WatchShowEmpty = false,
    --Cures panel display aids (Cures config tab), both off by default --
    --additive on top of the already-working plain list, not a replacement
    --for it. GroupDivider draws a thin rule wherever TargetName changes
    --between consecutive rows (see resources/renderers/alerts.lua's
    --DrawSection) -- cheap alternative to a full sub-header-per-target
    --layout, since Tick() already sorts rows by player so same-target rows
    --are adjacent regardless of this being on. ShowJobIcon draws each
    --row's job icon (uiskin:GetJobIcon, same source the Party tab uses)
    --before the text. Deliberately Cures-only -- Watch's alerts don't have
    --a stable per-row "owner" the same way (enemies are anonymous/
    --transient), so grouping-by-target doesn't apply there.
    CuresGroupDivider = false,
    CuresShowJobIcon = false,
    --Global (outermost) tier for Cures display -- the FIRST layer applied,
    --overridden by CureMap-level (per-spell) which is in turn overridden by
    --CureOverrides (per-player-per-spell); see those two entries' doc
    --comments above for the full three-tier chain. CuresScale/CuresSound
    --already served as this tier implicitly; CuresColor/CuresFlash fill the
    --matching gap for Color/Flash, which previously had no user-
    --configurable global and fell straight through to the renderer's
    --hardcoded default (white, no pulse) once no override existed at any
    --tier. CuresColor nil = that hardcoded renderer default; CuresFlash
    --false = no pulse, same off-by-default reasoning as every other Flash
    --field in this project.
    CuresColor = nil,
    CuresFlash = false,

    --Three-state coloring thresholds, both in seconds.  See reference sheet
    --section 1: Active -> Attention -> Not Active.
    AttentionThreshold = 15,  --Placeholder default; not finalized, see open items.
    AttentionGrace = 10,
    --Per-tracker audio cues (SoundId keys into libs/sounds.lua's
    --Available list). Enabled defaults to false across the board -- audio
    --is opt-in, not a surprise the first time someone updates. AlarmVolume
    --is 0-100, shared across every sound this addon plays (mirrors Eggs'
    --own alarm_volume convention, which libs/sounds.lua is ported from).
    GridSound = { Enabled = false, SoundId = 'chime' },
    CuresSound = { Enabled = false, SoundId = 'bell' },
    WatchSound = { Enabled = false, SoundId = 'alarm' },
    AlarmVolume = 100,
    --Layout fork point: 'Buff' (default) = one Grid panel, columns=buffs,
    --rows=players. 'Player' = one panel PER PLAYER (see gridgroup.lua's
    --NewPlayerPanel/SyncPlayerPanels), each showing just their own
    --tracked buffs as rows, positioned independently (PlayerPositions
    --above) and free to snap-align against each other or the Cures/Watch
    --panels like anything else in gPanels. Both modes share the same
    --GridScale/GridColors/GridSound tracker-level defaults -- per
    --explicit decision, ByPlayer doesn't get its own separate scale/sound
    --settings, only the existing per-entry overrides (Assignments[i].
    --Scale/etc, Alt-click) carry the "this one matters more" signal in
    --either mode.
    GridGroupBy = 'Buff',
    --Which resources/jobs/<style>/<abbr>.png set to pull job icons from.
    JobIconStyle = 'FFXI',
    --Click-to-cast (gridgroup.lua's HandleMouse/TryClickCast) -- off by
    --default, per explicit decision (unlike every other toggle in this
    --project, a misclick here has a real consequence -- an actual cast --
    --not just a cosmetic change). Sends `/ma "<spell>" <target>` via
    --AshitaCore:GetChatManager():QueueCommand -- the game's own sanctioned
    --command pathway, same as typing the command or clicking a macro, NOT
    --a raw outgoing packet (explicitly confirmed as the one acceptable
    --way for this project to trigger an action, distinct from the
    --fabricated-packet approach already ruled out and removed elsewhere
    --in this project -- see durations/data.lua's header comment).
    GridClickToCast = false,
};
gSettings = settings.load(gDefaultSettings:copy(true));

--One-time migration: the old single `Scale` field (removed from
--gDefaultSettings above) becomes the seed value for all three new
--per-tracker scale fields, then is dropped. Guarded the same way
--CureMapSeeded guards its own one-time seed -- only runs while a loaded
--settings file still has the old field.
if (gSettings.Scale ~= nil) then
    gSettings.GridScale = gSettings.Scale;
    gSettings.CuresScale = gSettings.Scale;
    gSettings.WatchScale = gSettings.Scale;
    gSettings.Scale = nil;
    settings.save();
end

--One-time migration: the old shared AlertsPosition/ShowEmptySections
--(Cures and Watch used to be two sections of one panel) seed the two new
--independent fields, then are dropped, same guard pattern as above.
if (gSettings.AlertsPosition ~= nil) then
    gSettings.CuresPosition = T{ X = gSettings.AlertsPosition.X, Y = gSettings.AlertsPosition.Y };
    gSettings.WatchPosition = T{ X = gSettings.AlertsPosition.X, Y = gSettings.AlertsPosition.Y + 100 };
    gSettings.AlertsPosition = nil;
    settings.save();
end
if (gSettings.ShowEmptySections ~= nil) then
    gSettings.CuresShowEmpty = gSettings.ShowEmptySections;
    gSettings.WatchShowEmpty = gSettings.ShowEmptySections;
    gSettings.ShowEmptySections = nil;
    settings.save();
end

--Initialize the grid panel..
local group = require('gridgroup');
gPanel = group:New(gSettings);

--Initialize the §7.1 (Cures) and §7.2 (Watch) alert panels -- now two
--independent panelbase.lua-based panels (see alertsgroup.lua's
--NewCuresPanel/NewWatchPanel) instead of one shared panel with two
--stacked sections.
local alertsGroup = require('alertsgroup');
gCuresPanel = alertsGroup.NewCuresPanel(gSettings);
gWatchPanel = alertsGroup.NewWatchPanel(gSettings);

--Initialize audio cues (see libs/sounds.lua) -- resolves resources/Sounds/
--file paths and stands up DirectSound (falling back to
--ashita.misc.play_sound if that fails) once at load, rather than lazily on
--first Play call, so any "Sound missing"/DirectSound-unavailable warnings
--surface immediately instead of at a random moment mid-session. gSounds is
--global (same convention as gTextureCache) since every tracker that fires
--a cue needs it (trackers/assignment.lua, trackers/curable.lua,
--trackers/dispellable.lua).
gSounds = require('libs.sounds');
gSounds:Initialize();

--Register callback so character change updates the panel..
local function UpdateSettings(newSettings)
    gSettings = newSettings;
    gPanel:UpdateSettings(gSettings, true);
    group.ResetPlayerPanels();
    gCuresPanel:UpdateSettings(gSettings);
    gWatchPanel:UpdateSettings(gSettings);
end
settings.register('settings', 'settings_update', UpdateSettings);
