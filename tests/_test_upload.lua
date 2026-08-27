-- tests/_test_upload.lua
--
-- The bulk push.
--
-- READ THIS BEFORE ADDING A PROGRESS TEST.
--
-- An earlier version of this file asserted that `report` was called many times
-- per book, to prove the pause dialog could be drawn while a book was in
-- flight. The assertion passed. The feature crashed on the device with
--
--     attempt to yield across C-call boundary
--
-- because `report` is Trapper:info, which yields, and the real callback runs
-- inside LuaSocket's `http.request` -- a C function you cannot yield across.
-- The test drove the callback from Lua, where there is no C frame in the way,
-- so it was checking a version of the world that does not exist.
--
-- The lesson is not "test harder". It is that a stub which calls your callback
-- from a friendlier place than production does can only ever confirm what you
-- already believed. Where the call comes FROM was the whole property, and a
-- table of fake books could not model it.
--
-- So: a blocking request cannot be interrupted from Lua, an abort takes effect
-- between books, and the tests below assert that -- not a smoother story.

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
    -- The three-step contract: presign, PUT to storage, complete. The proxy
    -- that used to take the bytes ran at 2 KB/s measured from the device, so
    -- they now go straight to storage and the server is only told about it.
    local state = { uploads = 0, reports = 0, presigns = 0, completes = 0 }
    local api = {
        fetchManifest = function() return {} end,
        postJson = function(_s, path, payload)
            if path == "/library/upload/presign" then
                state.presigns = state.presigns + 1
                return { bookId = "bok_" .. state.presigns,
                         uploadUrl = "https://storage.example/put?sig=x" }, nil
            elseif path == "/library/upload/complete" then
                state.completes = state.completes + 1
                return { id = payload.bookId, path = payload.path }, nil
            end
        end,
        putFile = function(_s, _url, _lp, cb)
            state.uploads = state.uploads + 1
            -- Pump it in 64 KB chunks, the way the real ltn12 source does.
            for sofar = 65536, size, 65536 do
                if cb then cb(sofar) end
            end
            return true
        end,
    }
    return api, store, state
end

test("nothing is reported from inside the upload", function()
    -- The property that actually matters, stated as what it is: `report`
    -- yields, the upload runs inside a C call, and yielding across that is
    -- fatal. So report must be called ONLY from the loop body, never from a
    -- callback the request drives.
    --
    -- Asserted as an exact count rather than a bound: one per book, plus the
    -- single "checking what the account has" line before the loop. A number
    -- that drifts upward means somebody has reintroduced a callback and this
    -- will die on a device again.
    local api, store, state = harness(3, 1024 * 1024)
    Upload.pushAll(api, store, function() state.reports = state.reports + 1; return true end)
    assert(state.reports == 3 + 1,
        "expected exactly one report per book plus one before the loop, got "
        .. state.reports)
end)

test("the id comes off the completed entry, not off presign", function()
    -- Uploading over a book that was deleted revives it IN PLACE and keeps its
    -- original id, so the two differ exactly when it matters most: every reader
    -- still holding that file is keyed on the old one.
    local api, store, _state = harness(1, 1024)
    api.postJson = function(_s, path, payload)
        if path == "/library/upload/presign" then
            return { bookId = "bok_FRESH", uploadUrl = "https://s/put" }, nil
        end
        return { id = "bok_REVIVED", path = payload.path }, nil
    end
    Upload.pushAll(api, store, function() return true end)
    assert(store._books["bok_REVIVED"], "must record the id the server settled on")
    assert(not store._books["bok_FRESH"], "must not record presign's provisional id")
end)

test("a complete that says the object is missing retries from presign", function()
    -- 400 upload_not_found is what a PUT that died halfway looks like. The
    -- grant is spent, so a retry has to start over -- and it is ONE retry,
    -- because a second failure is a pattern rather than a blip.
    local api, store, state = harness(1, 1024)
    local completes = 0
    api.postJson = function(_s, path, payload)
        if path == "/library/upload/presign" then
            state.presigns = state.presigns + 1
            return { bookId = "b" .. state.presigns, uploadUrl = "https://s/put" }, nil
        end
        completes = completes + 1
        if completes == 1 then return nil, 400 end
        return { id = "b_ok", path = payload.path }, nil
    end
    local _ok, _msg, stats = Upload.pushAll(api, store, function() return true end)
    assert(state.presigns == 2, "expected a second presign, got " .. state.presigns)
    assert(state.uploads == 2, "expected the bytes to be sent again, got " .. state.uploads)
    assert(stats.sent == 1, "and it counts once, got " .. stats.sent)
end)

