if isServer() then return end

require "AIDirectorConfig"

AIDirectorClient = AIDirectorClient or {}

local function hasTunedRadio(player, targetFreq)
    if not player then return false end
    targetFreq = tonumber(targetFreq) or AIDirectorConfig.RADIO_FREQ

    -- 1. Check player inventory radios / walkie-talkies
    local inv = player:getInventory()
    if inv then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and item.getDeviceData then
                local dd = item:getDeviceData()
                if dd and dd:getIsTurnedOn() and dd:getChannel() == targetFreq then
                    if not dd:getIsBatteryPowered() or dd:getPower() > 0 then
                        return true
                    end
                end
            end
        end
    end

    -- 2. Check vehicle radio if inside a vehicle
    local veh = player:getVehicle()
    if veh then
        local radioPart = veh:getPartById("Radio")
        if radioPart and radioPart:getDeviceData() then
            local dd = radioPart:getDeviceData()
            if dd:getIsTurnedOn() and dd:getChannel() == targetFreq then
                return true
            end
        end
    end

    -- 3. Check nearby world radios within 6 tiles
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local cell = getCell()
    if cell then
        for dx = -5, 5 do
            for dy = -5, 5 do
                local sq = cell:getGridSquare(px + dx, py + dy, pz)
                if sq then
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj and obj.getDeviceData then
                            local dd = obj:getDeviceData()
                            if dd and dd:getIsTurnedOn() and dd:getChannel() == targetFreq then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

local function appendToChatWindow(prefix, text, colorHex)
    if not ISChat or not ISChat.instance or not ISChat.instance.chatText then
        return
    end
    pcall(function()
        local chatText = ISChat.instance.chatText
        local formatted = (colorHex or "<RGB:0.35,1.0,0.45>") .. "[" .. tostring(prefix) .. "]: <RGB:0.92,0.98,0.92>" .. tostring(text) .. " <LINE> "
        table.insert(chatText.chatTextLines, formatted)
        if #chatText.chatTextLines > (ISChat.maxLine or 50) then
            table.remove(chatText.chatTextLines, 1)
        end
        local newText = ""
        for i, v in ipairs(chatText.chatTextLines) do
            if i == #chatText.chatTextLines then
                v = string.gsub(v, " <LINE> $", "")
            end
            newText = newText .. v
        end
        chatText.text = newText
        chatText:paginate()
        chatText:setYScroll(-10000)
    end)
end

local function showOverheadText(player, text, isAlert)
    if not player then return end
    local ok = pcall(function()
        if isAlert and HaloTextHelper and HaloTextHelper.addBadText then
            HaloTextHelper.addBadText(player, tostring(text))
        elseif HaloTextHelper and HaloTextHelper.addGoodText then
            HaloTextHelper.addGoodText(player, tostring(text))
        else
            player:Say(tostring(text))
        end
    end)
    if not ok then
        pcall(function() player:Say(tostring(text)) end)
    end
end

local function playSafeSound(player, soundName)
    if not player or not soundName or soundName == "" then return end
    pcall(function()
        if player.playSoundLocal then
            player:playSoundLocal(soundName)
        else
            getSoundManager():PlayWorldSound(soundName, player:getCurrentSquare(), 0, 10, 1.0, false)
        end
    end)
end

function AIDirectorClient.sendRadioToAI(player, text, freq)
    if not player or not text then return end
    local s = tostring(text)
    local startIdx = 1
    local endIdx = string.len(s)
    while startIdx <= endIdx do
        local c = string.sub(s, startIdx, startIdx)
        if c == " " or c == "\t" or c == "\r" or c == "\n" then startIdx = startIdx + 1 else break end
    end
    while endIdx >= startIdx do
        local c = string.sub(s, endIdx, endIdx)
        if c == " " or c == "\t" or c == "\r" or c == "\n" then endIdx = endIdx - 1 else break end
    end
    local clean = (startIdx <= endIdx) and string.sub(s, startIdx, endIdx) or ""
    if clean == "" then return end
    local useFreq = tonumber(freq) or AIDirectorConfig.RADIO_FREQ
    local mhzStr = string.format("%.1f MHz", useFreq / 1000.0)

    playSafeSound(player, "LightSwitch")
    showOverheadText(player, "[" .. mhzStr .. getText("UI_AIDirector_AirSuffix") .. "]: " .. clean, false)
    appendToChatWindow(getText("UI_AIDirector_YouPrefix", mhzStr), clean, "<RGB:0.5,0.85,1.0>")

    sendClientCommand(player, AIDirectorConfig.NET_MODULE, "playerRadioMessage", {
        text = clean,
        freq = useFreq,
        hasRadio = hasTunedRadio(player, useFreq),
    })
