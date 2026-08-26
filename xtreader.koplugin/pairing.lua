--[[
Pairing — OAuth 2.0 Device Authorization Grant (RFC 8628).

The reader never types a password. It asks the server for a code, shows the
short half on screen, and polls until the account owner approves it in a
browser.

Two codes exist and conflating them is the mistake to avoid: `userCode` is the
one shown and therefore photographable, and it only authorises. `deviceCode` is
never displayed and is what actually redeems the token. This file keeps the
device code in a local, never puts it in a widget, and drops it the moment the
grant resolves.

Polling runs on UIManager's scheduler rather than inside a Trapper coroutine.
The interval is 15 seconds and a grant lives for five minutes, so a blocking
sleep would freeze the UI for the entire pairing.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Pairing = {}

local MAX_ATTEMPTS = 40 -- 40 * >=15s comfortably outlives the 5 minute grant

--- Mirrors the provisioned KOSync credential into the kosync plugin's own
--- settings, so "scan the code and both syncs work" needs no second step.
--
-- `checksum_method` matters more than it looks. The server matches progress on
-- a document id that is either a partial MD5 of the content or an MD5 of the
-- bare filename, and a mismatch does not error — it makes sync appear to do
-- nothing at all, which is the worst way for this to fail.
--
-- BINARY is correct, and the reasons are the CrossPoint firmware's own
-- (SyncPairingActivity.cpp:230 and main.cpp:1552 both force it immediately
-- after provisioning the credential):
--
--   * it survives a rename. When the server moves a book to a new path this
--     plugin renames the local file to match; under FILENAME that silently
--     becomes a different document and the reading position is lost — the very
--     bug stable ids exist to prevent.
--   * it is stock KOReader's own default, so a plain KOReader client sharing
--     the account needs no configuration at all.
--
-- It also collapses an identity problem that looked much worse than it is.
-- `partial_md5_checksum` has exactly ONE writer in all of KOReader
-- (readerui.lua:497-501 — `util.partialMD5` computed once, cached in the
-- sidecar). KOSync in binary mode reads that key (kosync.koplugin/main.lua:675)
-- and so does the statistics plugin for its `book.md5` column
-- (statistics.koplugin/main.lua:2737). Reading progress and reading statistics
-- are therefore keyed on the same stored string — not two computations that
-- happen to agree, but literally one value read twice.
local function configureKosync(store, ui)
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")

    local username = store:get("kosync_username")
    local key = store:get("kosync_key")
    if not username or not key then
        return false, "no provisioned credential"
    end

    -- Writing only the credentials is not enough, and the gap is silent.
    -- `auto_sync` defaults to FALSE in kosync (main.lua:61, with a comment
    -- explaining the caution: wifi may not be on at all times). A device
    -- configured with a server and a login but without it stores its position
    -- locally and never sends it — sync looks configured, nothing ever syncs,
    -- and no screen says so.
    --
    -- The whole promise of pairing here is "scan the code and both readers
    -- share a position", so this turns it on. The caution behind kosync's
    -- default does not apply the same way: this plugin already routes every
    -- network call through NetworkMgr:runWhenOnline, and the reader is a
    -- Wi-Fi-connected device that was just paired over the network.
    --
    -- The two SYNC_STRATEGY values are kosync's own defaults, written out
    -- explicitly rather than left absent. `readSetting("settings", …)` returns
    -- the stored table when one exists, so a key we omit is nil rather than
    -- defaulted, and nil is not the same as PROMPT.
    local values = {
        custom_server = store:get("base_url"),
        username = username,
        userkey = key,
        checksum_method = 0, -- CHECKSUM_METHOD.BINARY — see the note above
        auto_sync = true,
        sync_forward = 1, -- SYNC_STRATEGY.PROMPT — ask before jumping ahead
        -- PROMPT rather than DISABLE. The dangerous case is reading offline past
        -- a position the server still holds — coming back online must not drag
        -- you backwards. DISABLE prevents that by never asking, but it also
        -- makes a genuine "I want to go back to where my other reader is"
        -- impossible. Asking covers both: the rewind never happens without a
        -- deliberate tap.
        sync_backward = 1, -- SYNC_STRATEGY.PROMPT
        -- Costs nothing on the wire and gives the server a filename, title and
        -- author to show next to a position instead of a bare hash.
        send_metadata = true,
    }

    -- kosync refuses to auto-sync unless this is exactly "turn_on"
    -- (kosync.koplugin/main.lua:102-105): it flips `auto_sync` back to false at
    -- load time and logs a warning nobody sees. So writing `auto_sync = true`
    -- without this is writing a setting that gets undone every boot.
    --
    -- This is a GLOBAL KOReader preference, not a plugin one — it makes every
    -- network action bring Wi-Fi up instead of prompting. kosync itself
    -- recommends it (its own menu comment at :1066 calls the prompt path "not
    -- practical (or even plain usable) here"), and without it none of the
    -- open-a-book-and-be-asked behaviour works at all.
    G_reader_settings:saveSetting("wifi_enable_action", "turn_on")

    local obj = LuaSettings:open(DataStorage:getSettingsDir() .. "/kosync.lua")
    local settings = obj:readSetting("settings", {})
    for k, v in pairs(values) do
        settings[k] = v
    end
    obj:saveSetting("settings", settings)
    obj:flush()

    -- The file is written; making it take effect is the awkward part, and
    -- kosync's own shape is why.
    --
    -- `kosync.koplugin` is `is_doc_only = true`, so it is simply not loaded
    -- while the file manager is up — which is exactly where someone would be
    -- standing when they use this menu. So `ui.kosync` being nil is the NORMAL
    -- case here, not a failure, and telling the user to restart because of it
    -- would be advice that fixes nothing.
    local live = ui and ui.kosync
    if live and type(live.settings) == "table" then
        for k, v in pairs(values) do
            live.settings[k] = v
        end
        live.updated = true
        return true, nil, "applied_live"
    end

    -- Not loaded right now, so it will read the file when a book is next
    -- opened — with one catch. `KOSync.settings_obj` is a CLASS field
    -- (kosync.koplugin/main.lua:70-73), so once any document has been opened in
    -- this KOReader session the file handle is cached on the class and our
    -- write would be clobbered by its next flush. Clearing it forces a fresh
    -- read. PluginLoader.enabled_plugins holds the plugin module tables
    -- themselves, each tagged with `.name` (pluginloader.lua:249, :264), which
    -- is the only handle on that class from outside.
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and PluginLoader and type(PluginLoader.enabled_plugins) == "table" then
        for _i, plugin in ipairs(PluginLoader.enabled_plugins) do
            if plugin.name == "kosync" then
                plugin.settings_obj = nil
                break
            end
        end
    end
    return true, nil, "applies_on_next_book"
end

--- Starts a pairing session. `on_done(ok, message)` is called exactly once.
function Pairing.start(api, store, ui, on_done)
    -- `deviceLabel` is what the owner sees in the device list, so it should say
    -- what the hardware actually is rather than what this plugin was first
    -- written on. `deviceKind` is a different thing entirely — it names a panel
    -- so a wallpaper can be rendered for it, and it is the only field here that
    -- is allowed to be a hardware identity.
    local Device = require("device")
    local label = (type(Device.model) == "string" and Device.model ~= "" and Device.model)
                  or "KOReader"

    local grant, code, err = api:postJson("/device/code", {
        deviceLabel = label,
        deviceKind = store.DEVICE_KIND,
    }, { anonymous = true })

    if not grant then
        return on_done(false, T(_("Could not reach the server (%1)."), tostring(code)))
    end
    if not grant.deviceCode or not grant.userCode then
        return on_done(false, _("The server returned an unusable pairing grant."))
    end

    local device_code = grant.deviceCode
    local interval = tonumber(grant.interval) or 15
    local attempts = 0

    -- The QR carries `verificationUriComplete` — the link with the code already
    -- in it — so scanning is the whole interaction. `userCode` is printed under
    -- it for when the screen is too dim to scan.
    local QRPair = require("qrpair")
    local prompt = QRPair:new({
        url = grant.verificationUriComplete
              or (grant.verificationUri or store:get("base_url") .. "/link"),
        code = grant.userCode,
        prompt = _("Scan this with your phone to approve this reader"),
        hint = T(_("Or open %1 and enter the code.\nTap anywhere to hide — pairing keeps running."),
                 grant.verificationUri or store:get("base_url") .. "/link"),
    })
    UIManager:show(prompt)

    -- Closing an already-closed widget is a no-op, so this is safe whether the
    -- reader tapped the QR away or left it up.
    local closePrompt = function()
        prompt.dismiss_callback = nil
        UIManager:close(prompt)
    end

    local poll
    poll = function()
        attempts = attempts + 1
        if attempts > MAX_ATTEMPTS then
            closePrompt()
            return on_done(false, _("The pairing code expired. Try again."))
        end

        local token, http_code, body = api:postJson("/device/token", {
            deviceCode = device_code,
        }, { anonymous = true })

        if token and token.accessToken then
            store:set("access_token", token.accessToken)
            store:set("device_id", token.deviceId)
            store:set("device_name", token.deviceName)
            if type(token.kosync) == "table" then
                store:set("kosync_username", token.kosync.username)
                store:set("kosync_key", token.kosync.key)
            end
            store:flush()

            -- The server echoes back the kind it recorded. If it disagrees with
            -- what we asked for, every wallpaper attach later would 409, so say
            -- so now rather than at the first confusing sync.
            if token.deviceKind and token.deviceKind ~= store.DEVICE_KIND then
                logger.warn("xtreader: server recorded deviceKind", token.deviceKind,
                            "but this build is", store.DEVICE_KIND)
            end

            local ok_ks, ks_err, hint = configureKosync(store, ui)
            closePrompt()
            if not ok_ks then
                return on_done(true, T(_("Paired as %1.\nProgress sync not configured: %2"),
                                       token.deviceName or "?", tostring(ks_err)))
            end
            if hint == "applies_on_next_book" then
                return on_done(true, T(_("Paired as %1.\nProgress sync is configured; it starts working when you next open a book."),
                                       token.deviceName or "?"))
            end
            return on_done(true, T(_("Paired as %1.\nProgress sync is configured."),
                                   token.deviceName or "?"))
        end

        -- RFC 8628 keeps the waiting states in a 400 with an `error` field.
        local reason = type(body) == "table" and body.error or nil
        if reason == "authorization_pending" then
            UIManager:scheduleIn(interval, poll)
        elseif reason == "slow_down" then
            interval = interval + 5
            UIManager:scheduleIn(interval, poll)
        elseif reason == "access_denied" then
            closePrompt()
            on_done(false, _("The account owner refused this device."))
        elseif reason == "expired_token" then
            closePrompt()
            on_done(false, _("The pairing code expired. Try again."))
        else
            -- A transport failure is not a verdict on the grant, so keep going;
            -- the grant's own five minute life is the real deadline.
            logger.warn("xtreader: pairing poll failed:", tostring(http_code))
            UIManager:scheduleIn(interval, poll)
        end
    end

    UIManager:scheduleIn(interval, poll)
end

Pairing.configureKosync = configureKosync

return Pairing
