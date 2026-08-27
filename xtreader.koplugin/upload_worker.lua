--[[
The bulk upload, as a program that is not KOReader.

    luajit upload_worker.lua <job-file>

WHY THIS EXISTS RATHER THAN A FORK

The first version used `ffiutil.runInSubProcess`, which forks KOReader. On the
device that got the reader killed:

    Out of memory: Kill process 14854 (reader.lua) score 982
    Killed process 14854 (reader.lua) total-vm:354512kB anon-rss:210884kB

A Paperwhite 5 has 485 MB and about 116 MB of it free with KOReader up. Forking
a 210 MB process into that is not something copy-on-write can save: the child
runs a Lua GC and an SSL stack, so it touches pages, and touching a shared page
copies it.

The upload needs a token, a URL and a list of files. It does not need a widget
tree, a font stack, a document engine or a cover cache. Measured on the device,
a bare luajit with LuaSocket and LuaSec loaded is **3.3 MB** against the fork's
210 MB.

So: no fork. The plugin writes a job file, spawns this, and polls the same state
file it always did. Nothing about the progress card changed.

WHAT THIS FILE MAY DEPEND ON

KOReader's bundled LuaSocket/LuaSec under `common/`, and nothing else. No
`logger`, no `gettext`, no `datastorage` -- every one of those pulls in a chain
that ends at the framebuffer. That is why the upload logic here is not shared
with upload.lua: sharing it would mean upload.lua could not require anything
either, and it is the half that has to talk to the UI.

THE JOB FILE HOLDS A TOKEN

It is written to the plugin's own settings directory, which on this device is
as private as the settings file the token already lives in, and it is removed
when the job ends. It is never passed on the command line, where `ps` would
show it to anything running on the device.
]]

local job_path = arg and arg[1]
if not job_path then
    io.stderr:write("usage: upload_worker.lua <job-file>\n")
    os.exit(2)
end

-- ── environment ─────────────────────────────────────────────────────────────
--
-- Set before anything is required. `common/` is where KOReader keeps the pure
-- Lua modules that do not need its own frontend, which is exactly the subset
-- this needs.
local KO = os.getenv("KOREADER_DIR") or "/mnt/us/koreader"
package.path = KO .. "/common/?.lua;" .. KO .. "/common/?/init.lua;"
            .. KO .. "/?.lua;" .. package.path
package.cpath = KO .. "/common/?.so;" .. KO .. "/common/?/core.so;"
             .. KO .. "/libs/?.so;" .. package.cpath

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local sha2 = require("ffi/sha2")

local JSON = require("json")

-- ── the job file ────────────────────────────────────────────────────────────
--
-- Plain `key=value` lines, then one `file=` line per book, for the same reason
-- the state file is: it is written by one process and read by another, and a
-- line-based format degrades into a missing line where a Lua table degrades
-- into a syntax error.

local job = { files = {} }
do
    local f = assert(io.open(job_path, "r"))
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k == "file" then
            local path, rel, size = v:match("^([^\t]*)\t([^\t]*)\t(.*)$")
            if path then
                job.files[#job.files + 1] = { path = path, rel = rel,
                                              size = tonumber(size) or 0 }
            end
        elseif k then
            job[k] = v
        end
    end
    f:close()
end

local function log(...)
    if not job.log then return end
    local f = io.open(job.log, "a")
    if not f then return end
    f:write(os.date("%H:%M:%S "), table.concat({ ... }, " "), "\n")
    f:close()
end

-- ── state, in exactly the format the plugin already reads ───────────────────

local st = {
    phase = "running", total = #job.files, done = 0,
    sent = 0, skipped = 0, conflict = 0, failed = 0, too_big = 0,
    bytes_done = 0, bytes_sent = 0, bytes_total = 0,
    started_at = os.time(), current = "",
}
for _i, b in ipairs(job.files) do st.bytes_total = st.bytes_total + b.size end
local accepted = {}

