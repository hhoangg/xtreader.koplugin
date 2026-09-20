-- tests/_test_fonts.lua
--
-- Font sync owns one folder on the card and deletes from it. The two ways to
-- get that wrong are not symmetric:
--
--   keep an extra wrongly   -> a font lingers in the menu until the next sync
--   delete wrongly          -> a font the reader was using is gone, and every
--                              book set in it reflows to the fallback
--
-- So deletion of anything that is not an interrupted download or a case-only
-- rename is gated on the manifest being authoritative, and most of this suite
-- is about that gate.

package.path = "./xtreader.koplugin/?.lua;" .. package.path
package.loaded["logger"]   = { warn = function() end, dbg = function() end }
package.loaded["gettext"]  = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["ffi/util"] = { template = function(f, ...)
    local a = { ... }
    return (f:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end))
end }
package.loaded["device"] = {}

-- A fake tree. `FILES[path] = contents`, `DIRS[path] = true`.
local FILES, DIRS = {}, {}
local function children(p)
    local seen, names = {}, {}
    local function add(k)
        if k:sub(1, #p + 1) == p .. "/" then
            local head = k:sub(#p + 2):match("^([^/]+)")
            if head and not seen[head] then seen[head] = true; names[#names + 1] = head end
        end
    end
    for k in pairs(FILES) do add(k) end
    for k in pairs(DIRS) do add(k) end
    table.sort(names)
    return names
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(p, key)
        local attr
        if FILES[p] ~= nil then
            attr = { mode = "file", size = #FILES[p] }
        elseif DIRS[p] then
            attr = { mode = "directory", size = 0 }
        end
        if attr and key then return attr[key] end
        return attr
    end,
    dir = function(p)
        local names = { ".", "..", unpack(children(p)) }
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
    mkdir = function(p) DIRS[p] = true; return true end,
    rmdir = function(p)
        if #children(p) > 0 then return nil, "not empty" end
        DIRS[p] = nil
        return true
    end,
}
os.remove = function(p)
    if FILES[p] ~= nil then FILES[p] = nil; return true end
    return nil, "no such file"
end
-- A hash that is just the contents, so a test can state "same bytes" directly.
package.loaded["ffi/sha2"] = {
    sha256 = function()
        local acc = {}
        return function(chunk)
            if chunk == nil then return table.concat(acc) end
            acc[#acc + 1] = chunk
        end
    end,
}
local real_open = io.open
io.open = function(p, mode)
    if FILES[p] ~= nil and (mode == nil or mode:sub(1, 1) == "r") then
        local body, pos = FILES[p], 1
        return {
            read = function(_self, n)
                if pos > #body then return nil end
                local r = body:sub(pos, pos + n - 1); pos = pos + n; return r
            end,
            close = function() end,
        }
    end
    return real_open(p, mode)
end

local Fonts = dofile("xtreader.koplugin/fonts.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function font(family, fileName, body, over)
    local e = {
        id = (family .. "_" .. fileName):gsub("[^A-Za-z0-9_%-]", "_"),
        family = family, fileName = fileName,
        format = fileName:lower():match("%.(%w+)$"),
        sizeBytes = #body, contentHash = body,
    }
    for k, v in pairs(over or {}) do e[k] = v end
    return e
end

local function set(list, field)
    local out = {}
    for _i, v in ipairs(list) do out[field and v[field] or v] = true end
    return out
end
local function paths(list)
    local out = {}
    for _i, v in ipairs(list) do out[v.path or Fonts.relPath(v)] = true end
    return out
end
local function count(t) local n = 0; for _k in pairs(t) do n = n + 1 end; return n end

--------------------------------------------------------------------------------
-- Entry validation
--------------------------------------------------------------------------------

test("a well-formed ttf and otf entry pass", function()
    assert(Fonts.invalidReason(font("Literata", "Literata-Regular.ttf", "x")) == nil)
    assert(Fonts.invalidReason(font("Lit_2-b", "Lit-Bold.OTF", "x", { format = "otf" })) == nil,
        "the extension is matched case-insensitively")
end)

test("each rule rejects on its own", function()
    local base = font("Lit", "a.ttf", "x")
    local function bad(over, why)
        local e = {}
        for k, v in pairs(base) do e[k] = v end
        for k, v in pairs(over) do e[k] = v end
        if over.id == false then e.id = nil end
        assert(Fonts.invalidReason(e) ~= nil, "should reject: " .. why)
    end
    bad({ id = false }, "missing id")
    bad({ id = "a/b" }, "slash in id")
    bad({ id = "../x" }, "traversal in id")
    bad({ family = "" }, "empty family")
    bad({ family = "../etc" }, "traversal in family")
    bad({ family = "a/b" }, "slash in family")
    bad({ family = "has space" }, "space in family")
    bad({ family = string.rep("a", 65) }, "family over 64")
    bad({ fileName = "" }, "empty fileName")
    bad({ fileName = "../a.ttf" }, "traversal in fileName")
    bad({ fileName = "x/a.ttf" }, "slash in fileName")
    bad({ fileName = "x\\a.ttf" }, "backslash in fileName")
    bad({ fileName = "a..ttf" }, "double dot in fileName")
    bad({ fileName = ".hidden.ttf" }, "leading dot")
    bad({ fileName = "a\nb.ttf" }, "control character")
    bad({ fileName = "a:b.ttf" }, "FAT-illegal character")
    bad({ fileName = string.rep("a", 125) .. ".ttf" }, "fileName over 128 bytes")
    bad({ format = "cpfont", fileName = "Lit_14.cpfont" }, "cpfont is not for this device")
    bad({ format = "otf" }, "format says otf, name says ttf")
    bad({ fileName = "a.otf" }, "format says ttf, name says otf")
    bad({ sizeBytes = -1 }, "negative size")
    bad({ sizeBytes = "12" }, "size as a string")
    bad({ contentHash = 5 }, "hash not a string")
    assert(Fonts.invalidReason(font("Lit", string.rep("a", 124) .. ".ttf", "x")) == nil,
        "exactly 128 bytes is allowed")
end)

test("invalid entries are dropped and the rest kept in order", function()
    local w = Fonts.wantedEntries({
        font("Lit", "a.ttf", "1"),
        font("Lit", "../b.ttf", "2"),
        "garbage",
        font("Lit", "c.ttf", "3"),
    })
    assert(#w == 2 and w[1].fileName == "a.ttf" and w[2].fileName == "c.ttf")
end)

test("case-insensitive duplicates keep the first", function()
    local w = Fonts.wantedEntries({
        font("Lit", "A.ttf", "first"),
        font("Lit", "a.TTF", "second", { format = "ttf" }),
        font("LIT", "b.ttf", "other spelling of the family"),
    })
    assert(#w == 1 and w[1].contentHash == "first",
        "FAT holds one of these; syncing both would flip between them forever")
end)

--------------------------------------------------------------------------------
-- Reconcile
--------------------------------------------------------------------------------

local A = font("Lit", "Lit-Regular.ttf", "AAAA")
local B = font("Lit", "Lit-Bold.ttf", "BBBBB")
local C = font("Mono", "Mono.otf", "CCC")

test("first sync downloads everything", function()
    local p = Fonts.reconcile({ A, B, C }, {}, {}, true)
    assert(#p.download == 3 and #p.delete == 0 and #p.verify == 0)
end)

test("a no-op sync does nothing", function()
    local listing = {
        { path = "Lit", mode = "directory" },
        { path = "Lit/Lit-Regular.ttf", mode = "file", size = 4 },
        { path = "Lit/Lit-Bold.ttf", mode = "file", size = 5 },
    }
    local ledger = {
        ["Lit/Lit-Regular.ttf"] = { id = A.id, hash = "AAAA", size = 4 },
        ["Lit/Lit-Bold.ttf"] = { id = B.id, hash = "BBBBB", size = 5 },
    }
    local p = Fonts.reconcile({ A, B }, listing, ledger, true)
    assert(#p.download == 0 and #p.delete == 0 and #p.verify == 0 and #p.drop == 0
        and #p.gone == 0)
end)

test("a size change downloads", function()
    local listing = { { path = "Lit", mode = "directory" },
                      { path = "Lit/Lit-Regular.ttf", mode = "file", size = 3 } }
    local p = Fonts.reconcile({ A }, listing,
        { ["Lit/Lit-Regular.ttf"] = { hash = "AAAA" } }, true)
    assert(#p.download == 1)
end)

test("a hash change recorded in the ledger downloads", function()
    local listing = { { path = "Lit", mode = "directory" },
                      { path = "Lit/Lit-Regular.ttf", mode = "file", size = 4 } }
    local p = Fonts.reconcile({ A }, listing,
        { ["Lit/Lit-Regular.ttf"] = { hash = "OLD!" } }, true)
    assert(#p.download == 1 and #p.verify == 0)
end)

test("right size but unknown to the ledger is hashed, not fetched", function()
    local listing = { { path = "Lit", mode = "directory" },
                      { path = "Lit/Lit-Regular.ttf", mode = "file", size = 4 } }
    local p = Fonts.reconcile({ A }, listing, {}, true)
    assert(#p.verify == 1 and #p.download == 0)
end)

local EXTRAS = {
    { path = "stray.ttf", mode = "file", size = 1 },
    { path = "Old", mode = "directory" },
    { path = "Old/old.ttf", mode = "file", size = 1 },
    { path = "Lit", mode = "directory" },
    { path = "Lit/Lit-Regular.ttf", mode = "file", size = 4 },
    { path = "Lit/unknown.ttf", mode = "file", size = 1 },
    { path = "Lit/nested", mode = "directory" },
    { path = "Lit/Lit-Bold.ttf.part", mode = "file", size = 2 },
    { path = "junk.part", mode = "file", size = 2 },
}
local EXTRA_LEDGER = {
    ["Lit/Lit-Regular.ttf"] = { hash = "AAAA" },
    ["Old/old.ttf"] = { hash = "o" },
}

test("extras are deleted when the set is authoritative", function()
    local p = Fonts.reconcile({ A }, EXTRAS, EXTRA_LEDGER, true)
    local d = paths(p.delete)
    for _i, want in ipairs({ "stray.ttf", "Old", "Lit/unknown.ttf", "Lit/nested",
                             "Lit/Lit-Bold.ttf.part", "junk.part" }) do
        assert(d[want], "should delete " .. want)
    end
    assert(not d["Lit/Lit-Regular.ttf"] and not d["Lit"], "the wanted font stays")
    assert(set(p.drop)["Old/old.ttf"] and not set(p.drop)["Lit/Lit-Regular.ttf"],
        "the ledger forgets what is gone and only that")
    local g = set(p.gone)
    assert(g["stray.ttf"] and g["Old/old.ttf"] and g["Lit/unknown.ttf"] and count(g) == 3,
        ".part files are not counted as removals")
    assert(p.kept == 0)
end)

test("extras are KEPT when the set is not authoritative", function()
    local p = Fonts.reconcile({ A }, EXTRAS, EXTRA_LEDGER, false)
    local d = paths(p.delete)
    assert(count(d) == 2 and d["Lit/Lit-Bold.ttf.part"] and d["junk.part"],
        "only the .part files may go")
    assert(#p.drop == 0, "a kept file keeps its ledger entry, so a later run can still delete it")
    assert(#p.gone == 0 and p.kept == 4)
end)

test("an empty manifest that is not authoritative deletes nothing", function()
    -- The shape of "the set failed to load": a trailer-only 200.
    local listing = {
        { path = "Lit", mode = "directory" },
        { path = "Lit/Lit-Regular.ttf", mode = "file", size = 4 },
    }
    local p = Fonts.reconcile({}, listing, { ["Lit/Lit-Regular.ttf"] = { hash = "AAAA" } }, false)
    assert(#p.delete == 0 and #p.download == 0 and #p.drop == 0 and p.kept == 1)
end)

test("an empty manifest that IS authoritative clears the folder", function()
    local listing = {
        { path = "Lit", mode = "directory" },
        { path = "Lit/Lit-Regular.ttf", mode = "file", size = 4 },
    }
    local p = Fonts.reconcile({}, listing, { ["Lit/Lit-Regular.ttf"] = { hash = "AAAA" } }, true)
    assert(paths(p.delete)["Lit"] and #p.drop == 1 and #p.gone == 1)
end)

test("a case-only rename deletes the old name and downloads the new, even unauthoritative", function()
    local listing = {
        { path = "Lit", mode = "directory" },
        { path = "Lit/lit-regular.TTF", mode = "file", size = 4 },
    }
    local p = Fonts.reconcile({ A }, listing, { ["Lit/lit-regular.TTF"] = { hash = "AAAA" } }, false)
    assert(paths(p.delete)["Lit/lit-regular.TTF"] and #p.download == 1)
    assert(set(p.drop)["Lit/lit-regular.TTF"])
end)

test("a mis-cased family folder is replaced whole", function()
    local listing = {
        { path = "lit", mode = "directory" },
        { path = "lit/Lit-Regular.ttf", mode = "file", size = 4 },
    }
    local p = Fonts.reconcile({ A }, listing, {}, false)
    assert(paths(p.delete)["lit"] and #p.download == 1,
        "left alone, FAT would keep the old spelling and every run would see it again")
end)

--------------------------------------------------------------------------------
-- Fonts.sync end to end, on the fake tree
--------------------------------------------------------------------------------

local function fakeStore(ledger)
    local s = { data = { font_dir = "/f" }, fonts = ledger or {}, flushed = 0 }
    function s:get(k) return self.data[k] end
    function s:set(k, v) self.data[k] = v end
    function s:eachFont() return pairs(self.fonts) end
    function s:setFont(k, v) self.fonts[k] = v end
    function s:removeFont(k) self.fonts[k] = nil end
    function s:flush() self.flushed = self.flushed + 1 end
    return s
end

local function fakeApi(entries, revision, bodies)
    return {
        downloads = 0,
        fetchManifest = function() return entries, 200, #entries, revision end,
        downloadTo = function(self, path, dest, size)
            self.downloads = self.downloads + 1
            local id = path:match("^/fonts/(.-)/file$")
            local body = bodies[id]
            if not body or #body ~= size then return false end
            FILES[dest] = body
            return true
        end,
    }
end

local function silent() return true end

test("sync: first run lands every file and records it", function()
    FILES, DIRS = { ["/f/stray.txt"] = "s", ["/f/Old/x.ttf.part"] = "p" }, { ["/f"] = true, ["/f/Old"] = true }
    local store = fakeStore()
    local api = fakeApi({ A, C }, 7, { [A.id] = "AAAA", [C.id] = "CCC" })
    local ok, msg, changed, rev = Fonts.sync(api, store, 7, silent)
    assert(ok and changed and rev == 7, msg)
    assert(FILES["/f/Lit/Lit-Regular.ttf"] == "AAAA" and FILES["/f/Mono/Mono.otf"] == "CCC")
    assert(FILES["/f/stray.txt"] == nil and DIRS["/f/Old"] == nil, "extras and emptied folders go")
    assert(store.fonts["Lit/Lit-Regular.ttf"].hash == "AAAA" and store.flushed > 0)
    assert(msg:find("2 new, 1 removed, 0 failed", 1, true), msg)

    -- Same set again: nothing to do, and nothing to restart for.
    local api2 = fakeApi({ A, C }, 7, {})
    local ok2, msg2, changed2 = Fonts.sync(api2, store, 7, silent)
    assert(ok2 and not changed2 and api2.downloads == 0, msg2)
end)

test("sync: a hash mismatch after download is deleted and not ok", function()
    FILES, DIRS = {}, { ["/f"] = true }
    local store = fakeStore()
    local api = fakeApi({ A }, 3, { [A.id] = "ZZZZ" })  -- right size, wrong bytes
    local ok, msg = Fonts.sync(api, store, 3, silent)
    assert(not ok and FILES["/f/Lit/Lit-Regular.ttf"] == nil and store.fonts["Lit/Lit-Regular.ttf"] == nil, msg)
    assert(msg:find("1 failed", 1, true), msg)
end)

test("sync: a revision mismatch keeps extras and is not ok", function()
    FILES, DIRS = { ["/f/Old/o.ttf"] = "o" }, { ["/f"] = true, ["/f/Old"] = true }
    local store = fakeStore()
    local api = fakeApi({}, 4, {})
    local ok, msg, changed = Fonts.sync(api, store, 5, silent)
    assert(not ok and not changed and FILES["/f/Old/o.ttf"] == "o", msg)
end)

test("sync: a file already on disk is adopted by hash, not fetched", function()
    FILES, DIRS = { ["/f/Lit/Lit-Regular.ttf"] = "AAAA" }, { ["/f"] = true, ["/f/Lit"] = true }
    local store = fakeStore()
    local api = fakeApi({ A }, 1, {})
    local ok, msg, changed = Fonts.sync(api, store, 1, silent)
    assert(ok and not changed and api.downloads == 0 and store.fonts["Lit/Lit-Regular.ttf"], msg)
end)

test("sync: cancelling stops and is not ok", function()
    FILES, DIRS = {}, { ["/f"] = true }
    local store = fakeStore()
    local api = fakeApi({ A, C }, 1, { [A.id] = "AAAA", [C.id] = "CCC" })
    local ok = Fonts.sync(api, store, 1, function(text)
        return not text:find("^Font ")
    end)
    assert(not ok and api.downloads == 0)
end)

--------------------------------------------------------------------------------
-- Api:fetchManifest's revision
--------------------------------------------------------------------------------

-- Lines are looked up rather than parsed: this is about paging, not JSON.
local ROWS = {}
package.loaded["json"] = {
    decode = setmetatable({ simple = {} }, { __call = function(_, s) return ROWS[s] end }),
}
package.loaded["socket.http"] = {}
package.loaded["ltn12"] = {}
package.loaded["socket"] = {}
package.loaded["socketutil"] = {}
package.loaded["socket.url"] = { escape = function(s) return s end }
local Api = dofile("xtreader.koplugin/api.lua")

local function pagedApi(pages)
    local api = Api.new({ get = function() return "https://x" end })
    local n = 0
    api.request = function()
        n = n + 1
        return 200, pages[n]
    end
    return api
end

test("fetchManifest: pages that agree yield their revision", function()
    ROWS = { e1 = { id = "1" }, e2 = { id = "2" },
             t1 = { done = true, nextCursor = "c", revision = 9 },
             t2 = { done = true, revision = 9 } }
    local entries, code, _total, rev = pagedApi({ "e1\nt1", "e2\nt2" }):fetchManifest("/fonts/manifest", "")
    assert(#entries == 2 and code == 200 and rev == 9, tostring(rev))
end)

test("fetchManifest: a page without a revision yields nil", function()
    ROWS = { e1 = { id = "1" }, t1 = { done = true, nextCursor = "c", revision = 9 },
             t2 = { done = true } }
    local entries, _code, _total, rev = pagedApi({ "e1\nt1", "t2" }):fetchManifest("/fonts/manifest", "")
    assert(entries and rev == nil)
end)

test("fetchManifest: pages that disagree yield nil", function()
    ROWS = { t1 = { done = true, nextCursor = "c", revision = 9 },
             t2 = { done = true, revision = 10 } }
    local entries, _code, _total, rev = pagedApi({ "t1", "t2" }):fetchManifest("/fonts/manifest", "")
    assert(entries and rev == nil)
end)

test("fetchManifest: a manifest with no revision at all still works", function()
    ROWS = { e1 = { id = "1" }, t1 = { done = true } }
    local entries, code, _total, rev = pagedApi({ "e1\nt1" }):fetchManifest("/library/manifest", "")
    assert(#entries == 1 and code == 200 and rev == nil)
end)

--------------------------------------------------------------------------------
-- Heartbeat
--------------------------------------------------------------------------------

local Heartbeat = dofile("xtreader.koplugin/heartbeat.lua")

local function hbStore(data)
    return {
        data = data or {},
        isPaired = function() return true end,
        get = function(self, k) return self.data[k] end,
    }
end
local function hbApi(body)
    return { postJson = function() return body, 200 end }
end

test("heartbeat returns fontsRevision even without a wallpaperRevision", function()
    local wp, fonts = Heartbeat.send(hbApi({ fontsRevision = 4 }), hbStore(), "ok")
    assert(wp == nil and fonts == 4)
    wp, fonts = Heartbeat.send(hbApi({ wallpaperRevision = 0, fontsRevision = 0 }), hbStore(), "ok")
    assert(wp == nil and fonts == 0, "0 is a real counter value, unlike the wallpaper fingerprint")
    wp, fonts = Heartbeat.send(hbApi({ wallpaperRevision = 77 }), hbStore(), "ok")
    assert(wp == 77 and fonts == nil)
end)

test("fontsChanged compares against the stored counter", function()
    assert(Heartbeat.fontsChanged(hbStore(), nil) == false, "no number, no sync")
    assert(Heartbeat.fontsChanged(hbStore(), 0) == false, "never synced and nothing to sync")
    assert(Heartbeat.fontsChanged(hbStore(), 1) == true)
    assert(Heartbeat.fontsChanged(hbStore({ fonts_revision = 3 }), 3) == false)
    assert(Heartbeat.fontsChanged(hbStore({ fonts_revision = 3 }), 4) == true)
end)

io.write(string.format("PASS %d  FAIL %d\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
