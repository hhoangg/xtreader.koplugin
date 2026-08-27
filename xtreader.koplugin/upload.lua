--[[
Push this device's books up to the account — `POST /library/upload`.

The other direction has existed since the beginning: the account is the source
and the reader catches up. This is what makes a book that only ever existed on
one card into a book the account holds, which is the difference between a
library and a pile of files on a device that will eventually die.

WHO IS ALLOWED

Exactly one reader per account, or none. The server holds
`devices.is_upload_source` and answers `403 not_upload_device` to everybody
else — including every device when nobody has been nominated, which is the
state a fresh account is in. One code covers both cases on purpose: from here
they are the same fact, and distinguishing them would tell this device about
the existence of another one.

The check happens before a single byte of the body is read, so a 403 costs
nothing. There is therefore no permission probe here — the push just pushes and
handles the refusal.

IDENTITY, AND THE TWO HASHES THAT ARE NOT INTERCHANGEABLE

`contentHash` is SHA-256 over the whole file. NOT the partial MD5 that KOSync
and the statistics plugin key on: that one samples a few ranges to identify a
reading position cheaply, and cannot answer "are these the same bytes", which
is the only question the account cares about when a book arrives from two
places.

Measured on a Paperwhite 5 before this was written, because a whole-file hash
on an e-reader is exactly the kind of requirement that is fine in a spec and
unaffordable on the hardware: `ffi/sha2`'s streaming sha256 runs at 13.7 MB/s,
so a 10 MB book costs about a second and a 440 MB library about a minute. The
transfer is roughly seven times slower than the hash, so there is nothing to
gain by trying to avoid hashing.

THE 409 THAT IS NOT A DUPLICATE

`409 path_taken` means a LIVE book already occupies that path. The constraint
is `(user_id, path)` and it knows nothing about content, so it fires in two
quite different situations:

    the account already has THIS book there     -> genuinely done, skip quietly
    the account has a DIFFERENT book there      -> this book was NOT adopted

The second is the one that matters. Skipping it silently would let a push
report "88 sent, 12 skipped" — every word true — while quietly failing to adopt
a book the owner wanted kept. So the manifest is fetched first and the hashes
are compared: an equal hash is a silent skip, a differing one is reported.

It is deliberately reported and not resolved. Whether two different books at
one path should displace each other is the owner's call and he has not made it;
guessing here would take the decision away from him.
]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Upload = {}

-- Extensions worth pushing. Kept narrow on purpose: this walks the reader's
-- whole library folder, and sweeping up every stray file next to the books
-- would upload someone's fonts and .sdr sidecars to their account.
local BOOK_EXT = {
    epub = true, mobi = true, azw = true, azw3 = true, pdf = true,
    fb2 = true, djvu = true, cbz = true, cbr = true, txt = true,
    rtf = true, doc = true, chm = true, htm = true, html = true,
}

-- The server's ceiling. Checked here as well so an oversized book is reported
-- as skipped rather than spending three minutes uploading to earn a 413.
local MAX_BYTES = 100 * 1024 * 1024

-- Read size for hashing. 64 KB is what KOReader's own file paths use; larger
-- buys nothing measurable and holds more of a big book in memory at once.
local HASH_CHUNK = 64 * 1024

--- Top-level folder names the reader has chosen not to upload.
--
-- A list rather than a filter on content, because the reasons for excluding a
-- folder are not things this code can detect. On the device this was built
-- against, two of them:
--
--   * `Downloads` holds the original Kindle AZW3 files that were converted to
--     EPUB and filed elsewhere. Uploading both puts the same book on the
--     account twice, under two paths, with no way for the account to know.
--   * `dictionaries` holds DRM-protected Amazon purchases. They cannot be
--     opened anywhere but the Kindle that bought them, so an account copy is
--     bytes nobody can ever read.
--
-- Neither is something a size or an extension reveals. So this is the reader's
-- call and the default is to exclude nothing.
-- Takes the raw comma-separated string rather than reading a settings store,
-- so scan() stays a pure function of its arguments and the callers -- which
-- already hold the store -- decide where the value comes from.
local function skipSet(raw)
    local set = {}
    if type(raw) ~= "string" or raw == "" then return set end
    for name in raw:gmatch("[^,]+") do
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then set[name] = true end
    end
    return set
end

Upload.skipSet = skipSet

--- Extensions the reader wants uploaded, or nil for "whatever is a book".
--
-- This is the filter that matches what people actually mean, and the folder
-- list above is the one that does not.
--
-- A library converted from a Kindle holds the ORIGINALS and the converted
-- copies side by side. Asking "which folders do I not want" makes the reader
-- work out where the originals ended up; asking "which formats do I want"
-- is the same answer stated directly -- and it keeps working when a stray
-- .azw3 turns up in a folder nobody thought to exclude.
local function formatSet(raw)
    if type(raw) ~= "string" or raw:gsub("%s", "") == "" then return nil end
    local set = {}
    for e in raw:gmatch("[^,]+") do
        e = e:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%.", ""):lower()
        if e ~= "" then set[e] = true end
    end
    return next(set) and set or nil
end

Upload.formatSet = formatSet

local function extOf(name)
    local e = name:match("%.([^.]+)$")
    return e and e:lower() or nil
end

--- SHA-256 of a whole file, hex, streamed. nil plus a reason on failure.
function Upload.contentHash(path)
    local ok, sha = pcall(require, "ffi/sha2")
    if not ok or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
        return nil, "no_sha256"
    end
    local f, err = io.open(path, "rb")
    if not f then return nil, err or "cannot_open" end
    -- sha.sha256() with no argument returns an appender: feed it chunks, then
    -- call it with nothing to finalise. This is what keeps a 100 MB book from
    -- ever being a 100 MB Lua string.
    local append = sha.sha256()
    while true do
        local chunk = f:read(HASH_CHUNK)
        if not chunk then break end
        append(chunk)
    end
    f:close()
    return append()
end

--- Percent-escape a path for a query string.
--
-- Escaping everything outside the unreserved set rather than a blocklist: these
-- paths carry Vietnamese titles, and a blocklist that has not thought about
-- U+1EA1 will pass it through and produce a request the server reads as a
-- different path than the one meant.
function Upload.escape(s)
    return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- Every book file under `root`, as { path = absolute, rel = account path }.
--
-- `rel` is the account path and the mapping is the one the owner chose: the
-- device's library root IS the account root, so a book at
-- `<root>/Tiên hiệp/X.epub` is `/Tiên hiệp/X.epub` on the account. That is
-- `localPathFor` run backwards, and nothing arbitrates it.
function Upload.scan(root, skip_csv, formats_csv)
    local lfs = require("libs/libkoreader-lfs")
    root = tostring(root):gsub("/+$", "")
    local skip = skipSet(skip_csv)
    -- nil means "every format this understands"; a set narrows it.
    local want = formatSet(formats_csv)
    local out = {}
    local function walk(dir, depth)
        -- 12 is far past any sane library nesting and stops a symlink loop from
        -- turning a scan into a hang with no way to tell what happened.
        if depth > 12 then return end
        local ok_iter, iter, obj = pcall(lfs.dir, dir)
        if not ok_iter or type(iter) ~= "function" then return end
        for name in iter, obj do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local full = dir .. "/" .. name
                local attr = lfs.attributes(full)
                if attr and attr.mode == "directory" then
                    -- Excluded only at the TOP level. A folder named
                    -- "Downloads" three levels down inside somebody's library
                    -- is theirs and has nothing to do with Kindle's.
                    local excluded = (depth == 1) and skip[name]
                    if not excluded and not name:match("%.sdr$") then
                        walk(full, depth + 1)
                    end
                elseif attr and attr.mode == "file"
                        and BOOK_EXT[extOf(name) or ""]
                        and (want == nil or want[extOf(name) or ""]) then
                    out[#out + 1] = {
                        path = full,
                        rel  = full:sub(#root + 1),   -- keeps the leading "/"
                        size = attr.size or 0,
                    }
                end
            end
        end
    end
    walk(root, 1)
    table.sort(out, function(a, b) return a.rel < b.rel end)
    return out
end

--- What the account already holds, keyed by path -> contentHash.
--
-- Fetched before anything is sent so a 409 can be explained rather than merely
-- counted. Also lets an interrupted push resume for free: a book the account
-- already has at the same path with the same bytes is skipped without being
-- hashed or read.
local function accountByPath(api)
    local entries, code = api:fetchManifest("/library/manifest", "limit=200")
    if not entries then return nil, code end
    local by_path = {}
    for _i, e in ipairs(entries) do
        if e.deleted ~= true and e.path then
            by_path[e.path] = e.contentHash or true
        end
    end
    return by_path
end

--- Push every local book the account does not already hold.
--
-- Call inside a Trapper:wrap. `report(text)` returns false when the reader
-- asked to stop, and a stop is honoured between books -- never mid-book, since
-- an aborted body is a partial object the server would have to clean up.
--
-- Returns ok, message, stats.
function Upload.pushAll(api, store, report)
    if not store:isPaired() then
        return false, _("Pair this device with xtreader first.")
    end
    local root = store:get("library_dir")
    if not root then
        return false, _("No library folder is configured.")
    end

    local books = Upload.scan(root, store:get("upload_skip"), store:get("upload_formats"))
    if #books == 0 then
        return true, _("No books found to upload."), { total = 0 }
    end

    -- The return value matters here too. Fetching the manifest is a network
    -- round trip on a device whose Wi-Fi may still be waking up, so it is a
    -- plausible moment to change your mind -- and an abort that lands on a
    -- report nobody checks is an abort that silently does nothing, which is
    -- how a reader learns not to trust the stop button.
    if report(T(_("Checking what the account already has… (%1 books here)"), #books)) == false then
        return true, _("Stopped before anything was sent.")
    end
    local have, code = accountByPath(api)
    if not have then
        return false, T(_("Could not read the library manifest (%1)."), tostring(code))
    end

    local stats = {
        total = #books, sent = 0, skipped = 0, conflict = 0,
        too_big = 0, failed = 0, forbidden = false,
    }
    -- Paths the account holds under a DIFFERENT book. Collected rather than
    -- counted so the message can name them: "3 conflicts" is not something the
    -- owner can act on, and acting on it is the only reason to report it.
    local conflicts = {}

    -- Set when the reader aborts DURING a book rather than between two. The
    -- upload itself is not cut short -- an abandoned body is a partial object
    -- the server has to clean up -- so the flag is checked at the top of the
    -- next iteration instead.
    local aborted = false

    for i, b in ipairs(books) do
        if aborted then break end
        if report(T(_("Uploading %1 of %2:\n%3"), i, #books, b.rel)) == false then
            break
        end

        if b.size > MAX_BYTES then
            stats.too_big = stats.too_big + 1
            logger.warn("xtreader: too large to upload:", b.rel, b.size)
        else
            local hash, hash_err = Upload.contentHash(b.path)
            if not hash then
                stats.failed = stats.failed + 1
                logger.warn("xtreader: cannot hash:", b.rel, tostring(hash_err))
            else
                local known = have[b.rel]
                if known == hash then
                    -- Same path, same bytes: the account has this exact book.
                    stats.skipped = stats.skipped + 1
                elseif known ~= nil then
                    -- Same path, DIFFERENT bytes. Not adopted, and the owner is
                    -- the one who decides what should happen -- see the header.
                    stats.conflict = stats.conflict + 1
                    conflicts[#conflicts + 1] = b.rel
                    logger.warn("xtreader: path held by a different book, not uploaded:", b.rel)
                else
                    local query = "path=" .. Upload.escape(b.rel)
                                  .. "&contentHash=" .. Upload.escape(hash)
                    -- THE STOP BUTTON LIVES HERE, and it is not decoration.
                    --
                    -- Trapper only repaints -- and only notices a tap -- when
                    -- the coroutine yields, and `report` is what yields. Called
                    -- once per book, as it was, a 10 MB upload is minutes in a
                    -- blocking socket loop with no yield in it: the pause
                    -- dialog cannot be drawn at the one moment somebody wants
                    -- it, so the reader taps a frozen screen and concludes the
                    -- device has hung. Reported on the device, and the only way
                    -- out was a signal over SSH.
                    --
                    -- Reporting from inside the upload's own byte pump gives
                    -- the coroutine a yield point every chunk. Throttled to
                    -- whole percent steps because `report` repaints e-ink and
                    -- doing that per 8 KB chunk would cost more than the
                    -- transfer.
                    local last_pct = -1
                    local sent_cb = function(sofar)
                        local pct = math.floor((sofar / math.max(1, b.size)) * 100)
                        if pct > last_pct then
                            last_pct = pct
                            if report(T(_("Uploading %1 of %2 — %3%%\n%4"),
                                        i, #books, pct, b.rel)) == false then
                                aborted = true
                            end
                        end
                    end
                    local entry, up_code = api:uploadFile("/library/upload", query,
                                                          b.path, sent_cb)
                    if entry then
                        stats.sent = stats.sent + 1
                        -- Record it the way a sync would, so the next inventory
                        -- report counts it and the next sync does not fetch
                        -- back the book we just sent.
                        if entry.id then
                            store:setBook(entry.id, {
                                path = entry.path or b.rel, hash = hash, size = b.size,
                            })
                        end
                    elseif up_code == 403 then
                        -- Nobody is nominated, or somebody else is. Either way
                        -- every remaining book would answer the same, so stop
                        -- rather than spending the walk to be refused 87 more
                        -- times.
                        stats.forbidden = true
                        break
                    elseif up_code == 409 then
                        -- Raced with another writer between the manifest and
                        -- now. Same meaning as the known-hash case.
                        stats.skipped = stats.skipped + 1
                    else
                        stats.failed = stats.failed + 1
                        logger.warn("xtreader: upload failed:", b.rel, tostring(up_code))
                    end
                end
            end
        end
    end
    store:flush()

    if aborted then
        local done = { T(_("Stopped. %1 uploaded so far"), stats.sent) }
        if stats.skipped > 0 then done[#done + 1] = T(_("%1 already there"), stats.skipped) end
        return true, table.concat(done, ", ") .. ".\n\n"
               .. _("Running it again carries on from here: books already on the account are skipped without being read."), stats
    end

    if stats.forbidden then
        return false, _("This reader is not the account's upload source.\n\nChoose it in the device list on the web, then try again."), stats
    end

    local parts = { T(_("Uploaded %1"), stats.sent) }
    if stats.skipped > 0 then parts[#parts + 1] = T(_("%1 already there"), stats.skipped) end
    if stats.too_big > 0 then parts[#parts + 1] = T(_("%1 too large"), stats.too_big) end
    if stats.failed  > 0 then parts[#parts + 1] = T(_("%1 failed"), stats.failed) end
    local msg = table.concat(parts, ", ") .. "."
    if stats.conflict > 0 then
        -- Named, not counted. The owner cannot act on a number.
        local shown = {}
        for i = 1, math.min(5, #conflicts) do shown[#shown + 1] = conflicts[i] end
        msg = msg .. "\n\n" .. T(_("%1 not uploaded: the account already has a different book at that path.\n\n%2"),
                                 stats.conflict, table.concat(shown, "\n"))
        if #conflicts > #shown then
            msg = msg .. "\n" .. T(_("…and %1 more (see the log)."), #conflicts - #shown)
        end
    end
    return true, msg, stats
end

--- What a push WOULD do, without sending anything.
--
-- Exists because the first real push should not also be the first time this
-- code runs: it hashes and compares exactly as pushAll does, and stops short of
-- the request. The 403 is the one thing it cannot predict -- the server does
-- not say who the upload source is, only whether you are it.
function Upload.dryRun(api, store, report)
    if not store:isPaired() then
        return false, _("Pair this device with xtreader first.")
    end
    local root = store:get("library_dir")
    if not root then return false, _("No library folder is configured.") end

    local books = Upload.scan(root, store:get("upload_skip"), store:get("upload_formats"))
    if report(T(_("Found %1 books. Reading the account…"), #books)) == false then
        return true, _("Stopped.")
    end
    local have, code = accountByPath(api)
    if not have then
        return false, T(_("Could not read the library manifest (%1)."), tostring(code))
    end

    local would, same, differ, big = 0, 0, 0, 0
    local bytes = 0
    for i, b in ipairs(books) do
        if report(T(_("Checking %1 of %2…"), i, #books)) == false then break end
        if b.size > MAX_BYTES then
            big = big + 1
        else
            local known = have[b.rel]
            if known == nil then
                would = would + 1
                bytes = bytes + b.size
            else
                local hash = Upload.contentHash(b.path)
                if hash and known == hash then same = same + 1 else differ = differ + 1 end
            end
        end
    end
    return true, T(_("Would upload %1 books (%2 MB).\n%3 already on the account, %4 at a path held by a different book, %5 too large."),
                   would, string.format("%.0f", bytes / 1048576), same, differ, big)
end

return Upload
