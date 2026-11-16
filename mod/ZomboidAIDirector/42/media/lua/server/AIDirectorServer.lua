if isClient() then return end

require "AIDirectorConfig"
require "AIDirectorJson"
require "AIDirectorRadio"

AIDirectorServer = AIDirectorServer or {}

AIDirectorServer.lastCmdPollMs = 0
AIDirectorServer.lastStateWriteMs = 0
AIDirectorServer.lastTriggerCheckMs = 0
AIDirectorServer.lastProcessedSeq = 0
AIDirectorServer.cursorLoaded = false
AIDirectorServer.msgCounter = 0
AIDirectorServer.inbox = {}
AIDirectorServer.acks = {}
AIDirectorServer.recentEvents = {}

-- ClimateManager float/bool indices (verified from Build 42 ISAdmPanelClimate.lua)
local FLOAT_PRECIPITATION_INTENSITY = 3
local FLOAT_TEMPERATURE = 4
local FLOAT_FOG_INTENSITY = 5
local FLOAT_WIND_INTENSITY = 6
local FLOAT_CLOUD_INTENSITY = 8
local BOOL_IS_SNOW = 0

local function nowMs()
    if getTimestampMs then
        return getTimestampMs()
    end
    return os.time() * 1000
end

local function pushBounded(list, item, maxLen)
    table.insert(list, item)
    while #list > maxLen do
        table.remove(list, 1)
    end
end

local function readAllText(relPath)
    local reader = getFileReader(relPath, false)
    if not reader then
        return nil
    end
    local lines = {}
    local line = reader:readLine()
    while line ~= nil do
        table.insert(lines, line)
        line = reader:readLine()
    end
    reader:close()
    return table.concat(lines, "\n")
end

local function writeAllText(relPath, content, appendMode)
    local writer = getFileWriter(relPath, true, appendMode == true)
    if not writer then
        return false
    end
    writer:write(tostring(content))
    writer:close()
    return true
end

local function appendEventLog(eventType, payload)
    local entry = {
        ts_ms = nowMs(),
        event = eventType,
        data = payload or {},
    }
    pushBounded(AIDirectorServer.recentEvents, entry, 30)
    pcall(function()
        writeAllText(AIDirectorConfig.EVENTS_FILE, AIDirectorJson.encode(entry) .. "\n", true)
    end)
end

local function trimStr(s)
    if not s then return "" end
    s = tostring(s)
    local a = 1
    local b = string.len(s)
    while a <= b do
        local c = string.sub(s, a, a)
        if c == " " or c == "\t" or c == "\r" or c == "\n" then a = a + 1 else break end
    end
    while b >= a do
        local c = string.sub(s, b, b)
        if c == " " or c == "\t" or c == "\r" or c == "\n" then b = b - 1 else break end
    end
    if a > b then return "" end
    return string.sub(s, a, b)
end

local function splitLines(s)
    local out = {}
    if not s then return out end
    s = tostring(s)
    local pos = 1
    local len = string.len(s)
    while pos <= len do
        local nl = string.find(s, "\n", pos, true)
        local part
        if nl then
            part = string.sub(s, pos, nl - 1)
            pos = nl + 1
        else
            part = string.sub(s, pos, len)
            pos = len + 1
        end
        part = trimStr(part)
        if part ~= "" then
            table.insert(out, part)
        end
    end
    return out
end

local function loadCursorIfNeeded()
    if AIDirectorServer.cursorLoaded then return end
    AIDirectorServer.cursorLoaded = true

    local raw = readAllText(AIDirectorConfig.CURSOR_FILE)
    if raw then
        local trimmed = trimStr(raw)
        local n = tonumber(trimmed)
        if n and n >= 0 then
            AIDirectorServer.lastProcessedSeq = math.floor(n)
            print("[AIDirector] Resumed command cursor at seq=" .. tostring(AIDirectorServer.lastProcessedSeq))
            return
        end
    end

    -- First load: if cmd_index.txt already exists from an earlier session without cursor, sync to it
    local idxRaw = readAllText(AIDirectorConfig.CMD_INDEX_FILE)
    if idxRaw then
        local n = tonumber(trimStr(idxRaw))
        if n and n >= 0 then
            AIDirectorServer.lastProcessedSeq = math.floor(n)
            writeAllText(AIDirectorConfig.CURSOR_FILE, tostring(AIDirectorServer.lastProcessedSeq), false)
        end
    else
        writeAllText(AIDirectorConfig.CURSOR_FILE, "0", false)
    end
end

local function saveCursor()
    writeAllText(AIDirectorConfig.CURSOR_FILE, tostring(AIDirectorServer.lastProcessedSeq), false)
end

local function getAllActivePlayers()
    local result = {}
    if isServer() then
        local online = getOnlinePlayers()
        if online then
            for i = 0, online:size() - 1 do
                local p = online:get(i)
                if p and not p:isDead() then
                    table.insert(result, p)
                end
            end
        end
    else
        local num = getNumActivePlayers and getNumActivePlayers() or 0
        for i = 0, num - 1 do
            local p = getSpecificPlayer(i)
            if p and not p:isDead() then
                table.insert(result, p)
            end
        end
        if #result == 0 and getPlayer then
            local p = getPlayer()
            if p and not p:isDead() then
                table.insert(result, p)
            end
        end
    end
    return result
end

local function findTargetPlayer(username)
    local players = getAllActivePlayers()
    if #players == 0 then
        return nil
    end
    if username and tostring(username) ~= "" then
        local targetLower = string.lower(tostring(username))
        for _, p in ipairs(players) do
            if p:getUsername() and string.lower(p:getUsername()) == targetLower then
                return p
            end
        end
    end
    return players[1]
end

local function notifyClients(command, args, targetPlayer)
    if isServer() then
        if targetPlayer then
            sendServerCommand(targetPlayer, AIDirectorConfig.NET_MODULE, command, args)
        else
            sendServerCommand(AIDirectorConfig.NET_MODULE, command, args)
        end
    else
        if AIDirectorClient and AIDirectorClient.onServerMessage then
            pcall(AIDirectorClient.onServerMessage, command, args)
        end
    end
