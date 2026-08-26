# xtreader.koplugin

[![Licence: AGPL-3.0](https://img.shields.io/badge/licence-AGPL--3.0-blue)](./LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-v2026.07.1-6b7280)](https://github.com/koreader/koreader)
[![Device API](https://img.shields.io/badge/device%20API-docs-f97316)](https://xtreader.com/docs)
[![Ko-fi](https://img.shields.io/badge/ko--fi-support-f97316)](https://ko-fi.com/hhoangg)

One account across every reader you own. This is the KOReader client for
[xtreader](https://xtreader.com): it syncs books, reading position, reading
statistics and sleep-screen wallpapers, so a Kindle running KOReader and an
Xteink X4 running the xtreader firmware share one library and one place in it.

Five sync paths. Three of them needed no server change at all -- reading
position, books and wallpapers all ride routes that already existed:

| What | How |
|---|---|
| reading position | KOReader's own **kosync**, pointed at this server — wire-compatible by design, so nothing here reimplements it |
| books | `GET /library/manifest`, reconciled against what is on disk |
| wallpapers | `GET /wallpapers/manifest`, into the screensaver folder |
| reading statistics | `POST /stats/pages`, read out of KOReader's own `statistics.sqlite3` |
| telemetry | `POST /devices/heartbeat` — battery, free space, last sync result |

The device API is public: <https://xtreader.com/docs>. Nothing in this plugin
reinterprets the contract, so it doubles as a worked reference client if you are
writing your own.

## Install

Two directories, nothing to build:

```
xtreader.koplugin/                      ->  <koreader>/plugins/
patches/2-xtreader-kosync-sync-date.lua ->  <koreader>/patches/
```

On a jailbroken Kindle `<koreader>` is `/mnt/us/koreader`. Restart KOReader —
plugins load only at startup. Everything then lives under **Menu → Tools →
xtreader**.

## Pairing

**You never type a password into the reader.** Pairing is the OAuth 2.0 Device
Authorization Grant (RFC 8628): the reader asks the server for a code, shows a
QR with the short code printed under it, and polls until you approve it in a
browser.

Two codes exist, and conflating them is the mistake worth avoiding. `userCode`
is the one on screen and therefore the one that can be photographed — it only
*authorises*. `deviceCode` is what actually redeems the token, is never drawn
into a widget, and is dropped the moment the grant resolves.

The short code's alphabet is eight consonants. No vowels, so a code can never
accidentally spell a word, and none of the characters that get misread off
low-contrast e-ink.

Dismissing the QR does **not** cancel pairing. E-ink keeps its last image after
power is lost, so a code on screen can outlive the session it belongs to; the
server's clock is the only authority on expiry, and the poll keeps running.

## What each file is for

- **`api.lua`** — HTTP. Deliberately thin. Two transport facts it depends on,
  both read out of KOReader's source rather than assumed: `socket.http` handles
  `https://` on its own through LuaSec, so there is no separate `ssl.https`
  call; and `http.request` returns a **number** when a response arrived and a
  **string** (`"timeout"`, `"wantread"`) when the socket failed — which is why
  every check is `code == 200` and never `code >= 200`.
- **`pairing.lua`** — the device grant, polled on UIManager's scheduler rather
  than in a Trapper coroutine. A grant lives five minutes at a 15-second
  interval, so a blocking sleep would freeze the UI for the whole pairing.
- **`qrpair.lua`** — the pairing screen. KOReader ships `QRMessage`, but it
  draws the code and nothing else; the contract asks for the short code as
  readable text underneath, as a fallback for a screen too dim to scan.
- **`library.lua`** — book sync, in three passes whose **order is load-bearing**:
  renames first (`id` is stable across moves, so a book that only changed folder
  is renamed on disk instead of re-downloaded), then deletions (so a full device
  gets its room back before anything is fetched), then downloads. The `.sdr`
  sidecar moves with the book — leaving it behind on a rename is exactly the
  progress-loss bug that stable ids exist to prevent.
- **`store.lua`** — credentials and the local library index. The index is what
  makes `id` useful: it remembers which local file a server id produced.
- **`wallpaper.lua`** — sleep-screen sync. Format is not a preference here:
  KOReader decides what is an image with `DocumentRegistry:isImageFile`, whose
  table has no `bmp`. A BMP in this folder is not an error, it is invisible.
- **`insights.lua`** — reading statistics. See below.
- **`heartbeat.lua`** — telemetry. Every field but `firmwareVersion` is
  optional, and an omitted field leaves the stored value alone rather than
  clearing it, so anything undeterminable is left out — never guessed, never
  sent as zero.

## Reading statistics, and the watermark

`statistics.sqlite3` is KOReader's own database and belongs to the statistics
plugin. This opens it **read-only** and never writes to it.

Rows come from `page_stat_data`, the real table — never the `page_stat` **view**.
That view rescales historical page numbers against the book's *current* page
count, fanning one stored row into several and integer-dividing `duration`
between them. Ingesting the view would store a lossy projection that cannot be
undone, so `total_pages` is sent honestly per row and the server reimplements the
rescaling.

Identity is `book.md5` — `util.partialMD5` of the file content — not `book.id`,
which is a local autoincrement that means nothing on another device. It is the
same string kosync sends in binary mode, so statistics and progress land on one
identity server-side with no bridging.

**The watermark is this device's own high-water mark, never the server's
`maxStartTime`.** That distinction is the whole correctness argument, and it is
not theoretical:

> Leave the Kindle offline for a month while another reader syncs daily. Come
> back, send the oldest 2000 rows, and the server answers with a `maxStartTime`
> of *today* — because of the **other** device. Adopt it as this device's cursor
> and every remaining row from that month is skipped. Permanently, and silently.

The account-wide figure cannot help in the other direction either, because
`page_stat_data` is local: another reader's rows were never in this table to be
skipped. So it is a pure loss, and the cursor advances only by what this device
actually sent and the server actually confirmed. Re-sending costs nothing — the
server dedups on `(book, page, start_time)` and reports duplicates back as
`ignored`. Skipping costs everything.

## The sync-date patch

KOReader already asks before moving you: *"Sync to latest location 42% from
device 'X'?"*. What it does not say is **when** that position was recorded, and
that is the one fact you need to answer the question. 42% from a reader you put
down an hour ago and 42% from one you last touched in March are the same
sentence and very different decisions.

The server already sends it — kosync reads `timestamp` to decide direction and
then drops it before drawing the dialog.

The patch does **not** replace `KOSync:getProgress`, which would mean copying
~80 lines of upstream logic and owning them forever. It patches two narrow
seams and copies no logic at all: it wraps `KOSyncClient.get_progress` to note
the timestamp, and wraps `ConfirmBox.new` to append one line while that flag is
set. Upstream can rewrite `getProgress` entirely and this keeps working.

Every step is guarded. If the plugin is missing or anything raises, the patch
does nothing and progress syncs exactly as before — a missing date line is
cosmetic, a broken `ConfirmBox` would break every yes/no dialog in the reader.

## Known limits

- **Verified against KOReader v2026.07.1.** The patch and several comments cite
  kosync and NetworkMgr internals by line number; another release may move
  behaviour, not just line numbers.
- **Tested on a Kindle Paperwhite 5.** Nothing here is Kindle-specific by
  design, but nothing else has run it.
- **One Kindle radio caveat.** Without `liblipclua`, KOReader's Kindle backend
  turns the radio on and calls the completion callback immediately rather than
  waiting for an address, so the first request after a cold radio can fail. That
  is a retry, not an error worth a dialog.
- **Filenames are generic.** `api.lua`, `store.lua` and `library.lua` are not
  namespaced. KOReader's plugin loader puts every plugin directory on
  `package.path`, so a name this common is in principle reachable from another
  plugin. Nothing has collided in practice; it is on the list.

## Related

- **[kindleui.koplugin](https://github.com/hhoangg/kindleui.koplugin)** — a
  Kindle-shaped reading UI for KOReader. Independent of this, but it grows a
  Sync button and an account row when this plugin is installed alongside it.

## Credits

Nothing third-party is vendored here — every `require` resolves either to one of
this plugin's own files or to a module KOReader ships.

- **KOReader** — [koreader/koreader](https://github.com/koreader/koreader),
  AGPL-3.0. No code is copied; this is a plugin that calls its widgets, events
  and network manager at runtime, and reuses `QRWidget`, `Trapper` and
  `DocumentRegistry` rather than reimplementing them.
- **kosync** (`kosync.koplugin`, in-tree in KOReader), AGPL-3.0. Reading
  position is *its* job, not this plugin's — pairing configures it and gets out
  of the way. The userpatch wraps two of its functions at runtime and copies
  none of them.

## Support

If this saved you some work, [ko-fi.com/hhoangg](https://ko-fi.com/hhoangg).
It is a side project run by one person; the hosted instance is free and has no
plans to charge.

## Licence

**AGPL-3.0** — see [LICENSE](./LICENSE).

KOReader is AGPL-3.0 and a plugin is useless without it, so this carries the
same licence.
