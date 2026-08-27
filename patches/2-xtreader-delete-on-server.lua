--[[
"Delete on the server too" in KOReader's own delete dialog.

Deleting a synced book on the reader only deletes the copy on the reader. The
server still lists it, so the next library sync sees a book the device does not
have and downloads it again. From where the reader is sitting the book simply
comes back, and nothing on screen ever explained why.

The server has had the other half of this since the beginning:
`DELETE /library/:id`, described in the API docs as "the 'delete on server too'
half of the reader's delete dialog". This is that half.

SHAPE

Upstream builds the delete ConfirmBox inside `FileManager:showDeleteFileDialog`
and shows it there, and it already demonstrates the pattern for adding a choice
to that dialog: `FileManager.addMetadataArcCheckButton` calls
`confirmbox:addWidget(CheckButton:new{...})` before the box is shown
(filemanager.lua:1154-1166). So this copies no upstream logic. It wraps
`showDeleteFileDialog`, and for the duration of that one call wraps
`UIManager.show` to catch the box on its way to the screen -- the same
"narrow seam plus a flag that lives for one call" idiom as the kosync patch
next to this file.

THE ORDER IS THE WHOLE SAFETY ARGUMENT

The server delete runs FIRST, and the local delete only happens if it succeeded.

Local-first is the ordering that looks natural and is wrong. Delete the file,
fail to reach the server, and the book is still in the manifest: the next sync
downloads it back. The user deleted a book and it returned -- the exact failure
this patch exists to remove, reintroduced by a dropped Wi-Fi connection.

Server-first fails the other way: the row is gone but the file is still on the
device. That is an orphan taking up space, visible, and deletable again by hand.
One of those two is recoverable by a person looking at the screen.

WHEN THE CHECKBOX APPEARS AT ALL

Only when the plugin is loaded, the device is paired, and the file is one this
server actually sent -- `Library.idForLocalPath` returns nil for a side-loaded
book, and a book the server never had must never be reported deleted.

It is unchecked by default and always will be. This deletes from the account,
not from the device; every other reader on that account loses the book too. That
is not something to arrive at by muscle memory on a dialog people confirm
without reading.

Verified against KOReader v2026.07.1.
]]

local logger = require("logger")
local userpatch = require("userpatch")
local _ = require("gettext")
local T = require("ffi/util").template

-- Non-nil only between showDeleteFileDialog being entered and the ConfirmBox it
-- builds reaching UIManager:show.
local pending = nil

local function plugin()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager or not FileManager.instance then
        return nil
    end
    -- registerModule(name, ...) attaches plugins by name (filemanager.lua:379),
    -- so this is the live instance or nil, never a second one of our own: a
    -- second Store would flush a stale library index over the real one.
    return FileManager.instance.xtreader
end

local function decorate(confirmbox)
    local p = pending
    if not p or type(confirmbox) ~= "table" or type(confirmbox.addWidget) ~= "function" then
        return
    end

    local CheckButton = require("ui/widget/checkbutton")
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")

    local online = NetworkMgr:isOnline()
    local also = false

    confirmbox:addWidget(CheckButton:new{
        text = online and _("delete from xtreader too")
                       or _("delete from xtreader too (needs Wi-Fi)"),
        enabled = online,
        checked = false,
        parent = confirmbox,
        callback = function() also = not also end,
    })

    -- Run before upstream's own ok_callback, which is what deletes the file.
    local proceed = confirmbox.ok_callback
    confirmbox.ok_callback = function(...)
        if also then
            local ok, code = p.Library.forget(p.api, p.store, p.id)
            if not ok then
                -- Stop here. See the header: deleting locally after this failed
                -- is what makes the book come back on the next sync.
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not delete this book on xtreader (%1).\nNothing was deleted."),
                             tostring(code)),
                    timeout = 10,
                })
                return
            end
        end
        if proceed then return proceed(...) end
    end
end

local function patch()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or type(FileManager) ~= "table" then
        return false, "no FileManager"
    end
    if rawget(FileManager, "_xtreader_delete_patched") then
        return true
    end
    local orig = rawget(FileManager, "showDeleteFileDialog")
    if type(orig) ~= "function" then
        return false, "showDeleteFileDialog is not a function"
    end

    FileManager.showDeleteFileDialog = function(self, filepath, post_cb, pre_cb)
        pending = nil

        local inst = plugin()
        if inst and inst.store and inst.store:isPaired() then
            local lok, Library = pcall(require, "library")
            local ffiUtil = require("ffi/util")
            local file = ffiUtil.realpath(filepath)
            if lok and Library and file then
                local id = Library.idForLocalPath(inst.store, file)
                if id then
                    pending = { id = id, api = inst.api, store = inst.store, Library = Library }
                end
            end
        end

        if not pending then
            return orig(self, filepath, post_cb, pre_cb)
        end

        -- Catch the ConfirmBox on its way to the screen. Restored in the same
        -- call, and through pcall if upstream raises, so nothing else that shows
        -- a widget later can be mistaken for ours.
        local UIManager = require("ui/uimanager")
        local real_show = UIManager.show
        local decorated = false
        UIManager.show = function(mgr, widget, ...)
            if not decorated then
                decorated = true
                pcall(decorate, widget)
            end
            return real_show(mgr, widget, ...)
        end
        local called_ok, err = pcall(orig, self, filepath, post_cb, pre_cb)
        UIManager.show = real_show
        pending = nil
        if not called_ok then
            error(err, 0)
        end
    end

    FileManager._xtreader_delete_patched = true
    return true
end

userpatch.registerPatchPluginFunc("xtreader", function()
    local ok, err = pcall(patch)
    if ok and err ~= false then
        logger.dbg("xtreader: delete-on-server patch applied")
    else
        logger.warn("xtreader: delete-on-server patch skipped:", tostring(err))
    end
end)