end

local function getZoneTriggersStore()
    local md = ModData.getOrCreate("AIDirectorZoneTriggers")
    md.triggers = md.triggers or {}
    return md.triggers
end

local function findClearOutdoorSquare(cx, cy, cz, maxRadius)
    local cell = getCell()
    if not cell then return nil end
    cz = tonumber(cz) or 0
    maxRadius = tonumber(maxRadius) or 12

    local centerSq = cell:getGridSquare(cx, cy, cz)
    if centerSq and centerSq:isFree(false) and centerSq:isOutside() then
        return centerSq
    end

    for r = 1, maxRadius do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local sq = cell:getGridSquare(cx + dx, cy + dy, cz)
                    if sq and sq:isFree(false) and sq:isOutside() and not sq:isVehicleIntersecting() then
                        return sq
                    end
                end
            end
        end
    end
    return centerSq
end

local function createSupplyCrateOnSquare(sq, crateName)
    if not sq then return nil end
    -- Reuse existing crate on this square if already created
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o and o:getContainer() and o:getModData() and o:getModData().isAIDirectorCrate then
            return o:getContainer(), o
        end
    end

    local crateObj = nil
    local ok = pcall(function()
        crateObj = IsoThumpable.new(getCell(), sq, "carpentry_01_16", false, {})
        crateObj:setName(crateName or getText("UI_AIDirector_CrateSupply"))
        crateObj:setIsContainer(true)
        if crateObj:getContainer() then
            crateObj:getContainer():setType("crate")
            crateObj:getContainer():setCapacity(50)
        end
        crateObj:getModData().isAIDirectorCrate = true
        sq:AddSpecialObject(crateObj)
        if isServer() and crateObj.transmitCompleteItemToClients then
            crateObj:transmitCompleteItemToClients()
        end
    end)
    if ok and crateObj and crateObj:getContainer() then
        return crateObj:getContainer(), crateObj
    end
    return nil, nil
end

local function syncItemAdded(container, item)
    if isServer() and sendAddItemToContainer and container and item then
        pcall(sendAddItemToContainer, container, item)
    end
end

local function createSingleItem(fullType)
    local item = nil
    pcall(function()
        if instanceItem then
            item = instanceItem(fullType)
        elseif InventoryItemFactory and InventoryItemFactory.CreateItem then
            item = InventoryItemFactory.CreateItem(fullType)
        end
    end)
    return item
end

-- =========================================================================
-- COMMAND HANDLERS
-- =========================================================================

local Handlers = {}

Handlers.ping = function(args)
    return { pong = true, version = AIDirectorConfig.VERSION, ts_ms = nowMs() }
end

Handlers.radio_broadcast = function(args)
    local lines = {}
    if type(args.lines) == "table" and #args.lines > 0 then
        for _, l in ipairs(args.lines) do
            table.insert(lines, tostring(l))
        end
    elseif args.text then
        for _, part in ipairs(splitLines(args.text)) do
            table.insert(lines, part)
        end
    end
    if #lines == 0 then
        error("radio_broadcast requires 'text' or 'lines'")
    end

    local freq = tonumber(args.freq) or AIDirectorConfig.RADIO_FREQ
    local r = tonumber(args.r) or 0.35
    local g = tonumber(args.g) or 1.0
    local b = tonumber(args.b) or 0.45
    local sender = args.sender or getText("UI_AIDirector_SenderFmt", string.format("%.1f", freq / 1000.0))
    local deliveryMode = args.delivery_mode or "radio_and_hud"

    local airedOnRadio = AIDirectorRadio.broadcastLines(lines, r, g, b, freq, args.add_static ~= false)

    local targetPlayer = nil
    if args.target_player and tostring(args.target_player) ~= "" then
        targetPlayer = findTargetPlayer(args.target_player)
    end

    notifyClients("radioBroadcast", {
        sender = sender,
        lines = lines,
        freq = freq,
        delivery_mode = deliveryMode,
        is_alert = args.is_alert == true,
        sound = args.sound or "LightSwitch",
    }, targetPlayer)

    return {
        aired_on_dynamic_radio = airedOnRadio,
        lines_count = #lines,
        freq = freq,
        delivery_mode = deliveryMode,
    }
end

Handlers.give_starter_radio = function(args)
    local players = {}
    if args.target_player and tostring(args.target_player) ~= "" then
        local p = findTargetPlayer(args.target_player)
        if p then table.insert(players, p) end
    else
        players = getAllActivePlayers()
    end
    if #players == 0 then
        error("No active players in world")
    end

    local freq = tonumber(args.freq) or AIDirectorConfig.RADIO_FREQ
    local radioType = args.radio_type or "Base.WalkieTalkie5"
    local givenTo = {}

    for _, p in ipairs(players) do
        local inv = p:getInventory()
        local item = inv:AddItem(radioType)
        if item then
            pcall(function()
                if item.getDeviceData then
                    local dd = item:getDeviceData()
                    if dd then
                        dd:setPower(1.0)
                        dd:setChannel(freq)
                        dd:setIsTurnedOn(true)
                        if dd.transmitBattryChange then dd:transmitBattryChange() end
                        if dd.transmitPresets then dd:transmitPresets() end
                    end
                end
                item:setName(getText("UI_AIDirector_RadioItemFmt", string.format("%.1f", freq / 1000.0)))
                item:setCustomName(true)
                if item.syncItemFields then item:syncItemFields() end
            end)
            syncItemAdded(inv, item)
            table.insert(givenTo, p:getUsername() or "Player")
        end
    end

    notifyClients("playAmbientSound", {
        sound = "LightSwitch",
        notice = getText("UI_AIDirector_RadioGivenFmt", string.format("%.1f", freq / 1000.0)),
    }, nil)

    return { given_to = AIDirectorJson.array(givenTo), freq = freq }
end

