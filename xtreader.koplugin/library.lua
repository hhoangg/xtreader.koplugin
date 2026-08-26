--[[
Book sync.

Mirrors the folder layout built in the web UI into the local documents folder.

The full manifest is fetched every time rather than a `since` delta. A delta is
cheaper but cannot express everything: the server's own docs are explicit that
the intended shape is to take the full list and reconcile against what is on
disk. The cost is bounded by how often this runs, not by the size of the reply.

Three passes, in this order, and the order is load-bearing:

  1. renames — `id` is stable across moves, so a book that only changed folder
     is renamed on disk instead of re-downloaded. Several MB of Wi-Fi saved per
     book, and it is also the only way the reading position survives a library
     reorganisation.
  2. deletions — run before downloads so a full device gets its room back first.
  3. downloads.

The sidecar directory moves with the book. KOReader keeps per-document state
(reading position, highlights, per-book settings) in a sibling `.sdr`; leaving
it behind on a rename is exactly the progress-loss bug that stable ids exist to
prevent.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Library = {}

--- Where KOReader keeps per-document state for `doc_path`.
-- Uses DocSettings when it is available so a user who moved their sidecars to a
-- central folder is respected, and falls back to the classic sibling otherwise.
local function sidecarDir(doc_path)
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.getSidecarDir then
        local ok2, dir = pcall(DocSettings.getSidecarDir, DocSettings, doc_path)
        if ok2 and type(dir) == "string" and dir ~= "" then
            return dir
        end
    end
    return (doc_path:gsub("%.%w+$", "")) .. ".sdr"
end

local function ensureDir(dir)
    if dir == nil or dir == "" or dir == "/" then
        return true
    end
    if lfs.attributes(dir, "mode") == "directory" then
        return true
    end
    ensureDir(dir:match("^(.*)/[^/]+$"))
    local ok = lfs.mkdir(dir)
    return ok or lfs.attributes(dir, "mode") == "directory"
end

local function removeTree(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then
        return
    end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local child = dir .. "/" .. name
            if lfs.attributes(child, "mode") == "directory" then
                removeTree(child)
            else
                os.remove(child)
            end
        end
    end
    lfs.rmdir(dir)
end

local function localPathFor(root, server_path)
    -- `path` is already sanitised for FAT/exFAT server-side and always starts
    -- with a slash, so this is a join and not a rewrite.
    return root .. server_path
end

--- Runs a full library sync. Must be called inside a Trapper:wrap.
-- `report(text)` returns false when the user asked to stop.
function Library.sync(api, store, report)
    local root = store:get("library_dir")
    if not ensureDir(root) then
        return false, T(_("Cannot create %1"), root)
    end

    report(_("Fetching the library manifest…"))
    local entries, code = api:fetchManifest("/library/manifest", "limit=200")
    if not entries then
        return false, T(_("Manifest failed (%1)"), tostring(code))
    end

    local server = {}
    for _idx, e in ipairs(entries) do
        if e.deleted ~= true and e.id and e.path then
            server[e.id] = e
        end
    end

    local renamed, downloaded, deleted, failed = 0, 0, 0, 0

    -- Pass 1: renames.
    for id, entry in pairs(server) do
        local known = store:getBook(id)
        if known and known.path and known.path ~= entry.path then
            local from = localPathFor(root, known.path)
            local to = localPathFor(root, entry.path)
            if lfs.attributes(from, "mode") == "file" then
                ensureDir(to:match("^(.*)/[^/]+$"))
                if os.rename(from, to) then
                    local sc_from, sc_to = sidecarDir(from), sidecarDir(to)
                    if lfs.attributes(sc_from, "mode") == "directory" then
                        os.rename(sc_from, sc_to)
                    end
                    known.path = entry.path
                    store:setBook(id, known)
                    renamed = renamed + 1
                else
                    logger.warn("xtreader: rename failed", from, "->", to)
                end
            else
                -- The recorded file is gone; forget the path so pass 3 treats
                -- this as a fresh download rather than a failed rename.
                known.path = nil
                store:setBook(id, known)
            end
        end
    end

    -- Pass 2: deletions. Anything we recorded that the server no longer lists.
    --
    -- An empty manifest is never an instruction to wipe the device. A live
    -- account that really holds no books produces the same 200 + trailer-only
    -- response as an account whose library failed to load, and the two are
    -- indistinguishable from here — so the destructive reading is refused and
    -- the user is told. They can still delete a book from the web UI and see it
    -- go, because that leaves the other rows in the manifest.
    local have_local = false
    for _id in store:eachBook() do
        have_local = true
        break
    end
    local empty_manifest = next(server) == nil

    if empty_manifest and have_local then
        logger.warn("xtreader: manifest is empty but books are recorded locally; skipping deletions")
    else
        for id, known in store:eachBook() do
            if server[id] == nil then
                if known.path then
                    local target = localPathFor(root, known.path)
                    os.remove(target)
                    removeTree(sidecarDir(target))
                end
                store:removeBook(id)
                deleted = deleted + 1
            end
        end
    end

    -- Pass 3: downloads.
    local pending = {}
    for id, entry in pairs(server) do
        local known = store:getBook(id)
        local target = localPathFor(root, entry.path)
        local on_disk = lfs.attributes(target, "mode") == "file"
        if not on_disk or not known or known.hash ~= entry.contentHash then
            pending[#pending + 1] = { id = id, entry = entry, target = target }
        elseif known.path ~= entry.path then
            known.path = entry.path
            store:setBook(id, known)
        end
    end

    for i, job in ipairs(pending) do
        if report(T(_("Downloading %1 of %2:\n%3"), i, #pending,
                    job.entry.path:match("[^/]+$") or job.entry.path)) == false then
            break
        end
        ensureDir(job.target:match("^(.*)/[^/]+$"))
        -- No size gate for books: the server's recorded `sizeBytes` can
        -- legitimately be stale, unlike a wallpaper's immutable bytes.
        local ok = api:downloadTo("/library/" .. job.id .. "/file", job.target, nil)
        if ok then
            store:setBook(job.id, {
                path = job.entry.path,
                hash = job.entry.contentHash,
                size = job.entry.sizeBytes,
            })
            downloaded = downloaded + 1
        else
            failed = failed + 1
        end
    end

    store:set("last_library_sync", os.time())
    store:flush()

    if empty_manifest and have_local then
        return true, _("The server listed no books at all, so nothing was deleted.\nCheck the library on the web before syncing again.")
    end
    return true, T(_("Books: %1 new, %2 moved, %3 removed, %4 failed."),
                   downloaded, renamed, deleted, failed)
end

Library.sidecarDir = sidecarDir
Library.ensureDir = ensureDir

return Library
