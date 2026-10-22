--- Minimal JSON decoder, for mod manifests (`<mod>/<Name>.json`, the Steamodded format).
---
--- Decodes objects, arrays, strings (with the standard escapes, `\uXXXX` included), numbers,
--- `true`, `false` and `null`. Raises a readable error with the byte offset on bad input, so a
--- malformed manifest reports where it broke rather than just that it did. `null` decodes to
--- nil, which drops the key -- a manifest field that is null is a field that is absent.

local Json = {}

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8_char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    return string.char(0xE0 + math.floor(code / 0x1000),
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function fail(str, pos, msg)
    local line = 1
    for _ in str:sub(1, pos):gmatch("\n") do line = line + 1 end
    error(("json: %s at line %d (byte %d)"):format(msg, line, pos), 0)
end

local function skip(str, pos)
    return str:find("[^ \t\r\n]", pos) or #str + 1
end

local decode_value

local function decode_string(str, pos)
    local out, i = {}, pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then fail(str, pos, "unterminated string") end
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local e = str:sub(i + 1, i + 1)
            if e == "u" then
                local hex = str:sub(i + 2, i + 5)
                if not hex:match("^%x%x%x%x$") then fail(str, i, "bad \\u escape") end
                out[#out + 1] = utf8_char(tonumber(hex, 16))
                i = i + 6
            elseif escapes[e] then
                out[#out + 1] = escapes[e]
                i = i + 2
            else
                fail(str, i, "bad escape")
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

local function decode_array(str, pos)
    local out, n = {}, 0
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "]" then return out, pos + 1 end
    while true do
        local v
        v, pos = decode_value(str, pos)
        n = n + 1
        out[n] = v
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == "]" then return out, pos + 1 end
        if c ~= "," then fail(str, pos, "expected ',' or ']'") end
        pos = skip(str, pos + 1)
    end
end

local function decode_object(str, pos)
    local out = {}
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "}" then return out, pos + 1 end
    while true do
        if str:sub(pos, pos) ~= '"' then fail(str, pos, "expected a key") end
        local key
        key, pos = decode_string(str, pos)
        pos = skip(str, pos)
        if str:sub(pos, pos) ~= ":" then fail(str, pos, "expected ':'") end
        local v
        v, pos = decode_value(str, skip(str, pos + 1))
        out[key] = v
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == "}" then return out, pos + 1 end
        if c ~= "," then fail(str, pos, "expected ',' or '}'") end
        pos = skip(str, pos + 1)
    end
end

decode_value = function(str, pos)
    pos = skip(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then return decode_object(str, pos) end
    if c == "[" then return decode_array(str, pos) end
    if c == '"' then return decode_string(str, pos) end
    if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
    if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
    if str:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if num and num ~= "" and tonumber(num) then return tonumber(num), pos + #num end
    fail(str, pos, "unexpected '" .. c .. "'")
end

--- @param str string
--- @return any value
function Json.decode(str)
    if type(str) ~= "string" then error("json: expected a string", 0) end
    -- A UTF-8 byte-order mark is what Windows editors put at the front of a saved file.
    if str:sub(1, 3) == "\239\187\191" then str = str:sub(4) end
    local value, pos = decode_value(str, 1)
    pos = skip(str, pos)
    if pos <= #str then fail(str, pos, "trailing characters") end
    return value
end

return Json