Handlers.spawn_items = function(args)
    local itemsSpec = args.items or {}
    if #itemsSpec == 0 and args.item_type then
        table.insert(itemsSpec, { type = args.item_type, count = tonumber(args.count) or 1 })
    end
    if #itemsSpec == 0 then
        error("spawn_items requires 'items' array or 'item_type'")
    end

    local placement = args.placement or "crate" -- "inventory" | "ground" | "crate"
    local player = findTargetPlayer(args.target_player)
    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = tonumber(args.z) or 0

    if (not x or not y) then
        if not player then
            error("No coordinates provided and no active player found")
        end
        local offsetX = tonumber(args.offset_x) or 2
        local offsetY = tonumber(args.offset_y) or 2
        x = math.floor(player:getX()) + offsetX
        y = math.floor(player:getY()) + offsetY
        z = math.floor(player:getZ())
    end

    local spawnedCount = 0
    if placement == "inventory" then
        if not player then
            error("placement='inventory' requires an active player")
        end
        local inv = player:getInventory()
        for _, entry in ipairs(itemsSpec) do
            local fullType = tostring(entry.type)
            local qty = math.max(1, math.min(100, tonumber(entry.count) or 1))
            for _ = 1, qty do
                local it = inv:AddItem(fullType)
                if it then
                    if entry.custom_name then
                        it:setName(tostring(entry.custom_name))
                        it:setCustomName(true)
                        if it.syncItemFields then pcall(function() it:syncItemFields() end) end
                    end
                    syncItemAdded(inv, it)
                    spawnedCount = spawnedCount + 1
                end
            end
        end
        return { placement = "inventory", player = player:getUsername(), spawned = spawnedCount }
    end

    local sq = getCell():getGridSquare(x, y, z)
    if not sq then
        error(string.format("Target square (%d, %d, %d) is not loaded in memory. Use schedule_zone_trigger for distant locations.", x, y, z))
    end

    local crateContainer = nil
    if placement == "crate" then
        local clearSq = findClearOutdoorSquare(x, y, z, 5) or sq
        sq = clearSq
        x, y, z = sq:getX(), sq:getY(), sq:getZ()
        crateContainer = createSupplyCrateOnSquare(sq, args.crate_name or getText("UI_AIDirector_CrateMilitary"))
    end

    for _, entry in ipairs(itemsSpec) do
        local fullType = tostring(entry.type)
        local qty = math.max(1, math.min(100, tonumber(entry.count) or 1))
        for _ = 1, qty do
            if crateContainer then
                local it = crateContainer:AddItem(fullType)
                if it then
                    if entry.custom_name then
                        it:setName(tostring(entry.custom_name))
                        it:setCustomName(true)
                        if it.syncItemFields then pcall(function() it:syncItemFields() end) end
                    end
                    syncItemAdded(crateContainer, it)
                    spawnedCount = spawnedCount + 1
                end
            else
                local it = sq:AddWorldInventoryItem(fullType, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
                if it then
                    if entry.custom_name then
                        it:setName(tostring(entry.custom_name))
                        it:setCustomName(true)
                        if it.syncItemFields then pcall(function() it:syncItemFields() end) end
                    end
                    spawnedCount = spawnedCount + 1
                end
            end
        end
    end

    if args.add_smoke == true then
        pcall(function()
            IsoFireManager.StartSmoke(getCell(), sq, true, 100, 600)
        end)
    end

    return {
        placement = crateContainer and "crate" or "ground",
        x = x,
        y = y,
        z = z,
        spawned = spawnedCount,
        smoke = args.add_smoke == true,
    }
end

Handlers.spawn_story_note = function(args)
    local title = tostring(args.title or getText("UI_AIDirector_DefaultNoteTitle"))
    local pages = args.pages or {}
    if #pages == 0 and args.text then
        table.insert(pages, tostring(args.text))
    end
    if #pages == 0 then
        error("spawn_story_note requires 'text' or 'pages'")
    end

    local itemType = args.item_type or "Base.Notebook"
    local note = createSingleItem(itemType)
    if not note then
        note = createSingleItem("Base.Notebook")
    end
    if not note then
        error("Could not instantiate notebook item: " .. tostring(itemType))
    end

    pcall(function()
        note:setName(title)
        note:setCustomName(true)
        if note.addPage then
            for idx, pageText in ipairs(pages) do
                note:addPage(idx, tostring(pageText))
            end
        end
        if note.syncItemFields then
            note:syncItemFields()
        end
    end)

    local placement = args.placement or "inventory"
    local player = findTargetPlayer(args.target_player)

    if placement == "inventory" and player then
        local inv = player:getInventory()
        inv:AddItem(note)
        syncItemAdded(inv, note)
        return { placement = "inventory", player = player:getUsername(), title = title, pages = #pages }
    end

    local x = tonumber(args.x) or (player and math.floor(player:getX()) + 1)
    local y = tonumber(args.y) or (player and math.floor(player:getY()) + 1)
    local z = tonumber(args.z) or (player and math.floor(player:getZ()) or 0)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then
        error("Target square not loaded for story note")
    end

    if placement == "crate" then
        local crateContainer = createSupplyCrateOnSquare(sq, args.crate_name or getText("UI_AIDirector_CrateStash"))
        if crateContainer then
            crateContainer:AddItem(note)
            syncItemAdded(crateContainer, note)
            return { placement = "crate", x = x, y = y, z = z, title = title }
        end
    end

    sq:AddWorldInventoryItem(note, 0.5, 0.5, 0)
    return { placement = "ground", x = x, y = y, z = z, title = title }
end

Handlers.spawn_horde = function(args)
    local count = math.max(1, math.min(300, tonumber(args.count) or 10))
    local radius = math.max(1, math.min(40, tonumber(args.radius) or 6))
    local outfit = (args.outfit and tostring(args.outfit) ~= "") and tostring(args.outfit) or nil
    local femaleChance = tonumber(args.female_chance)
    local crawler = args.crawler == true
    local isFallOnFront = args.fall_on_front == true
    local isFakeDead = args.fake_dead == true
    local knockedDown = args.knocked_down == true
    local isInvulnerable = false
    local isSitting = args.sitting == true
    local health = tonumber(args.health) or 1.0
    local onFire = args.on_fire == true

    local player = findTargetPlayer(args.target_player)
    local cx = tonumber(args.x)
    local cy = tonumber(args.y)
    local cz = tonumber(args.z) or 0

    if not cx or not cy then
        if not player then
            error("No coordinates provided and no active player found")
        end
        local dist = math.max(12, math.min(75, tonumber(args.distance_from_player) or 35))
        local dir = string.upper(tostring(args.direction or "RANDOM"))
        local angle = ZombRandFloat(0, math.pi * 2)
        if dir == "N" then angle = -math.pi / 2
        elseif dir == "S" then angle = math.pi / 2
        elseif dir == "E" then angle = 0
        elseif dir == "W" then angle = math.pi
        elseif dir == "NE" then angle = -math.pi / 4
        elseif dir == "NW" then angle = -3 * math.pi / 4
        elseif dir == "SE" then angle = math.pi / 4
        elseif dir == "SW" then angle = 3 * math.pi / 4
        end
        cx = math.floor(player:getX() + math.cos(angle) * dist)
        cy = math.floor(player:getY() + math.sin(angle) * dist)
        cz = 0
    end

    local sq = getCell():getGridSquare(cx, cy, cz)
    if not sq then
        error(string.format("Target square (%d, %d, %d) is not loaded in memory (keep distance_from_player <= 70 or use schedule_zone_trigger).", cx, cy, cz))
    end

    local spawned = 0
    for _ = 1, count do
        local zx = ZombRand(cx - radius, cx + radius + 1)
        local zy = ZombRand(cy - radius, cy + radius + 1)
        local zList = addZombiesInOutfit(
            zx, zy, cz, 1, outfit, femaleChance,
            crawler, isFallOnFront, isFakeDead, knockedDown,
            isInvulnerable, isSitting, health, false, 0, false, onFire, false
        )
        if zList and zList:size() > 0 then
            spawned = spawned + zList:size()
        else
            spawned = spawned + 1
        end
    end

    -- Optional lure toward the player so the horde marches in organically
    if args.lure_to_player ~= false and player then
        addSound(player, math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()), 85, 85)
    end

    return {
        spawned = spawned,
        center_x = cx,
        center_y = cy,
        z = cz,
        outfit = outfit or "random",
        lured = args.lure_to_player ~= false,
    }
end

Handlers.sound_event = function(args)
    local eventType = tostring(args.event_type or "gunshot")
    local player = findTargetPlayer(args.target_player)
    local x = tonumber(args.x) or (player and math.floor(player:getX()) or 0)
    local y = tonumber(args.y) or (player and math.floor(player:getY()) or 0)
    local z = tonumber(args.z) or (player and math.floor(player:getZ()) or 0)
    local radius = math.max(10, math.min(300, tonumber(args.radius) or 120))
    local volume = math.max(10, math.min(100, tonumber(args.volume) or 90))

    if eventType == "helicopter" then
        testHelicopter()
        notifyClients("playAmbientSound", {
            notice = getText("UI_AIDirector_HeliNotice"),
            is_alert = true,
        }, nil)
        return { event_type = "helicopter", triggered = true }

    elseif eventType == "building_alarm" then
        local cell = getCell()
        local triggeredBuilding = false
        for r = 0, 45, 3 do
            for dx = -r, r, 3 do
                for dy = -r, r, 3 do
                    local sq = cell:getGridSquare(x + dx, y + dy, 0)
                    if sq and sq:getBuilding() and sq:getBuilding():getDef() then
                        local bDef = sq:getBuilding():getDef()
                        bDef:setAlarmed(true)
                        sq:getBuilding():TriggerAlarm()
                        triggeredBuilding = true
                        x, y = sq:getX(), sq:getY()
                        break
                    end
                end
                if triggeredBuilding then break end
            end
            if triggeredBuilding then break end
        end
        if not triggeredBuilding then
            addSound(player, x, y, z, 180, 100)
        end
        return { event_type = "building_alarm", triggered_building = triggeredBuilding, x = x, y = y }

    elseif eventType == "gunshot" then
        local ox = x + ZombRand(-35, 36)
        local oy = y + ZombRand(-35, 36)
        addSound(player, ox, oy, 0, radius, volume)
        notifyClients("playAmbientSound", {
            sound = "MetaGunShot1",
            notice = args.notice or getText("UI_AIDirector_GunshotNotice"),
            is_alert = true,
        }, nil)
        return { event_type = "gunshot", sound_x = ox, sound_y = oy, radius = radius }

    elseif eventType == "scream" then
        local ox = x + ZombRand(-30, 31)
        local oy = y + ZombRand(-30, 31)
        addSound(player, ox, oy, 0, radius, volume)
        notifyClients("playAmbientSound", {
            sound = "MetaScream1",
            notice = args.notice or getText("UI_AIDirector_ScreamNotice"),
            is_alert = true,
        }, nil)
        return { event_type = "scream", sound_x = ox, sound_y = oy, radius = radius }

    elseif eventType == "thunder" then
        getClimateManager():getThunderStorm():triggerThunderEvent(x, y, true, true, true)
        return { event_type = "thunder", x = x, y = y }

    else
        -- Pure invisible zombie attractor at (x, y)
        addSound(player, x, y, z, radius, volume)
        if args.notice then
            notifyClients("playAmbientSound", { notice = tostring(args.notice) }, nil)
        end
        return { event_type = "invisible_attractor", x = x, y = y, radius = radius, volume = volume }
    end
end

Handlers.weather = function(args)
    local clim = getClimateManager()
    if not clim then
        error("ClimateManager unavailable")
    end

    local preset = args.preset and string.lower(tostring(args.preset)) or nil
    local durationHours = math.max(1, math.min(120, tonumber(args.duration_hours) or 6))

    local function resetAdminFloats()
        for _, fid in ipairs({ FLOAT_PRECIPITATION_INTENSITY, FLOAT_TEMPERATURE, FLOAT_FOG_INTENSITY, FLOAT_WIND_INTENSITY, FLOAT_CLOUD_INTENSITY }) do
            local cf = clim:getClimateFloat(fid)
            if cf then cf:setEnableAdmin(false) end
        end
        local cb = clim:getClimateBool(BOOL_IS_SNOW)
        if cb then cb:setEnableAdmin(false) end
    end

    if preset == "clear" then
        clim:stopWeatherAndThunder()
        resetAdminFloats()
        clim:getClimateFloat(FLOAT_FOG_INTENSITY):setEnableAdmin(true)
        clim:getClimateFloat(FLOAT_FOG_INTENSITY):setAdminValue(0.0)
        clim:getClimateFloat(FLOAT_PRECIPITATION_INTENSITY):setEnableAdmin(true)
        clim:getClimateFloat(FLOAT_PRECIPITATION_INTENSITY):setAdminValue(0.0)
    elseif preset == "storm" then
        resetAdminFloats()
        clim:triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM, durationHours)
    elseif preset == "tropical_storm" then
        resetAdminFloats()
        clim:triggerCustomWeatherStage(WeatherPeriod.STAGE_TROPICAL_STORM, durationHours)
    elseif preset == "blizzard" then
        resetAdminFloats()
        clim:triggerCustomWeatherStage(WeatherPeriod.STAGE_BLIZZARD, durationHours)
    elseif preset == "dense_fog" then
        clim:getClimateFloat(FLOAT_FOG_INTENSITY):setEnableAdmin(true)
        clim:getClimateFloat(FLOAT_FOG_INTENSITY):setAdminValue(tonumber(args.fog) or 0.85)
    elseif preset == "natural" then
        resetAdminFloats()
    end

    if args.fog ~= nil then
        clim:getClimateFloat(FLOAT_FOG_INTENSITY):setEnableAdmin(true)
        clim:getClimateFloat(FLOAT_FOG_INTENSITY):setAdminValue(math.max(0, math.min(1, tonumber(args.fog))))
    end
    if args.wind_kph ~= nil then
        local maxW = clim:getMaxWindspeedKph()
        clim:getClimateFloat(FLOAT_WIND_INTENSITY):setEnableAdmin(true)
        clim:getClimateFloat(FLOAT_WIND_INTENSITY):setAdminValue(math.max(0, math.min(1, tonumber(args.wind_kph) / maxW)))
    end
    if args.precipitation ~= nil then
        clim:getClimateFloat(FLOAT_PRECIPITATION_INTENSITY):setEnableAdmin(true)
        clim:getClimateFloat(FLOAT_PRECIPITATION_INTENSITY):setAdminValue(math.max(0, math.min(1, tonumber(args.precipitation))))
    end
    if args.is_snow ~= nil then
        clim:getClimateBool(BOOL_IS_SNOW):setEnableAdmin(true)
        clim:getClimateBool(BOOL_IS_SNOW):setAdminValue(args.is_snow == true)
    end
    if args.temperature_c ~= nil then
        clim:getClimateFloat(FLOAT_TEMPERATURE):setEnableAdmin(true)
        clim:getClimateFloat(FLOAT_TEMPERATURE):setAdminValue(math.max(-40, math.min(45, tonumber(args.temperature_c))))
    end

    if isServer() and clim.transmitClientChangeAdminVars then
        pcall(function() clim:transmitClientChangeAdminVars() end)
    end

    return {
        preset = preset or "custom",
        duration_hours = durationHours,
    }