end

local function openRadioPrompt(player, freq)
    if not player then return end
    local useFreq = tonumber(freq) or AIDirectorConfig.RADIO_FREQ
    local mhzStr = string.format("%.1f MHz", useFreq / 1000.0)

    local modal = ISTextBox:new(
        0, 0, 420, 180,
        getText("UI_AIDirector_PromptTitle", mhzStr),
        "",
        nil,
        function(_, button)
            if button.internal == "OK" then
                local msg = button.parent.entry:getText()
                AIDirectorClient.sendRadioToAI(player, msg, useFreq)
            end
        end,
        player:getPlayerNum()
    )
    modal.x = (getCore():getScreenWidth() - modal.width) / 2
    modal.y = (getCore():getScreenHeight() - modal.height) / 2
    modal:initialise()
    modal:addToUIManager()
    if modal.entry then
        modal.entry:focus()
    end
end

local function tuneInventoryRadio(player, item)
    if not item or not item.getDeviceData then return end
    local dd = item:getDeviceData()
    if not dd then return end
    pcall(function()
        if dd:getIsBatteryPowered() and dd:getPower() <= 0 then
            showOverheadText(player, getText("UI_AIDirector_NoBattery"), true)
            return
        end
        if not dd:getIsTurnedOn() then
            dd:setIsTurnedOn(true)
        end
        dd:setChannel(AIDirectorConfig.RADIO_FREQ)
        if dd.transmitPresets then dd:transmitPresets() end
        playSafeSound(player, "LightSwitch")
        showOverheadText(player, getText("UI_AIDirector_RadioTuned"), false)
    end)
end

local function onFillWorldContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local subMenuOption = context:addOption(getText("UI_AIDirector_MenuRoot"), worldobjects, nil)
    local subMenu = ISContextMenu:getNew(context)
    context:addSubMenu(subMenuOption, subMenu)

    subMenu:addOption(getText("UI_AIDirector_SendCustom"), player, openRadioPrompt, AIDirectorConfig.RADIO_FREQ)
    subMenu:addOption(getText("UI_AIDirector_SendSOS"), player, function(p)
        local x, y = math.floor(p:getX()), math.floor(p:getY())
        AIDirectorClient.sendRadioToAI(p, getText("UI_AIDirector_SOSTemplate", tostring(x), tostring(y)), AIDirectorConfig.RADIO_FREQ)
    end)
    subMenu:addOption(getText("UI_AIDirector_SendSitrep"), player, function(p)
        AIDirectorClient.sendRadioToAI(p, getText("UI_AIDirector_SitrepTemplate"), AIDirectorConfig.RADIO_FREQ)
    end)
end

