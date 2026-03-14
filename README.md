# Discord Webhook Logger for ox_lib

A modified `server.lua` for ox_lib that adds Discord webhook support to the existing logger system.

## Installation

Replace `ox_lib/imports/logger/server.lua` with this file.

## Configuration

Add the following to your `server.cfg`:

```
set ox:logger "discord"
set discord:webhook "YOUR_WEBHOOK_URL"
```

## Available Logging Services

| Service | Convar |
|---------|--------|
| discord | `set ox:logger "discord"` + `set discord:webhook "URL"` |
| datadog | `set ox:logger "datadog"` + `set datadog:key "KEY"` |
| fivemanage | `set ox:logger "fivemanage"` + `set fivemanage:key "KEY"` |
| loki | `set ox:logger "loki"` + `set loki:endpoint "URL"` |

## Contact

rgxprime (Discord)