end

Handlers.spawn_vehicle = function(args)
    local vehicleType = tostring(args.vehicle_type or "Base.Van")
    local player = findTargetPlayer(args.target_player)
    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local z = 0

    if not x or not y then
        if not player then
            error("No coordinates provided and no active player found")
        end
        x = math.floor(player:getX()) + (tonumber(args.offset_x) or 6)
        y = math.floor(player:getY()) + (tonumber(args.offset_y) or 6)
    end

    local sq = findClearOutdoorSquare(x, y, z, 15)
    if not sq then
        error(string.format("Target square (%d, %d) is not loaded or obstructed", x, y))
    end

    local dirMap = {
        N = IsoDirections.N,
        S = IsoDirections.S,
        E = IsoDirections.E,
        W = IsoDirections.W,
    }
    local dir = dirMap[string.upper(tostring(args.direction or "E"))] or IsoDirections.E
    local vehicle = addVehicleDebug(vehicleType, dir, nil, sq)
    if not vehicle then
        error("Failed to spawn vehicle of type: " .. vehicleType)
    end

    local conditionPreset = string.lower(tostring(args.condition or "survivor"))
    local fuelPct = tonumber(args.fuel_percent)

    pcall(function()
        vehicle:repair()
        if conditionPreset == "wrecked" then
            fuelPct = fuelPct or 8
            vehicle:setRust(0.8)
            for i = 0, vehicle:getPartCount() - 1 do
                local part = vehicle:getPartByIndex(i)
                if part then
                    part:setCondition(ZombRand(10, 38))
                    if isServer() then vehicle:transmitPartCondition(part) end
                end
            end
        elseif conditionPreset == "survivor" then
            fuelPct = fuelPct or 35
            for i = 0, vehicle:getPartCount() - 1 do
                local part = vehicle:getPartByIndex(i)
                if part then
                    part:setCondition(ZombRand(48, 88))
                    if isServer() then vehicle:transmitPartCondition(part) end
                end
            end
        else
            fuelPct = fuelPct or 85
        end

        local gasTank = vehicle:getPartById("GasTank")
        if gasTank and gasTank:isContainer() then
            local cap = gasTank:getContainerCapacity()
            local amt = math.max(0, math.min(cap, cap * (fuelPct / 100.0)))
            gasTank:setContainerContentAmount(amt)
            if isServer() then vehicle:transmitPartModData(gasTank) end
        end

        if args.create_key ~= false then
            local key = vehicle:createVehicleKey()
            if key then
                if args.key_to_player == true and player then
                    player:getInventory():AddItem(key)
                    syncItemAdded(player:getInventory(), key)
                else
                    local gloveBox = vehicle:getPartById("GloveBox")
                    if gloveBox and gloveBox:getItemContainer() then
                        gloveBox:getItemContainer():AddItem(key)
                        syncItemAdded(gloveBox:getItemContainer(), key)
                    elseif player then
                        player:getInventory():AddItem(key)
                        syncItemAdded(player:getInventory(), key)
                    end
                end
            end
        end

        if type(args.trunk_items) == "table" and #args.trunk_items > 0 then
            local trunkPart = vehicle:getPartById("TruckBed") or vehicle:getPartById("TruckBedOpen") or vehicle:getPartById("TrailerTrunk") or vehicle:getPartById("GloveBox")
            if trunkPart and trunkPart:getItemContainer() then
                local cont = trunkPart:getItemContainer()
                for _, entry in ipairs(args.trunk_items) do
                    local itType = tostring(entry.type)
                    local qty = math.max(1, math.min(50, tonumber(entry.count) or 1))
                    for _ = 1, qty do
                        local it = cont:AddItem(itType)
                        if it then syncItemAdded(cont, it) end
                    end
                end
            end
        end
    end)

    return {
        vehicle_type = vehicleType,
        x = sq:getX(),
        y = sq:getY(),
        condition = conditionPreset,
        fuel_percent = fuelPct,
    }
