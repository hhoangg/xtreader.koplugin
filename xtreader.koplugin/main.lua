--[[
xtreader — one account across every reader you own.

Four sync paths, three of which need no server change at all:

  * reading progress — KOReader's own kosync plugin, pointed at this server and
    configured with the credential provisioned at pairing. Wire-compatible by
    design, so nothing here reimplements it.
  * books           — GET /library/manifest, reconciled against disk
  * wallpapers      — GET /wallpapers/manifest, into the screensaver folder
  * telemetry       — POST /devices/heartbeat

Everything network-facing goes through NetworkMgr:runWhenOnline. One Kindle
caveat worth knowing: when liblipclua is missing, KOReader's Kindle backend
turns the radio on and calls the completion callback immediately rather than
waiting for an address, so the first request after a cold radio can fail. That
is not an error worth a dialog — it is a retry.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("api")
local Heartbeat = require("heartbeat")
local Insights = require("insights")
local Library = require("library")
local Pairing = require("pairing")
local Store = require("store")
local Wallpaper = require("wallpaper")

local Xtreader = WidgetContainer:extend({
    name = "xtreader",
    is_doc_only = false,
})

function Xtreader:onDispatcherRegisterActions()
    Dispatcher:registerAction("xtreader_sync", {
        category = "none",
        event = "XtreaderSync",
        title = _("xtreader: sync now"),
        general = true,
    })
end

function Xtreader:init()
    self.store = Store:open()
    self.api = Api.new(self.store)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Xtreader:onFlushSettings()
    if self.store and self.store.dirty then
        self.store:flush()
    end
end

local function notify(text, timeout)
    UIManager:show(InfoMessage:new({ text = text, timeout = timeout or 5 }))
end

--- Sends one heartbeat and returns the wallpaper fingerprint it came back with.
--
-- Called after every path that reaches the server, not just a full sync. The
-- dashboard's battery and card figures come from nowhere else, so a device that
-- only ever ran a partial sync would sit there reporting "Unknown" forever with
-- nothing on screen explaining why.
--
-- Returns the fingerprint and deliberately does NOT store it.
-- `wallpaper_revision` means "the set we last successfully synced against", not
-- "the last number the server said". Recording it here would mark the device up
-- to date before a single image had been downloaded, and the equality check
-- would then suppress every future wallpaper sync. Only wallpaper sync writes
-- that key, and only once it has actually run.
function Xtreader:beat(status)
    return Heartbeat.send(self.api, self.store, status)
end

--- Runs `fn(report)` inside a Trapper coroutine so the UI stays responsive and
--- the user can stop a long run by tapping the progress message.
-- `opts.beat` sends a heartbeat once `fn` is done; syncAll does its own, mid-run.
function Xtreader:runSync(fn, opts)
    opts = opts or {}
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            Trapper:setPausedText(_("Sync paused. Continue or abort?"))
            local report = function(text)
                return Trapper:info(text)
            end
            local ok, message = fn(report)
            if opts.beat then
                self:beat(ok and "ok" or "failed")
            end
            Trapper:clear()
            notify(message or (ok and _("Done.") or _("Failed.")), ok and 5 or 10)
        end)
    end)
end

