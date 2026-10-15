--[[
    durations/data.lua

    Tracks player id/name/job, TP, buffs, equipped gear, and merit counts --
    entirely from incoming packets and direct memory reads. No outgoing
    packets are sent by this file (Job Point polling, the one thing that
    used to send outgoing packets here, has been removed entirely --
    unneeded on this server and outgoing packets are off-limits for this
    project on principle, not just for that one case).
]]--

local augments = dofile(string.gsub(debug.getinfo(1, "S").source:sub(2), 'data.lua', 'augments.lua'));
local equipment = {};
local player = {
    Id = 0,
    Name = 'Unknown',
    TP = 1000,
    Job = {
        Main = 0,
        MainLevel = 0,
        Sub = 0,
        SubLevel = 0;
    },
    MeritCount = {},
};

--Initialize name/id/merits if ingame
local playerIndex = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
if playerIndex ~= 0 then
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local flags = entity:GetRenderFlags0(playerIndex);
    if (bit.band(flags, 0x200) == 0x200) and (bit.band(flags, 0x4000) == 0) then
        local playMgr = AshitaCore:GetMemoryManager():GetPlayer();
        player.Name = entity:GetName(playerIndex);
        player.Id = entity:GetServerId(playerIndex);
        player.Job = {
            Main = playMgr:GetMainJob(),
            MainLevel = playMgr:GetMainJobLevel(),
            Sub = playMgr:GetSubJob(),
            SubLevel = playMgr:GetSubJobLevel(),
        };
        player.Buffs = T{};
        
        local ids = playMgr:GetStatusIcons();
        local durations = playMgr:GetStatusTimers();
        for i = 1,32 do
            if ids[i] and ids[i] ~= 255 then
                player.Buffs:append({Id=ids[i], Duration=durations[i]});
            end
        end

        local pInventory = AshitaCore:GetPointerManager():Get('inventory');
        if (pInventory > 0) then
            local ptr = ashita.memory.read_uint32(pInventory);
            if (ptr ~= 0) then                    
                ptr = ashita.memory.read_uint32(ptr);
                if (ptr ~= 0) then
                    ptr = ptr + 0x2CFF4;
                    local count = ashita.memory.read_uint16(ptr + 2);
                    local meritptr = ashita.memory.read_uint32(ptr + 4);
                    if (count > 0) then
                        for i = 1,count do
                            local meritId = ashita.memory.read_uint16(meritptr + 0);
                            local meritCount = ashita.memory.read_uint8(meritptr + 3);
                            player.MeritCount[meritId] = meritCount;
                            meritptr = meritptr + 4;
                        end
                    end
                end
            end
        end
        
        for i = 0,15 do
            local equippedItem = AshitaCore:GetMemoryManager():GetInventory():GetEquippedItem(i);
            local index = bit.band(equippedItem.Index, 0x00FF);
            if index > 0 then
                equipment[i] = {
                    Container = bit.rshift(bit.band(equippedItem.Index, 0xFF00), 8);
                    Index = index;
                };
            end
            equipment.Changed = true;
        end
    end
end

