-- tests/_test_upload.lua
--
-- The bulk push. Most of this file exists because of one bug that reached the
-- device: pushAll called `report` once per BOOK, and Trapper only repaints --
-- and only notices a tap -- when the coroutine yields, which is what `report`
-- does. So during a 10 MB upload there was no yield point for minutes, the
-- pause dialog could not be drawn at the one moment somebody wanted it, and
-- the only way to stop a running push was a signal over SSH.
--
-- "The stop button exists" is not the property worth testing. "The stop button
-- can be drawn while a book is in flight" is, and that is a claim about how
-- often report is called.

package.path = "./xtreader.koplugin/?.lua;" .. package.path
package.loaded["logger"]   = { warn = function() end, dbg = function() end }
package.loaded["gettext"]  = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["ffi/util"] = { template = function(f, ...)
    local a = { ... }
    return (f:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end))
end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    dir = function() error("no filesystem in tests") end,
}

local Upload = dofile("xtreader.koplugin/upload.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- ---------------------------------------------------------------- pure bits

test("escape: round-trips, and leaves nothing that would split a query", function()
    local cases = {
        "/Tiên hiệp/Mục Thần Ký.epub",
        "/Cổ Chân Nhân/Cổ Chân Nhân - 1 - 蛊真人.epub",
        "/a b&c=d?e/x#y.epub",
        "/plain.epub",
    }
    for _i, c in ipairs(cases) do
        local e = Upload.escape(c)
        local back = e:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        assert(back == c, "round-trip lost data: " .. c)
        assert(not e:find("[&=?# ]"), "unescaped separator survived: " .. e)
    end
end)

test("escape: an allow-list, not a block-list", function()
    -- The reason: these paths carry Vietnamese titles, and a block-list that
    -- has not thought about U+1EA1 passes it through and produces a request
    -- for a different path than the one meant.
    local e = Upload.escape("ạ")
    assert(e == "%E1%BA%A1", "expected the UTF-8 bytes escaped, got " .. e)
end)

-- ------------------------------------------------------------------ pushAll

-- A library of `n` books of `size` bytes each, with the filesystem and the
-- hash stubbed out -- neither is what these tests are about.
local function harness(n, size)
    local books = {}
    for i = 1, n do
        books[i] = { path = "/x/" .. i .. ".epub", rel = "/" .. i .. ".epub", size = size }
    end
    Upload.scan = function() return books end
    Upload.contentHash = function(p) return "hash-of" .. p end

    local store = {
        _books = {},
        isPaired = function() return true end,
        get = function(_s, k) return k == "library_dir" and "/x" or nil end,
        setBook = function(s, id, e) s._books[id] = e end,
        flush = function() end,
    }
    local state = { uploads = 0, reports = 0 }
    local api = {
        fetchManifest = function() return {} end,
        uploadFile = function(_s, _p, _q, _lp, cb)
            state.uploads = state.uploads + 1
            -- Pump it in 64 KB chunks, the way the real ltn12 source does.
            for sofar = 65536, size, 65536 do
                if cb then cb(sofar) end
            end
            return { id = "bok_" .. state.uploads, path = "/x" }, nil
        end,
    }
    return api, store, state
end

test("report is called many times per book, not once", function()
    local api, store, state = harness(3, 1024 * 1024)
    Upload.pushAll(api, store, function() state.reports = state.reports + 1; return true end)
    -- One per book would be 3. Anything close to 3 means a book uploads with
    -- no yield inside it and the pause dialog cannot be drawn.
    assert(state.reports > 3 * 4,
        "expected a yield point per chunk; got " .. state.reports .. " reports for 3 books")
end)

test("progress is reported as whole percent steps, not per chunk", function()
    -- Each report repaints e-ink. Reporting per 64 KB chunk would cost more
    -- than the transfer it is describing.
    local api, store, state = harness(1, 10 * 1024 * 1024)  -- 160 chunks
    Upload.pushAll(api, store, function() state.reports = state.reports + 1; return true end)
    assert(state.reports <= 105,
        "expected throttling to ~100 steps + overhead, got " .. state.reports)
    assert(state.reports > 10, "expected real progress reporting, got " .. state.reports)
end)

test("aborting mid-book finishes that book, then stops", function()
    -- Never mid-body: an abandoned upload is a partial object the server has
    -- to clean up.
    local api, store, state = harness(5, 1024 * 1024)
    local n = 0
    local ok, msg, stats = Upload.pushAll(api, store, function()
        n = n + 1
        return n < 3          -- refuse once the first book is in flight
    end)
    assert(state.uploads == 1,
        "expected the in-flight book to finish and no more; uploaded " .. state.uploads)
    assert(stats.sent == 1, "the finished book must still be counted, got " .. stats.sent)
    assert(ok, "an abort is not a failure")
    assert(tostring(msg):find("Stopped"), "the message must say it stopped: " .. tostring(msg))
end)

test("aborting between books stops without uploading another", function()
    local api, store, state = harness(5, 1024)
    local first = true
    Upload.pushAll(api, store, function()
        if first then first = false; return false end
        return true
    end)
    assert(state.uploads == 0, "nothing should have been sent, got " .. state.uploads)
end)

test("403 stops the run instead of asking 87 more times", function()
    local api, store, state = harness(5, 1024)
    api.uploadFile = function() state.uploads = state.uploads + 1; return nil, 403 end
    local ok, msg, stats = Upload.pushAll(api, store, function() return true end)
    assert(state.uploads == 1, "expected one refusal then a stop, got " .. state.uploads)
    assert(ok == false and stats.forbidden, "a 403 is a failure the reader must be told about")
end)

test("409 is a skip, not a failure", function()
    local api, store, state = harness(3, 1024)
    api.uploadFile = function() state.uploads = state.uploads + 1; return nil, 409 end
    local _ok, _msg, stats = Upload.pushAll(api, store, function() return true end)
    assert(stats.skipped == 3 and stats.failed == 0,
        "409 means already there; got skipped=" .. stats.skipped .. " failed=" .. stats.failed)
end)

test("a path the account holds under DIFFERENT bytes is reported, not skipped", function()
    -- The whole reason the manifest is fetched before anything is sent. Both
    -- cases are 409 from the server, and silently skipping both lets a push
    -- report "sent, skipped" while failing to adopt a book.
    local api, store, state = harness(2, 1024)
    api.fetchManifest = function()
        return {
            { path = "/1.epub", contentHash = "hash-of/x/1.epub" },  -- same book
            { path = "/2.epub", contentHash = "something-else" },    -- different book
        }
    end
    local _ok, msg, stats = Upload.pushAll(api, store, function() return true end)
    assert(state.uploads == 0, "neither should have been sent")
    assert(stats.skipped == 1, "the matching one is a silent skip, got " .. stats.skipped)
    assert(stats.conflict == 1, "the differing one is a conflict, got " .. stats.conflict)
    assert(tostring(msg):find("/2.epub", 1, true),
        "the conflict must be named, not counted: " .. tostring(msg))
end)

test("a book over the server's ceiling is not sent", function()
    local api, store, state = harness(1, 1024)
    Upload.scan = function()
        return { { path = "/x/big.epub", rel = "/big.epub", size = 200 * 1024 * 1024 } }
    end
    local _ok, _msg, stats = Upload.pushAll(api, store, function() return true end)
    assert(state.uploads == 0, "an oversized book must not spend the transfer to earn a 413")
    assert(stats.too_big == 1)
end)

-- ---------------------------------------------- folders the device owns

test("Amazon's own folders are excluded without being configured", function()
    -- /mnt/us/documents is the folder the Kindle firmware owns and KOReader was
    -- merely pointed at. Downloads/ is where the firmware puts what it
    -- downloads -- including the original files a converted library was made
    -- FROM -- and dictionaries/ holds DRM'd purchases. Asking every Kindle
    -- owner to work these out and type them in, on a device that already knows
    -- which folder it is looking at, is a question with one answer.
    local owned = Upload.deviceOwnedFolders("/mnt/us/documents")
    assert(owned.Downloads and owned.dictionaries,
        "expected the firmware's folders to be excluded by default")
    assert(Upload.deviceOwnedFolders("/mnt/us/documents/") .Downloads,
        "a trailing slash must not defeat it")
end)

test("only for THAT root, not for the whole device", function()
    -- A reader who points KOReader at /mnt/us/books has a Downloads folder
    -- that is theirs, on the same hardware. Keying this on "am I a Kindle"
    -- rather than on the path would have this code overrule them.
    assert(next(Upload.deviceOwnedFolders("/mnt/us/books")) == nil,
        "a different root on the same device must be left alone")
    assert(next(Upload.deviceOwnedFolders("/mnt/onboard/.adds/books")) == nil)
    assert(next(Upload.deviceOwnedFolders(nil)) == nil)
end)

io.write(string.format("PASS %d  FAIL %d\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
