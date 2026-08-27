--[[
HTTP client for the xtreader device API.

Deliberately thin. Every route this plugin calls is documented in the server's
`docs/API.md`, and the contract in `packages/contract/src/` is the source of
truth; nothing here reinterprets it.

Two notes on the transport, both verified against KOReader's own source rather
than assumed:

  * `socket.http` handles https:// as well as http://. LuaSocket resolves the
    scheme through its own table and delegates to LuaSec, which `socketutil`
    pulls in and patches for timeouts. There is no separate `ssl.https.request`
    call anywhere in KOReader and there should not be one here.
  * `http.request` returns a NUMBER status code when a response arrived and a
    STRING when the socket failed ("timeout", "wantread", "sink timeout"). So
    every check is `code == 200`, never `code >= 200`.

The manifests are NDJSON. KOReader has no streaming line parser and no caller
that needs one, so this collects the page and splits it. That is the right
trade here: the byte-at-a-time discipline in the server's docs exists for an
ESP32-C3 with ~137 KB of heap, and a page of 200 entries is a few tens of KB on
a device with hundreds of megabytes.
]]

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local Api = {}
Api.__index = Api

-- At the server's max page size this is 100,000 entries, far past any real
-- library. It exists to stop a paging bug from looping forever, never to
-- shorten a legitimate answer — see fetchManifest.
local MAX_PAGES = 200

function Api.new(store)
    return setmetatable({ store = store }, Api)
end

function Api:baseUrl()
    local base = self.store:get("base_url") or ""
    return (base:gsub("/+$", ""))
end

function Api:authHeaders(extra)
    local headers = extra or {}
    local token = self.store:get("access_token")
    if token then
        headers["Authorization"] = "Bearer " .. token
    end
    return headers
end