end

Handlers.world_effect = function(args)
    local effect = string.lower(tostring(args.effect or "smoke"))
    local player = findTargetPlayer(args.target_player)
    local x = tonumber(args.x) or (player and (math.floor(player:getX()) + (tonumber(args.offset_x) or 6)))
    local y = tonumber(args.y) or (player and (math.floor(player:getY()) + (tonumber(args.offset_y) or 6)))
    local z = tonumber(args.z) or 0

    if effect == "power_on" or effect == "power_off" then
        local sb = getSandboxOptions()
        if effect == "power_on" then
            sb:set("ElecShutModifier", 99999)
        else
            sb:set("ElecShutModifier", -1)
        end
        sb:toLua()
        if isServer() and sb.sendToServer then pcall(function() sb:sendToServer() end) end
        return { effect = effect, applied = true }
    end

    if not x or not y then
        error("world_effect requires coordinates or an active player")
    end

    if effect == "lightning" then
        getClimateManager():getThunderStorm():triggerThunderEvent(x, y, true, true, true)
        return { effect = "lightning", x = x, y = y }
    end

    local sq = getCell():getGridSquare(x, y, z)
    if not sq then
        error(string.format("Square (%d, %d, %d) is not loaded", x, y, z))
    end

    if effect == "fire" then
        IsoFireManager.StartFire(getCell(), sq, true, 100, 500)
    elseif effect == "smoke" then
        IsoFireManager.StartSmoke(getCell(), sq, true, 100, 600)
    elseif effect == "explosion" then
        IsoFireManager.explode(getCell(), sq, 100)
    else
        error("Unknown world_effect: " .. tostring(effect))
    end

    return { effect = effect, x = x, y = y, z = z }
