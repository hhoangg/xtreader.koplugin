--[[
What was read on the Kindle before this device ran KOReader.

Amazon's framework keeps `/var/local/cc.db`, the content catalogue for the
library currently on the device, and `Entries.p_percentFinished` is how far
through each book the reader got. Switching to KOReader leaves all of that
behind: the dashboard starts from the day KOReader was installed and says
nothing about the years before it.

This ships that list to the server once, so the account can answer "what have I
read" for the whole device rather than for the part of it xtreader witnessed.

WHAT THIS IS NOT, AND WHY THE DISTINCTION IS LOAD-BEARING

It is NOT reading statistics, and the server stores it apart from them.

`cc.db` has no clock in it. There is no session table, no page-turn history, and
`p_lastOpenTime` is populated on none of the rows -- 0 of 244 on the device this
was written against. Every figure here is "this book, this percent, as of now".

The server's achievements all derive from timestamped page views: `booksFinished`
reads a book's furthest page out of stored page views and deliberately ignores
the percentage in `progress_history` (docs/API.md:710-714), and every family
shares one definition of a page, a finished book and a day (:677-679). So the
only way to make this data move an achievement would be to invent
`(page, start_time, duration)` rows -- reading sessions that never happened, at
times chosen by a script. That would poison `hours`, `pages`, `dayStreak` and
the rest along with it.

A list that answers "what have I read" without pretending to answer "when" is
worth having. A dashboard that reports hours nobody sat through is not.

ONE-SHOT, DELIBERATELY

Not part of `syncAll`. The Kindle side of a device stops changing the moment its
owner moves to KOReader, so re-reading it on every sync would spend a database
open to send the same answer forever. It is a menu item, and running it again
replaces the stored list rather than appending to it.
]]

local Device = require("device")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local KindleHistory = {}

