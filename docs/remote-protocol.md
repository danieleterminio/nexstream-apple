# NexStream remote and "Riproduci su…" protocol, version 2

Every NexStream app that runs on a TV (Android TV, Fire TV, Apple TV) is a *host*; every phone or tablet app is a
*client*. The same wire format on every platform, so any phone drives any TV.

Transport (unchanged from version 1): plain HTTP/1.1 on the home network, `Connection: close`, JSON bodies, ports
8790–8792 (the first free one), Bonjour / NSD service `_nexremote._tcp`, service name `NexStream · <device name>`.
Every call after pairing carries `X-Token: <token>`. A host answers 403 to callers that are not on a private address
and 401 `{"ok":false,"error":"Da abbinare"}` to an unknown token.

## Version 1 calls (keep them exactly as they are)

| call | body | answer |
|---|---|---|
| `POST /hello` | `{}` | `{"app":"nexstream","name":"…","paired":bool,"volume":bool}` |
| `POST /pair/start` | `{"name":"<phone name>"}` | `{"ok":true}`; the TV shows a 4-digit PIN for 2 minutes |
| `POST /pair` | `{"pin":"1234"}` | `{"ok":true,"token":"…","name":"…"}` or 401 / 410 |
| `POST /key` | `{"k": up|down|left|right|ok|back|menu|playpause|chup|chdown}` | `{"ok":true}` |
| `POST /home` | `{}` | `{"ok":true}` |
| `POST /search` | `{"q":"text"}` | `{"ok":true}` |
| `POST /vol` | `{"d": up|down|mute}` | `{"ok":true}` (only where `volume` is true) |
| `POST /tune` | `{"id":"<streamId>"}` or `{"num":101}` | `{"ok":true}` |
| `POST /channels` | `{}` | JSON array `[{"id","num","name","cat","logo","now","start","stop"}]` |

## Version 2 additions

`/hello` also returns `"v": 2` and `"platform": "androidtv" | "firetv" | "tvos"`. A client treats a missing `v` as 1 and
hides what version 1 cannot do.

### `POST /play` — "Riproduci su…"

Starts something on the TV, from the point the phone was at.

```json
{ "kind": "live", "id": "<streamId>" }
{ "kind": "vod", "media": "movie", "tmdb": 603, "season": 0, "episode": 0, "pos": 754000, "profile": "<profile uuid>" }
```
`pos` = milliseconds to start from (0 = from the beginning). `profile` = the uuid of the profile in use on the phone
(see the sync protocol); the host switches to that profile if it has it and it has no PIN, otherwise stays on its
current one. A host with no profile selected and no usable one answers `{"ok":false,"error":"Scegli un profilo sulla TV"}`.
Answer `{"ok":true}` as soon as the request is accepted (the film then resolves its source on the TV).

### `POST /state` — what the TV is doing

```json
{ "ok": true, "playing": true, "kind": "vod", "title": "Matrix", "sub": "1999", "art": "https://image.tmdb.org/…",
  "pos": 760000, "dur": 8160000, "paused": false, "id": "", "media": "movie", "tmdb": 603, "season": 0, "episode": 0 }
```
`"playing": false` with nothing else when the TV is not in a player. For live: `kind: "live"`, `id` = streamId,
`title` = programme, `sub` = channel name, `pos`/`dur` = how far the programme is (0 when unknown). The client polls
it every 2 seconds while the remote screen is open.

### `POST /seek`

`{"pos": 900000}` (absolute, milliseconds) or `{"by": -10000}` (relative). On demand only. `{"ok":true}`.

### `POST /stop`

Closes the player on the TV. `{"ok":true}`.

## Client behaviour

- **"Riproduci su…" button** in the phone player (live and on demand): lists paired TVs first, then TVs found on the
  network. Choosing one sends `/play` with the current position, closes the phone player and opens the remote screen
  on that TV. An unpaired TV goes through pairing first, then the play is sent.
- **Remote screen**, the same layout on iPhone and Android: on top what the TV is playing (artwork, title, a
  progress bar that seeks on demand, play/pause, −10 / +10), then the directional pad with OK in the middle, then
  Back / Home / Menu, then volume (when available) and channel up/down, then "Canali" (the TV's channel list, tap to
  tune) and "Cerca sulla TV" (the phone keyboard). A "Riprendi qui" button stops the TV and continues on the phone
  from the TV's position.