end

Handlers.modify_player = function(args)
    local player = findTargetPlayer(args.target_player)
    if not player then
        error("Target player not found")
    end
    local action = string.lower(tostring(args.action or "heal_full"))

    if action == "heal_full" or action == "cure_infection" then
        local bd = player:getBodyDamage()
        if action == "heal_full" then
            bd:RestoreToFullHealth()
        else
            if bd.setInfected then pcall(function() bd:setInfected(false) end) end
            if bd.setInfectionLevel then pcall(function() bd:setInfectionLevel(0) end) end
            if bd.setInfectionTime then pcall(function() bd:setInfectionTime(-1) end) end
            local parts = bd:getBodyParts()
            for i = 0, parts:size() - 1 do
                local bp = parts:get(i)
                if bp.SetBitten then pcall(function() bp:SetBitten(false) end) end
                if bp.SetInfected then pcall(function() bp:SetInfected(false) end) end
                if bp.SetFakeInfected then pcall(function() bp:SetFakeInfected(false) end) end
                if syncBodyPart then pcall(syncBodyPart, bp, 0xFFFFFFFFFFF) end
            end
            -- Build 42 fallback: ensure infection is actually cleared even if B42 body-damage API changed
            local stillInfected = false
            pcall(function()
                if bd.isInfected and bd:isInfected() then stillInfected = true end
            end)
            if stillInfected then
                bd:RestoreToFullHealth()
            end
        end
    elseif action == "give_xp" then
        local perkName = tostring(args.perk or "Mechanics")
        local amount = tonumber(args.amount) or 150
        local perk = Perks.FromString(perkName)
        if not perk then
            error("Unknown perk: " .. perkName)
        end
        if addXp then
            addXp(player, perk, amount)
        else
            player:getXp():AddXP(perk, amount, false, false, false, false)
        end
    elseif action == "calm_panic" then
        pcall(function()
            player:getStats():set(CharacterStat.PANIC, 0)
            player:getStats():set(CharacterStat.STRESS, 0)
        end)
    elseif action == "induce_panic" then
        pcall(function()
            player:getStats():set(CharacterStat.PANIC, tonumber(args.amount) or 85)
        end)
    else
        error("Unknown modify_player action: " .. action)
    end

    return { player = player:getUsername(), action = action }
end

Handlers.add_zone_trigger = function(args)
    local x = tonumber(args.x)
    local y = tonumber(args.y)
    if not x or not y then
        error("add_zone_trigger requires numeric x and y")
    end
    local store = getZoneTriggersStore()
    local trigId = tostring(args.id or ("trig_" .. tostring(nowMs()) .. "_" .. tostring(ZombRand(100, 999))))
    local trig = {
        id = trigId,
        name = tostring(args.name or getText("UI_AIDirector_DefaultTriggerName")),
        x = math.floor(x),
        y = math.floor(y),
        z = math.floor(tonumber(args.z) or 0),
        radius = math.max(10, math.min(90, tonumber(args.radius) or 55)),
        actions = args.actions or {},
        created_ms = nowMs(),
    }
    store[trigId] = trig
    return { trigger_id = trigId, name = trig.name, x = trig.x, y = trig.y, radius = trig.radius }
