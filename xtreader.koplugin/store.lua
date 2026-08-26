--[[
Persistent state for the xtreader plugin.

Two things live here and they have very different lifetimes:

  * credentials — written once at pairing, read on every request
  * the library index — rewritten after every library sync

The index is what makes `id` useful. `GET /library/manifest` guarantees `id` is
stable across renames and moves, so when only `path` changes the right move is
to rename the local file rather than spend several MB of Wi-Fi re-downloading
bytes we already have. That is only possible if we remember which local file a
server id produced, which is what `library[id] = { path, hash, size }` is for.

Kept in KOReader's own settings dir rather than next to the books: the documents
folder is mirrored from the server and anything we leave there would show up in
the user's library as a stray file.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Store = {}

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/xtreader.lua"

-- The panel this build targets. The server refuses a wallpaper attach whose
-- panel is not the device's (409 device_kind_mismatch), so a wrong value here
-- fails loudly at pairing rather than producing a silently stretched image.
Store.DEVICE_KIND = "kindle-pw5"

Store.DEFAULTS = {
    base_url = "https://xtreader.com",
    access_token = nil,
    device_id = nil,
    device_name = nil,
    -- Provisioned at pairing, mirrored into the kosync plugin's own settings.
    kosync_username = nil,
    kosync_key = nil,
    -- Absolute path books are mirrored into. `/mnt/us/documents` is what the
    -- Kindle's own reader also scans, so a sideloaded EPUB is visible to both.
    library_dir = "/mnt/us/documents",
    -- Wallpapers land here and nowhere else; see wallpaper.lua for why the
    -- folder must stay flat.
    wallpaper_dir = "/mnt/us/koreader/xtreader_wallpapers",
    last_library_sync = 0,
    last_wallpaper_sync = 0,
}

function Store:open()
    if not self.obj then
        self.obj = LuaSettings:open(SETTINGS_FILE)
    end
    -- readSetting(key, default) writes the default and hands back a REFERENCE to
    -- it, so passing Store.DEFAULTS directly would let later writes mutate the
    -- module's own defaults table. This plugin is re-initialised on every
    -- FileManager<->Reader transition, so that aliasing would leak across
    -- instances. Hand it a fresh copy instead.
    local seed = {}
    for k, v in pairs(Store.DEFAULTS) do
        seed[k] = v
    end
    self.data = self.obj:readSetting("config", seed)
    self.library = self.obj:readSetting("library", {})
    for k, v in pairs(Store.DEFAULTS) do
        if self.data[k] == nil then
            self.data[k] = v
        end
    end
    return self
end

function Store:get(key)
    return self.data and self.data[key]
end

function Store:set(key, value)
    self.data[key] = value
    self.dirty = true
end

function Store:isPaired()
    local token = self:get("access_token")
    return type(token) == "string" and token ~= ""
end

--- Clears every credential. Used when the server answers 401: a token that has
--- been revoked server-side is not going to start working again, and keeping it
--- would make every later sync fail the same way with no path to recovery.
function Store:clearCredentials()
    self:set("access_token", nil)
    self:set("device_id", nil)
    self:set("device_name", nil)
    self:set("kosync_username", nil)
    self:set("kosync_key", nil)
    self.library = {}
    self.obj:saveSetting("library", self.library)
    self:flush()
end

--- The recorded local state of one server book, or nil if we have never had it.
function Store:getBook(id)
    return self.library[id]
end

function Store:setBook(id, entry)
    self.library[id] = entry
    self.dirty = true
end

function Store:removeBook(id)
    self.library[id] = nil
    self.dirty = true
end

function Store:eachBook()
    return pairs(self.library)
end

function Store:flush()
    if not self.obj then
        return
    end
    self.obj:saveSetting("config", self.data)
    self.obj:saveSetting("library", self.library)
    self.obj:flush()
    self.dirty = nil
end

return Store
