addon.name      = 'BuffTrack';
addon.author    = 'Jowston + Claude';
addon.version   = '1.0';
addon.desc      = 'Tracks user-assigned buffs on party/alliance members, showing which players should have a given buff and whether they currently do.';
addon.link      = 'https://ashitaxi.com/';

require('common');
require('helpers');

local jit = require('jit');
jit.off();
local gdi = require('gdifonts.include');

ashita.events.register('load', 'load_cb', function ()
    require('initializer');
    require('callbacks');
end);

ashita.events.register('unload', 'unload_cb', function ()
    gdi:destroy_interface();
    if (gSounds ~= nil) then
        gSounds:Cleanup();
    end
end);
