local function parse_datetime_cached()
    local cache = {}
    return function(str)
        if type(str) ~= "string" then return 0 end
        if cache[str] then return cache[str] end
        local y, m, d, h, min, s = str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
        if not y then return 0 end
        local t = os.time{
            year = tonumber(y), month = tonumber(m), day = tonumber(d),
            hour = tonumber(h), min = tonumber(min), sec = tonumber(s),
        } or 0
        cache[str] = t
        return t
    end
end
local parse_datetime = parse_datetime_cached()

local function get_datetime(item)
    return item.datetime_updated or item.datetime
end

local function get_newer(item1, item2)
    local t1 = parse_datetime(get_datetime(item1))
    local t2 = parse_datetime(get_datetime(item2))
    return t1 >= t2 and item1 or item2
end

local function serialize_position(value)
    if type(value) ~= "table" then
        return tostring(value)
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. serialize_position(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Generate a stable key using pos0+pos1 (XPath positions) which are consistent
-- across devices regardless of font size, screen size, or page layout settings.
-- PDF positions are tables, so serialize their contents deterministically rather
-- than using tostring(table), which contains a device-local memory address.
-- Falls back to page + text hash for older annotations without position data.
local function generate_key(highlight)
    if highlight.pos0 and highlight.pos1 then
        return serialize_position(highlight.pos0) .. "|" .. serialize_position(highlight.pos1)
    end
    -- Fallback: use page + text hash for annotations without position data
    local text = highlight.text or ""
    local hash = tostring(#text) .. ":" .. (text:sub(1, 20) or "")
    return string.format("%s|%s", highlight.page or "?", hash)
end

local function convert_to_map(highlights)
    local map = {}
    for i = 1, #highlights do
        local h = highlights[i]
        map[generate_key(h)] = h
    end
    return map
end

local function merge_highlights(local_annotations, server_annotations, last_sync_annotations)
    local local_map = convert_to_map(local_annotations or {})
    local server_map = convert_to_map(server_annotations or {})
    local last_sync_map = convert_to_map(last_sync_annotations or {})

    local merged = {}

    -- Processa os highlights locais
    for key, local_highlight in pairs(local_map) do
        local server_highlight = server_map[key]
        local last_sync_highlight = last_sync_map[key]
        if not (server_highlight == nil and last_sync_highlight ~= nil) then
            merged[key] = local_highlight
        end
    end

    -- Processa highlights do servidor
    for key, server_highlight in pairs(server_map) do
        if last_sync_map[key] ~= nil and local_map[key] == nil then
            -- foi deletado localmente, ignorar
        else
            if not local_map[key] then
                merged[key] = server_highlight
            else
                merged[key] = get_newer(server_highlight, local_map[key])
            end
        end
    end

    -- Converte o resultado de volta para array
    local merged_annotations = {}
    for _, h in pairs(merged) do
        merged_annotations[#merged_annotations+1] = h
    end

    -- Ordenação simples por pageno e pos0
    table.sort(merged_annotations, function(a, b)
        if a.pageno ~= b.pageno then
            return (a.pageno or 0) < (b.pageno or 0)
        end
        if not a.pos0 then return true end
        if not b.pos0 then return false end

        -- Consider case where positions are tables
        -- with keys x, y, zoom, page, rotation,
        -- as is the case with pdf highlights
        if type(a.pos0) == "table" then
          if type(b.pos0) == "table" then
            local ay, by = a.pos0.y or 0, b.pos0.y or 0
            local ax, bx = a.pos0.x or 0, b.pos0.x or 0
            return ay < by or (ay == by and ax < bx)
          end
          -- Posistions can't be compared
          return false
        elseif type(b.pos0) == "table" then
          -- Posistions can't be compared
          return true
        end

        return a.pos0 < b.pos0
    end)

    return merged_annotations
end

local M = {}

M.Merge_highlights = merge_highlights

return M
