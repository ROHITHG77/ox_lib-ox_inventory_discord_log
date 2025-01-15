local buffer = {}
local bufferSize = 0
local MAX_EMBEDS_PER_REQUEST = 10
local BATCH_INTERVAL = 1000

local function removeColorCodes(str)
    str = string.gsub(str, "%^%d", "")
    str = string.gsub(str, "%^#[%dA-Fa-f]+", "")
    str = string.gsub(str, "~[%a]~", "")
    return str
end

local hostname = removeColorCodes(GetConvar('sv_projectName', 'fxserver'))

local function badResponse(endpoint, status, response)
    warn(('Unable to submit logs to Discord webhook (status: %s)\n%s'):format(status, json.encode(response, { indent = true })))
end

local playerData = {}

AddEventHandler('playerDropped', function()
    playerData[source] = nil
end)

local function formatPlayerInfo(source)
    if type(source) == 'number' and source > 0 then
        local data = playerData[source]

        if not data then
            local identifiers = {}
            local playerName = GetPlayerName(source)

            for i = 0, GetNumPlayerIdentifiers(source) - 1 do
                local identifier = GetPlayerIdentifier(source, i)
                if not identifier:find('ip') then
                    table.insert(identifiers, identifier)
                end
            end

            data = {
                name = playerName,
                identifiers = identifiers
            }
            playerData[source] = data
        end

        return data
    end
    return nil
end

local webhookUrl = GetConvar('discord:webhook', '')

if webhookUrl ~= '' then
    local function processBuffer()
        if bufferSize == 0 then return end

        local totalEmbeds = {}
        local currentBatch = {}
        local batchSize = 0

        for _, logEntry in ipairs(buffer) do
            local playerInfo = logEntry.playerInfo
            local embedFields = {}
            
            if playerInfo then
                table.insert(embedFields, {
                    name = "Player",
                    value = playerInfo.name,
                    inline = true
                })
                
                if #playerInfo.identifiers > 0 then
                    table.insert(embedFields, {
                        name = "Identifiers",
                        value = "```\n" .. table.concat(playerInfo.identifiers, "\n") .. "\n```",
                        inline = false
                    })
                end
            end

            table.insert(embedFields, {
                name = "Event",
                value = logEntry.event,
                inline = true
            })

            table.insert(embedFields, {
                name = "Resource",
                value = logEntry.resource,
                inline = true
            })

            local embed = {
                title = hostname,
                description = logEntry.message,
                fields = embedFields,
                color = 3447003,
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
            }
            
            table.insert(totalEmbeds, embed)
        end

        for i, embed in ipairs(totalEmbeds) do
            table.insert(currentBatch, embed)
            batchSize = batchSize + 1

            if batchSize >= MAX_EMBEDS_PER_REQUEST or i == #totalEmbeds then
                local payload = { embeds = currentBatch }

                PerformHttpRequest(webhookUrl, function(status, _, _, response)
                    if status ~= 204 and status ~= 200 then
                        if type(response) == 'string' then
                            response = json.decode(response) or response
                            badResponse(webhookUrl, status, response)
                        end
                    end
                end, 'POST', json.encode(payload), {['Content-Type'] = 'application/json'})

                currentBatch = {}
                batchSize = 0
                Wait(100)
            end
        end

        buffer = {}
        bufferSize = 0
    end

    function lib.logger(source, event, message, ...)
        if not buffer[1] then
            SetTimeout(BATCH_INTERVAL, processBuffer)
        end

        bufferSize += 1
        buffer[bufferSize] = {
            message = message,
            event = event,
            resource = cache.resource,
            playerInfo = formatPlayerInfo(source),
            extraTags = ... and string.strjoin(',', string.tostringall(...)) or nil
        }
    end
end

return lib.logger
