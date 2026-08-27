--[[
The bulk upload as a background job: fork it, poll it, show it in the control
centre, let the reader carry on reading.

WHY A SUBPROCESS AND NOT A COROUTINE

Because a coroutine cannot help. `http.request` is a blocking C call, and Lua
cannot yield across a C boundary -- an earlier attempt to report progress from
inside the request died with exactly that error and took the whole run with it.
So while a book is in flight the Lua VM is stuck, full stop. The only way the
reader keeps reading is if the upload is not in this process at all.

`ffiutil.runInSubProcess` forks. The child gets a copy of everything, including
the API object and its token, does the whole upload, and never touches the UI.
The parent polls, paints, and turns pages.

WHY A FILE AND NOT THE PIPE

`runInSubProcess` can hand back a pipe, and Trapper uses one -- but it reads it
exactly once, at the end, because `readAllFromFD` closes the fd. There is no
incremental read.

That matters more than it looks: a kernel pipe buffer is about 64 KB, and a
child that fills it BLOCKS on write until somebody drains it. A progress line
per book would fit, but a job that runs long enough would eventually wedge
itself waiting for a reader that only arrives at the end.

So progress goes through a file in a scratch directory instead. The child writes
it after each book, the parent reads it on a timer, and neither ever waits for
the other. The file also carries the RESULTS -- see below.

THE RESULTS HAVE TO COME BACK

`store:setBook` in the child writes to a copy-on-write page and vanishes when
the child exits. That is the trap in forking: everything appears to work, the
uploads really happen, and the device forgets it ever sent them -- so the next
sync downloads its own books back.

So the child records each accepted book in the state file and the PARENT commits
them to the store when the job ends.

WHAT HAPPENS IF KOREADER DIES MID-JOB

The child is orphaned and carries on uploading, which is harmless -- the server
is the source of truth and a re-run skips what arrived. What is lost is the
result commit, so the next sync sees books it does not know it has and reads
them from the manifest instead. Slower, not wrong.
]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")

local Job = {}

-- How often the parent looks at the state file. One second is well under the
-- time any single book takes to upload and far above the cost of a stat plus a
-- short read, so the card moves smoothly without the poll ever showing up.
local POLL_SEC = 1

-- The live job, or nil. One at a time: two concurrent bulk pushes would race
-- on the same paths and each would see the other's books as 409s.
local job = nil

local function statePath()
    return DataStorage:getDataDir() .. "/cache/xtreader-upload.state"
end

-- ── the state file ──────────────────────────────────────────────────────────
--
-- One `key=value` per line, values are plain and never contain a newline. Not
-- a Lua table written with `return {...}`: the parent reads this while the
-- child is still writing, and a half-written Lua file is a syntax error where a
-- half-written key/value list is just a missing line.
--
-- Written to a temporary path and renamed, which is atomic within a directory,
-- so a reader never sees a partial file at all in the normal case.

-- Forward declaration: writeState wraps this, and a local has to exist before
-- the wrapper closes over it or the call resolves to a global at run time.
local writeStateUnsafe

--- Never raises. The child writes this from inside a forked process where an
--- error is silent, and the parent from its own paths; neither wants a full
--- disk to be fatal.
local function writeState(t)
    local ok, res = pcall(writeStateUnsafe, t)
    if not ok then
        logger.warn("xtreader: could not write upload state:", tostring(res))
        return false
    end
    return res
end

writeStateUnsafe = function(t)
    local path = statePath()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    for _i, k in ipairs({ "phase", "total", "done", "sent", "skipped", "conflict",
                          "failed", "too_big", "bytes_done", "bytes_sent", "bytes_total",
                          "started_at", "current", "message" }) do
        local v = t[k]
        if v ~= nil then
            f:write(k, "=", tostring(v):gsub("[\r\n]", " "), "\n")
        end
    end
    -- Books the child got accepted, for the parent to commit. `book=` lines are
    -- repeated and deliberately last, so a truncated file loses results rather
    -- than the counters the card is drawn from.
    for _i, b in ipairs(t.books or {}) do
        f:write("book=", b.id, "\t", b.path, "\t", b.hash, "\t", tostring(b.size), "\n")
    end
    f:close()
    os.remove(path)
    return os.rename(tmp, path)
end

-- Returns nil on ANY failure, and never raises.
--
-- It raised once, and it took KOReader down with it -- back to the Kindle home
-- screen, mid-upload:
--
--     luajit: upload_job.lua:109: No such file or directory
--       in function 'readState'
--       in function 'action'          <- the poll
--       uimanager.lua:1019 _checkTasks
--
-- Two things went wrong and both are worth naming.
--
-- The mechanism: /mnt/us on a Kindle is `fuse.fsp`, not a POSIX filesystem.
-- The write side removes the old file and renames the new one over it, which on
-- a real filesystem gives a reader either the old contents or the new ones and
-- never an error. FUSE makes no such promise: a handle opened as that swap
-- happens can fail on the READ, after io.open has already succeeded. So the nil
-- check on io.open was never enough.
--
-- The consequence, which is the more important half: this runs from UIManager's
-- scheduler, and an error raised there is not caught by anything. A progress
-- display that cannot read a status file should show a stale figure for one
-- second. It should not be able to close the application.
local function readState()
    local ok, result = pcall(function()
        local f = io.open(statePath(), "r")
        if not f then return nil end
        local t = { books = {} }
        -- read("*a") then split, rather than f:lines(): lines() is an iterator
        -- that raises mid-loop, so a failure part-way through a file cannot be
        -- distinguished from a failure to open it, and a partial parse is
        -- abandoned rather than returned.
        local body = f:read("*a")
        f:close()
        if not body then return nil end
        for line in body:gmatch("[^\n]+") do
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k == "book" then
                local id, path, hash, size = v:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
                if id then
                    t.books[#t.books + 1] = { id = id, path = path, hash = hash,
                                              size = tonumber(size) }
                end
            elseif k then
                t[k] = tonumber(v) or v
            end
        end
        return t
    end)
    if not ok then
        logger.warn("xtreader: could not read upload state:", tostring(result))
        return nil
    end
    return result
end

Job.writeState = writeState
Job.readState  = readState

--- Bytes per second actually transferred, or nil when there is nothing honest
--- to divide.
--
-- `bytes_sent`, NOT `bytes_done`. A run that resumes an interrupted one begins
-- by skipping every book the account already has: those advance bytes_done at
-- disk speed and send nothing, so dividing them by elapsed time reports a
-- throughput the connection never had -- and then an estimate built on it.
--
-- Averaged over the whole job rather than sampled: a per-book rate on a device
-- whose Wi-Fi power-saves swings wildly, and a figure jumping between 0.3 and
-- 4 MB/s tells the reader less than one that settles.
function Job.rate(st)
    if not st or not st.started_at then return nil end
    local sent = st.bytes_sent or 0
    local elapsed = os.time() - st.started_at
    if elapsed < 2 or sent <= 0 then return nil end
    return sent / elapsed
end

--- Seconds left, or nil when that cannot be said honestly.
--
-- Deliberately absent until something has actually been sent. During an
-- all-skips opening there is no rate, and an estimate derived from one anyway
-- read "1020 min left" on a job that finished in minutes -- worse than no
-- estimate, because a wrong number is one the reader will act on.
--
-- The remainder is an OVERESTIMATE by construction: some of what is left will
-- turn out to be skippable and cost nothing. Erring long is the right way round
-- -- a job that beats its estimate is a pleasant surprise.
function Job.eta(st)
    local rate = Job.rate(st)
    if not rate then return nil end
    local total, done = st.bytes_total or 0, st.bytes_done or 0
    if total <= done then return nil end
    return (total - done) / rate
end

--- A snapshot for the control centre, or nil when there is nothing to show.
function Job.state()
    if not job then return nil end
    return job.st
end

function Job.isActive()
    return job ~= nil and job.st ~= nil and job.st.phase == "running"
end

--- Forget a finished job's card. Refuses while one is running -- that is
--- `cancel`, and the two must not be one tap apart.
function Job.dismiss()
    if not job or Job.isActive() then return false end
    job = nil
    os.remove(statePath())
    return true
end

--- Stop a running job.
function Job.cancel()
    if not job then return false end
    if job.pid then
        ffiutil.terminateSubProcess(job.pid)
        -- Collect it later so it does not linger as a zombie. Rescheduled
        -- rather than waited on: the child may be mid-request and take a moment
        -- to die, and the UI must not block on that.
        local pid = job.pid
        local collect
        collect = function()
            if not ffiutil.isSubProcessDone(pid) then
                UIManager:scheduleIn(5, collect)
            end
        end
        UIManager:scheduleIn(2, collect)
    end
    if job.poll then UIManager:unschedule(job.poll) end
    -- Commit whatever it managed before it was stopped, so those books are not
    -- downloaded back on the next sync.
    Job._commit()
    job.st = job.st or {}
    job.st.phase = "cancelled"
    job.st.message = _("Upload stopped.")
    job.pid = nil
    return true
end

--- Write the child's accepted books into the store. Parent side only.
function Job._commit()
    if not job or not job.store then return 0 end
    local st = readState()
    if not st or not st.books then return 0 end
    local n = 0
    for _i, b in ipairs(st.books) do
        if b.id and b.id ~= "" then
            job.store:setBook(b.id, { path = b.path, hash = b.hash, size = b.size })
            n = n + 1
        end
    end
    if n > 0 then job.store:flush() end
    return n
end

--- Start the job. Returns true, or false plus a reason.
function Job.start(api, store, Upload)
    if job and Job.isActive() then
        return false, _("An upload is already running.")
    end
    if not store:isPaired() then
        return false, _("Pair this device with xtreader first.")
    end
    local root = store:get("library_dir")
    if not root then return false, _("No library folder is configured.") end

    local books = Upload.scan(root, store:get("upload_skip"), store:get("upload_formats"))
    if #books == 0 then
        return false, _("No books found to upload.")
    end

    os.remove(statePath())
    local seed = {
        phase = "running", total = #books, done = 0,
        sent = 0, skipped = 0, conflict = 0, failed = 0, too_big = 0,
        bytes_done = 0, bytes_total = 0, started_at = os.time(), current = "",
    }
    for _i, b in ipairs(books) do seed.bytes_total = seed.bytes_total + (b.size or 0) end
    writeState(seed)

    -- The child. It must not touch UIManager or any widget: it shares their
    -- memory but not their screen, and a repaint from here would be drawn by a
    -- process that does not own the framebuffer.
    local pid = ffiutil.runInSubProcess(function()
        local ok, err = pcall(function()
            Upload.pushAll(api, store, function() return true end, {
                books = books,
                on_book = function(update) writeState(update) end,
            })
        end)
        if not ok then
            local st = readState() or seed
            st.phase = "failed"
            st.message = tostring(err)
            writeState(st)
        end
    end)
    if not pid then
        return false, _("Could not start the upload.")
    end

    job = { pid = pid, store = store, st = seed }

    -- Poll. Cheap, and the only thing standing between the child and a card
    -- that never updates.
    -- EVERY path in here is wrapped, not just the file read.
    --
    -- This runs from UIManager's scheduler, where a raised error is caught by
    -- nothing and closes the application. That is not theoretical: readState
    -- raised on a FUSE filesystem mid-upload and dropped the reader back to the
    -- Kindle home screen. readState is now safe on its own, but so is
    -- everything else here -- isSubProcessDone goes through FFI, and _commit
    -- writes to the settings store, and neither is a thing to bet a running
    -- application on.
    --
    -- A poll that fails is a card showing a stale figure for a second. It is
    -- never worth more than that.
    job.poll = function()
        local ok, err = pcall(function()
            local st = readState()
            if st then job.st = st end
            if ffiutil.isSubProcessDone(pid) then
                job.pid = nil
                local committed = Job._commit()
                job.st = job.st or {}
                if job.st.phase == "running" then job.st.phase = "done" end
                logger.dbg("xtreader: upload job finished, committed", committed, "books")
                return true   -- finished: do not reschedule
            end
            return false
        end)
        if not ok then
            logger.warn("xtreader: upload poll failed:", tostring(err))
            -- Keep polling. The job itself is in another process and is
            -- unaffected by whatever went wrong in here.
            err = false
        end
        if err ~= true then
            UIManager:scheduleIn(POLL_SEC, job.poll)
        end
    end
    UIManager:scheduleIn(POLL_SEC, job.poll)
    return true
end

return Job