end

Handlers.remove_zone_trigger = function(args)
    local store = getZoneTriggersStore()
    local tid = tostring(args.id or "")
    if tid == "ALL" then
        for k, _ in pairs(store) do store[k] = nil end
        return { cleared_all = true }
    end
    local existed = store[tid] ~= nil
    store[tid] = nil
    return { removed = existed, id = tid }
end

-- =========================================================================
-- TELEMETRY & POLLING LOOP
-- =========================================================================

local function safeStat(stats, enumObj)
    local val = 0
    if stats and enumObj then
        pcall(function()
            val = stats:get(enumObj) or 0
        end)
    end
    return math.floor(val * 100) / 100
end

local function collectPlayerState(p)
    local bd = p:getBodyDamage()
    local stats = p:getStats()
    local bittenCount = 0
    local bleedingCount = 0
    local fractureCount = 0
    pcall(function()
        local parts = bd:getBodyParts()
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            if bp:bitten() then bittenCount = bittenCount + 1 end
            if bp:bleeding() then bleedingCount = bleedingCount + 1 end
            if bp:getFractureTime() > 0 then fractureCount = fractureCount + 1 end
        end
    end)

    local primaryWeapon = "Unarmed"
    pcall(function()
        local item = p:getPrimaryHandItem()
        if item then primaryWeapon = item:getDisplayName() or item:getFullType() end
    end)

    local vehicleInfo = nil
    local veh = p:getVehicle()
    if veh then
        vehicleInfo = {
            script = veh:getScriptName() or "Unknown",
            speed_kph = math.floor((veh:getCurrentSpeedKmHour() or 0) * 10) / 10,
            engine_running = veh:isEngineRunning(),
            fuel_percent = 0,
            engine_condition = 0,
        }
        pcall(function()
            local gt = veh:getPartById("GasTank")
            if gt and gt:getContainerCapacity() > 0 then
                vehicleInfo.fuel_percent = math.floor((gt:getContainerContentAmount() / gt:getContainerCapacity()) * 1000) / 10
            end
            local eng = veh:getPartById("Engine")
            if eng then
                vehicleInfo.engine_condition = eng:getCondition()
            end
        end)
    end

    local visibleZombies = 0
    pcall(function() visibleZombies = stats:getNumVisibleZombies() or 0 end)

    return {
        username = p:getUsername() or "Survivor",
        x = math.floor(p:getX()),
        y = math.floor(p:getY()),
        z = math.floor(p:getZ()),
        health = math.floor((bd:getOverallBodyHealth() or 100) * 10) / 10,
        infected = bd:isInfected(),
        bitten_parts = bittenCount,
        bleeding_parts = bleedingCount,
        fractures = fractureCount,
        hunger = safeStat(stats, CharacterStat and CharacterStat.HUNGER),
        thirst = safeStat(stats, CharacterStat and CharacterStat.THIRST),
        fatigue = safeStat(stats, CharacterStat and CharacterStat.FATIGUE),
        panic = safeStat(stats, CharacterStat and CharacterStat.PANIC),
        outside = p:isOutside(),
        primary_item = primaryWeapon,
        visible_zombies = visibleZombies,
        vehicle = vehicleInfo,
    }
end

function AIDirectorServer.writeWorldState()
    local gt = getGameTime()
    local clim = getClimateManager()
    local playersOut = {}
    for _, p in ipairs(getAllActivePlayers()) do
        local ok, pData = pcall(collectPlayerState, p)
        if ok and pData then
            table.insert(playersOut, pData)
        end
    end

    local triggersOut = {}
    local store = getZoneTriggersStore()
    for _, trig in pairs(store) do
        table.insert(triggersOut, {
            id = trig.id,
            name = trig.name,
            x = trig.x,
            y = trig.y,
            z = trig.z,
            radius = trig.radius,
            actions_count = trig.actions and #trig.actions or 0,
        })
    end

    local weatherInfo = {}
    pcall(function()
        weatherInfo = {
            temperature_c = math.floor((clim:getTemperature() or 20) * 10) / 10,
            rain_intensity = math.floor((clim:getRainIntensity() or 0) * 100) / 100,
            snow_intensity = math.floor((clim:getSnowIntensity() or 0) * 100) / 100,
            fog_intensity = math.floor((clim:getFogIntensity() or 0) * 100) / 100,
            wind_kph = math.floor((clim:getWindspeedKph() or 0) * 10) / 10,
            is_storming = clim:getWeatherPeriod() and clim:getWeatherPeriod():isRunning() or false,
        }
    end)

    local stateObj = {
        version = AIDirectorConfig.VERSION,
        updated_ms = nowMs(),
        is_multiplayer_server = isServer(),
        last_processed_seq = AIDirectorServer.lastProcessedSeq,
        radio_channel = {
            name = AIDirectorConfig.RADIO_NAME,
            freq = AIDirectorConfig.RADIO_FREQ,
            mhz = string.format("%.1f MHz", AIDirectorConfig.RADIO_FREQ / 1000.0),
        },
        world_time = {
            year = gt:getYear(),
            month = gt:getMonth() + 1,
            day = gt:getDay() + 1,
            hour = gt:getHour(),
            minutes = gt:getMinutes(),
            nights_survived = gt:getNightsSurvived(),
            elec_on = gt:getNightsSurvived() < getSandboxOptions():getElecShutModifier(),
        },
        weather = weatherInfo,
        players = AIDirectorJson.array(playersOut),
        inbox = AIDirectorJson.array(AIDirectorServer.inbox),
        acks = AIDirectorJson.array(AIDirectorServer.acks),
        zone_triggers = AIDirectorJson.array(triggersOut),
        recent_events = AIDirectorJson.array(AIDirectorServer.recentEvents),
    }

    local encoded = AIDirectorJson.encode(stateObj) .. "\n__EOF__"
    writeAllText(AIDirectorConfig.STATE_FILE, encoded, false)
