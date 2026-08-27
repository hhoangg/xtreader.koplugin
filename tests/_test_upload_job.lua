-- tests/_test_upload_job.lua
--
-- The state file is the whole conversation between two processes, so a bug in
-- it is a bug neither side can see. The parent draws a card from these numbers
-- and commits these books to the store; get the format wrong and the upload
-- still works while the device forgets it ever happened, then downloads its own
-- books back on the next sync.

package.path = "./xtreader.koplugin/?.lua;" .. package.path

local SCRATCH = os.getenv("TMPDIR") or "/tmp"
package.loaded["datastorage"] = { getDataDir = function() return SCRATCH end }
package.loaded["ui/uimanager"] = { scheduleIn = function() end, unschedule = function() end }
package.loaded["ffi/util"]  = {
    runInSubProcess = function() return nil end,
    isSubProcessDone = function() return true end,
    terminateSubProcess = function() end,
}
package.loaded["logger"]  = { warn = function() end, dbg = function() end }
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })

os.execute("mkdir -p '" .. SCRATCH .. "/cache'")
local Job = dofile("xtreader.koplugin/upload_job.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

test("state survives a round trip, numbers as numbers", function()
    Job.writeState{
        phase = "running", total = 87, done = 12, sent = 10, skipped = 2,
        bytes_done = 148 * 1048576, bytes_total = 927 * 1048576,
        started_at = 1000, current = "/Tiên hiệp/Mục Thần Ký.epub",
    }
    local st = Job.readState()
    assert(st.phase == "running")
    assert(st.total == 87 and st.done == 12, "counters must come back as numbers")
    assert(st.current == "/Tiên hiệp/Mục Thần Ký.epub", "got " .. tostring(st.current))
end)

test("accepted books survive, which is what the parent commits", function()
    Job.writeState{
        phase = "done", total = 2,
        books = {
            { id = "bok_A", path = "/a.epub", hash = "h1", size = 100 },
            { id = "bok_B", path = "/Tiên hiệp/b.epub", hash = "h2", size = 200 },
        },
    }
    local st = Job.readState()
    assert(#st.books == 2, "expected 2 books, got " .. #st.books)
    assert(st.books[2].path == "/Tiên hiệp/b.epub", "got " .. st.books[2].path)
    assert(st.books[2].size == 200, "size must be a number")
end)

test("a newline in a title cannot forge a state line", function()
    -- The format is line-based, so an unescaped newline in a filename would let
    -- a book called "x\nphase=done" end the job.
    Job.writeState{ phase = "running", total = 1, current = "bad\nphase=done\nx" }
    local st = Job.readState()
    assert(st.phase == "running", "phase was overwritten by a title: " .. tostring(st.phase))
end)

test("counters are written before books, so truncation loses the less important half", function()
    Job.writeState{ phase = "running", total = 5, done = 1,
                    books = { { id = "b", path = "/p", hash = "h", size = 1 } } }
    local f = io.open(SCRATCH .. "/cache/xtreader-upload.state", "r")
    local body = f:read("*a"); f:close()
    local first_book = body:find("book=", 1, true)
    local phase_at = body:find("phase=", 1, true)
    assert(phase_at < first_book,
        "counters must precede results: a half-written file should cost the results, "
        .. "not the numbers the card is drawn from")
end)

test("rate is nil until something has honestly been sent", function()
    assert(Job.rate(nil) == nil)
    assert(Job.rate{ started_at = os.time(), bytes_sent = 0 } == nil,
        "zero bytes is not a rate")
    assert(Job.rate{ started_at = os.time(), bytes_sent = 500 } == nil,
        "under two seconds is noise, not a measurement")
    local r = Job.rate{ started_at = os.time() - 10, bytes_sent = 10 * 1048576 }
    assert(r and math.abs(r - 1048576) < 1024, "expected ~1 MB/s, got " .. tostring(r))
end)

test("skipped books do not count towards the rate", function()
    -- Seen on the device: a run resuming an interrupted one opened by skipping
    -- eight books the account already had. Those advance bytes_done at disk
    -- speed and send nothing, so a rate taken from bytes_done claimed a
    -- throughput the connection never had -- and the card read
    -- "8 of 89 - 0.0 MB/s - 1020 min left - 0%", every figure wrong in a
    -- different direction.
    local st = { started_at = os.time() - 30,
                 bytes_done = 148 * 1048576,   -- all of it skipped
                 bytes_sent = 0,
                 bytes_total = 927 * 1048576 }
    assert(Job.rate(st) == nil, "nothing was sent, so there is no rate")
    assert(Job.eta(st) == nil, "and no rate means no estimate, not a huge one")
end)

test("eta refuses to guess when it cannot", function()
    assert(Job.eta{ started_at = os.time() - 10, bytes_sent = 1048576 } == nil,
        "no total means no estimate")
    assert(Job.eta{ started_at = os.time() - 10, bytes_sent = 10,
                    bytes_done = 10, bytes_total = 10 } == nil,
        "nothing left is not 'a moment', it is over")
    -- Remaining is measured from bytes_DONE (what is left to get through),
    -- divided by a rate measured from bytes_SENT (how fast the wire is).
    local e = Job.eta{ started_at = os.time() - 10, bytes_sent = 10 * 1048576,
                       bytes_done = 10 * 1048576, bytes_total = 20 * 1048576 }
    assert(e and math.abs(e - 10) < 2, "expected ~10s left, got " .. tostring(e))
end)

test("state carries both byte counters", function()
    Job.writeState{ phase = "running", total = 89, done = 8,
                    bytes_done = 100, bytes_sent = 0, bytes_total = 900 }
    local st = Job.readState()
    assert(st.bytes_done == 100 and st.bytes_sent == 0 and st.bytes_total == 900,
        "both counters must survive the round trip or the card cannot tell "
        .. "progress from throughput")
end)

test("dismiss refuses while a job is running", function()
    -- The two are one tap apart on the card, and only one of them throws work
    -- away. Confusing them is how somebody loses a half-finished upload.
    assert(Job.dismiss() == false, "nothing to dismiss should be false, not an error")
end)

os.remove(SCRATCH .. "/cache/xtreader-upload.state")
io.write(string.format("PASS %d  FAIL %d\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
