-- Pure-Lua JSON encoder/decoder tailored for Project Zomboid's Kahlua2 VM (JVM UTF-16 strings).
-- Preserves non-ASCII characters (such as Cyrillic) directly so Java's UTF-8 FileReader/FileWriter
-- handles them natively without byte-splitting corruption.

AIDirectorJson = AIDirectorJson or {}

local function escapeStr(s)
    local out = {}
    local len = string.len(s)
    for i = 1, len do
        local c = string.sub(s, i, i)
        local b = string.byte(s, i)
        if c == '"' then
            table.insert(out, '\\"')
        elseif c == '\\' then
            table.insert(out, '\\\\')
        elseif c == '\b' then
            table.insert(out, '\\b')
        elseif c == '\f' then
            table.insert(out, '\\f')
        elseif c == '\n' then
            table.insert(out, '\\n')
        elseif c == '\r' then
            table.insert(out, '\\r')
        elseif c == '\t' then
            table.insert(out, '\\t')
        elseif b and b < 32 then
            table.insert(out, string.format("\\u%04x", b))
        else
            table.insert(out, c)
        end
    end
    return table.concat(out)
end

local function isArrayTable(t)
    if t.__is_array then
        return true
    end
    local count = 0
    local maxIdx = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            return false
        end
        if k > maxIdx then
            maxIdx = k
        end
        count = count + 1
    end
    if count == 0 then
        return false
    end
    return maxIdx == count
end

function AIDirectorJson.array(list)
    local t = list or {}
    setmetatable(t, { __index = { __is_array = true } })
    return t
end

function AIDirectorJson.encode(val)
    local vtype = type(val)
    if val == nil then
        return "null"
    elseif vtype == "boolean" then
        return val and "true" or "false"
    elseif vtype == "number" then
        if val ~= val or val >= math.huge or val <= -math.huge then
            return "0"
        end
        if math.floor(val) == val and val >= -2147483648 and val <= 2147483647 then
            return string.format("%d", val)
        end
        return tostring(val)
    elseif vtype == "string" then
        return '"' .. escapeStr(val) .. '"'
    elseif vtype == "table" then
        if isArrayTable(val) then
            local items = {}
            local n = #val
            for i = 1, n do
                table.insert(items, AIDirectorJson.encode(val[i]))
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            local items = {}
            for k, v in pairs(val) do
                if k ~= "__is_array" and type(v) ~= "function" and type(v) ~= "userdata" then
                    local keyStr = tostring(k)
                    table.insert(items, '"' .. escapeStr(keyStr) .. '":' .. AIDirectorJson.encode(v))
                end
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    end
    return '"' .. escapeStr(tostring(val)) .. '"'
end

local function skipWhitespace(str, idx, len)
    while idx <= len do
        local c = string.sub(str, idx, idx)
        if c == " " or c == "\t" or c == "\r" or c == "\n" then
            idx = idx + 1
        else
            break
        end
    end
    return idx
end

local parseValue

local function parseString(str, idx, len)
    idx = idx + 1 -- skip opening quote
    local out = {}
    while idx <= len do
        local c = string.sub(str, idx, idx)
        if c == '"' then
            return table.concat(out), idx + 1
        elseif c == '\\' then
            idx = idx + 1
            if idx > len then
                error("JSON decode: unterminated escape sequence")
            end
            local esc = string.sub(str, idx, idx)
            if esc == '"' or esc == '\\' or esc == '/' then
                table.insert(out, esc)
                idx = idx + 1
            elseif esc == 'b' then
                table.insert(out, '\b')
                idx = idx + 1
            elseif esc == 'f' then
                table.insert(out, '\f')
                idx = idx + 1
            elseif esc == 'n' then
                table.insert(out, '\n')
                idx = idx + 1
            elseif esc == 'r' then
                table.insert(out, '\r')
                idx = idx + 1
            elseif esc == 't' then
                table.insert(out, '\t')
                idx = idx + 1
            elseif esc == 'u' then
                local hex = string.sub(str, idx + 1, idx + 4)
                local code = tonumber(hex, 16)
                if not code then
                    error("JSON decode: invalid \\u escape: " .. tostring(hex))
                end
                table.insert(out, string.char(code))
                idx = idx + 5
            else
                table.insert(out, esc)
                idx = idx + 1
            end
        else
            table.insert(out, c)
            idx = idx + 1
        end
    end
    error("JSON decode: unterminated string")