function Xtreader:syncAll(report)
    local lines = {}
    local ok_books, books_msg = Library.sync(self.api, self.store, report)
    lines[#lines + 1] = books_msg

    -- The heartbeat rides a request we owe the server anyway, and its reply
    -- says whether the wallpaper set moved. Comparing the fingerprint saves a
    -- manifest round trip on the common no-change run.
    local revision = Heartbeat.send(self.api, self.store, ok_books and "ok" or "failed")
    if Heartbeat.wallpapersChanged(self.store, revision) then
        local ok_wp, wp_msg = Wallpaper.sync(self.api, self.store, report)
        lines[#lines + 1] = wp_msg
        -- Only a sync that actually succeeded may claim this fingerprint. A
        -- failed run that recorded it would leave the device permanently
        -- convinced it was up to date and stop trying.
        if ok_wp and revision then
            self.store:set("wallpaper_revision", revision)
        end
    else
        lines[#lines + 1] = _("Wallpapers already up to date.")
    end

    self.store:flush()
    return ok_books, table.concat(lines, "\n")
end

function Xtreader:pair()
    NetworkMgr:runWhenOnline(function()
        Pairing.start(self.api, self.store, self.ui, function(ok, message)
            if ok then
                -- Pairing is the first moment a device row exists, and the
                -- dashboard has nothing to show for it until a heartbeat
                -- arrives. Sending one here means the reader appears complete
                -- the moment it is approved, rather than after some later sync
                -- the owner has no reason to know they need to run.
                self:beat("never")
            end
            notify(message, ok and 8 or 10)
        end)
    end)
end

function Xtreader:unpair()
    UIManager:show(ConfirmBox:new({
        text = _("Forget this server?\n\nBooks already downloaded stay on the device. Progress sync stops."),
        ok_text = _("Forget"),
        ok_callback = function()
            self.store:clearCredentials()
            notify(_("Unpaired."))
        end,
    }))
end

function Xtreader:editSetting(key, title)
    local dialog
    dialog = InputDialog:new({
        title = title,
        input = tostring(self.store:get(key) or ""),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    if value and value ~= "" then
                        self.store:set(key, (value:gsub("%s+$", "")))
                        self.store:flush()
                    end
                    UIManager:close(dialog)
                end,
            },
        } },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Xtreader:statusText()
    if not self.store:isPaired() then
        return _("Not paired.")
    end
    local last = self.store:get("last_library_sync")
    return T(_("Paired as %1.\nServer: %2\nBooks: %3\nLast sync: %4"),
             self.store:get("device_name") or "?",
             self.store:get("base_url"),
             self.store:get("library_dir"),
             last and last > 0 and os.date("%Y-%m-%d %H:%M", last) or _("never"))
end

function Xtreader:addToMainMenu(menu_items)
    menu_items.xtreader = {
        text = _("xtreader"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                enabled_func = function() return self.store:isPaired() end,
                callback = function()
                    self:runSync(function(report) return self:syncAll(report) end)
                end,
            },
            {
                text = _("Sync books only"),
                enabled_func = function() return self.store:isPaired() end,
                callback = function()
                    self:runSync(function(report)
                        return Library.sync(self.api, self.store, report)
                    end, { beat = true })
                end,
            },
            {
                text = _("Send reading statistics"),
                enabled_func = function() return self.store:isPaired() end,
                help_text = _("Uploads KOReader's own per-page reading records so the web dashboard can show streaks, heatmaps and reading time across every reader on the account. Reads the statistics database, never writes to it."),
                callback = function()
                    self:runSync(function(report)
                        return Insights.sync(self.api, self.store, report)
                    end, { beat = true })
                end,
            },
            {
                text = _("Sync wallpapers only"),
                enabled_func = function() return self.store:isPaired() end,
                separator = true,
                callback = function()
                    self:runSync(function(report)
                        return Wallpaper.sync(self.api, self.store, report)
                    end, { beat = true })
                end,
            },
            {
                text = _("Pair this device"),
                enabled_func = function() return not self.store:isPaired() end,
                callback = function() self:pair() end,
            },
            {
                text = _("Unpair"),
                enabled_func = function() return self.store:isPaired() end,
                callback = function() self:unpair() end,
            },
            {
                text = _("Reapply progress sync settings"),
                enabled_func = function() return self.store:isPaired() end,
                separator = true,
                help_text = _("Points KOReader's progress sync at this server and sets binary (content) matching, which is what the CrossPoint reader uses and what stock KOReader defaults to. A mismatch here makes sync appear to do nothing at all."),
                callback = function()
                    local ok, err, hint = Pairing.configureKosync(self.store, self.ui)
                    if not ok then
                        notify(T(_("Failed: %1"), tostring(err)))
                    elseif hint == "applies_on_next_book" then
                        notify(_("Progress sync reconfigured.\nIt takes effect when you next open a book — KOReader only loads the sync plugin while a document is open."))
                    else
                        notify(_("Progress sync reconfigured."))
                    end
                end,
            },
            {
                text = _("Server address"),
                callback = function() self:editSetting("base_url", _("Server address")) end,
            },
            {
                text = _("Books folder"),
                callback = function() self:editSetting("library_dir", _("Books folder")) end,
            },
            {
                text = _("Wallpapers folder"),
                separator = true,
                callback = function()
                    self:editSetting("wallpaper_dir", _("Wallpapers folder"))
                    Wallpaper.configureScreensaver(self.store)
                end,
            },
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function() notify(self:statusText(), 10) end,
            },
        },
    }
end

function Xtreader:onXtreaderSync()
    if not self.store:isPaired() then
        notify(_("Pair this device with xtreader first."))
        return true
    end
    self:runSync(function(report) return self:syncAll(report) end)
    return true
end

return Xtreader
