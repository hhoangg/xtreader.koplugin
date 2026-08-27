--[[
Notice a move the moment it happens, rather than at the next sync.

WHY

Moving a book between folders left it visible in its new home AND showing as a
placeholder in its old one, until the reader opened the control centre and
synced. Reported from the device, and it is a fair complaint: nothing about
dragging a file suggests you then have to go and tell the application about it.

The placeholder providers list each catalogue entry whose file is not where the
catalogue says. A local move makes that true for the old path instantly, and the
catalogue only learns better when a sync fetches a fresh manifest.

WHERE IT HOOKS

`FileManager:moveFile(from, to)` is the single function every move goes through
-- paste-from-clipboard, the folder menu, bulk operations. Patching one function
covers all of them, and it is the narrowest seam available: KOReader broadcasts
no event for a move, and `pasteFileFromClipboard` does its own bookkeeping
inline (DocSettings, ReadHistory, ReadCollection) rather than announcing
anything.

`to` may be a DIRECTORY. In the paste path it is the destination folder, not the
destination file, so the new path has to be reconstructed from the source's
basename. Getting that wrong would record a move to a path that does not exist,
which is worse than recording nothing.

WHAT IT DOES NOT DO

It does not talk to the network. A move is a local, instant action and a reader
who has just dragged a file is not waiting for a round trip -- and may have no
Wi-Fi at all. The note is written locally and the next sync pushes it, which it
now does without having to rediscover the move by hashing.
]]

local logger = require("logger")
local userpatch = require("userpatch")

local function plugin()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager or not FileManager.instance then
        return nil
    end
    return FileManager.instance.xtreader
end

local function patch()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or type(FileManager) ~= "table" then
        return false, "no FileManager"
    end
    if rawget(FileManager, "_xtreader_move_patched") then return true end

    local orig_move = rawget(FileManager, "moveFile")
    if type(orig_move) ~= "function" then
        return false, "unexpected FileManager shape"
    end

    FileManager.moveFile = function(self, from, to)
        local ok_move = orig_move(self, from, to)
        if not ok_move then return ok_move end

        -- Everything below is best-effort. A bookkeeping note is never worth
        -- turning a successful move into an error dialog, so the whole thing is
        -- wrapped and a failure is a log line.
        pcall(function()
            local inst = plugin()
            if not (inst and inst.store and inst.store:isPaired()) then return end
            local lfs = require("libs/libkoreader-lfs")

            -- `to` is a directory in the paste path and a full path elsewhere.
            local dest = to
            if lfs.attributes(to, "mode") == "directory" then
                local name = from:match("[^/]+$")
                if not name then return end
                dest = to:gsub("/+$", "") .. "/" .. name
            end

            local Library = require("library")
            local id = Library.noteLocalMove(inst.store, from, dest)
            if id then
                logger.dbg("xtreader: noted local move", from, "->", dest)
            end
        end)
        return ok_move
    end

    FileManager._xtreader_move_patched = true
    return true
end

userpatch.registerPatchPluginFunc("xtreader", function()
    local ok, err = pcall(patch)
    if ok and err ~= false then
        logger.dbg("xtreader: move patch applied")
    else
        -- Without this a move is still noticed, just one sync later. Losing the
        -- patch costs promptness, not correctness.
        logger.warn("xtreader: move patch skipped:", tostring(err))
    end
end)
