-- tests/_test_library_move.lua
--
-- Deciding a move from a delete, which the server cannot do and this can only
-- do by guessing. The two guesses are not symmetric, and that asymmetry is the
-- whole design:
--
--   guess DELETE wrongly -> one reader shows a placeholder until next sync
--   guess MOVE   wrongly -> the account's folder tree changes for every device
--
-- So the hash is a GATE. A candidate that cannot be hashed falls back to
-- delete. A same-basename match on its own is worthless -- this library has
-- muc-than-ky.epub at more than one path already.

package.path = "./xtreader.koplugin/?.lua;" .. package.path
package.loaded["logger"]   = { warn = function() end, dbg = function() end }
package.loaded["gettext"]  = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["ffi/util"] = { template = function(f, ...)
    local a = { ... }
    return (f:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end))
end }

-- A fake tree. `FILES[path] = contents`; directories are inferred.
local FILES = {}
local function dirsOf(path)
    local out = {}
    for seg in path:gmatch("/([^/]+)") do out[#out + 1] = seg end
    return out
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(p, key)
        if FILES[p] ~= nil then
            if key == "mode" then return "file" end
            return { mode = "file", size = #FILES[p] }
        end
        -- a directory exists if anything lives under it
        for k in pairs(FILES) do
            if k:sub(1, #p + 1) == p .. "/" then
                if key == "mode" then return "directory" end
                return { mode = "directory", size = 0 }
            end
        end
        return nil
    end,
    dir = function(p)
        local seen, names = {}, { ".", ".." }
        for k in pairs(FILES) do
            if k:sub(1, #p + 1) == p .. "/" then
                local rest = k:sub(#p + 2)
                local head = rest:match("^([^/]+)")
                if head and not seen[head] then seen[head] = true; names[#names + 1] = head end
            end
        end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
-- A hash that is just the contents, so a test can state "same bytes" directly.
package.loaded["ffi/sha2"] = {
    sha256 = function()
        local acc = {}
        return function(chunk)
            if chunk == nil then return table.concat(acc) end
            acc[#acc + 1] = chunk
            return nil
        end
    end,
}

-- io.open has to be faked too, or contentHash opens the real filesystem and
-- every candidate reads as unhashable -- which the gate then correctly refuses,
-- so the whole suite passes for the wrong reason.
local real_open = io.open
local function fake_open(p, mode)
    if FILES[p] ~= nil then
        local body, pos = FILES[p], 1
        return {
            read = function(_self, n)
                if pos > #body then return nil end
                if n == "*a" then local r = body:sub(pos); pos = #body + 1; return r end
                local r = body:sub(pos, pos + n - 1); pos = pos + n; return r
            end,
            close = function() end,
        }
    end
    return real_open(p, mode)
end
io.open = fake_open

local Library = dofile("xtreader.koplugin/library.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local ROOT = "/lib"

test("a book moved to another folder is found by its bytes", function()
    FILES = { ["/lib/B/x.epub"] = "CONTENTS-A" }
    local found = Library.findMovedTo(ROOT, "/A/x.epub", "CONTENTS-A")
    assert(found == "/lib/B/x.epub", "expected the new path, got " .. tostring(found))
end)

test("a same-named DIFFERENT book is not a move", function()
    -- The case that makes basename alone worthless: he has muc-than-ky.epub at
    -- more than one path already.
    FILES = { ["/lib/B/x.epub"] = "SOMETHING-ELSE" }
    assert(Library.findMovedTo(ROOT, "/A/x.epub", "CONTENTS-A") == nil,
        "matching only the name would re-file somebody's library")
end)

test("a genuine delete stays a delete", function()
    FILES = {}
    assert(Library.findMovedTo(ROOT, "/A/x.epub", "CONTENTS-A") == nil)
end)

test("no hash to compare against means no move", function()
    -- The manifest did not carry a contentHash. Proceeding on the basename is
    -- exactly what must not happen.
    FILES = { ["/lib/B/x.epub"] = "CONTENTS-A" }
    assert(Library.findMovedTo(ROOT, "/A/x.epub", nil) == nil)
end)

test("an unreadable candidate falls back to delete", function()
    -- Permissions, a race, a dying card. The gate must close, not open.
    FILES = { ["/lib/B/x.epub"] = "CONTENTS-A" }
    io.open = function(p, m)
        if p == "/lib/B/x.epub" then return nil, "permission denied" end
        return fake_open(p, m)
    end
    local found = Library.findMovedTo(ROOT, "/A/x.epub", "CONTENTS-A")
    io.open = fake_open
    assert(found == nil, "a file that cannot be hashed is not a proven move")
end)

test("the file still at its old path is not reported as moved", function()
    FILES = { ["/lib/A/x.epub"] = "CONTENTS-A" }
    assert(Library.findMovedTo(ROOT, "/A/x.epub", "CONTENTS-A") == nil,
        "the old path is where it is supposed to be, not a destination")
end)

test("it looks several folders deep", function()
    FILES = { ["/lib/a/b/c/x.epub"] = "CONTENTS-A" }
    assert(Library.findMovedTo(ROOT, "/A/x.epub", "CONTENTS-A") == "/lib/a/b/c/x.epub")
end)

test(".sdr folders are not searched", function()
    -- A sidecar directory holds no books, and walking them on a large library
    -- doubles the tree for nothing.
    FILES = { ["/lib/A/x.sdr/x.epub"] = "CONTENTS-A" }
    assert(Library.findMovedTo(ROOT, "/A/x.epub", "CONTENTS-A") == nil)
end)

io.write(string.format("PASS %d  FAIL %d\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
