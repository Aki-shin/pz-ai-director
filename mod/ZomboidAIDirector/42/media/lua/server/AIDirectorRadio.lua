if isClient() then return end

require "radio/ISDynamicRadio"
require "AIDirectorConfig"

AIDirectorRadio = AIDirectorRadio or {}

local function registerAIDirectorChannel()
    if not DynamicRadio or not DynamicRadio.channels then
        return
    end
    for _, ch in ipairs(DynamicRadio.channels) do
        if ch.uuid == AIDirectorConfig.RADIO_UUID then
            return
        end
    end
    table.insert(DynamicRadio.channels, {
        name = AIDirectorConfig.RADIO_NAME,
        freq = AIDirectorConfig.RADIO_FREQ,
        category = AIDirectorConfig.RADIO_CATEGORY,
        uuid = AIDirectorConfig.RADIO_UUID,
        register = true,
        airCounterMultiplier = 1.0,
    })
    print("[AIDirector] Registered DynamicRadio channel: " .. tostring(AIDirectorConfig.RADIO_NAME) .. " (" .. tostring(AIDirectorConfig.RADIO_FREQ) .. ")")
end

registerAIDirectorChannel()

function AIDirectorRadio.getChannel(freqOverride)
    if DynamicRadio and DynamicRadio.cache and DynamicRadio.cache[AIDirectorConfig.RADIO_UUID] then
        local ch = DynamicRadio.cache[AIDirectorConfig.RADIO_UUID]
        if not freqOverride or freqOverride == AIDirectorConfig.RADIO_FREQ then
            return ch
        end
    end
    local targetFreq = tonumber(freqOverride) or AIDirectorConfig.RADIO_FREQ
    local zRadio = getZomboidRadio and getZomboidRadio() or nil
    if zRadio and zRadio.getScriptManager then
        local sm = zRadio:getScriptManager()
        if sm and sm.getChannelsList then
            local list = sm:getChannelsList()
            if list then
                for i = 0, list:size() - 1 do
                    local ch = list:get(i)
                    if ch and ch:GetFrequency() == targetFreq then
                        return ch
                    end
                end
            end
        end
    end
    if DynamicRadio and DynamicRadio.cache then
        return DynamicRadio.cache[AIDirectorConfig.RADIO_UUID]
    end
    return nil
end

function AIDirectorRadio.broadcastLines(lines, r, g, b, freqOverride, addStatic)
    local ch = AIDirectorRadio.getChannel(freqOverride)
    if not ch then
        print("[AIDirector] Warning: DynamicRadio channel not ready yet for broadcast")
        return false
    end
    local cr = tonumber(r) or 0.35
    local cg = tonumber(g) or 1.0
    local cb = tonumber(b) or 0.45
    local bc = RadioBroadCast.new("AIDIR-" .. tostring(ZombRand(100000, 999999)), -1, -1)
    if addStatic ~= false then
        bc:AddRadioLine(RadioLine.new("<bzzt>", 0.75, 0.85, 0.75))
    end
    for _, line in ipairs(lines) do
        if line and tostring(line) ~= "" then
            bc:AddRadioLine(RadioLine.new(tostring(line), cr, cg, cb))
        end
    end
    if addStatic ~= false then
        bc:AddRadioLine(RadioLine.new("<fzzt>", 0.75, 0.85, 0.75))
    end
    ch:setAiringBroadcast(bc)
    return true
end

return AIDirectorRadio