ashita.events.register('packet_in', 'duration_lib_data_handleincomingpacket', function (e)
    if (e.id == 0x00A) then
        local id = struct.unpack('L', e.data, 0x04 + 1);
        local name = struct.unpack('c16', e.data, 0x84 + 1):trimend('\x00');
        local job = struct.unpack('B', e.data, 0xB4 + 1);
        local sub = struct.unpack('B', e.data, 0xB7 + 1);

        if (id ~= player.Id) or (name ~= player.Name) then
            player = {
                Id = id,
                Name = name,
                MeritCount = {},
                Job = {
                    Main = job,
                    MainLevel = 0,
                    Sub = sub,
                    SubLevel = 0
                },
                TP = 1000,
            };
        else
            player.Job.Main = job;
            player.Job.Sub = sub;
        end
        equipment = {};        
    elseif (e.id == 0x0DD) or (e.id == 0x0DF) or (e.id == 0x0E2) then
        --Storing the last recorded TP value for use in calculating duration of buff/debuff WS.
        if (struct.unpack('L', e.data, 0x04 + 1) == player.Id) then
            local tp = struct.unpack('L', e.data, 0x10 + 1);
            if tp >= 1000 then
                player.TP = tp;
            else
                player.TP = 1000;
            end
        end
    elseif (e.id == 0x01B) then
        local job = struct.unpack('B', e.data, 0x08 + 1);
        local sub = struct.unpack('B', e.data, 0x0B + 1);
        if (player.Id ~= 0) then
            player.Job.Main = job;
            player.Job.Sub = sub;
        end
    elseif (e.id == 0x50) then
        local slot = struct.unpack('B', e.data, 0x05 + 1);
        local index = struct.unpack('B', e.data, 0x04 + 1);
        if (index == 0) then
            equipment[slot] = nil;
        else
            local container = struct.unpack('B', e.data, 0x06 + 1);
            equipment[slot] = {
                Container = container;
                Index = index;
            };
        end
        equipment.Changed = true;
    elseif (e.id == 0x061) then
        local job = struct.unpack('B', e.data, 0x0C + 1);
        local mainLevel = struct.unpack('B', e.data, 0x0D + 1);
        local sub = struct.unpack('B', e.data, 0x0E + 1);
        local subLevel = struct.unpack('B', e.data, 0x0F + 1);
        if (player.Id ~= 0) then
            player.Job.Main = job;
            player.Job.Sub = sub;
            player.Job.MainLevel = mainLevel;
            player.Job.SubLevel = subLevel;
        end
    elseif (e.id == 0x63) then
        if struct.unpack('B', e.data, 0x04 + 1) == 9 then
            player.Buffs = T{};
            for i = 1,32 do
                local id = struct.unpack('H', e.data, 0x06 + (i * 2) + 1);
                local duration = struct.unpack('L', e.data, 0x44 + (i * 4) + 1);
                if id ~= 0xFF then
                    player.Buffs:append({Id=id, Duration=duration});
                end
            end
        end
    elseif (e.id == 0x08C) then
        local meritNum = struct.unpack('B', e.data, 0x04 + 1);
        for i = 1,meritNum,1 do
            local meritId = struct.unpack('H', e.data, 0x04 + (4 * i) + 1);
            local meritCount = struct.unpack('B', e.data, 0x04 + (4 * i) + 0x03 + 1);
            player.MeritCount[meritId] = meritCount;
        end        
    end
end);

local function MakeItemTable(item)
    local newItem = {
        Id = item.Id,
        Index = item.Index,
        Count = item.Count,
        Flags = item.Flags,
        Price = item.Price,
        Extra = item.Extra,
        Resource = AshitaCore:GetResourceManager():GetItemById(item.Id);
    };
    return newItem;
end

local equippedSet = T{};
local function UpdateEquippedSet()
    if (equipment.Changed ~= true) then
        return;
    end

    local set = T{};
    for slot = 0,15 do
        local itemLocation = equipment[slot];
        if (itemLocation ~= nil) then
            local item = AshitaCore:GetMemoryManager():GetInventory():GetContainerItem(itemLocation.Container, itemLocation.Index);
            if (item ~= nil) and (item.Id > 0) then
                local itemTable = MakeItemTable(item);
                itemTable.Container = itemLocation.Container;
                itemTable.Slot = slot;
                set:append(itemTable);
            end
        end
    end
    equippedSet = set;
    equipment.Changed = nil;
end

