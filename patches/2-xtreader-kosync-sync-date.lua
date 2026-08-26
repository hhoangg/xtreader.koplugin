--[[
Adds "last synced" to KOSync's jump-to-position dialog.

KOReader already asks before moving you — `sync_forward`/`sync_backward` set to
PROMPT produce a ConfirmBox reading "Sync to latest location 42% from device
'X'?". What it does not say is WHEN that position was recorded, and that is the
one fact you need to answer the question. 42% from a reader you put down an hour
ago and 42% from one you last touched in March are the same sentence and very
different decisions.

The server already sends it. `GET /syncs/progress/:document` returns a
`timestamp`, KOSync reads it to decide direction (kosync.koplugin/main.lua:898)
and then drops it before drawing the dialog.

WHY IT IS SHAPED LIKE THIS

The obvious patch is to replace `KOSync:getProgress`, since that is where the
ConfirmBox is built. That means copying ~80 lines of upstream logic into this
file and owning them forever — every upstream fix to sync direction, conflict
handling or error paths would have to be re-merged here by hand, and a stale
copy would silently reintroduce bugs that were already fixed.

So instead this patches two narrow seams and copies no logic at all:

  1. `KOSyncClient.get_progress` — wrap the callback to note `body.timestamp`.
     The callback runs SYNCHRONOUSLY (KOSyncClient.lua:169 calls it inside the
     coroutine), and the ConfirmBox is built inside it, so a flag set just
     before and cleared just after covers exactly that window and nothing else.
  2. `ConfirmBox.new` — while that flag is set, append one line.

Upstream can rewrite `getProgress` entirely and this keeps working, because it
depends only on the client's callback signature and on a dialog being shown.

FAILURE MODE, ON PURPOSE

Every step is guarded. If the plugin is missing, the client has a different
shape, or anything raises, the patch does nothing and reading progress syncs
exactly as it did before. A missing date line is a cosmetic loss; a broken
ConfirmBox would break every yes/no dialog in the reader.

Verified against KOReader v2026.07.1.
]]

local logger = require("logger")
local userpatch = require("userpatch")
local _ = require("gettext")
local T = require("ffi/util").template

-- Non-nil only for the instant between the sync response arriving and the
-- dialog being constructed from it.
local pending_timestamp = nil

local function patchConfirmBox()
    local ok, ConfirmBox = pcall(require, "ui/widget/confirmbox")
    if not ok or type(ConfirmBox) ~= "table" then
        return false
    end
    if rawget(ConfirmBox, "_xtreader_date_patched") then
        return true
    end

    -- `new` is inherited through the widget metatable chain; resolve it once and
    -- install ours directly on ConfirmBox so only this class is affected.
    local inherited_new = ConfirmBox.new
    if type(inherited_new) ~= "function" then
        return false
    end

    ConfirmBox.new = function(cls, o)
        if pending_timestamp and type(o) == "table" and type(o.text) == "string" then
            local when = os.date("%Y-%m-%d %H:%M", pending_timestamp)
            o.text = o.text .. "\n\n" .. T(_("Last synced: %1"), when)
            -- One dialog per response. Anything else drawn later in the same
            -- window is not ours to annotate.
            pending_timestamp = nil
        end
        return inherited_new(cls, o)
    end

    ConfirmBox._xtreader_date_patched = true
    return true
end

local function patchClient()
    local ok, Client = pcall(require, "KOSyncClient")
    if not ok or type(Client) ~= "table" then
        return false
    end
    if rawget(Client, "_xtreader_date_patched") then
        return true
    end
    local orig = rawget(Client, "get_progress")
    if type(orig) ~= "function" then
        return false
    end

    Client.get_progress = function(self, username, password, document, callback)
        if type(callback) ~= "function" then
            return orig(self, username, password, document, callback)
        end
        return orig(self, username, password, document, function(success, body)
            local ts = nil
            if success and type(body) == "table" then
                ts = tonumber(body.timestamp)
            end
            -- Only arm for a plausible epoch. A server sending 0, a string, or
            -- something absurd should produce no line rather than "1970-01-01".
            pending_timestamp = (ts and ts > 0) and ts or nil
            local cb_ok, err = pcall(callback, success, body)
            pending_timestamp = nil
            if not cb_ok then
                -- Re-raise rather than swallow: this is upstream's own error
                -- path and hiding it here would be far worse than a missing date.
                error(err, 0)
            end
        end)
    end

    Client._xtreader_date_patched = true
    return true
end

userpatch.registerPatchPluginFunc("kosync", function()
    local ok, err = pcall(function()
        if patchClient() and patchConfirmBox() then
            logger.dbg("xtreader: kosync sync-date patch applied")
        else
            logger.warn("xtreader: kosync sync-date patch skipped (unexpected shape)")
        end
    end)
    if not ok then
        logger.warn("xtreader: kosync sync-date patch failed, ignoring:", err)
    end
end)
