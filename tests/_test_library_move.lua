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

-- ------------------------------------------------- noting a move as it happens

local function fakeStore(books, catalogue, root)
    return {
        _books = books, _cat = catalogue, flushed = false,
        get = function(_s, k) return k == "library_dir" and (root or "/lib") or nil end,
        eachBook = function(s) return pairs(s._books) end,
        setBook = function(s, id, e) s._books[id] = e end,
        getCatalogueEntry = function(s, id) return s._cat[id] end,
        setCatalogueEntry = function(s, id, e) s._cat[id] = e end,
        flush = function(s) s.flushed = true end,
    }
end

test("a noted move corrects the CATALOGUE, which is what draws placeholders", function()
    local st = fakeStore({ b1 = { path = "/test/x.epub" } },
                         { b1 = { path = "/test/x.epub", hash = "h" } })
    local id = Library.noteLocalMove(st, "/lib/test/x.epub", "/lib/Tien hiep/x.epub")
    assert(id == "b1", "expected the book id, got " .. tostring(id))
    assert(st._cat.b1.path == "/Tien hiep/x.epub",
        "the catalogue must follow immediately or the old folder keeps a phantom")
    assert(st.flushed, "an unflushed note is lost on the next restart")
end)

test("it does NOT move library.path, which would undo the move next sync", function()
    -- library.path holds what the SERVER thinks. Pass 1 renames the local file
    -- whenever the two disagree, so writing the new path here would have the
    -- next sync drag the book back to where it came from.
    local st = fakeStore({ b1 = { path = "/test/x.epub" } },
                         { b1 = { path = "/test/x.epub" } })
    Library.noteLocalMove(st, "/lib/test/x.epub", "/lib/Tien hiep/x.epub")
    assert(st._books.b1.path == "/test/x.epub",
        "library.path must still be the server's view, got " .. st._books.b1.path)
    assert(st._books.b1.pending_move == "/Tien hiep/x.epub",
        "the push has to be remembered somewhere, got " .. tostring(st._books.b1.pending_move))
end)

test("a SECOND move before any sync is still found", function()
    -- Reported from the device: /A -> /B worked, /B -> /A left a placeholder in
    -- /B until a sync.
    --
    -- After the first note, library.path still says /test -- deliberately, it
    -- is the SERVER's view -- while the file really sits in /Tien hiep. Matching
    -- the move's source against library.path alone therefore finds nothing the
    -- second time, and the catalogue is left pointing at a folder the book left.
    local st = fakeStore({ b1 = { path = "/test/x.epub" } },
                         { b1 = { path = "/test/x.epub" } })
    Library.noteLocalMove(st, "/lib/test/x.epub", "/lib/Tien hiep/x.epub")
    local id = Library.noteLocalMove(st, "/lib/Tien hiep/x.epub", "/lib/Kiem hiep/x.epub")
    assert(id == "b1", "the book has to be found by where it IS, got " .. tostring(id))
    assert(st._cat.b1.path == "/Kiem hiep/x.epub",
        "the catalogue must follow the second move too, got " .. tostring(st._cat.b1.path))
    assert(st._books.b1.pending_move == "/Kiem hiep/x.epub",
        "the push must name the latest path, got " .. tostring(st._books.b1.pending_move))
    assert(st._books.b1.path == "/test/x.epub",
        "library.path is still the server's view, got " .. tostring(st._books.b1.path))
end)

test("moving a book BACK to where the server has it cancels the push", function()
    -- The end state is the one the server already believes, so there is nothing
    -- left to tell it. A pending_move here would be a no-op round trip, and a
    -- catalogue still naming the middle folder is the placeholder bug itself.
    local st = fakeStore({ b1 = { path = "/test/x.epub" } },
                         { b1 = { path = "/test/x.epub" } })
    Library.noteLocalMove(st, "/lib/test/x.epub", "/lib/Tien hiep/x.epub")
    local id = Library.noteLocalMove(st, "/lib/Tien hiep/x.epub", "/lib/test/x.epub")
    assert(id == "b1", "expected the book id, got " .. tostring(id))
    assert(st._cat.b1.path == "/test/x.epub",
        "the catalogue must come back with it, got " .. tostring(st._cat.b1.path))
    assert(st._books.b1.pending_move == nil,
        "nothing to push, got " .. tostring(st._books.b1.pending_move))
end)

test("a STALE pending_move must not hide a move from the server's own path", function()
    -- pending_move is a hint, not a fact: pass 1 of the sync clears it whenever
    -- the file is not where it says. A sync that rewrites the catalogue from a
    -- fresh manifest can leave the hint behind pointing at a folder the book is
    -- not in.
    --
    -- Matching ONLY on `pending_move or path` let that stale hint shadow
    -- library.path, so a perfectly ordinary first move -- out of the folder the
    -- server names -- matched nothing and the catalogue kept the old folder.
    -- That is the placeholder-in-the-source-folder bug, reintroduced from the
    -- other side.
    local st = fakeStore({ b1 = { path = "/tieu thuyet/x.epub",
                                  pending_move = "/somewhere else/x.epub" } },
                         { b1 = { path = "/tieu thuyet/x.epub" } })
    local id = Library.noteLocalMove(st, "/lib/tieu thuyet/x.epub", "/lib/test/x.epub")
    assert(id == "b1", "the server's own path must still match, got " .. tostring(id))
    assert(st._cat.b1.path == "/test/x.epub",
        "the catalogue must follow, got " .. tostring(st._cat.b1.path))
    assert(st._books.b1.pending_move == "/test/x.epub",
        "the stale hint must be replaced, got " .. tostring(st._books.b1.pending_move))
end)

test("the book actually AT the source wins over one the server merely names there", function()
    -- Two books can name the same path from different sides: b1 left it (the
    -- server has not been told yet), b2 was moved into it. The one that is
    -- really there is the one being moved.
    local st = fakeStore({
        b1 = { path = "/A/x.epub", pending_move = "/B/x.epub" },
        b2 = { path = "/C/x.epub", pending_move = "/A/x.epub" },
    }, { b1 = { path = "/B/x.epub" }, b2 = { path = "/A/x.epub" } })
    local id = Library.noteLocalMove(st, "/lib/A/x.epub", "/lib/D/x.epub")
    assert(id == "b2", "expected the book that is at /A, got " .. tostring(id))
    assert(st._books.b1.pending_move == "/B/x.epub", "b1 must not be touched")
end)

test("a file the account does not know about is ignored", function()
    local st = fakeStore({ b1 = { path = "/test/x.epub" } }, { b1 = {} })
    assert(Library.noteLocalMove(st, "/lib/other/z.epub", "/lib/Tien hiep/z.epub") == nil)
    assert(st._books.b1.pending_move == nil, "an unrelated book must not be touched")
end)

test("a move to or from outside the library root is ignored", function()
    local st = fakeStore({ b1 = { path = "/test/x.epub" } }, { b1 = {} })
    assert(Library.noteLocalMove(st, "/lib/test/x.epub", "/somewhere/else/x.epub") == nil,
        "out of the library is out of scope")
    assert(Library.noteLocalMove(st, "/elsewhere/x.epub", "/lib/test/x.epub") == nil)
end)

test("moving a file onto itself is not a move", function()
    local st = fakeStore({ b1 = { path = "/test/x.epub" } }, { b1 = {} })
    assert(Library.noteLocalMove(st, "/lib/test/x.epub", "/lib/test/x.epub") == nil)
end)

io.write(string.format("PASS %d  FAIL %d\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