--[[
    WIP: Needs a real signature, this cannot be used as is..
local pLoginData;
local function GetLoginNames()
    if (pLoginData == nil) then
        pLoginData = ashita.memory.find('FFXiMain.dll', 0, 'F1D20000????????????0000????????F2D200000100', 36, 0);
        if (pLoginData == nil) then
            return T{};
        end
    end

    local count = ashita.memory.read_uint32(pLoginData);
    local output = T{};
    local sizeOfEntry = 140;
    for i = 1,count do
        local offset = ((i - 1) * sizeOfEntry) + pLoginData + 4;
        local idBase = ashita.memory.read_uint16(offset + 4);
        local idWorld = bit.lshift(ashita.memory.read_uint8(offset + 11), 16);
        local id = idBase + idWorld;
        local name = ashita.memory.read_string(offset + 12, 16):trimend('\x00');
        local server = ashita.memory.read_string(offset + 28, 16):trimend('\x00');
        if (idBase > 0) and (idWorld > 0) and (type(name) == 'string') and (string.len(name) > 2) then
            output:append({Id = id, MenuIndex = i, Name=name, Server=server});
        end
    end
    return output;
end

local function LookupServer()
    local server = 'Unknown';
    local loginNames = GetLoginNames();
    for _,entry in ipairs(loginNames) do
        if (entry.Name == player.Name) then
            server = entry.Server;
            if (entry.Id == player.Id) then
                return server;
            end
        end
    end
    return server;
end
]]--

local exports = {};

function exports:GetBuffActive(id)
    for _,entry in ipairs(player.Buffs) do
        if (entry.Id == id) then
            return true;
        end
    end
    return false;
end

function exports:GetBuffCount(id)
    local count = 0;
    for _,entry in ipairs(player.Buffs) do
        if (entry.Id == id) then
            count = count + 1;
        end
    end
    return count;
end

--Used for items that only count in a specific slot
local forceSlot = T{
    [25444] = 12,
    [25445] = 12,
    [25446] = 12,
};
function exports:EquipSum(values)
    UpdateEquippedSet();
    local total = 0;
    for _,equipPiece in ipairs(equippedSet) do
        if (equipPiece ~= nil) and (player.Job.MainLevel >= equipPiece.Resource.Level) then
            local value = values[equipPiece.Id];
            if value ~= nil then
                if (forceSlot[equipPiece.Id] == nil) or (forceSlot[equipPiece.Id] == equipPiece.Slot) then
                    total = total + value;
                end
            end
        end
    end
    return total;
end

function exports:GetEquippedSet()
    UpdateEquippedSet();
    return equippedSet;
end

function exports:GetMeritCount(meritId)
    local count = player.MeritCount[meritId];
    if not count then
        return 0;
    else
        return count;
    end
end

function exports:GetPlayerId()
    return player.Id;
end

function exports:GetJobData()
    return player.Job;
end

--Always 0 -- Job Points are never polled (see this file's header comment:
--outgoing packets are off-limits, and this server doesn't need
--mastery/level-99 data anyway). Kept as stubs rather than removed
--outright: enhancing.lua, songs.lua, bluemagic.lua, and abilities.lua all
--call these (Shadowbind, the DNC Sambas, Run Wild, Dematerialize,
--Vallation, Gambit, One for All, every Corsair Roll, etc), always gated
--behind a MainLevel==99 check -- removing the functions instead of
--stubbing them would crash the addon the instant any level-99 character
--in those jobs triggers a duration lookup. Returning 0 here makes every
--"+ jobPoints"/"x(1 + jobPoints/100)" in those call sites a no-op, which
--is functionally identical to stripping every one of those call sites by
--hand, without touching four other files to do it.
function exports:GetJobPointCount(job, category)
    return 0;
end

function exports:GetJobPointTotal(job)
    return 0;
end

--[[
function exports:GetServer()
    return LookupServer();
end
]]--

function exports:IsNotoriousMonster(id)
    --Possible, but probably too tedious.
    return false;
end

function exports:ParseAugments()
    UpdateEquippedSet();
    return augments:Parse(player.Job.MainLevel, equippedSet);
end

function exports:GetWeaponskillCost()
    return player.TP;
end

return exports;