--[[
The same account-holds-it-but-this-device-does-not books, on the home screen.

`2-xtreader-placeholders.lua` puts them in KOReader's FILE BROWSER by patching
FileChooser. That reaches the wrong screen for anyone running kindleui, whose
home screen is bookshelf's shelf and keeps its own book repository -- the file
browser is a screen they may never open.

kindleui exposes a registry for exactly this (lib/bookshelf_placeholders.lua):
it asks a provider which books belong in a folder, and asks an opener to fetch
one when the reader taps it. Neither side depends on the other -- with no
provider registered the shelf lists only real files, and with kindleui absent
this patch does nothing at all.

WHY A PATCH AND NOT PART OF THE PLUGIN

`registerPatchPluginFunc("kindleui", ...)` runs when kindleui loads, which is
the only moment `require("lib/bookshelf_placeholders")` can resolve: the plugin
loader puts a plugin's own directory on package.path as it loads it. Requiring
it from xtreader's main.lua would run either too early (path not set yet) or
never (kindleui not installed), and the failure would look like placeholders
silently not working rather than like a missing dependency.

The two patches coexist deliberately. They feed different screens and neither
knows about the other; a reader who uses both the shelf and the file browser
sees the same books in both.
]]

local logger = require("logger")
local userpatch = require("userpatch")
local _ = require("gettext")
local T = require("ffi/util").template

--- The live xtreader plugin instance, or nil.
--
-- Reached through FileManager rather than held, because the plugin is
-- re-instantiated whenever the file manager is, and a captured reference would
-- go stale the first time the reader closes a book.
local function plugin()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager or not FileManager.instance then
        return nil
    end
    return FileManager.instance.xtreader
end

--- The account's library root on this device, with no trailing slash.
local function libraryRoot(inst)
    local root = inst and inst.store and inst.store:get("library_dir")
    if not root then return nil end
    return (root:gsub("/+$", ""))
end

--- Books the catalogue places directly inside `dir` that are not on disk.
--
-- Directly: a book two folders down belongs to that folder's listing, and the
-- shelf will ask again when the reader walks into it.
--
-- `unavailable` entries are skipped here, unlike in the file browser. The
-- browser can afford to show one and explain on tap because its rows are text;
-- on the shelf every entry is a full cover-sized card, and spending one on a
-- book that cannot be downloaded is a poor trade for the eight cards a page
-- holds. They remain visible in the file browser.
local function provider(dir)
    local inst = plugin()
    if not (inst and inst.store and inst.store.eachCatalogueEntry) then return {} end
    if not inst.store:isPaired() then return {} end

    local root = libraryRoot(inst)
    if not root then return {} end
    dir = tostring(dir):gsub("/+$", "")

    local lfs = require("libs/libkoreader-lfs")
    local out = {}
    for id, entry in inst.store:eachCatalogueEntry() do
        if entry.path and not entry.unavailable then
            local full = root .. "/" .. entry.path:gsub("^/+", "")
            local parent, name = full:match("^(.*)/([^/]+)$")
            if parent == dir and name and lfs.attributes(full, "mode") ~= "file" then
                -- title / authors / series are passed through but are nil
                -- today, and that is not an oversight to fix here.
                -- `/library/manifest` returns exactly
                -- `{ id, path, contentHash, sizeBytes, updatedAt }` (verified
                -- against the live account), and the metadata a shelf wants
                -- lives INSIDE the EPUB -- which is the file this device does
                -- not have. So a placeholder shows its filename, which is the
                -- only true thing available about it until it is downloaded.
                --
                -- Left in place rather than dropped so that if the manifest
                -- ever carries them, this starts using them with no change.
                out[#out + 1] = {
                    id      = id,
                    name    = name,
                    title   = entry.title,
                    authors = entry.authors or entry.author,
                    series  = entry.series,
                    series_index = entry.series_index,
                    -- The server's figure, which is the honest one: it is what
                    -- the download will cost, not what it occupies here.
                    size    = entry.size or 0,
                }
            end
        end
    end
    return out
end