local function onFillInventoryContextMenu(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    if not player or not items then return end

    local actualItems = ISInventoryPane.getActualItems(items)
    for _, item in ipairs(actualItems) do
        if item and item.getDeviceData and item:getDeviceData() then
            context:addOption(getText("UI_AIDirector_TuneRadio"), player, function(p)
                tuneInventoryRadio(p, item)
                openRadioPrompt(p, AIDirectorConfig.RADIO_FREQ)
            end)
            break
        end
    end
end

-- Hook Multiplayer Chat so messages starting with '@' or '!ai ' go straight to the AI Dispatcher
local function installChatHook()
    if not ISChat or AIDirectorClient._chatHooked then return end
    if type(ISChat.onCommandEntered) == "function" then
        local origOnCommandEntered = ISChat.onCommandEntered
        ISChat.onCommandEntered = function(self)
            pcall(function()
                if ISChat.instance and ISChat.instance.textEntry then
                    local raw = ISChat.instance.textEntry:getText()
                    if raw and string.len(raw) > 1 then
                        local first = string.sub(raw, 1, 1)
                        if first == "@" then
                            local msg = string.sub(raw, 2)
                            AIDirectorClient.sendRadioToAI(getPlayer(), msg, AIDirectorConfig.RADIO_FREQ)
                        elseif string.sub(raw, 1, 4) == "!ai " then
                            local msg = string.sub(raw, 5)
                            AIDirectorClient.sendRadioToAI(getPlayer(), msg, AIDirectorConfig.RADIO_FREQ)
                        end
                    end
                end
            end)
            return origOnCommandEntered(self)
        end
        AIDirectorClient._chatHooked = true
    end
end

function AIDirectorClient.onServerMessage(command, args)
    local player = getPlayer()
    if not player or not args then return end

    if command == "radioBroadcast" then
        local freq = tonumber(args.freq) or AIDirectorConfig.RADIO_FREQ
        local mode = args.delivery_mode or "radio_and_hud"
        if mode == "strict_radio" and not hasTunedRadio(player, freq) then
            return
        end

        local sender = args.sender or getText("UI_AIDirector_DefaultSender")
        local sound = args.sound or "LightSwitch"
        playSafeSound(player, sound)

        local isAlert = args.is_alert == true
        local colorTag = isAlert and "<RGB:1.0,0.4,0.35>" or "<RGB:0.35,1.0,0.45>"

        if type(args.lines) == "table" then
            for idx, line in ipairs(args.lines) do
                local prefix = (idx == 1) and ("[" .. sender .. "] ") or ""
                showOverheadText(player, prefix .. tostring(line), isAlert)
                appendToChatWindow(sender, tostring(line), colorTag)
            end
        elseif args.text then
            showOverheadText(player, "[" .. sender .. "] " .. tostring(args.text), isAlert)
            appendToChatWindow(sender, tostring(args.text), colorTag)
        end

    elseif command == "teammateRadio" then
        if args.senderUsername and player:getUsername() == args.senderUsername then
            return
        end
        local freq = tonumber(args.freq) or AIDirectorConfig.RADIO_FREQ
        local mhzStr = string.format("%.1f MHz", freq / 1000.0)
        local senderName = tostring(args.senderUsername or "Survivor")
        local msgText = tostring(args.text or "")
        playSafeSound(player, "LightSwitch")
        showOverheadText(player, "[" .. senderName .. " -> " .. mhzStr .. "]: " .. msgText, false)
        appendToChatWindow(getText("UI_AIDirector_TeammatePrefix", senderName, mhzStr), msgText, "<RGB:0.55,0.9,1.0>")

    elseif command == "playAmbientSound" then
        if args.sound then
            playSafeSound(player, tostring(args.sound))
        end
        if args.notice and tostring(args.notice) ~= "" then
            showOverheadText(player, tostring(args.notice), args.is_alert == true)
            appendToChatWindow(getText("UI_AIDirector_EventPrefix"), tostring(args.notice), "<RGB:1.0,0.75,0.3>")
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= AIDirectorConfig.NET_MODULE then return end
    AIDirectorClient.onServerMessage(command, args)
end

local function onClientGameStart()
    installChatHook()
    pcall(function()
        if getCore and getCore():getOptionPauseOnFocusloss() then
            getCore():setOptionPauseOnFocusloss(false)
            getCore():saveOptions()
            print("[AIDirector] Disabled PauseOnFocusloss to keep live MCP link smooth during Alt+Tab")
        end
    end)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldContextMenu)
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryContextMenu)
Events.OnServerCommand.Add(onServerCommand)
Events.OnGameStart.Add(onClientGameStart)

return AIDirectorClient
