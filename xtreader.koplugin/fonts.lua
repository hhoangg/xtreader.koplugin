--[[
Font sync.

Mirrors the account's `.ttf` / `.otf` files into
`/mnt/us/fonts/xtreader/<family>/<fileName>`.

Why that folder, and why a restart:

  * KOReader on Kindle adds `/mnt/us/fonts` to its font path (EXT_FONT_DIR in
    koreader.sh) and scans it recursively, so one subfolder per family is
    picked up with no setting to change.
  * crengine registers fonts once, at startup (CreDocument:engineInit). A font
    added now is invisible until KOReader restarts, and so is the removal of
    one -- a deleted file stays registered and in the menu until then. Either
    change is a reason to ask for a restart.
  * The plugin owns `/mnt/us/fonts/xtreader` outright. After a sync it may
    trust, that folder holds exactly the manifest's files and nothing else.
    Everything else in `/mnt/us/fonts` is the user's and is never looked at.
  * On Kindle, KOReader silently skips any font whose bare filename is on its
    blacklist (fontlist.lua isInFontsBlacklist). Such a file downloads fine and
    never shows up. Nothing here can change that, so nothing here tries.

Deleting is gated harder than downloading. The manifest is always the full set
with no tombstones, so anything local it does not list is a deletion candidate
-- but an empty or stale answer looks exactly like that too. Extras are removed
only when the manifest's `revision` equals the `fontsRevision` the heartbeat
just reported: the server's way of saying "this is the whole set, as of now".
Otherwise the sync adds and replaces, and leaves the rest to a run that can be
sure.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Fonts = {}

local FORMATS = { ttf = true, otf = true }

--- Ids are turned into URLs, so they are checked like every other id.
local function safeId(id)
    return type(id) == "string" and id ~= "" and id:match("^[A-Za-z0-9_%-]+$") ~= nil
end

--- Why a manifest entry is unusable, or nil when it is fine.
--
-- Family and fileName become a path on the card, so a hostile or buggy server
-- must not be able to steer a write out of the font folder with a `/`, a `\`
-- or a `..`. The server promises all of this; it is checked anyway, because
-- the cost of trusting it wrongly is a write anywhere under /mnt/us.
local function invalidReason(e)
    if type(e) ~= "table" then
        return "not an object"
    end
    if not safeId(e.id) then
        return "bad id"
    end
    local family = e.family
    if type(family) ~= "string" or #family > 64 or not family:match("^[A-Za-z0-9_%-]+$") then
        return "bad family"
    end
    local name = e.fileName
    if type(name) ~= "string" or name == "" or #name > 128 then
        return "bad fileName length"
    end
    if name:find("[/\\]") or name:find("..", 1, true)
        or name:sub(1, 1) == "." or name:find("%c") then
        return "unsafe fileName"
    end
    -- Not in the contract's list, but just as illegal on the Kindle's FAT
    -- volume: such a name would fail at open time on every sync, forever.
    if name:find('[:*?"<>|]') then
        return "unsafe fileName"
    end
    if not FORMATS[e.format] then
        return "unsupported format"
    end
    -- KOReader picks fonts by extension, so a `.otf` served as "ttf" (or the
    -- reverse) is a server bug that would still install, just under a lie.
    if name:lower():sub(-(#e.format + 1)) ~= "." .. e.format then
        return "extension does not match format"
    end
    if type(e.sizeBytes) ~= "number" or e.sizeBytes < 0 then
        return "bad sizeBytes"
    end
    if type(e.contentHash) ~= "string" or e.contentHash == "" then
        return "bad contentHash"
    end
    return nil
end

local function relPath(e)
    return e.family .. "/" .. e.fileName
end

local function sameHash(a, b)
    return type(a) == "string" and type(b) == "string" and a:lower() == b:lower()
end

--- The manifest entries worth acting on, in manifest order.
--
-- Duplicates are judged case-insensitively because the card is FAT: two names
-- that differ only by case are one file there, and syncing both would have
-- each run overwrite the other forever. The first one wins. The same goes for
-- a family spelled two ways: both would land in one folder, under whichever
-- spelling FAT kept, and the other would look mis-cased on every run.
function Fonts.wantedEntries(entries)
    local wanted, seen, families = {}, {}, {}
    for _idx, e in ipairs(entries or {}) do
        local why = invalidReason(e)
        if why then
            logger.warn("xtreader: font entry skipped:", why,
                        type(e) == "table" and tostring(e.id) or "")
        else
            local key = relPath(e):lower()
            local fam = families[e.family:lower()]
            if seen[key] or (fam ~= nil and fam ~= e.family) then
                logger.warn("xtreader: duplicate font path skipped:", relPath(e))
            else
                seen[key] = true
                families[e.family:lower()] = e.family
                wanted[#wanted + 1] = e
            end
        end
    end
    return wanted
end

--- Everything under `dir`, one level into each family folder, as
--- `{ path = "<rel>", mode = "file"|"directory", size = n }`.
-- A folder nested inside a family is listed but not entered: nothing wanted
-- ever lives there, so it is only ever removed whole.
function Fonts.listLocal(dir)
    local out = {}
    local function scan(abs, prefix, descend)
        local ok_iter, iter, obj = pcall(lfs.dir, abs)
        if not ok_iter or type(iter) ~= "function" then
            return
        end
        for name in iter, obj do
            if name ~= "." and name ~= ".." then
                local rel = prefix and (prefix .. "/" .. name) or name
                local attr = lfs.attributes(abs .. "/" .. name)
                if attr and attr.mode == "directory" then
                    out[#out + 1] = { path = rel, mode = "directory" }
                    if descend then
                        scan(abs .. "/" .. name, rel, false)
                    end
                elseif attr then
                    out[#out + 1] = { path = rel, mode = "file", size = attr.size }
                end
            end
        end
    end
    scan(dir, nil, true)
    return out
end

--- Decides what to delete, download and hash-check. Pure: no I/O.
--
-- `wanted` is the output of wantedEntries, `listing` of listLocal, `ledger` is
-- `rel -> { id, hash, size }`. Returns:
--
--   delete   items from `listing` to remove (`part = true` for `.part` files)
--   gone     non-`.part` file paths that will not survive the deletions
--   download entries to fetch
--   verify   entries present at the right size that the ledger does not know;
--            hash them, adopt on a match, download otherwise
--   drop     ledger paths with no file left behind them
--   kept     how many extras were left alone because `authoritative` was false
--
-- Matching is case-insensitive because the card is FAT. A local name that
-- differs from the wanted one only by case is deleted even when the set is
-- not authoritative: the wanted file replaces it, so nothing is lost, and
-- leaving it would have every later run see the wrong name again. A mis-cased
-- family folder goes whole for the same reason, extras inside it included.
function Fonts.reconcile(wanted, listing, ledger, authoritative)
    local plan = { delete = {}, gone = {}, download = {}, verify = {}, drop = {}, kept = 0 }
    ledger = ledger or {}

    local by_key, families = {}, {}
    for _i, e in ipairs(wanted) do
        by_key[relPath(e):lower()] = e
        families[e.family:lower()] = e.family
    end

    local present = {}   -- exact rel -> size, for wanted files at their exact name
    local survives = {}  -- rel -> true, for files still on disk afterwards
    local dir_fate = {}  -- top-level dir -> "delete" | "keep" when handled whole

    local function extra(item)
        if authoritative then
            plan.delete[#plan.delete + 1] = item
            return "delete"
        end
        plan.kept = plan.kept + 1
        return "keep"
    end

    -- Top-level folders first, so their contents can follow their fate
    -- whatever order the listing arrived in.
    for _i, item in ipairs(listing) do
        if item.mode == "directory" and not item.path:find("/", 1, true) then
            local fam = families[item.path:lower()]
            if fam == nil then
                dir_fate[item.path] = extra(item)
            elseif fam ~= item.path then
                plan.delete[#plan.delete + 1] = item
                dir_fate[item.path] = "delete"
            end
        end
    end

    for _i, item in ipairs(listing) do
        local top, rest = item.path:match("^([^/]+)/(.+)$")
        top = top or item.path
        local is_part = item.mode == "file" and item.path:lower():match("%.part$") ~= nil
        if is_part then
            -- An interrupted download is never anybody's font.
            plan.delete[#plan.delete + 1] = { path = item.path, mode = "file", part = true }
        elseif rest == nil then
            if item.mode ~= "directory" and extra(item) == "keep" then
                survives[item.path] = true
            end
        elseif dir_fate[top] then
            if item.mode == "file" and dir_fate[top] == "keep" then
                survives[item.path] = true
            end
        elseif not rest:find("/", 1, true) then
            local e = by_key[item.path:lower()]
            if item.mode == "directory" then
                extra(item)
            elseif e == nil then
                if extra(item) == "keep" then
                    survives[item.path] = true
                end
            elseif relPath(e) ~= item.path then
                plan.delete[#plan.delete + 1] = item
            else
                present[item.path] = item.size
                survives[item.path] = true
            end
        end
        -- Anything deeper sits inside a nested folder, which was handled whole.
        if item.mode == "file" and not is_part and not survives[item.path]
            and (rest == nil or not rest:find("/", 1, true)) then
            plan.gone[#plan.gone + 1] = item.path
        end
    end

    for _i, e in ipairs(wanted) do
        local rel = relPath(e)
        local size = present[rel]
        local known = ledger[rel]
        if size == nil or size ~= e.sizeBytes then
            plan.download[#plan.download + 1] = e
        elseif known then
            if not sameHash(known.hash, e.contentHash) then
                plan.download[#plan.download + 1] = e
            end
        else
            plan.verify[#plan.verify + 1] = e
        end
    end

    for rel in pairs(ledger) do
        if not survives[rel] then
            plan.drop[#plan.drop + 1] = rel
        end
    end

    return plan
end

--- Runs a full font sync. Must be called inside a Trapper:wrap.
--
-- Returns `ok, message, changed, revision`. `ok` is true only for a run that
-- may be recorded as done: manifest fetched, every file landed, nothing
-- cancelled, and the set authoritative -- a run that could not delete is not
-- finished, and recording it would stop the next one from happening.
-- `changed` means the files crengine will see at its next start differ from
-- the ones it registered, which is what a restart prompt is for.
function Fonts.sync(api, store, heartbeat_revision, report)
    local Library = require("library")
    local dir = store:get("font_dir")
    if not Library.ensureDir(dir) then
        return false, T(_("Cannot create %1"), dir), false, nil
    end

    report(_("Fetching fonts…"))
    local entries, code, _total, revision = api:fetchManifest("/fonts/manifest", "formats=ttf,otf&limit=200")
    if not entries then
        return false, T(_("Font manifest failed (%1)"), tostring(code)), false, nil
    end

    local authoritative = revision ~= nil and revision == heartbeat_revision
    if not authoritative then
        logger.warn("xtreader: font manifest revision", tostring(revision),
                    "does not match heartbeat", tostring(heartbeat_revision),
                    "; unlisted files will be kept")
    end

    local wanted = Fonts.wantedEntries(entries)
    local ledger = {}
    for rel, known in store:eachFont() do
        ledger[rel] = known
    end
    local plan = Fonts.reconcile(wanted, Fonts.listLocal(dir), ledger, authoritative)

    -- Deletions first, so a case-only rename frees its name before the
    -- replacement is written, and a full card gets its room back.
    for _i, item in ipairs(plan.delete) do
        local full = dir .. "/" .. item.path
        if item.mode == "directory" then
            Library.removeTree(full)
        else
            os.remove(full)
        end
    end
    -- Counted by looking, not by trusting os.remove: a file that would not go
    -- is still registered at the next start, so it is not a change.
    local removed = 0
    for _i, rel in ipairs(plan.gone) do
        if lfs.attributes(dir .. "/" .. rel, "mode") == nil then
            removed = removed + 1
        end
    end
    if authoritative then
        local empty = {}
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".."
                and lfs.attributes(dir .. "/" .. name, "mode") == "directory" then
                empty[#empty + 1] = dir .. "/" .. name
            end
        end
        for _i, full in ipairs(empty) do
            lfs.rmdir(full) -- refuses a folder that still has anything in it
        end
    end
    for _i, rel in ipairs(plan.drop) do
        store:removeFont(rel)
    end

    -- A file of the right size the ledger never recorded: most likely a
    -- previous run's download whose ledger write never happened. Hashing it
    -- is cheaper than fetching it again, and honest about a mismatch.
    if #plan.verify > 0 then
        report(_("Checking fonts…"))
    end
    for _i, e in ipairs(plan.verify) do
        local rel = relPath(e)
        if sameHash(Library.contentHash(dir .. "/" .. rel), e.contentHash) then
            store:setFont(rel, { id = e.id, hash = e.contentHash, size = e.sizeBytes })
        else
            plan.download[#plan.download + 1] = e
        end
    end

    local added, failed, cancelled = 0, 0, false
    for i, e in ipairs(plan.download) do
        if report(T(_("Font %1 of %2…"), i, #plan.download)) == false then
            cancelled = true
            break
        end
        local rel = relPath(e)
        local target = dir .. "/" .. rel
        Library.ensureDir(dir .. "/" .. e.family)
        -- Size is gated in downloadTo and the hash here. A font that is not
        -- the manifest's bytes is not installed: crengine would register it at
        -- the next start and there would be no second opinion after that.
        local ok = api:downloadTo("/fonts/" .. e.id .. "/file", target, e.sizeBytes)
        if ok and sameHash(Library.contentHash(target), e.contentHash) then
            store:setFont(rel, { id = e.id, hash = e.contentHash, size = e.sizeBytes })
            added = added + 1
        else
            if ok then
                logger.warn("xtreader: font hash mismatch, deleted:", rel)
                os.remove(target)
                store:removeFont(rel)
            end
            failed = failed + 1
        end
    end

    store:flush()

    local ok = failed == 0 and not cancelled and authoritative
    local message = T(_("Fonts: %1 new, %2 removed, %3 failed."), added, removed, failed)
    if plan.kept > 0 then
        message = message .. "\n"
            .. _("Fonts no longer listed were kept: the server's list could not be confirmed complete.")
    end
    return ok, message, (added > 0 or removed > 0), revision
end

-- Exported for the tests.
Fonts.invalidReason = invalidReason
Fonts.relPath = relPath

return Fonts
