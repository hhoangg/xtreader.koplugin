--[[
Reading-statistics ingest — `POST /stats/pages`.

Ships KOReader's own per-page reading records to the server so the web dashboard
can show streaks, heatmaps, time-of-day and per-book pace across every reader on
the account, rather than one device's local view.

WHAT IS READ, AND WHAT IS DELIBERATELY NOT

The source is `statistics.sqlite3`, KOReader's own database, opened READ-ONLY.
Nothing here ever writes to it. It belongs to the statistics plugin.

Rows come from `page_stat_data`, the real table — never from the `page_stat`
VIEW. That view rescales historical page numbers against the book's *current*
page count, fanning one stored row into several and integer-dividing `duration`
between them. Ingesting the view would store a lossy projection that cannot be
undone; the server reimplements the same rescaling from `total_pages` per row,
which is why `tp` is sent honestly per row rather than stamped with today's
pagination.

IDENTITY

`book.id` is a local autoincrement and means nothing on another device —
KOReader's own history-merge code builds a remap table for exactly this reason.
The stable key is `book.md5`, which is `util.partialMD5` of the file content,
cached once in the sidecar (readerui.lua:497-501). It is the SAME string KOSync
sends as its document id in binary mode, so reading statistics and reading
progress land on one identity server-side with no bridging.

THE WATERMARK

The floor for the next run is the highest `start_time` in the batch this device
just sent -- its own progress through its own table.

It is deliberately NOT the server's `maxStartTime`, even though the response
carries one. That figure is computed over the WHOLE ACCOUNT, so a reader that
synced more recently drags it forward; adopting it here would jump this device's
cursor past rows it had not sent yet and skip them permanently. The account-wide
value cannot help in the other direction either, because `page_stat_data` is
local -- another reader's rows were never in this table to be skipped.

It is advanced ONLY after a request the server confirmed. A watermark moved past
rows that were never stored would skip them permanently and silently, and the
server refuses oversized batches outright (413, nothing written) precisely so a
partial write can never be mistaken for a whole one.

Re-sending costs nothing: the server dedups on (book, page, start_time) and
reports the duplicates back as `ignored`. Skipping costs everything. So where
the two risks meet, this errs toward sending again.
]]

local DataStorage = require("datastorage")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Insights = {}

-- Server limits. Exceeding any of them is a 413 with nothing written, so these
-- are ceilings to stay under, not targets to aim at.
local MAX_ROWS_PER_BATCH = 2000
local MAX_BOOKS_PER_BATCH = 200

local function dbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

--- Reads one batch of page records newer than `since`.
-- Returns books[], rows[], and the highest start_time in the batch, or nil.
local function readBatch(since, limit)
    local lfs = require("libs/libkoreader-lfs")
    local path = dbPath()
    if lfs.attributes(path, "mode") ~= "file" then
        return nil, "no_statistics_db"
    end

    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        return nil, "no_sqlite_binding"
    end

    local conn
    local opened = pcall(function() conn = SQ3.open(path, "ro") end)
    if not opened or not conn then
        -- Older bindings may not accept a mode argument; fall back, but never
        -- issue anything but SELECT against this file.
        local ok2 = pcall(function() conn = SQ3.open(path) end)
        if not ok2 or not conn then
            return nil, "cannot_open_db"
        end
    end

    -- A book with no md5 has no stable identity, so its rows cannot be
    -- attributed to anything and are skipped rather than sent under a
    -- fabricated key.
    local sql = string.format([[
        SELECT d.id_book, b.md5, b.title, b.authors, b.pages,
               d.page, d.start_time, d.duration, d.total_pages
        FROM page_stat_data d
        JOIN book b ON b.id = d.id_book
        WHERE d.start_time > %d
          AND b.md5 IS NOT NULL AND b.md5 != ''
          AND d.duration > 0
        ORDER BY d.start_time ASC
        LIMIT %d;
    ]], since, limit)

    local result
    local queried = pcall(function() result = conn:exec(sql) end)
    pcall(function() conn:close() end)
    if not queried or type(result) ~= "table" or not result[1] then
        return {}, {}, nil -- no rows is a normal, successful answer
    end

    -- ljsqlite3's exec returns column-major arrays.
    local col = {}
    for i, name in ipairs({ "id_book", "md5", "title", "authors", "pages",
                            "page", "start_time", "duration", "total_pages" }) do
        col[name] = result[i]
    end

    local books, rows = {}, {}
    local by_md5 = {}
    local max_ts = nil
    local count = #col.md5

    for i = 1, count do
        local md5 = col.md5[i]
        if type(md5) == "string" and md5 ~= "" then
            local idx = by_md5[md5]
            if idx == nil then
                if #books >= MAX_BOOKS_PER_BATCH then
                    -- Stop cleanly at the book ceiling; the remaining rows come
                    -- back on the next run, ordered by start_time as always.
                    break
                end
                books[#books + 1] = {
                    idx = #books,
                    partialMd5 = md5,
                    title = col.title[i],
                    authors = col.authors[i],
                    pages = tonumber(col.pages[i]),
                }
                idx = #books - 1
                by_md5[md5] = idx
            end

            local ts = tonumber(col.start_time[i])
            rows[#rows + 1] = {
                b = idx,
                page = tonumber(col.page[i]),
                t = ts,
                d = tonumber(col.duration[i]),
                tp = tonumber(col.total_pages[i]),
            }
            if ts and (max_ts == nil or ts > max_ts) then
                max_ts = ts
            end
        end
    end

    return books, rows, max_ts