-- Device-facing, so no /api prefix -- that half of the surface is the browser's,
-- with a cookie. Same side as /stats/pages and /library/*.
local ENDPOINT = "/imports/kindle-library"

-- The server rejects a payload whole rather than storing part of it, so a single
-- malformed row would cost the entire import. These are its limits, checked here
-- so one bad title cannot take the other 56 books down with it.
local MAX_BOOKS = 2000
local MAX_FIELD = 512

local CC_DB = "/var/local/cc.db"

-- His rule, applied here rather than server-side so the server never has to
-- carry a threshold that only means something to Amazon's rounding.
local FINISHED_AT = 99

-- The clippings file is an Entries row like any other and is not a book.
local SKIP = {
    ["Your Clippings"] = true,
    ["My Clippings"] = true,
}

--- True when this device can offer the import at all.
function KindleHistory.available()
    if not Device:isKindle() then
        return false
    end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(CC_DB, "mode") == "file"
end

--- Reads the catalogue. Returns books[] or nil, reason.
--
-- `p_percentFinished` is scaled 0-100, and -1 means unknown -- not 0-1, which is
-- what it looks like at a glance and which silently turns a `>= 0.9` filter into
-- "at least 0.9 percent read".
local function readCatalogue()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(CC_DB, "mode") ~= "file" then
        return nil, "no_cc_db"
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        return nil, "no_sqlite_binding"
    end

    local conn
    local opened = pcall(function() conn = SQ3.open(CC_DB, "ro") end)
    if not opened or not conn then
        -- This file belongs to Amazon's framework. If a read-only handle cannot
        -- be had, stop -- do not fall back to opening it writable.
        return nil, "cannot_open_cc_db"
    end

    -- `p_credits_0_name_collation` is the author already flattened out of
    -- `j_credits`, so nothing here has to parse Amazon's JSON.
    local sql = [[
        SELECT p_titles_0_nominal, p_credits_0_name_collation, p_percentFinished
        FROM Entries
        WHERE p_percentFinished > 0
        ORDER BY p_percentFinished DESC;
    ]]
    local result
    local queried = pcall(function() result = conn:exec(sql) end)
    pcall(function() conn:close() end)
    if not queried then
        return nil, "query_failed"
    end
    if type(result) ~= "table" or not result[1] then
        return {}, 0 -- an empty catalogue is a valid answer
    end

    -- ljsqlite3 returns column-major arrays.
    local titles, authors, pcts = result[1], result[2], result[3]
    local books, done = {}, 0
    for i = 1, #titles do
        local title = titles[i]
        local raw = tonumber(pcts[i])
        if type(title) == "string" and title ~= "" and not SKIP[title] and raw and raw > 0 then
            local finished = raw >= FINISHED_AT
            -- Floor at 1, not 0. A book at 0.4% rounds to zero, and zero on the
            -- dashboard reads as "never opened" -- the one thing every row in
            -- this list is evidence against, since the query only selects rows
            -- with progress above zero.
            local percent = 100
            if not finished then
                percent = math.floor(raw + 0.5)
                if percent < 1 then percent = 1 end
                if percent > 100 then percent = 100 end
            end
            local author = authors[i]
            if type(author) ~= "string" or author == "" or #author > MAX_FIELD then
                author = nil
            end
            -- `finished` is NOT sent. After the normalisation above it is exactly
            -- `percent == 100` on every row this can produce, and a second column
            -- derived from the first is a column that can drift from it. The
            -- server derives it.
            if #title <= MAX_FIELD and #books < MAX_BOOKS then
                books[#books + 1] = {
                    title = title,
                    authors = author,
                    percent = percent,
                }
                if finished then
                    done = done + 1
                end
            else
                logger.warn("xtreader: skipping Kindle entry, over the server's limits")
            end
        end
    end
    -- The tally is returned beside the list, never stored on it: `books` is
    -- serialised straight to a JSON array, and a Lua table holding both array
    -- entries and a string key is not an array any more -- the encoder may emit
    -- an object, or carry the stray key onto the wire.
    return books, done
end

--- Sends the catalogue. Call inside a Trapper:wrap; `report(text)` returns false
--- when the user asked to stop.
function KindleHistory.sync(api, store, report)
    if not store:isPaired() then
        return false, _("Pair this device with xtreader first.")
    end
    if not Device:isKindle() then
        return false, _("This is only available on a Kindle.")
    end

    -- Second return is the finished tally on success and the failure reason on
    -- nil, which the nil check below separates before either is used.
    local books, done_or_reason = readCatalogue()
    if books == nil then
        local reason = done_or_reason
        if reason == "no_cc_db" then
            return false, _("No Kindle library database on this device.")
        end
        return false, T(_("Cannot read the Kindle library (%1)."), tostring(reason))
    end
    if #books == 0 then
        return true, _("The Kindle library has no books with reading progress.")
    end

    if report(T(_("Sending %1 books from the Kindle library…"), #books)) == false then
        return false, _("Stopped.")
    end

    local body, code = api:postJson(ENDPOINT, { books = books })
    if not body then
        -- The two rejections mean different things to whoever reads the message.
        -- 413 is "you sent too many", which is actionable and should not happen
        -- at all while MAX_BOOKS holds. 400 is "a row was malformed", which is a
        -- bug here rather than anything the reader can act on.
        --
        -- Both leave the previously stored list alone -- the server replaces in
        -- one batch or not at all -- and saying so matters, because a failed
        -- import that silently emptied the dashboard would look identical to a
        -- successful one on a library that had shrunk to nothing.
        if code == 413 then
            return false, T(_("Too many books to send at once (%1). Nothing was changed."), #books)
        elseif code == 400 then
            return false, _("The server rejected this Kindle library as malformed.\nNothing was changed.")
        end
        return false, T(_("Import failed (%1).\nNothing was changed."), tostring(code))
    end

    local finished = tonumber(done_or_reason) or 0
    store:set("kindle_import_at", os.time())
    store:flush()

    return true, T(_("Imported %1 books from the Kindle, %2 of them finished.\nThey are listed on the dashboard and are kept out of your reading statistics, because the Kindle records no times."),
                   tonumber(body.stored) or #books, finished)
end

KindleHistory.readCatalogue = readCatalogue

return KindleHistory
