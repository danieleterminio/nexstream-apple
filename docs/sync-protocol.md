# NexStream sync protocol, version 1

One small store per IPTV line. The line's username and password are the account: whoever signs in with them on any
device sees the same profiles, lists, positions and tastes. The server never sees names, titles or credentials: record
names and contents are encrypted on the device. Both apps (Swift and Kotlin) must implement this byte for byte.

## Keys

```
U   = username, trimmed, lower-cased (UTF-8)
P   = password, trimmed (UTF-8)
AID = hex( SHA-256( "nexstream/sync/1/id\n"  + U + "\n" + P ) )      64 hex chars, sent to the server
K   =      SHA-256( "nexstream/sync/1/key\n" + U + "\n" + P )        32 bytes, never leaves the device
```

Record name on the server: `kid = hex( HMAC-SHA256(K, plainKey) )` truncated to the first 40 hex characters.
Record content on the server: `d = base64( nonce(12 random bytes) || AES-256-GCM(K, nonce, plaintext) || tag(16) )`
(standard base64 with padding; this is CryptoKit's `SealedBox.combined` and Java's `nonce + doFinal()`).
Plaintext is UTF-8 JSON `{"k": "<plainKey>", "v": { ...fields } }`.

## Endpoint

`POST https://<worker>/v1/sync`, headers `Content-Type: application/json`, `X-Account: <AID>`.

Request:
```json
{ "since": 0, "dev": "iPhone di Daniele", "changes": [ { "k": "<kid>", "t": 1763000000000, "d": "<base64>" }, { "k": "<kid>", "t": 1763000001000, "d": null } ] }
```
`since` = the `seq` returned by the previous call (0 the first time). `t` = milliseconds since 1970 when the record was
changed on the device. `d: null` deletes the record (a tombstone is kept).

The server applies each change only if it has no record with that `k` or its stored `t` is lower or equal (last write
wins), giving it the next sequence number of the account. Response:
```json
{ "seq": 42, "changes": [ { "k": "<kid>", "t": 1763000000000, "d": "<base64>|null" } ] }
```
`changes` = every record whose sequence number is greater than `since`, except the ones this same request wrote.
At most 1000 per answer, oldest first; when `"more": true` is present the client calls again with `since` = the
returned `seq`. Errors: HTTP 400 (bad request), 413 (too big: body over 1 MB, more than 1000 changes, a `d` over
12 000 characters), 429 (too many requests), 507 (account over 30 000 records).

## Records

`<p>` is the profile's uuid (lower-case UUID v4, created with the profile, kept in the local `meta` table under
`puid.<localProfileId>`). Booleans are JSON booleans, times are milliseconds, missing optional fields are omitted.

| plainKey | fields (`v`) | local table |
|---|---|---|
| `profile/<p>` | `name` string, `color` int, `icon` int, `kids` bool, `maturity` int, `pin` string (omitted = none), `created` ms | profiles |
| `fav/<p>/<streamId>` | `at` ms | favorites |
| `recent/<p>/<streamId>` | `at` ms | recents |
| `usage/<p>/<key>` | `s` number (seconds), `at` ms | usage |
| `list/<p>/<media>/<tmdbId>` | `at` ms | list_item |
| `prog/<p>/<media>/<tmdbId>/<season>/<episode>` | `pos` ms, `dur` ms, `done` bool, `at` ms, `dev` string (device that wrote it) | progress |
| `ev/<p>/<at>/<media>/<tmdbId>/<kind>` | `w` number (weight) | watch_event (only the newest 1500 per profile are sent) |
| `rem/<p>/<streamId>` | `at` ms, `title` string, `sub` string, `created` ms | reminders |
| `teams/<p>` | `list` array of `{ "n": name, "c": crestUrl }` | meta `teams.<localProfileId>` |
| `set/<p>` | `audio` string, `text` string, `autoplay` bool, `credits` bool, `swHours` int, `swEps` int, `speed` number | per-profile settings (not the video quality) |

`media` is `movie` or `tv`; films use season 0 episode 0. `streamId` is the line's own channel id (the same on every
device of that line).

## Client algorithm

The client keeps, per account, `seq` and a snapshot map `plainKey -> hash of the JSON of v` of what it last knew to be in
sync, plus a map `plainKey -> t` of the newest time it has seen for each record.

1. **First contact** (`seq == 0` for this account): call with `since: 0` and no changes, following `more`.
   - The answer holds at least one live `profile/…` record: **the online data wins**. Local profiles and everything that
     belongs to them (favourites, recents, usage, list, progress, events, reminders, teams, settings) are deleted, then
     the downloaded records are applied.
   - Otherwise the local data becomes the account's data: every local record is uploaded.
2. **Every later round**: build the current local records, compare with the snapshot. New or changed → a change with
   `t = now`; in the snapshot but gone → a delete with `t = now`. Send them with `since = seq`.
3. Apply each returned change if its `t` is greater than the `t` known for that key (a delete removes the local row),
   then update snapshot, times and `seq`. `prog` records: also keep the higher position rule out of it, the newest `t`
   simply wins.
4. When to run: at sign-in, when the app comes to the foreground, 2 seconds after a local change (debounced), every
   60 seconds while the app is in use, and when a player closes. Only with the VPN up, like every other request.

Removing a profile deletes all its records. Signing out of the line clears `seq` and the snapshot (the local data stays
until another line signs in).

"Resume from another device": a `prog` record applied from the server whose `dev` differs from this device's name and
whose `at` is within the last 3 days feeds the row "Stavi guardando su <dev>".