end

local function executeSingleAction(actionObj)
    local cmdName = tostring(actionObj.command or actionObj.action or "")
    local handler = Handlers[cmdName]
    if not handler then
        error("Unknown AI Director command: " .. cmdName)
    end
    return handler(actionObj.args or actionObj)
end

function AIDirectorServer.pollCommands()
    loadCursorIfNeeded()
    local idxRaw = readAllText(AIDirectorConfig.CMD_INDEX_FILE)
    if not idxRaw then return false end
    local latestSeq = tonumber(trimStr(idxRaw))
    if not latestSeq or latestSeq <= AIDirectorServer.lastProcessedSeq then
        return false
    end

    local processedAny = false
    for seq = AIDirectorServer.lastProcessedSeq + 1, latestSeq do
        local cmdFile = string.format("%s/cmd_%d.json", AIDirectorConfig.DATA_DIR, seq)
        local cmdText = readAllText(cmdFile)
        if not cmdText then
            -- Wait one cycle if the file is still flushing
            break
        end

        local okParse, parsed = pcall(AIDirectorJson.decode, cmdText)
        if not okParse or type(parsed) ~= "table" then
            pushBounded(AIDirectorServer.acks, {
                seq = seq,
                ok = false,
                error = "JSON parse error: " .. tostring(parsed),
                ts_ms = nowMs(),
            }, AIDirectorConfig.MAX_ACKS)
        else
            local okExec, resOrErr = pcall(executeSingleAction, parsed)
            pushBounded(AIDirectorServer.acks, {
                seq = seq,
                id = parsed.id,
                command = parsed.command,
                ok = okExec,
                result = okExec and resOrErr or nil,
                error = (not okExec) and tostring(resOrErr) or nil,
                ts_ms = nowMs(),
            }, AIDirectorConfig.MAX_ACKS)
        end

        AIDirectorServer.lastProcessedSeq = seq
        saveCursor()
        processedAny = true
    end

    return processedAny
end

function AIDirectorServer.checkZoneTriggers()
    local store = getZoneTriggersStore()
    local players = getAllActivePlayers()
    if #players == 0 then return end
    local cell = getCell()
    if not cell then return end

    for trigId, trig in pairs(store) do
        for _, p in ipairs(players) do
            local dx = p:getX() - trig.x
            local dy = p:getY() - trig.y
            local distSq = dx * dx + dy * dy
            if distSq <= (trig.radius * trig.radius) then
                -- Ensure target square chunk is loaded in memory before firing!
                local targetSq = cell:getGridSquare(trig.x, trig.y, trig.z or 0)
                if targetSq then
                    print("[AIDirector] Firing zone trigger: " .. tostring(trig.name) .. " (" .. tostring(trigId) .. ")")
                    local results = {}
                    if type(trig.actions) == "table" then
                        for _, act in ipairs(trig.actions) do
                            local ok, res = pcall(executeSingleAction, act)
                            table.insert(results, { command = act.command, ok = ok, detail = tostring(res) })
                        end
                    end
                    appendEventLog("zone_trigger_fired", {
                        id = trigId,
                        name = trig.name,
                        triggered_by = p:getUsername() or "Survivor",
                        x = trig.x,
                        y = trig.y,
                    })
                    store[trigId] = nil
                    AIDirectorServer.writeWorldState()
                    break
                end
            end
        end
    end
end

local function onTick()
    local now = nowMs()
    if now - AIDirectorServer.lastCmdPollMs >= AIDirectorConfig.CMD_POLL_MS then
        AIDirectorServer.lastCmdPollMs = now
        local ok, ranCmd = pcall(AIDirectorServer.pollCommands)
        if ok and ranCmd then
            AIDirectorServer.lastStateWriteMs = now
            pcall(AIDirectorServer.writeWorldState)
        end
    end

    if now - AIDirectorServer.lastTriggerCheckMs >= AIDirectorConfig.TRIGGER_CHECK_MS then
        AIDirectorServer.lastTriggerCheckMs = now
        pcall(AIDirectorServer.checkZoneTriggers)
    end

    if now - AIDirectorServer.lastStateWriteMs >= AIDirectorConfig.STATE_WRITE_MS then
        AIDirectorServer.lastStateWriteMs = now
        pcall(AIDirectorServer.writeWorldState)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= AIDirectorConfig.NET_MODULE then return end
    if command == "playerRadioMessage" and player and args and args.text then
        AIDirectorServer.msgCounter = AIDirectorServer.msgCounter + 1
        local msgEntry = {
            msg_id = nowMs() .. "_" .. tostring(AIDirectorServer.msgCounter),
            ts_ms = nowMs(),
            player = player:getUsername() or "Survivor",
            x = math.floor(player:getX()),
            y = math.floor(player:getY()),
            z = math.floor(player:getZ()),
            freq = tonumber(args.freq) or AIDirectorConfig.RADIO_FREQ,
            has_tuned_radio = args.hasRadio == true,
            text = tostring(args.text),
        }
        pushBounded(AIDirectorServer.inbox, msgEntry, AIDirectorConfig.MAX_INBOX)
        appendEventLog("player_radio_message", msgEntry)
        pcall(AIDirectorRadio.broadcastLines, { "[" .. msgEntry.player .. "]: " .. msgEntry.text }, 0.55, 0.9, 1.0, msgEntry.freq, false)
        notifyClients("teammateRadio", {
            senderUsername = msgEntry.player,
            text = msgEntry.text,
            freq = msgEntry.freq,
        }, nil)
        pcall(AIDirectorServer.writeWorldState)
    end
end

Events.OnTick.Add(onTick)
Events.OnClientCommand.Add(onClientCommand)

print("[AIDirector] Server module initialized (Build 42 MCP Bridge v" .. tostring(AIDirectorConfig.VERSION) .. ")")

return AIDirectorServer