test("a presign that is refused sends no bytes", function()
    -- The whole point of checking the path at presign: a doomed 30 MB upload
    -- should be refused before it starts, not after.
    local api, store, state = harness(2, 1024)
    api.postJson = function(_s, path)
        if path == "/library/upload/presign" then return nil, 409 end
    end
    local _ok, _msg, stats = Upload.pushAll(api, store, function() return true end)
    assert(state.uploads == 0, "nothing should have been PUT, got " .. state.uploads)
    assert(stats.skipped == 2, "409 is already-there, got skipped=" .. stats.skipped)
end)

test("the FOREGROUND run hands the request no callback", function()
    -- Belt and braces for the same thing, checked at the seam rather than by
    -- counting. The foreground's reporter is Trapper:info, which yields, and
    -- handing it to a request that runs inside a C call kills the run.
    local api, store, _state = harness(2, 1024)
    local saw_callback = false
    api.putFile = function(_s, _url, _lp, cb)
        if cb ~= nil then saw_callback = true end
        return true
    end
    Upload.pushAll(api, store, function() return true end)
    assert(not saw_callback,
        "a progress callback here yields across a C boundary and kills the run")
end)

test("the BACKGROUND job does get one, because writing a file cannot yield", function()
    -- Same callback position, different thing being called. on_book writes to
    -- disk; a write does not yield, so the C frame in between is nothing to it.
    -- Without this the card sits still for the whole of a large book.
    local api, store, _state = harness(1, 4 * 1024 * 1024)
    local saw_callback = false
    api.putFile = function(_s, _url, _lp, cb)
        saw_callback = cb ~= nil
        return true
    end
    Upload.pushAll(api, store, function() return true end, { on_book = function() end })
    assert(saw_callback, "the background job needs per-chunk progress")
end)

test("bytes in flight are not counted twice when the book lands", function()
    -- The partial figure is added to the totals for display only. Committing it
    -- would double-count the moment the book finishes and its full size is
    -- added properly -- and a bar that overshoots 100% is a bar nobody trusts
    -- for the rest of the run.
    local size = 4 * 1024 * 1024
    local api, store, _state = harness(1, size)
    local seen = {}
    api.putFile = function(_s, _url, _lp, cb)
        -- Report the whole file as sent, the way a real pump's last chunk does.
        if cb then cb(size) end
        return true
    end
    Upload.pushAll(api, store, function() return true end, {
        on_book = function(u) seen[#seen + 1] = u end,
    })
    local last = seen[#seen]
    assert(last.bytes_sent == size,
        "expected exactly one file's worth, got " .. tostring(last.bytes_sent)
        .. " for a " .. size .. " byte book")
    assert(last.bytes_done <= last.bytes_total,
        "progress must never exceed the total")
end)

test("stopping between books stops before the next upload", function()
    -- The only kind of stop there is. An in-flight book cannot be interrupted,
    -- which is why the progress line names its size: it is what the reader is
    -- committing to when they let it start.
    local api, store, state = harness(5, 1024 * 1024)
    local n = 0
    local ok, msg, stats = Upload.pushAll(api, store, function()
        n = n + 1
        return n < 3          -- allow the pre-loop line and book 1, refuse book 2
    end)
    assert(state.uploads == 1, "expected one book sent then a stop, got " .. state.uploads)
    assert(stats.sent == 1, "the sent book must be counted, got " .. stats.sent)
    assert(ok, "stopping is not a failure")
    assert(tostring(msg):find("Stopped"), "the message must say it stopped: " .. tostring(msg))
end)

test("stopping at the first prompt sends nothing at all", function()
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
    api.postJson = function(_s, path)
        if path == "/library/upload/presign" then
            state.uploads = state.uploads + 1
            return nil, 403
        end
    end
    local ok, msg, stats = Upload.pushAll(api, store, function() return true end)
    assert(state.uploads == 1, "expected one refusal then a stop, got " .. state.uploads)
    assert(ok == false and stats.forbidden, "a 403 is a failure the reader must be told about")
end)

test("409 is a skip, not a failure", function()
    local api, store, state = harness(3, 1024)
    api.postJson = function(_s, path)
        if path == "/library/upload/presign" then
            state.uploads = state.uploads + 1
            return nil, 409
        end
    end
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