--- Runs one request and normalises the three failure shapes into one.
-- Returns code, body, headers. `code` is a number for an HTTP response and a
-- string for a transport failure; callers only ever compare it to 200/201.
function Api:request(opts)
    local sink = {}
    local request = {
        url = opts.url,
        method = opts.method or "GET",
        headers = opts.headers,
        source = opts.source,
        sink = ltn12.sink.table(sink),
        -- LuaSocket only follows redirects for GET/HEAD and refuses an
        -- https->http downgrade, but this API never redirects off its own
        -- origin by design, so a redirect means something is wrong.
        redirect = false,
    }
    socketutil:set_timeout(opts.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
                           opts.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("xtreader: request interrupted:", status or code, opts.url)
        return code, nil, nil
    end
    if headers == nil then
        logger.warn("xtreader: no response headers:", status or code, opts.url)
        return code or "network_unreachable", nil, nil
    end
    return code, table.concat(sink), headers
end

local function decodeJson(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local first = body:sub(1, 1)
    if first ~= "{" and first ~= "[" then
        return nil
    end
    -- JSON.decode.simple maps `null` to nil. Without it luajson yields a
    -- function, which breaks any later comparison and cannot be serialised.
    local ok, decoded = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok then
        logger.warn("xtreader: malformed JSON:", decoded)
        return nil
    end
    return decoded
end

function Api:getJson(path, headers)
    local code, body = self:request({
        url = self:baseUrl() .. path,
        headers = self:authHeaders(headers),
    })
    if code ~= 200 then
        return nil, code, decodeJson(body)
    end
    return decodeJson(body), code
end

--- DELETE with no body.
--
-- 404 is folded into success on purpose: it means the row is already gone, and
-- the caller's goal -- "this book should not be on the server" -- is met either
-- way. Treating it as a failure would strand a book locally forever, because
-- the delete would never be able to report done.
function Api:delete(path)
    local code, body = self:request({
        url = self:baseUrl() .. path,
        method = "DELETE",
        headers = self:authHeaders({ ["Accept"] = "application/json" }),
    })
    if code == 200 or code == 204 or code == 404 then
        return true, code
    end
    return false, code, decodeJson(body)
end

function Api:postJson(path, payload, opts)
    opts = opts or {}
    local data = payload and JSON.encode(payload) or ""
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#data),
        ["Accept"] = "application/json",
    }
    if not opts.anonymous then
        headers = self:authHeaders(headers)
    end
    local code, body = self:request({
        url = self:baseUrl() .. path,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(data),
    })
    -- 201 is a success here (POST /device/code, POST /wallpapers/:id/attach).
    if code ~= 200 and code ~= 201 then
        return nil, code, decodeJson(body)
    end
    return decodeJson(body) or {}, code
end

--- Fetches every page of an NDJSON manifest and returns the entries.
--
-- Paging is keyset: the trailer's `nextCursor` is echoed back verbatim until it
-- is null. Cursors are opaque and carry the ordering that produced them, so
-- they are never synthesised or cached across a query change.
--
-- `on_entry` is called per entry so a caller can filter without a second pass.
function Api:fetchManifest(path, query, on_entry)
    local entries = {}
    local cursor = nil
    local total = nil
    local pages = 0

    repeat
        local url = self:baseUrl() .. path .. "?" .. (query or "")
        if cursor then
            url = url .. "&cursor=" .. require("socket.url").escape(cursor)
        end
        local code, body = self:request({ url = url, headers = self:authHeaders() })
        if code ~= 200 then
            return nil, code
        end

        local trailer = nil
        for line in body:gmatch("[^\r\n]+") do
            local ok, row = pcall(JSON.decode, line, JSON.decode.simple)
            if not ok or type(row) ~= "table" then
                logger.warn("xtreader: unparsable manifest line, skipped")
            elseif row.done == true then
                trailer = row
            else
                if on_entry == nil or on_entry(row) ~= false then
                    entries[#entries + 1] = row
                end
            end
        end

        if trailer == nil then
            -- No trailer means the page was truncated mid-flight. Treating a
            -- partial page as complete would delete every book that did not
            -- make it into this response.
            logger.warn("xtreader: manifest page had no trailer, aborting")
            return nil, "truncated_manifest"
        end
        cursor = trailer.nextCursor
        total = trailer.totalCount
        pages = pages + 1

        -- A runaway-paging backstop, but it must never look like a completed
        -- walk. Callers use the returned set to decide what to DELETE, so
        -- handing back a truncated list that reports success would delete
        -- everything past the cap. Same family as the missing-trailer case
        -- below: a partial answer is an error, not a smaller answer.
        if cursor ~= nil and pages >= MAX_PAGES then
            logger.warn("xtreader: manifest exceeded", MAX_PAGES, "pages; refusing to truncate")
            return nil, "manifest_too_long"
        end
    until cursor == nil

    return entries, 200, total
end

--- Streams a response body straight to disk.
--
-- Writes to `dest .. ".part"` and only renames into place once the size checks
-- out, so an interrupted download can never be mistaken for a complete file.
-- KOReader has no Range/resume precedent anywhere in its source, so a failed
-- download is simply retried on the next sync rather than resumed.
function Api:downloadTo(path, dest, expected_size, progress_cb)
    local part = dest .. ".part"
    local handle, io_err = io.open(part, "w")
    if not handle then
        return false, io_err or "cannot_open"
    end

    local sink = ltn12.sink.file(handle)
    if progress_cb then
        sink = socketutil.chainSinkWithProgressCallback(sink, progress_cb)
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request({
        url = self:baseUrl() .. path,
        method = "GET",
        headers = self:authHeaders({ ["Accept-Encoding"] = "identity" }),
        sink = sink,
        redirect = false,
    }))
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.warn("xtreader: download failed:", status or code, path)
        os.remove(part)
        return false, code
    end

    if expected_size then
        local lfs = require("libs/libkoreader-lfs")
        local attr = lfs.attributes(part)
        if not attr or attr.size ~= expected_size then
            logger.warn("xtreader: size mismatch for", path,
                        "expected", expected_size, "got", attr and attr.size)
            os.remove(part)
            return false, "size_mismatch"
        end
    end

    os.remove(dest)
    local ok, rename_err = os.rename(part, dest)
    if not ok then
        os.remove(part)
        return false, rename_err or "rename_failed"
    end
    return true
end

--- Stream one local file to the server as a raw body.
--
-- `query` is the already-escaped query string the endpoint wants; the caller
-- owns escaping because it owns the values.
--
-- Returns `entry, nil` on 201, or `nil, code` otherwise. The CODE is returned
-- rather than a message because the caller has to branch on it -- 409 means
-- "already there", 403 means "this reader is not the upload source", and those
-- are different outcomes, not two flavours of failure.
--
-- Streamed with ltn12 rather than read into a string: a 100 MiB book held whole
-- in memory on a device with ~256 MB is how a reader gets OOM-killed halfway
-- through a bulk push.
--
-- Content-Length is mandatory and is taken from the filesystem, not from a
-- caller-supplied figure. S3 rejects a streamed PUT without one, so a wrong
-- length does not fail politely -- it fails after the bytes have been sent.
function Api:uploadFile(path, query, local_path, progress_cb)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(local_path)
    if not attr or attr.mode ~= "file" then
        return nil, "not_a_file"
    end
    local handle, io_err = io.open(local_path, "rb")
    if not handle then
        return nil, io_err or "cannot_open"
    end

    local source = ltn12.source.file(handle)
    if progress_cb then
        local sent = 0
        local inner = source
        source = function()
            local chunk, err = inner()
            if chunk then
                sent = sent + #chunk
                progress_cb(sent)
            end
            return chunk, err
        end
    end

    local url = self:baseUrl() .. path
    if query and query ~= "" then url = url .. "?" .. query end

    local sink = {}
    -- A total timeout DERIVED FROM THE FILE SIZE. Both fixed answers are wrong,
    -- and both were tried on the device:
    --
    --   KOReader's FILE_TOTAL_TIMEOUT is a flat 60 seconds for the whole
    --   request. At the ~2 MB/s a Kindle manages that kills any book over about
    --   120 MB outright, and on Wi-Fi that dips it kills much smaller ones --
    --   seen as `wantwrite` and `Connection reset by peer` on two large books,
    --   which is what a healthy transfer looks like when something cuts it off.
    --
    --   No total timeout at all then hangs forever on a connection that stalls
    --   rather than dies. Seen minutes later on a 1 MB book, with
    --   `netstat` showing 26 KB sitting in the send queue and going nowhere:
    --   the block timeout never fires, because a trickle is not silence.
    --
    -- So the ceiling scales with what is being sent: a floor of 60 seconds for
    -- the handshake and the server's own work, plus the time the file would
    -- take at a deliberately pessimistic 50 KB/s. That is roughly a fortieth of
    -- what the device actually manages, so a healthy transfer never comes near
    -- it, while a stalled one still ends.
    local floor_sec, slow_bytes_per_sec = 60, 50 * 1024
    local total_timeout = floor_sec + math.ceil(attr.size / slow_bytes_per_sec)
    socketutil:set_timeout(30, total_timeout)
    local code, _, status = socket.skip(1, http.request({
        url     = url,
        method  = "POST",
        headers = self:authHeaders({
            ["Content-Type"]   = "application/octet-stream",
            ["Content-Length"] = tostring(attr.size),
        }),
        source   = source,
        sink     = ltn12.sink.table(sink),
        redirect = false,
    }))
    socketutil:reset_timeout()
    pcall(function() handle:close() end)

    if code ~= 201 and code ~= 200 then
        logger.warn("xtreader: upload failed:", status or code, local_path)
        return nil, code
    end
    return decodeJson(table.concat(sink)) or {}, nil
end

return Api