local function writeState(in_flight)
    local flight = in_flight or 0
    local ok = pcall(function()
        local tmp = job.state .. ".tmp"
        local f = assert(io.open(tmp, "w"))
        for _i, k in ipairs({ "phase", "total", "done", "sent", "skipped",
                              "conflict", "failed", "too_big", "bytes_done",
                              "bytes_sent", "bytes_total", "started_at",
                              "current", "message" }) do
            local v = st[k]
            if k == "bytes_done" then v = st.bytes_done + flight end
            if k == "bytes_sent" then v = st.bytes_sent + flight end
            if v ~= nil then
                f:write(k, "=", tostring(v):gsub("[\r\n]", " "), "\n")
            end
        end
        for _i, b in ipairs(accepted) do
            f:write("book=", b.id, "\t", b.path, "\t", b.hash, "\t", tostring(b.size), "\n")
        end
        f:close()
        os.remove(job.state)
        os.rename(tmp, job.state)
    end)
    if not ok then log("state write failed") end
end

-- ── http ────────────────────────────────────────────────────────────────────

local function requestJson(path, payload)
    local body = JSON.encode(payload)
    local sink = {}
    -- socket.skip(1, ...) already drops the leading 1 that the table form of
    -- request returns, so `code` is the FIRST value here. Binding it second --
    -- `local _, code` -- silently lands the headers table in `code`, and the
    -- failure surfaces as "manifest table: 0xb6ab0a60" rather than as a status.
    local code = socket.skip(1, https.request{
        url = job.base_url .. path,
        method = "POST",
        headers = {
            ["Authorization"]  = "Bearer " .. job.token,
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
        redirect = false,
    })
    local text = table.concat(sink)
    if code ~= 200 and code ~= 201 then return nil, code end
    local ok, decoded = pcall(JSON.decode, text)
    return ok and decoded or {}, code
end

--- PUT to a presigned URL. No Authorization header: the signature is in the
--- query string and a bearer token alongside it is rejected as double auth.
local function putFile(url, path, size, on_progress)
    local handle, err = io.open(path, "rb")
    if not handle then return nil, err or "cannot_open" end
    local sent = 0
    local inner = ltn12.source.file(handle)
    local source = function()
        local chunk, e = inner()
        if chunk then
            sent = sent + #chunk
            if on_progress then on_progress(sent) end
        end
        return chunk, e
    end
    -- socket.skip(1, ...) already drops the leading 1 that the table form of
    -- request returns, so `code` is the FIRST value here. Binding it second --
    -- `local _, code` -- silently lands the headers table in `code`, and the
    -- failure surfaces as "manifest table: 0xb6ab0a60" rather than as a status.
    local code = socket.skip(1, https.request{
        url = url,
        method = "PUT",
        headers = {
            ["Content-Type"]   = "application/octet-stream",
            ["Content-Length"] = tostring(size),
        },
        source = source,
        sink = ltn12.sink.null(),
        redirect = false,
    })
    pcall(function() handle:close() end)
    if code ~= 200 and code ~= 201 and code ~= 204 then return nil, code end
    return true
end

local function contentHash(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local append = sha2.sha256()
    while true do
        local chunk = f:read(64 * 1024)
        if not chunk then break end
        append(chunk)
    end
    f:close()
    return append()
end

-- ── what the account already holds ──────────────────────────────────────────

local function accountByPath()
    local sink = {}
    -- socket.skip(1, ...) already drops the leading 1 that the table form of
    -- request returns, so `code` is the FIRST value here. Binding it second --
    -- `local _, code` -- silently lands the headers table in `code`, and the
    -- failure surfaces as "manifest table: 0xb6ab0a60" rather than as a status.
    local code = socket.skip(1, https.request{
        url = job.base_url .. "/library/manifest?limit=500",
        headers = { ["Authorization"] = "Bearer " .. job.token },
        sink = ltn12.sink.table(sink),
        redirect = false,
    })
    if code ~= 200 then return nil, code end
    local by_path = {}
    for line in table.concat(sink):gmatch("[^\n]+") do
        local ok, e = pcall(JSON.decode, line)
        if ok and type(e) == "table" and e.path and e.deleted ~= true then
            by_path[e.path] = e.contentHash or true
        end
    end
    return by_path
end

-- ── the run ─────────────────────────────────────────────────────────────────

local MAX_BYTES = 100 * 1024 * 1024

writeState()
local have, manifest_code = accountByPath()
if not have then
    st.phase = "failed"
    st.message = "manifest " .. tostring(manifest_code)
    writeState()
    os.exit(1)
end

for _i, b in ipairs(job.files) do
    st.current = b.rel
    local counted = false

    if b.size > MAX_BYTES then
        st.too_big = st.too_big + 1
        counted = true
    else
        local hash = contentHash(b.path)
        if not hash then
            st.failed = st.failed + 1
            counted = true
        else
            local known = have[b.rel]
            if known == hash then
                st.skipped = st.skipped + 1
                counted = true
            elseif known ~= nil then
                st.conflict = st.conflict + 1
                counted = true
                log("path held by a different book:", b.rel)
            else
                -- Progress within the book, every 512 KB. This is a file write,
                -- not a UI call, so there is nothing here that could block or
                -- yield -- the reason this was impossible in-process.
                local step, next_at = 512 * 1024, 512 * 1024
                local function on_progress(sofar)
                    if sofar < next_at then return end
                    next_at = sofar + step
                    writeState(sofar)
                end

                local grant, pre_code = requestJson("/library/upload/presign",
                                                    { path = b.rel })
                local entry, up_code
                if not grant or not grant.uploadUrl then
                    up_code = pre_code
                else
                    local ok_put, put_err = putFile(grant.uploadUrl, b.path,
                                                    b.size, on_progress)
                    if not ok_put then
                        up_code = put_err
                    else
                        entry, up_code = requestJson("/library/upload/complete", {
                            bookId = grant.bookId, path = b.rel, contentHash = hash,
                        })
                        -- 400 is upload_not_found: the object is not in the
                        -- bucket, which is what a PUT that died halfway looks
                        -- like. The grant is spent, so retry from presign --
                        -- once, because a second failure is a pattern.
                        if not entry and up_code == 400 then
                            local g2 = requestJson("/library/upload/presign", { path = b.rel })
                            if g2 and g2.uploadUrl
                                    and putFile(g2.uploadUrl, b.path, b.size, on_progress) then
                                entry, up_code = requestJson("/library/upload/complete", {
                                    bookId = g2.bookId, path = b.rel, contentHash = hash,
                                })
                            end
                        end
                    end
                end

                if entry then
                    st.sent = st.sent + 1
                    st.bytes_sent = st.bytes_sent + b.size
                    counted = true
                    -- The id off the RETURNED entry: uploading over a deleted
                    -- book revives it keeping its ORIGINAL id.
                    if entry.id then
                        accepted[#accepted + 1] = { id = entry.id,
                            path = entry.path or b.rel, hash = hash, size = b.size }
                    end
                elseif up_code == 403 then
                    st.phase = "failed"
                    st.message = "not_upload_device"
                    writeState()
                    os.exit(1)
                elseif up_code == 409 then
                    st.skipped = st.skipped + 1
                    counted = true
                else
                    st.failed = st.failed + 1
                    counted = true
                    log("upload failed:", b.rel, tostring(up_code))
                end
            end
        end
    end

    if counted then
        st.done = st.done + 1
        st.bytes_done = st.bytes_done + b.size
    end
    writeState()
end

st.phase = "done"
st.current = ""
writeState()
-- The job file carries the token, so it does not outlive the job.
os.remove(job_path)
os.exit(0)
