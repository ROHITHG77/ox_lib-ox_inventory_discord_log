--[[
    https://github.com/overextended/ox_lib

    This file is licensed under LGPL-3.0 or higher <https://www.gnu.org/licenses/lgpl-3.0.en.html>

    Copyright © 2025 Linden <https://github.com/thelindat>
]]

local service = GetConvar('ox:logger', 'datadog')
local buffer
local bufferSize = 0

local function removeColorCodes(str)
    str = string.gsub(str, "%^%d", "")
    str = string.gsub(str, "%^#[%dA-Fa-f]+", "")
    str = string.gsub(str, "~[%a]~", "")
    return str
end

local hostname = removeColorCodes(GetConvar('ox:logger:hostname', GetConvar('sv_projectName', 'fxserver')))

local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64encode(data)
    return ((data:gsub(".", function(x)
        local r, byte = "", x:byte()
        for i = 8, 1, -1 do
            r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do
            c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
        end
        return b:sub(c + 1, c + 1)
    end) .. ({"", "==", "="})[#data % 3 + 1])
end

local function getAuthorizationHeader(user, password)
    return "Basic " .. base64encode(user .. ":" .. password)
end

local function badResponse(endpoint, status, response)
    warn(('unable to submit logs to %s (status: %s)\n%s'):format(endpoint, status, json.encode(response, { indent = true })))
end

local playerData = {}
local identifierToSource = {}
local playerCache = {}

local function cachePlayerData(playerSource)
    if playerCache[playerSource] then return playerCache[playerSource] end

    local name = GetPlayerName(playerSource) or 'Unknown'
    local identifiers = {}

    for i = 0, GetNumPlayerIdentifiers(playerSource) - 1 do
        local identifier = GetPlayerIdentifier(playerSource, i)
        if identifier and not identifier:find('ip') then
            local idType, idValue = identifier:match('([^:]+):(.+)')
            if idType and idValue then
                identifiers[idType] = idValue
                identifierToSource[idValue] = playerSource
            end
        end
    end

    playerCache[playerSource] = {
        name = name,
        identifiers = identifiers
    }

    return playerCache[playerSource]
end

AddEventHandler('playerConnecting', function()
    cachePlayerData(source)
end)

AddEventHandler('playerDropped', function()
    local cached = playerCache[source]
    if cached then
        for _, idValue in pairs(cached.identifiers) do
            identifierToSource[idValue] = nil
        end
        playerCache[source] = nil
    end
    playerData[source] = nil
end)

local function getPlayerInfo(logSource)
    if type(logSource) == 'number' and logSource > 0 then
        local cached = cachePlayerData(logSource)
        return {
            id = logSource,
            name = cached.name,
            identifiers = cached.identifiers
        }
    elseif type(logSource) == 'string' then
        local idType, idValue = logSource:match('([^:]+):(.+)')
        if not idType or not idValue then
            return { id = nil, name = 'Unknown', identifiers = {} }
        end

        local playerId = identifierToSource[idValue]
        if playerId then
            local cached = cachePlayerData(playerId)
            return {
                id = playerId,
                name = cached.name,
                identifiers = cached.identifiers
            }
        end

        return {
            id = nil,
            name = 'Offline/Unknown',
            identifiers = { [idType] = idValue }
        }
    end

    return nil
end

local function formatTags(source, tags)
    if type(source) == 'number' and source > 0 then
        local data = playerData[source]

        if not data then
            local _data = { ('username:%s'):format(GetPlayerName(source)) }
            local num = 1

            for i = 0, GetNumPlayerIdentifiers(source) - 1 do
                local identifier = GetPlayerIdentifier(source, i)
                if identifier and not identifier:find('ip') then
                    num += 1
                    _data[num] = identifier
                end
            end

            data = table.concat(_data, ',')
            playerData[source] = data
        end

        tags = tags and ('%s,%s'):format(tags, data) or data
    end

    return tags
end

if service == 'discord' then
    local webhookUrl = GetConvar('discord:webhook', '')

    if webhookUrl ~= '' then
        local discordHeaders = { ['Content-Type'] = 'application/json' }

        local function sendToDiscord(embeds)
            PerformHttpRequest(webhookUrl, function(status, _, _, response)
                if status ~= 204 and status ~= 200 then
                    if type(response) == 'string' then
                        response = json.decode(response) or response
                        badResponse(webhookUrl, status, response)
                    end
                end
            end, 'POST', json.encode({ username = hostname, embeds = embeds }), discordHeaders)
        end

        function lib.logger(source, event, message, ...)
            if not buffer then
                buffer = {}
                SetTimeout(500, function()
                    sendToDiscord(buffer)
                    buffer = nil
                    bufferSize = 0
                end)
            end

            local playerInfo = getPlayerInfo(source)
            local fields = {
                { name = 'Event', value = event, inline = true },
                { name = 'Resource', value = cache.resource, inline = true }
            }

            if playerInfo then
                local playerName = playerInfo.id
                    and ('**%s** (ID: %d)'):format(playerInfo.name, playerInfo.id)
                    or playerInfo.name

                fields[#fields + 1] = { name = 'Owner', value = playerName, inline = false }

                local idParts = {}
                for idType, idValue in pairs(playerInfo.identifiers) do
                    idParts[#idParts + 1] = ('%s: %s'):format(idType, idValue)
                end

                if #idParts > 0 then
                    fields[#fields + 1] = { name = 'Identifiers', value = table.concat(idParts, '\n'), inline = false }
                end
            else
                fields[#fields + 1] = { name = 'Owner', value = source and tostring(source) or 'Server/System', inline = false }
            end

            local args = { ... }
            for _, arg in pairs(args) do
                if type(arg) == 'table' then
                    for k, v in pairs(arg) do
                        fields[#fields + 1] = { name = tostring(k), value = tostring(v), inline = true }
                    end
                elseif type(arg) == 'string' then
                    local key, value = string.strsplit(':', arg)
                    if key and value then
                        fields[#fields + 1] = { name = key, value = value, inline = true }
                    end
                end
            end

            bufferSize += 1
            buffer[bufferSize] = {
                title = message,
                color = 3447003,
                fields = fields,
                footer = { text = os.date('%Y-%m-%d %H:%M:%S') }
            }
        end
    end
end

if service == 'fivemanage' then
    local key = GetConvar('fivemanage:key', '')
    local dataset = GetConvar('fivemanage:dataset', '')

    if key ~= '' then
        local endpoint = 'https://api.fivemanage.com/api/logs/batch'
        local headers = {
            ['Content-Type'] = 'application/json',
            ['Authorization'] = key,
            ['User-Agent'] = 'ox_lib',
        }

        if dataset ~= "" then
            headers['X-Fivemanage-Dataset'] = dataset
        end

        function lib.logger(source, event, message, ...)
            if not buffer then
                buffer = {}
                SetTimeout(500, function()
                    PerformHttpRequest(endpoint, function(status, _, _, response)
                        if status ~= 200 then
                            if type(response) == 'string' then
                                response = json.decode(response) or response
                                badResponse(endpoint, status, response)
                            end
                        end
                    end, 'POST', json.encode(buffer), headers)
                    buffer = nil
                    bufferSize = 0
                end)
            end

            local metadata = {
                hostname = hostname,
                service = event,
                source = source,
            }

            local playerTags = formatTags(source, nil)
            if playerTags and type(playerTags) == 'string' then
                local tempTable = { string.strsplit(',', playerTags) }
                for _, v in pairs(tempTable) do
                    local key, value = string.strsplit(':', v)
                    if key and value then
                        metadata[key] = value
                    end
                end
            end

            local args = { ... }
            for _, arg in pairs(args) do
                if type(arg) == 'table' then
                    for k, v in pairs(arg) do
                        metadata[k] = v
                    end
                elseif type(arg) == 'string' then
                    local key, value = string.strsplit(':', arg)
                    if key and value then
                        metadata[key] = value
                    end
                end
            end

            bufferSize += 1
            buffer[bufferSize] = {
                level = "info",
                message = message,
                resource = cache.resource,
                metadata = metadata,
            }
        end
    end
end

if service == 'datadog' then
    local key = GetConvar('datadog:key', ''):gsub("[\'\"]", '')

    if key ~= '' then
        local endpoint = ('https://http-intake.logs.%s/api/v2/logs'):format(GetConvar('datadog:site', 'datadoghq.com'))
        local headers = {
            ['Content-Type'] = 'application/json',
            ['DD-API-KEY'] = key,
        }

        function lib.logger(source, event, message, ...)
            if not buffer then
                buffer = {}
                SetTimeout(500, function()
                    PerformHttpRequest(endpoint, function(status, _, _, response)
                        if status ~= 202 then
                            if type(response) == 'string' then
                                response = json.decode(response:sub(10)) or response
                                badResponse(endpoint, status, type(response) == 'table' and response.errors[1] or response)
                            end
                        end
                    end, 'POST', json.encode(buffer), headers)
                    buffer = nil
                    bufferSize = 0
                end)
            end

            bufferSize += 1
            buffer[bufferSize] = {
                hostname = hostname,
                service = event,
                message = message,
                resource = cache.resource,
                ddsource = tostring(source),
                ddtags = formatTags(source, ... and string.strjoin(',', string.tostringall(...)) or nil),
            }
        end
    end
end

if service == 'loki' then
    local lokiUser = GetConvar('loki:user', '')
    local lokiPassword = GetConvar('loki:password', GetConvar('loki:key', ''))
    local lokiEndpoint = GetConvar('loki:endpoint', '')
    local lokiTenant = GetConvar('loki:tenant', '')
    local headers = { ['Content-Type'] = 'application/json' }

    if lokiUser ~= '' then
        headers['Authorization'] = getAuthorizationHeader(lokiUser, lokiPassword)
    end

    if lokiTenant ~= '' then
        headers['X-Scope-OrgID'] = lokiTenant
    end

    if not lokiEndpoint:find('^http[s]?://') then
        lokiEndpoint = 'https://' .. lokiEndpoint
    end

    local endpoint = ('%s/loki/api/v1/push'):format(lokiEndpoint)

    local function convertDDTagsToKVP(tags)
        if not tags or type(tags) ~= 'string' then return {} end
        local tempTable = { string.strsplit(',', tags) }
        local result = table.create(0, #tempTable)
        for _, v in pairs(tempTable) do
            local key, value = string.strsplit(':', v)
            result[key] = value
        end
        return result
    end

    function lib.logger(source, event, message, ...)
        if not buffer then
            buffer = {}
            SetTimeout(500, function()
                local tempBuffer = {}
                for _, v in pairs(buffer) do
                    tempBuffer[#tempBuffer + 1] = v
                end
                PerformHttpRequest(endpoint, function(status, _, _, _)
                    if status ~= 204 then
                        badResponse(endpoint, status, tostring(status))
                    end
                end, 'POST', json.encode({ streams = tempBuffer }), headers)
                buffer = nil
            end)
        end

        local timestamp = ('%s000000000'):format(os.time(os.date('*t')))
        local values = { message = message }
        local tags = formatTags(source, ... and string.strjoin(',', string.tostringall(...)) or nil)
        local tagsTable = convertDDTagsToKVP(tags)

        for k, v in pairs(tagsTable) do
            values[k] = v
        end

        local payload = {
            stream = {
                server = hostname,
                resource = cache.resource,
                event = event
            },
            values = { { timestamp, json.encode(values) } }
        }

        if not buffer then buffer = {} end

        if not buffer[event] then
            buffer[event] = payload
        else
            local lastIndex = #buffer[event].values
            buffer[event].values[lastIndex + 1] = { timestamp, json.encode(values) }
        end
    end
end

return lib.logger
