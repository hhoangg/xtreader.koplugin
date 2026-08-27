--[[
Books the account has and this device does not, shown where they belong.

Without this the file browser can only show files. A book on the account that
was never downloaded is then indistinguishable from a book that does not exist,
and the only way to get it is to sync everything -- which is the wrong shape
once a library outgrows a device.

WHERE IT HOOKS

`FileChooser:getList(path, collate)` returns `dirs, files`, and every entry in
those lists is a plain Lua table -- `{ text, path, attr, is_file }`
(filechooser.lua:161-166). Nothing requires an entry to correspond to a file on
disk; that is merely the only kind `getPathList` has ever built. So the seam is
to let upstream produce the real listing and append ours to it.

Taps arrive at `FileChooser:onMenuSelect(item)`, which forwards to
`onFileSelect` for anything flagged `is_file` (:400-408). Ours are intercepted
there, before that fork, and never reach the code that would try to open a file
that is not there.

Patching this widget is an established seam rather than a new idea:
coverbrowser.koplugin already replaces `getListItem` and the menu classes around
it. This one adds entries and consumes taps on its own entries, and touches
nothing upstream builds.

THREE STATES, AND THE THIRD IS THE POINT

    on disk                     -> upstream's own entry, untouched
    in catalogue, not on disk   -> placeholder, tap downloads it
    ... and `unavailable`       -> placeholder, tap explains, no download

The third is a book the account still lists whose bytes are gone from storage.
Offering a download would spend a request to be told `404 file_deleted`. Hiding
it would be worse: a reader who still holds that file somewhere else needs to
see that the account knows about it.
]]

local logger = require("logger")
local userpatch = require("userpatch")
local _ = require("gettext")
local T = require("ffi/util").template

-- Non-nil only while a tap on one of our entries is being handled.
local BADGE_PENDING     = "\u{F019}"  -- download arrow
local BADGE_UNAVAILABLE = "\u{F127}"  -- broken link

local function plugin()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager or not FileManager.instance then
        return nil
    end
    return FileManager.instance.xtreader
end

--- Placeholder entries belonging directly inside `dir`.
--
-- Directly: a catalogue path two folders down is not this folder's business,
-- and upstream will ask again when the reader walks into that folder.
local function placeholdersFor(dir)
    local inst = plugin()
    if not (inst and inst.store and inst.store.eachCatalogueEntry) then
        return nil
    end
    if not inst.store:isPaired() then
        return nil
    end

    local lfs = require("libs/libkoreader-lfs")
    local root = inst.store:get("library_dir")
    if not root then return nil end
    root = root:gsub("/+$", "")
    dir = dir:gsub("/+$", "")

    local out = {}
    for id, entry in inst.store:eachCatalogueEntry() do
        if entry.path then
            local full = root .. "/" .. entry.path:gsub("^/+", "")
            local parent, name = full:match("^(.*)/([^/]+)$")
            -- Only when the file really is absent. A catalogue is a record of
            -- what the account has, not of what this card has, and the two
            -- disagree the moment anything is downloaded or deleted.
            if parent == dir and name and lfs.attributes(full, "mode") ~= "file" then
                out[#out + 1] = {
                    text = name,
                    path = full,
                    is_file = true,
                    dim = true, -- drawn grey: present, not openable
                    -- `attr` is not decoration. Downstream assumes every file
                    -- entry carries one -- `getMenuItemMandatory` reaches
                    -- straight for `item.attr.size` (filechooser.lua:303) -- so
                    -- an entry without it does not render badly, it raises, and
                    -- the raise takes the whole listing with it. That is what a
                    -- missing folder looks like from the outside.
                    --
                    -- `size` is the server's figure, which is the honest one:
                    -- it is what the download will cost.
                    attr = {
                        mode = "file",
                        size = entry.size or 0,
                        modification = 0,
                    },
                    mandatory = entry.unavailable and BADGE_UNAVAILABLE or BADGE_PENDING,
                    xtreader_ph = { id = id, entry = entry },
                }
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function patch()
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if not ok or type(FileChooser) ~= "table" then
        return false, "no FileChooser"
    end
    if rawget(FileChooser, "_xtreader_ph_patched") then
        return true
    end

    local orig_getList = rawget(FileChooser, "getList")
    local orig_select  = rawget(FileChooser, "onMenuSelect")
    if type(orig_getList) ~= "function" or type(orig_select) ~= "function" then
        return false, "unexpected FileChooser shape"
    end

    FileChooser.getList = function(self, path, collate)
        local dirs, files = orig_getList(self, path, collate)
        -- Appended, never merged into the sort. Upstream has already ordered
        -- `files` by the reader's chosen collation, and re-sorting a list that
        -- has just been sorted by rules we do not own is how a browser starts
        -- ordering itself differently from every other view in the app.
        local ok_ph, extra = pcall(placeholdersFor, path)
        if ok_ph and extra then
            for _i, item in ipairs(extra) do
                files[#files + 1] = item
            end
        elseif not ok_ph then
            logger.warn("xtreader: placeholder listing failed:", tostring(extra))
        end
        return dirs, files
    end

    FileChooser.onMenuSelect = function(self, item)
        local ph = type(item) == "table" and item.xtreader_ph
        if not ph then
            return orig_select(self, item)
        end
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        if ph.entry and ph.entry.unavailable then
            UIManager:show(InfoMessage:new{
                text = T(_("%1\n\nThis book is still in your library, but its file is no longer stored on the server, so it cannot be downloaded.\n\nA reader that already holds a copy keeps it."),
                         item.text),
                timeout = 10,
            })
            return true
        end
        -- Download it, then let the browser redraw. Inside a Trapper coroutine
        -- so the progress message can repaint and the reader can abort a large
        -- book rather than watching a frozen screen.
        local inst = plugin()
        if not (inst and inst.api and inst.store) then
            UIManager:show(InfoMessage:new{ text = _("xtreader is not available."), timeout = 5 })
            return true
        end
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:runWhenOnline(function()
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                Trapper:info(T(_("Downloading:\n%1"), item.text))
                local entry = ph.entry
                local dir = item.path:match("^(.*)/[^/]+$")
                if dir then
                    -- The folder may not exist yet: this book's place in the
                    -- account's tree has no reason to have been created here.
                    os.execute(string.format("mkdir -p '%s'", dir:gsub("'", "'\\''")))
                end
                local ok_dl, err = inst.api:downloadTo("/library/" .. ph.id .. "/file",
                                                       item.path, entry.size)
                Trapper:clear()
                if ok_dl then
                    -- Record it the way a sync would, so the next inventory
                    -- report counts it and the next sync does not fetch it again.
                    inst.store:setBook(ph.id, {
                        path = entry.path, hash = entry.hash, size = entry.size,
                    })
                    inst.store:flush()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Downloaded:\n%1"), item.text), timeout = 3 })
                    -- Redraw so the placeholder becomes the real file.
                    if self.refreshPath then
                        self:refreshPath()
                    elseif self.changeToPath then
                        self:changeToPath(self.path)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not download:\n%1\n\n%2"), item.text, tostring(err)),
                        timeout = 10 })
                end
            end)
        end)
        return true
    end

    FileChooser._xtreader_ph_patched = true
    return true
end

userpatch.registerPatchPluginFunc("xtreader", function()
    local ok, err = pcall(patch)
    if ok and err ~= false then
        logger.dbg("xtreader: placeholder patch applied")
    else
        -- A file browser that lists only real files is the status quo. A file
        -- browser that raises while listing is a device with no way back to it.
        logger.warn("xtreader: placeholder patch skipped:", tostring(err))
    end
end)