--- Subfolder names directly under `dir` that hold catalogue books at ANY depth.
--
-- Without this the shelf never shows the folder, so its placeholders cannot be
-- reached: getAll drops a directory with no book file under it, and a folder
-- whose books are all still on the server has none. On a freshly paired device
-- that is every folder the account has.
--
-- "At any depth" is the load-bearing part. A folder three levels above a book
-- still has to be listed, or the reader cannot walk down to it -- so this
-- matches on the path PREFIX and takes the next segment, rather than asking
-- whether a book sits directly inside.
local function folderProvider(dir)
    local inst = plugin()
    if not (inst and inst.store and inst.store.eachCatalogueEntry) then return {} end
    if not inst.store:isPaired() then return {} end

    local root = libraryRoot(inst)
    if not root then return {} end
    dir = tostring(dir):gsub("/+$", "")
    -- Only paths inside the library are ours to answer for.
    if dir ~= root and dir:sub(1, #root + 1) ~= root .. "/" then return {} end

    local prefix = (dir == root) and "" or dir:sub(#root + 2)
    if prefix ~= "" then prefix = prefix .. "/" end

    local seen, out = {}, {}
    for _id, entry in inst.store:eachCatalogueEntry() do
        if entry.path and not entry.unavailable then
            local rel = entry.path:gsub("^/+", "")
            if prefix == "" or rel:sub(1, #prefix) == prefix then
                local rest = rel:sub(#prefix + 1)
                local seg = rest:match("^([^/]+)/")  -- nil when the book is directly here
                if seg and not seen[seg] then
                    seen[seg] = true
                    out[#out + 1] = seg
                end
            end
        end
    end
    return out
end

--- Fetch one tapped book, then hand back where it landed.
--
-- `done(path)` on success, `done(nil, message)` on failure. Called exactly
-- once; kindleui guards against a second call, but this does not rely on that.
local function opener(book, done)
    local inst = plugin()
    if not (inst and inst.api and inst.store) then
        return done(nil, _("xtreader is not available."))
    end
    local id = book.placeholder_id
    local entry = id and inst.store:getCatalogueEntry(id)
    if not entry or not entry.path then
        return done(nil, _("This book is no longer in your library."))
    end
    local root = libraryRoot(inst)
    if not root then
        return done(nil, _("No library folder is configured."))
    end
    -- The REAL path, rebuilt from the catalogue -- never book.filepath, which
    -- is kindleui's pseudo-path and has a marker spliced into its filename.
    local target = root .. "/" .. entry.path:gsub("^/+", "")

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            Trapper:info(T(_("Downloading:\n%1"), book.title or entry.path))
            local dir = target:match("^(.*)/[^/]+$")
            if dir then
                -- This book's place in the account's tree has no reason to
                -- exist here yet.
                os.execute(string.format("mkdir -p '%s'", dir:gsub("'", "'\\''")))
            end
            local ok_dl, err = inst.api:downloadTo("/library/" .. id .. "/file",
                                                   target, entry.size)
            Trapper:clear()
            if not ok_dl then
                return done(nil, tostring(err))
            end
            -- Record it the way a sync would, so the next inventory report
            -- counts it and the next sync does not fetch it a second time.
            inst.store:setBook(id, {
                path = entry.path, hash = entry.hash, size = entry.size,
            })
            inst.store:flush()
            done(target)
        end)
    end)
end

userpatch.registerPatchPluginFunc("kindleui", function()
    local ok, Placeholders = pcall(require, "lib/bookshelf_placeholders")
    if not ok or type(Placeholders) ~= "table"
            or type(Placeholders.setProvider) ~= "function" then
        -- An older kindleui without the registry, or bookshelf upstream. The
        -- shelf then lists only real files, which is the status quo, and the
        -- file-browser patch still covers its own screen.
        logger.dbg("xtreader: kindleui has no placeholder registry; shelf placeholders off")
        return
    end
    Placeholders.setProvider(provider)
    Placeholders.setOpener(opener)
    -- Optional on older kindleui builds: registered only when present, so this
    -- patch keeps working against a version that has books but not folders.
    if type(Placeholders.setFolderProvider) == "function" then
        Placeholders.setFolderProvider(folderProvider)
    end
    logger.dbg("xtreader: shelf placeholders registered with kindleui")
end)
