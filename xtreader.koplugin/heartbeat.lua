--[[
Telemetry.

The point of this route on the X4 is that the person reading cannot describe a
fault, so the device speaks for them. A KOReader client is less mute than that,
but the value is the same: one dashboard showing every reader on the account,
its battery, its free space and whether its last sync worked.

Every field except `firmwareVersion` is optional, and an omitted field leaves
the stored value alone rather than clearing it. So anything we cannot determine
is simply left out — never guessed, never sent as zero.

The response carries `wallpaperRevision`, an opaque fingerprint of the wallpaper
set currently assigned to this device. It is compared for equality and nothing
else: never ordered, never parsed, never assumed to increase. A real revision is
never 0, which leaves 0 free as "unknown" and inert in both directions.
]]

local Device = require("device")
local logger = require("logger")

local Heartbeat = {}

local function batteryPercent()
    local ok, powerd = pcall(function() return Device:getPowerDevice() end)
    if not ok or not powerd then
        return nil
    end
    local ok2, capacity = pcall(function() return powerd:getCapacity() end)
    if ok2 and type(capacity) == "number" and capacity >= 0 and capacity <= 100 then
        return capacity
    end
    return nil
end

local function firmwareVersion()
    local ok, Version = pcall(require, "version")
    if ok and Version and Version.getCurrentRevision then
        local ok2, rev = pcall(Version.getCurrentRevision, Version)
        if ok2 and type(rev) == "string" and rev ~= "" then
            return "koreader-" .. rev
        end
    end
    return "koreader-unknown"
end

--- Free and total bytes of the volume holding `path`.
-- There is no filesystem-statistics binding to rely on here, so this shells out
-- to df, which busybox provides on every device KOReader ships for. Both values
-- are dropped together on failure: free space without a denominator cannot draw
-- a usage bar.
local function diskBytes(path)
    if type(path) ~= "string" or path == "" then
        return nil, nil
    end
    -- The folder is user-editable from the plugin's own menu, so it is quoted
    -- rather than interpolated bare into a shell command.
    local quoted = "'" .. path:gsub("'", "'\\''") .. "'"
    local ok, pipe = pcall(io.popen, "df -k " .. quoted .. " 2>/dev/null")
    if not ok or not pipe then
        return nil, nil
    end
    local out = pipe:read("*a")
    pipe:close()
    if type(out) ~= "string" then
        return nil, nil
    end
    -- Skip the header, then take 1K-blocks total and available.
    local total_k, _used, avail_k = out:match("\n%S+%s+(%d+)%s+(%d+)%s+(%d+)")
    if not total_k or not avail_k then
        return nil, nil
    end
    return tonumber(total_k) * 1024, tonumber(avail_k) * 1024
end

--- Sends one heartbeat. Returns the server's `wallpaperRevision`, or nil.
function Heartbeat.send(api, store, last_sync_status)
    if not store:isPaired() then
        return nil
    end

    local total, free = diskBytes(store:get("library_dir"))
    local payload = {
        firmwareVersion = firmwareVersion(),
        batteryPercent = batteryPercent(),
        sdTotalBytes = total,
        sdFreeBytes = free,
        lastSyncStatus = last_sync_status, -- "ok" | "failed" | "never", or nil
    }

    local body, code = api:postJson("/devices/heartbeat", payload)
    if not body then
        logger.dbg("xtreader: heartbeat failed:", tostring(code))
        return nil
    end

    local revision = tonumber(body.wallpaperRevision)
    if revision == nil or revision == 0 then
        return nil
    end
    return revision
end

--- True when the wallpaper set changed since the sync we last ran.
-- 0 on either side means "unknown" and is never a reason to sync, and never a
-- reason to suppress one.
function Heartbeat.wallpapersChanged(store, revision)
    if revision == nil or revision == 0 then
        return false
    end
    local seen = store:get("wallpaper_revision")
    if seen == nil or seen == 0 then
        return true
    end
    return seen ~= revision
end

return Heartbeat
