--[[
Sleep-screen wallpaper sync.

Mirrors the wallpapers attached to this device into KOReader's screensaver
folder, then points the screensaver at it.

Format is not a preference here. KOReader decides whether a file is an image
with `DocumentRegistry:isImageFile`, whose extension table is
`gif jpeg jpg png svg tif tiff webp` — no `bmp`. A BMP dropped in this folder is
not an error, it is invisible. That is what rules out the 2-bit BMP the X4 uses.

`kindle-pw5` is served as full-colour JPEG, and the decode path is why that is
not a compromise. `renderimage.lua` sniffs the header and sends `\xff\xd8`
straight to libjpeg-turbo, never to MuPDF, having first set
`Pic.color = Device:hasColorScreen()`. On a greyscale panel that is false, so
`ffi/jpeg.lua` allocates a `TYPE_BB8` blitbuffer and asks turbojpeg for
`TJPF_GRAY` output — the colour is dropped inside the decoder, in the same pass
that decompresses, writing directly into the final greyscale buffer. No RGB
intermediate is ever allocated and there is no conversion at blit time. The same
file on a colour Kindle decodes to `TYPE_BBRGB24` instead, so one upload serves
both panels and the device decides, which is exactly the decision a browser
should not have been making on its behalf.

Three properties of the folder that shape this file:

  * the scan is NOT recursive, so everything lives flat in one directory
  * `screensaver_max_files` (default 256) counts every file encountered, not
    just images, so leftover junk eats the budget
  * basenames starting with `._` are skipped

The full manifest is fetched every time, never a `since` delta. Detaching a
wallpaper deletes a link row outright and leaves nothing for a delta to report,
so a client that only ever asked for deltas would keep an unassigned wallpaper
forever.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Wallpaper = {}

local PREFIX = "xtr_"

-- One extension per server format. `png8` is legacy: it shipped for a few hours
-- and nothing produces it now, so it is a value that may be encountered and
-- displayed, never one to expect.
local EXT = {
    jpeg = ".jpg",
    png8 = ".png",
}
local DEFAULT_EXT = ".jpg"

--- Ids are turned into filenames, so they are checked before a path is built
--- from one. A hostile or buggy server must not be able to steer a write with a
--- `/` or a `..`.
local function safeId(id)
    return type(id) == "string" and id ~= "" and id:match("^[A-Za-z0-9_%-]+$") ~= nil
end

local function extFor(format)
    return EXT[format] or DEFAULT_EXT
end

local function fileFor(dir, id, format)
    return dir .. "/" .. PREFIX .. id .. extFor(format)
end

--- True only for names this plugin itself would have produced.
-- The screensaver folder is shared: the user has always been able to drop their
-- own pictures in it. Anything that is not one of our names is invisible to the
-- reconciler and is never a deletion candidate.
--
-- Both extensions are recognised so that a wallpaper whose server format changed
-- has its stale file cleaned up rather than left behind as a second, older copy
-- of the same picture in a folder the screensaver picks from at random.
local function isOurs(name)
    if name:sub(1, #PREFIX) ~= PREFIX then
        return false
    end
    for _fmt, ext in pairs(EXT) do
        if name:sub(-#ext) == ext then
            return true, name:sub(#PREFIX + 1, -(#ext + 1))
        end
    end
    return false
end

--- Points KOReader's screensaver at the synced folder.
-- Without this the device shows the default "Sleeping" text: `screensaver_type`
-- defaults to "disable", which is why a fresh install shows no image at all.
function Wallpaper.configureScreensaver(store)
    local dir = store:get("wallpaper_dir")
    G_reader_settings:saveSetting("screensaver_type", "random_image")
    G_reader_settings:saveSetting("screensaver_dir", dir)
    -- The scan is O(n) per wake and counts non-images too; the server caps what
    -- it hands out well below this anyway.
    G_reader_settings:saveSetting("screensaver_max_files", 64)
    -- Images are rendered at exactly the panel's geometry server-side, so any
    -- scaling here would only soften them.
    G_reader_settings:makeFalse("screensaver_stretch_images")
    G_reader_settings:makeFalse("screensaver_rotate_auto_for_best_fit")
    G_reader_settings:makeFalse("screensaver_show_message")
    return dir
end

--- Runs a full wallpaper sync. Must be called inside a Trapper:wrap.
function Wallpaper.sync(api, store, report)
    local dir = store:get("wallpaper_dir")
    local Library = require("library")
    if not Library.ensureDir(dir) then
        return false, T(_("Cannot create %1"), dir)
    end

    report(_("Fetching wallpapers…"))
    local entries, code = api:fetchManifest("/wallpapers/manifest", "limit=50")
    if not entries then
        return false, T(_("Wallpaper manifest failed (%1)"), tostring(code))
    end

    local wanted = {}
    for _idx, e in ipairs(entries) do
        if e.deleted ~= true and safeId(e.id) then
            -- The stream is already filtered server-side; a line for another
            -- panel means a server bug, and drawing it would produce a
            -- stretched image nobody would trace back to here.
            if e.deviceKind and e.deviceKind ~= store.DEVICE_KIND then
                logger.warn("xtreader: manifest offered", e.deviceKind,
                            "to a", store.DEVICE_KIND, "device; skipped")
            else
                wanted[e.id] = e
            end
        end
    end

    -- Reconcile, then delete, then download.
    --
    -- An empty manifest is never treated as an instruction to clear the folder,
    -- the same rule the CrossPoint client follows. A trailer-only 200 is what
    -- both "nothing is attached" and "the set failed to load" look like from
    -- here, and only one of those readings is recoverable.
    local empty_manifest = next(wanted) == nil
    local removed, added, failed = 0, 0, 0
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local ours, id = isOurs(name)
            if ours then
                local entry = wanted[id]
                -- Delete when the id is gone, and also when the id survives but
                -- now arrives in a different format: the old file is a second
                -- copy of the same picture, and the screensaver picks from this
                -- folder at random, so leaving it would show a stale version.
                local stale_format = entry ~= nil
                    and name:sub(-#extFor(entry.format)) ~= extFor(entry.format)
                if (entry == nil and not empty_manifest) or stale_format then
                    os.remove(dir .. "/" .. name)
                    removed = removed + 1
                end
            end
            -- A stale `.part` from an interrupted run is ours too.
            if name:sub(1, #PREFIX) == PREFIX and name:sub(-5) == ".part" then
                os.remove(dir .. "/" .. name)
            end
        end
    end

    local pending = {}
    for id, entry in pairs(wanted) do
        local target = fileFor(dir, id, entry.format)
        local attr = lfs.attributes(target)
        if not attr or (entry.sizeBytes and attr.size ~= entry.sizeBytes) then
            pending[#pending + 1] = { id = id, entry = entry, target = target }
        end
    end

    for i, job in ipairs(pending) do
        if report(T(_("Wallpaper %1 of %2…"), i, #pending)) == false then
            break
        end
        -- Size IS gated here, unlike books: a wallpaper's bytes are immutable
        -- and identified by their id, so a mismatch means a truncated or wrong
        -- body, and the sleep screen draws whatever is in this directory
        -- without a second opinion.
        local ok = api:downloadTo("/wallpapers/" .. job.id .. "/file",
                                  job.target, job.entry.sizeBytes)
        if ok then
            added = added + 1
        else
            failed = failed + 1
        end
    end

    Wallpaper.configureScreensaver(store)
    store:set("last_wallpaper_sync", os.time())
    store:flush()

    return true, T(_("Wallpapers: %1 new, %2 removed, %3 failed."), added, removed, failed)
end

return Wallpaper
