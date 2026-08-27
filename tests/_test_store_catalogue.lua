-- tests/_test_store_catalogue.lua
--
-- The catalogue is what the placeholder providers read, so an entry that is
-- wrong here becomes a card on the shelf for a book that is not missing.

package.path = "./xtreader.koplugin/?.lua;" .. package.path
package.loaded["logger"] = { warn = function() end, dbg = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end }
package.loaded["luasettings"] = {
    open = function() return {
        readSetting = function(_s, _k, d) return d end,
        saveSetting = function() end,
        flush = function() end,
    } end,
}

local Store = dofile("xtreader.koplugin/store.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function fresh()
    local s = setmetatable({ catalogue = {}, library = {}, dirty = false }, { __index = Store })
    return s
end

test("one entry can be corrected without replacing the catalogue", function()
    -- A full replacement is normally right -- a merge cannot express removal --
    -- but a sync that CHANGES the account partway through has already written
    -- its snapshot from a manifest fetched before the change existed.
    local s = fresh()
    s.catalogue = {
        a = { path = "/test/x.epub", hash = "h1" },
        b = { path = "/other/y.epub", hash = "h2" },
    }
    local e = s:getCatalogueEntry("a")
    e.path = "/Tien hiep/x.epub"
    s:setCatalogueEntry("a", e)
    assert(s:getCatalogueEntry("a").path == "/Tien hiep/x.epub", "the moved entry must follow")
    assert(s:getCatalogueEntry("b").path == "/other/y.epub", "everything else must be untouched")
    assert(s:getCatalogueEntry("a").hash == "h1", "the rest of the entry must survive")
end)

test("it marks the store dirty, or the correction is never written", function()
    local s = fresh()
    s.catalogue = { a = { path = "/x" } }
    s.dirty = false
    s:setCatalogueEntry("a", { path = "/y" })
    assert(s.dirty == true, "an unflushed correction is the same as no correction")
end)

test("a nil id is ignored rather than crashing a sync", function()
    local s = fresh()
    local ok = pcall(function() s:setCatalogueEntry(nil, { path = "/x" }) end)
    assert(ok, "must not raise")
end)

io.write(string.format("PASS %d  FAIL %d\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
