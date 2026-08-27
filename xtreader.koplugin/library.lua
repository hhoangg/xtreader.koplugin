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

--- SHA-256 of a whole file, hex, streamed. nil when it cannot be read.
--
-- The same hash the server stores as contentHash, so the two are comparable.
-- Cheap enough to be worth it: measured on a Paperwhite 5 this runs at
-- 13.7 MB/s, so deciding whether a book already on the card is the account's
-- copy costs about a second for a 10 MB book -- against re-downloading it.
local function contentHash(path)
    local ok, sha = pcall(require, "ffi/sha2")
    if not ok or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    local append = sha.sha256()
    while true do
        local chunk = f:read(64 * 1024)
        if not chunk then break end
        append(chunk)
    end
    f:close()
    return append()
end

--- Absolute paths under `root` whose basename is `name`.
--
-- Basename first, and only basename, because a move almost always keeps the
-- filename -- dragging a book between folders in a file manager does not rename
-- it. Searching by name narrows a library to a candidate or two, and hashing
-- only those costs about a second each instead of hashing everything.
--
-- Depth-bounded for the same reason the upload scan is: 12 is far past any
-- sane nesting and stops a symlink loop turning a sync into a hang.
local function findByName(root, name, limit)
    local out = {}
    local function walk(dir, depth)
        if depth > 12 or #out >= (limit or 4) then return end
        local ok_iter, iter, obj = pcall(lfs.dir, dir)
        if not ok_iter or type(iter) ~= "function" then return end
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
                local full = dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr and attr.mode == "directory" then
                    if not entry:match("%.sdr$") then walk(full, depth + 1) end
                elseif attr and attr.mode == "file" and entry == name then
                    out[#out + 1] = full
                    if #out >= (limit or 4) then return end
                end
            end
        end
    end
    walk(root, 1)
    return out
end

local function localPathFor(root, server_path)
    -- `path` is already sanitised for FAT/exFAT server-side and always starts
    -- with a slash, so this is a join and not a rewrite.
    return root .. server_path
end

--- Where a book recorded at `server_path` has actually been moved to, or nil.
--
-- Returns a path only when the bytes match the manifest's contentHash, so a
-- different book that happens to share a filename is never mistaken for the
-- one that moved. Nil means "treat this as a delete", which is the safe
-- direction to be wrong in: a missed move costs a placeholder the reader can
-- tap, a false move would silently re-file somebody's library.
local function findMovedTo(root, server_path, expect_hash)
    if not expect_hash then return nil end
    local name = server_path:match("[^/]+$")
    if not name then return nil end
    local old_full = localPathFor(root, server_path)
    for _i, cand in ipairs(findByName(root, name, 4)) do
        if cand ~= old_full and contentHash(cand) == expect_hash then
            return cand
        end
    end
    return nil
end

--- Runs a full library sync. Must be called inside a Trapper:wrap.
-- `report(text)` returns false when the user asked to stop.
--- The server id of the book sitting at `local_path`, plus its recorded entry.
--
-- Walks the index rather than keeping a reverse map: a library is hundreds of
-- entries, this runs once when a delete dialog opens, and a second map would be
-- one more thing to keep in step with `path` changing under a rename.
--
-- Returns nil for a side-loaded file, which is the answer that matters -- a book
-- the server never had must never be reported to the server as deleted.
function Library.idForLocalPath(store, local_path)
    local root = store:get("library_dir")
    if not root or not local_path then
        return nil
    end
    for id, known in store:eachBook() do
        if known.path and localPathFor(root, known.path) == local_path then
            return id, known
        end
    end
    return nil
end

--- Deletes a book on the server and drops it from the local index.
--
-- The index entry is removed ONLY after the server confirms. A local index that
-- has forgotten a book the server still lists is not a small error: the next
-- sync sees an entry it has no record of and downloads the whole thing again.
function Library.forget(api, store, id)
    local ok, code = api:delete("/library/" .. id)
    if not ok then
        return false, code
    end
    store:removeBook(id)
    store:flush()
    return true
end

--- Tells the server which books this device actually holds.
--
-- A full snapshot every time, never a diff. The server keeps `device_books` so
-- the web UI can refuse to delete the last copy of something silently -- and
-- for that to be worth anything the picture has to be true, not merely
-- eventually true.
--
-- Reporting events instead ("downloaded X", "deleted Y") would be smaller and
-- would drift permanently the first time one went missing: a sync that dies
-- mid-way, a flat battery, a file deleted from the file manager, a device
-- restored from a backup. Nothing downstream could detect the divergence. A
-- snapshot cannot drift, and re-sending it costs nothing -- the whole payload
-- is about 2 KB for this library and 51 KB for a two-thousand-book one.
--
-- Only ids whose file is ACTUALLY on disk are sent. The local index remembers
-- what was downloaded, which is not the same as what is still there; a book
-- deleted outside this plugin would otherwise be reported forever as held.
--- Tell the account a book now lives somewhere else.
--
-- Returns true, or false plus a reason.
--
-- THE ENDPOINT IS NOT AGREED YET. This is the single place that changes when it
-- is, which is why the move detection calls through here rather than building a
-- request inline at the one site that needs it.
--
-- Until then it declines rather than guessing at a URL. Declining is not a
-- degraded mode: the caller leaves the file exactly where the reader put it and
-- retries next sync, so the only cost of the endpoint not existing yet is that
-- the account keeps the old path -- which is what happens today anyway.
--
-- A 409 is NOT a failure to retry forever. It means a live book already holds
-- the destination, so this reader has two books where the account has one, and
-- no amount of retrying resolves that. Reported once and left alone.
function Library.moveOnServer(api, id, new_path)
    if type(api.movePath) ~= "function" then
        return false, "no_endpoint"
    end
    local ok, code = api:movePath(id, new_path)
    if ok then return true end
    -- 405 is the route not existing yet, NOT the book. Kept apart from 404
    -- deliberately: reading an undeployed endpoint as "this book is gone" would
    -- have every device quietly forget its library.
    if code == 405 or code == 501 then return false, "no_endpoint" end
    -- 404 is the row: tombstoned by another device, or deleted in the browser.
    -- That is a real delete and the caller must treat it as one.
    if code == 404 then return false, "gone" end
    -- 409 is a live book already holding the destination. Retrying cannot
    -- change that, and it is not a local delete either -- the file on the card
    -- is fine, the account just disagrees about where it belongs.
    if code == 409 then return false, "path_taken" end
    return false, tostring(code)
end

function Library.reportInventory(api, store)
    local lfs = require("libs/libkoreader-lfs")
    local root = store:get("library_dir")
    if not root then
        return false, "no_library_dir"
    end

    local ids = {}
    for id, known in store:eachBook() do
        if known.path and lfs.attributes(localPathFor(root, known.path), "mode") == "file" then
            ids[#ids + 1] = id
        end
    end

    -- An empty list is a legitimate answer -- a device that has downloaded
    -- nothing yet -- and the server has to hear it, or it would go on believing
    -- this device holds whatever it held last time.
    local body, code = api:postJson("/devices/inventory", { bookIds = ids })
    if not body then
        return false, code
    end
    return true, tonumber(body.stored) or #ids
end

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

    -- Remember the account's list, not just what we ended up downloading.
    --
    -- Without this the device can only see books it holds, and a book it does
    -- not hold is indistinguishable from one that does not exist -- which is
    -- exactly the distinction a placeholder is.
    --
    -- Written before the passes below, so the catalogue reflects what the
    -- server said even if a download later fails.
    local catalogue = {}
    for id, e in pairs(server) do
        catalogue[id] = {
            path = e.path,
            hash = e.contentHash,
            size = e.sizeBytes,
            unavailable = e.unavailable == true or nil,
        }
    end
    store:setCatalogue(catalogue)

    local renamed, downloaded, deleted, failed = 0, 0, 0, 0
    -- Books already on the card that the ledger had lost track of.
    local adopted = 0
    -- Books the reader re-filed locally, propagated to the account.
    local moved, move_failed = 0, 0

    -- Off by default. Pulling every book onto every reader is the wrong shape
    -- once an account outgrows the smallest card on it, and it is the behaviour
    -- that makes a local delete meaningless.
    local auto_download = G_reader_settings:isTrue("xtreader_auto_download")

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
        if entry.unavailable == true then
            -- The account still lists it; the bytes are gone. Queueing it would
            -- spend a request to be told 404 file_deleted, once per sync,
            -- forever. A copy already on the card stays exactly where it is --
            -- being the last holder of a book is not a reason to lose it.
            if on_disk and known and known.path ~= entry.path then
                known.path = entry.path
                store:setBook(id, known)
            end
        elseif not on_disk and not auto_download then
            -- On demand: the account lists it, this card does not have it, and
            -- that is a placeholder rather than a job.
            --
            -- This is the line that makes deleting a book locally mean
            -- something. While sync fetched everything missing, a delete was
            -- undone by the next sync -- so "remove this from my device" was
            -- not an operation the reader could actually perform, and no
            -- placeholder could exist long enough to be seen.
            --
            -- Note it deliberately does not fire for a book that IS on disk with
            -- a stale hash: a changed file still gets re-fetched, because that
            -- is a different intent from having deleted it.
            -- Before treating this as a delete: did it MOVE?
            --
            -- Dragging a book between folders leaves the ledger and the
            -- manifest both pointing at the old path and nothing there, which
            -- is byte-for-byte what a delete looks like from here. Reading it
            -- as one produces two wrong things at once -- a placeholder at the
            -- old path for a book he still has, and an orphaned file at the new
            -- one that this plugin has no record of.
            --
            -- Only asked when the ledger knew about the book: a path that was
            -- never held here cannot have been moved from it.
            local moved_to = known and findMovedTo(root, entry.path, entry.contentHash)
            if moved_to then
                local new_rel = moved_to:sub(#root + 1)
                local ok_move, move_err = Library.moveOnServer(api, id, new_rel)
                if ok_move then
                    known.path = new_rel
                    known.move_conflict = nil
                    store:setBook(id, known)
                    moved = moved + 1
                elseif move_err == "gone" then
                    -- The account no longer has this book at all. That is a
                    -- delete, arriving by a different route, and it gets the
                    -- delete path rather than a retry.
                    store:removeBook(id)
                elseif move_err == "path_taken" then
                    -- Remembered so it is attempted ONCE. A live book holds the
                    -- destination, and asking again every sync forever cannot
                    -- change that -- it only spends a request to be refused. If
                    -- the reader moves the book somewhere else, the destination
                    -- differs and it is tried again, which is the right trigger.
                    if known.move_conflict ~= new_rel then
                        known.move_conflict = new_rel
                        store:setBook(id, known)
                        move_failed = move_failed + 1
                        logger.warn("xtreader: the account already has a book at:", new_rel)
                    end
                else
                    -- Transport trouble, or the endpoint is not deployed. The
                    -- file stays exactly where the reader put it and the next
                    -- sync tries again -- the alternative is a ledger claiming
                    -- a path the account does not have.
                    logger.warn("xtreader: could not move on the server:",
                                entry.path, "->", new_rel, tostring(move_err))
                    if move_err ~= "no_endpoint" then move_failed = move_failed + 1 end
                end
            elseif known then
                store:removeBook(id)
            end
        elseif on_disk and not known then
            -- ADOPT rather than download.
            --
            -- The file is already here and the ledger has simply lost track of
            -- it -- which happens after this device UPLOADS a book (the account
            -- learns about it, this ledger only finds out when the job commits)
            -- and after any interrupted run. On his device that was 90 books on
            -- the account against 70 in the ledger, and every one of those
            -- twenty was re-downloaded on the next sync: bytes spent to
            -- overwrite a file with itself.
            --
            -- Hashing decides it honestly rather than assuming. If the bytes
            -- match, record it and move on; if they do not, the local copy is
            -- genuinely a different file and the download below is right.
            local local_hash = contentHash(target)
            if local_hash and local_hash == entry.contentHash then
                store:setBook(id, { path = entry.path, hash = entry.contentHash,
                                    size = entry.sizeBytes })
                adopted = adopted + 1
            else
                pending[#pending + 1] = { id = id, entry = entry, target = target }
            end
        elseif not on_disk or not known or known.hash ~= entry.contentHash then
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
    -- `adopted` is reported rather than folded into `new`. They are different
    -- events: one spent bandwidth and one recognised a file that was already
    -- here, and a reader watching a sync say "20 new" for books they can see
    -- were never downloaded has been told something untrue.
    -- `moved` is the reader re-filing a book HERE and the account following;
    -- `renamed` is the account re-filing one and this device following. Two
    -- directions, and collapsing them would make a sync report unreadable in
    -- exactly the case somebody is trying to work out which end moved what.
    if moved > 0 or move_failed > 0 then
        return true, T(_("Books: %1 new, %2 already here, %3 re-filed on the account, %4 could not be, %5 moved here, %6 removed, %7 failed."),
                       downloaded, adopted, moved, move_failed, renamed, deleted, failed)
    end
    if adopted > 0 then
        return true, T(_("Books: %1 new, %2 already here, %3 moved, %4 removed, %5 failed."),
                       downloaded, adopted, renamed, deleted, failed)
    end
    return true, T(_("Books: %1 new, %2 moved, %3 removed, %4 failed."),
                   downloaded, renamed, deleted, failed)
end

-- Exported for the move tests: deciding a move from a delete is the one piece
-- of guesswork in this file, and it is testable without a device.
Library.findMovedTo = findMovedTo

Library.sidecarDir = sidecarDir
Library.ensureDir = ensureDir

return Library