end

local function parseNumber(str, idx, len)
    local startIdx = idx
    while idx <= len do
        local c = string.sub(str, idx, idx)
        if (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E' then
            idx = idx + 1
        else
            break
        end
    end
    local numStr = string.sub(str, startIdx, idx - 1)
    local n = tonumber(numStr)
    if n == nil then
        error("JSON decode: invalid number: " .. tostring(numStr))
    end
    return n, idx
end

local function parseArray(str, idx, len)
    idx = idx + 1 -- skip '['
    local arr = {}
    idx = skipWhitespace(str, idx, len)
    if idx <= len and string.sub(str, idx, idx) == ']' then
        return arr, idx + 1
    end
    local i = 1
    while idx <= len do
        local val
        val, idx = parseValue(str, idx, len)
        arr[i] = val
        i = i + 1
        idx = skipWhitespace(str, idx, len)
        local c = string.sub(str, idx, idx)
        if c == ']' then
            return arr, idx + 1
        elseif c == ',' then
            idx = skipWhitespace(str, idx + 1, len)
        else
            error("JSON decode: expected ',' or ']' at position " .. tostring(idx))
        end
    end
    error("JSON decode: unterminated array")
end

local function parseObject(str, idx, len)
    idx = idx + 1 -- skip '{'
    local obj = {}
    idx = skipWhitespace(str, idx, len)
    if idx <= len and string.sub(str, idx, idx) == '}' then
        return obj, idx + 1
    end
    while idx <= len do
        if string.sub(str, idx, idx) ~= '"' then
            error("JSON decode: expected string key at position " .. tostring(idx))
        end
        local key
        key, idx = parseString(str, idx, len)
        idx = skipWhitespace(str, idx, len)
        if string.sub(str, idx, idx) ~= ':' then
            error("JSON decode: expected ':' at position " .. tostring(idx))
        end
        idx = skipWhitespace(str, idx + 1, len)
        local val
        val, idx = parseValue(str, idx, len)
        obj[key] = val
        idx = skipWhitespace(str, idx, len)
        local c = string.sub(str, idx, idx)
        if c == '}' then
            return obj, idx + 1
        elseif c == ',' then
            idx = skipWhitespace(str, idx + 1, len)
        else
            error("JSON decode: expected ',' or '}' at position " .. tostring(idx))
        end
    end
    error("JSON decode: unterminated object")
end

parseValue = function(str, idx, len)
    idx = skipWhitespace(str, idx, len)
    if idx > len then
        error("JSON decode: unexpected end of input")
    end
    local c = string.sub(str, idx, idx)
    if c == '"' then
        return parseString(str, idx, len)
    elseif c == '{' then
        return parseObject(str, idx, len)
    elseif c == '[' then
        return parseArray(str, idx, len)
    elseif c == 't' and string.sub(str, idx, idx + 3) == "true" then
        return true, idx + 4
    elseif c == 'f' and string.sub(str, idx, idx + 4) == "false" then
        return false, idx + 5
    elseif c == 'n' and string.sub(str, idx, idx + 3) == "null" then
        return nil, idx + 4
    elseif c == '-' or (c >= '0' and c <= '9') then
        return parseNumber(str, idx, len)
    end
    error("JSON decode: unexpected token '" .. tostring(c) .. "' at position " .. tostring(idx))
end

function AIDirectorJson.decode(str)
    if type(str) ~= "string" then
        error("JSON decode: expected string, got " .. type(str))
    end
    local len = string.len(str)
    local val, _ = parseValue(str, 1, len)
    return val
end

return AIDirectorJson