end

--- Pushes every page record the server has not seen. Call inside a Trapper:wrap.
-- `report(text)` returns false when the user asked to stop.
function Insights.sync(api, store, report)
    if not store:isPaired() then
        return false, _("Pair this device with xtreader first.")
    end

    local since = tonumber(store:get("stats_watermark")) or 0
    local total_accepted, total_ignored, batches = 0, 0, 0

    while true do
        local books, rows, batch_max = readBatch(since, MAX_ROWS_PER_BATCH)
        if books == nil then
            local reason = rows
            if reason == "no_statistics_db" then
                return false, _("No reading statistics yet.\nKOReader records them once you have read a few pages with the Statistics plugin enabled.")
            end
            return false, T(_("Cannot read reading statistics (%1)."), tostring(reason))
        end
        if #rows == 0 then
            break
        end

        batches = batches + 1
        if report(T(_("Sending reading statistics: %1 records…"), #rows)) == false then
            break
        end

        local body, code = api:postJson("/stats/pages", {
            books = books,
            rows = rows,
        })
        if not body then
            return false, T(_("Statistics upload failed (%1)."), tostring(code))
        end

        total_accepted = total_accepted + (tonumber(body.accepted) or 0)
        total_ignored = total_ignored + (tonumber(body.ignored) or 0)

        -- ADVANCE BY THIS BATCH, NEVER BY THE SERVER'S maxStartTime.
        --
        -- `maxStartTime` is computed over the WHOLE ACCOUNT, so another reader
        -- that synced more recently drags it forward. Using it as this device's
        -- cursor loses data, and loses it silently:
        --
        --   this Kindle is offline for a month while the other reader syncs
        --   daily -> we come back, send our oldest 2000 rows, and the server
        --   answers with a maxStartTime of *today* because of the other device
        --   -> the cursor jumps a month ahead -> every remaining row we had
        --   queued from that month is skipped, permanently.
        --
        -- The account-wide figure never helps here either, which is what makes
        -- this a pure loss: `page_stat_data` is local, so the other reader's
        -- rows were never in our table to be skipped.
        --
        -- `batch_max` is our own progress through our own table, so it can only
        -- ever skip rows we just sent. Re-sending is free -- the server dedups
        -- on (book, page, start_time) and reports them back as `ignored`.
        local next_since = batch_max
        if next_since == nil or next_since <= since then
            -- No forward movement means another pass would re-read the same
            -- rows forever.
            logger.warn("xtreader: statistics watermark did not advance, stopping")
            break
        end
        since = next_since
        store:set("stats_watermark", since)
        store:flush()

        -- A short batch usually means the table is drained -- but not when
        -- readBatch stopped early because it hit MAX_BOOKS_PER_BATCH. In that
        -- case there is more to send, so keep going; the cursor has moved, so
        -- the next pass starts after what we just sent rather than repeating it.
        if #rows < MAX_ROWS_PER_BATCH and #books < MAX_BOOKS_PER_BATCH then
            break
        end
    end

    if batches == 0 then
        return true, _("Reading statistics already up to date.")
    end
    return true, T(_("Reading statistics: %1 sent, %2 already known."),
                   total_accepted, total_ignored)
end

Insights.dbPath = dbPath

return Insights
