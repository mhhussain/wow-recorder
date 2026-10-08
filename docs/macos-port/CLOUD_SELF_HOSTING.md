# Self-hosting the cloud ("Pro") backend

How the app's cloud features work, what a compatible backend must implement, and how to point the app at it. Written from the client code in this repository (`src/storage/CloudClient.ts` and its callers); upstream's server code is not public, so anything about the server below is a design for you to build, not a description of upstream's.

## 1. What "Pro" cloud gives you in the app

The client has no Pro or paid check of its own. Every cloud feature switches on when the server answers the calls below the right way:

| Feature | Where in the app | Needs |
| --- | --- | --- |
| Automatic upload after each recording (per category, minimum raid difficulty, minimum key level, rate limit) | Settings > Cloud | write permission |
| Cloud videos listed next to disk videos, streamed without downloading | Every category page | read |
| Multiple points of view (your guildmates' recordings of the same pull, side by side) | Video player | videos sharing a `uniqueHash` |
| Download a cloud video to disk, bulk upload or download | Category page buttons | read / write |
| Protect from deletion, tag, delete | Video row buttons | write / del |
| Shareable link copied to the clipboard | Video row menu | a link id, plus a web page if you want links to open in a browser |
| Per-video chat | Video player | chat endpoints |
| Storage usage and limit, automatic cleanup of old videos | Status card, after every upload | usage, limit, housekeeper |
| Live updates when a guildmate uploads, deletes or tags | Everywhere | the WebSocket |

Concepts: a **guild** is a shared video library with a storage limit. A **user** logs in with a name and password and has an **affiliation** (read, write, delete, admin) with one or more guilds. In Settings > Cloud the user enters account name, password and guild name.

## 2. What you need to build

```
 Warcraft Recorder (Electron main process)
   |  HTTPS JSON API, Basic auth        https://cloud.example.com/api/...
   |  WebSocket, Basic auth             wss://cloud.example.com/poll?guild=...
   v
 API service  ----  database (users, guilds, affiliations, videos, chat, links)
   |
   |  issues presigned URLs
   v
 S3-compatible object storage  <---- the app uploads (PUT) and streams (GET) directly
```

1. **API service**: about 20 HTTP endpoints plus one WebSocket endpoint (section 5 and 6). Any language. It authenticates every request, checks guild permissions, stores metadata, issues presigned storage URLs, and broadcasts changes.
2. **Object storage**: anything S3-compatible with presigned URLs and multipart uploads: MinIO or Garage on your own hardware, or Cloudflare R2, AWS S3, Backblaze B2. Video bytes never pass through the API.
3. **Database**: Postgres or SQLite is plenty (schema sketch in section 7).
4. **TLS**: required in practice (section 8). A reverse proxy such as Caddy or Traefik in front of the API and the storage endpoint handles it.
5. **Optional web page** for shareable links (`/link/<id>`).

A small, proven layout on one machine: Docker Compose with Caddy (TLS), the API service, Postgres, and MinIO, with the storage served on its own hostname (for example `https://s3.example.com`).

## 3. Connecting the app

The server addresses are constants in `src/storage/CloudClient.ts`:

```ts
private static api = 'https://api.warcraftrecorder.com/api';
private static poll = 'wss://api.warcraftrecorder.com/poll';
private static website = 'https://warcraftrecorder.com';
```

Change them to your hosts (or ask me to make them a setting) and rebuild:

```ts
private static api = 'https://cloud.example.com/api';
private static poll = 'wss://cloud.example.com/poll';
private static website = 'https://cloud.example.com';
```

Then in the app: Settings > Cloud, enable Cloud Storage, enter the account name, password and guild name you created on your server, and enable upload if you want it. The status card shows "Connected" once the sequence in section 4 succeeds.

Two things to know:

- `GET /keystone/timer/<mapId>` is called at the start of **every** Retail Mythic+ run, even with cloud storage off, to fetch up-to-date key timers. With the constants pointed at your server it goes there; if it fails, the app uses its built-in timers, so implementing it is optional.
- Passwords are stored in the app's config file in plain text (`~/Library/Application Support/WarcraftRecorder/config-v3.json`) and sent with every request as HTTP Basic auth. Use HTTPS and a password used nowhere else.

## 4. What the app does when it connects

On startup and whenever cloud settings change:

1. `GET /user/affiliations`. A 401 or error means bad credentials: status "not authenticated".
2. Find the affiliation whose `guildName` equals the configured guild. None: "not authorized". Upload enabled but `write` false: "not authorized".
3. `GET /guild/<guild>`. `migrated: true` shows a "guild migrated" error; always return `false`.
4. `GET /guild/<guild>/usage` and `GET /guild/<guild>/limit`.
5. Open the WebSocket `wss://<host>/poll?guild=<guild>` with the same `Authorization` header. When it opens, the app calls `GET /guild/<guild>/video` and refreshes usage and limit. It sends a WebSocket ping every 60 s and reconnects every 10 s if closed, refetching everything each time it reconnects.

Any 401 from an authenticated call makes the app redo this sequence, which effectively logs it out if the credentials stopped working.

## 5. HTTP API reference

Conventions:

- Base URL: the `api` constant, for example `https://cloud.example.com/api`. Paths below are relative to it.
- Auth: `Authorization: Basic base64(user:password)` on every call except the keystone timers. Unknown user or wrong password: 401.
- `<guild>` is the guild name, URL-encoded. Check the user's affiliation with it on every call (403 if missing or lacking the permission).
- Bodies are JSON. Any 2xx means success; the app ignores bodies it does not list below.

### Account and guild

| Method and path | Request | Response | Notes |
| --- | --- | --- | --- |
| `GET /user/affiliations` | | `[{ "id": 1, "userName": "me", "guildName": "My Guild", "read": true, "write": true, "del": true, "admin": true }]` | All seven fields required (validated with zod). Drives the guild dropdown. |
| `GET /guild/<guild>` | | `{ "guildName": "My Guild", "usageGB": 12.5, "limitGB": 500, "mtime": 1759700000000, "expiry": 4102444800000, "region": "home", "disabled": false, "migrated": false }` | All eight fields required. Only `migrated` changes app behaviour. |
| `GET /guild/<guild>/usage` | | `{ "bytes": 13421772800 }` | Total bytes of stored videos. |
| `GET /guild/<guild>/limit` | | `{ "bytes": 536870912000 }` | Shown as the storage bar; the housekeeper enforces it. |

### Videos

| Method and path | Request | Response | Notes |
| --- | --- | --- | --- |
| `GET /guild/<guild>/video` | | Array of video objects (below) | Full list; the app merges it with disk videos. |
| `POST /guild/<guild>/upload` | `{ "key": "2026-10-05 21-02-08 - Rainbowlight - Altar of Fangs +10 (+1).mp4", "bytes": 15728640 }` | `{ "signed": "<presigned PUT URL>" }` | Used for files under 16 MiB. Check write permission and quota here. |
| `POST /guild/<guild>/create-multipart-upload` | `{ "key": "...mp4", "total": 2147483648, "part": 16777216 }` | `{ "urls": ["<presigned UploadPart URL for part 1>", "..."] }` | Files of 16 MiB or more. One URL per part, `ceil(total / part)` of them, in order. Start an S3 multipart upload and remember its UploadId for this key. |
| `POST /guild/<guild>/complete-multipart-upload` | `{ "key": "...mp4", "etags": ["9b2c...", "..."] }` | 2xx | ETags in part order, without quotes. Complete the S3 upload with PartNumber = index + 1. |
| `POST /guild/<guild>/video` | Video metadata (below, without `signedVideoKey`) | 2xx | Sent after the file upload finishes. Store it, recompute usage, broadcast `vc:` and `gu:`. |
| `GET /guild/<guild>/video/<key>/size` | | `{ "bytes": 2147483648 }` | Before a download, for the progress bar. `<key>` is the URL-encoded file name. |
| `POST /guild/<guild>/bulk/delete` | `["videoName 1", "videoName 2"]` | 2xx | Delete objects and rows; broadcast `vd:` per video and `gu:`. Needs del. |
| `POST /guild/<guild>/bulk/protect` | `{ "videos": ["videoName"], "protect": true }` | 2xx | Protected videos are skipped by the housekeeper. Broadcast `vp:` or `vu:`. |
| `POST /guild/<guild>/bulk/tag` | `{ "videos": ["videoName"], "tag": "progression" }` | 2xx | Broadcast `vt:`. |
| `POST /guild/<guild>/housekeeper` | | Any JSON (logged) | Called after every upload. Delete the oldest unprotected videos until usage is under the limit, and anything you mark for deletion. |
| `POST /guild/<guild>/video/<videoName>/link` | | `{ "id": "a1b2c3" }` | The app copies `<website>/link/a1b2c3`. Serve that page however you like (for example a redirect to a fresh presigned URL). |

**Video object.** The app posts the recording's metadata (the same JSON it writes next to each video on disk, type `Metadata` in `src/main/types.ts`) plus four fields; you return it as posted, plus `signedVideoKey`:

| Field | Meaning |
| --- | --- |
| `videoName` | File name without `.mp4`; the identity used by delete, protect, tag and link. |
| `videoKey` | Object key in storage: the file name with `.mp4`. |
| `start` | Epoch milliseconds of the activity start. |
| `uniqueHash` | Identifies the same pull across players: same value on guildmates' uploads of one encounter puts them in the multiple-points-of-view player. |
| `signedVideoKey` | **Returned only.** A presigned GET URL for `videoKey`; the player streams from it. Must be `https://` (section 8). |
| everything else | `category`, `duration`, `result`, `flavour`, `zoneID`, `encounterName`, `difficulty`, `keystoneLevel`, `player`, `combatants`, `deaths`, `challengeModeTimeline`, `protected`, `tag`, and so on. Store as a JSON document; return unchanged (with `protected` and `tag` reflecting later changes). |

Upstream stores metadata in SQL columns, which is why the app renames `level` to `keystoneLevel` before upload. A JSON column avoids caring about field names.

### Chat

| Method and path | Request | Response | Notes |
| --- | --- | --- | --- |
| `POST /guild/<guild>/chat/<uniqueHash>/<start>` | | `{ "correlator": "c-123" }` | Get or create the chat thread for a pull (shared across points of view). |
| `POST /guild/<guild>/named-chat/<name>` | | `{ "correlator": "c-124" }` | Same, for clips and manual recordings. |
| `GET /guild/<guild>/chat/<correlator>` | | `[{ "id": 7, "correlator": "c-123", "userName": "me", "message": "nice", "timestamp": 1759700000000 }]` | All five fields required. |
| `POST /guild/<guild>/chat/<correlator>` | `{ "message": "nice" }` | 2xx | Store with the caller's user name; broadcast `vm:`. |
| `DELETE /guild/<guild>/chat/<id>` | | 2xx | Broadcast `vmd:`. |

### Keystone timers (optional, unauthenticated)

| Method and path | Response | Notes |
| --- | --- | --- |
| `GET /keystone/timer/<mapId>` | `{ "1": 1224, "2": 1632, "3": 2040 }` | Seconds. `"3"` is the time limit, `"2"` the +2 threshold, `"1"` the +3 threshold (the app reads them as `[3, 2, 1]`). On error the app falls back to its built-in table. |

## 6. WebSocket protocol

- Endpoint: the `poll` constant plus `?guild=<URL-encoded guild>`, with the same `Authorization` header. Reject unauthenticated or unaffiliated connections.
- The app sends protocol-level pings every 60 s; reply with pongs (most WebSocket libraries do this automatically). Do not close idle sockets sooner than about 5 minutes.
- Server to app only. Text frames of the form `key:value`; frames without a colon are ignored.

| Frame | Sent when | Value |
| --- | --- | --- |
| `vc:<json>` | A video was added | The full video object including `signedVideoKey` |
| `vd:<videoName>` | A video was deleted | Video name |
| `vp:<videoName>` / `vu:<videoName>` | Protected / unprotected | Video name |
| `vt:<URL-encoded videoName>:<tag>` | Tagged | Encoded name, colon, tag |
| `vm:<json>` | Chat message posted | A chat message object |
| `vmd:<id>` | Chat message deleted | Message id |
| `gu:<bytes>` | Usage changed | Integer |
| `gl:<bytes>` | Limit changed | Integer |

Broadcast to every socket subscribed to that guild, including the sender's (the app relies on these to update its own list).

## 7. Database sketch

```sql
CREATE TABLE users (
  id            SERIAL PRIMARY KEY,
  name          TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL          -- argon2 or bcrypt, never plain text
);

CREATE TABLE guilds (
  id          SERIAL PRIMARY KEY,
  name        TEXT UNIQUE NOT NULL,
  bucket      TEXT NOT NULL,           -- or a key prefix in one bucket
  limit_bytes BIGINT NOT NULL
);

CREATE TABLE affiliations (
  id       SERIAL PRIMARY KEY,
  user_id  INT REFERENCES users(id),
  guild_id INT REFERENCES guilds(id),
  can_read BOOLEAN, can_write BOOLEAN, can_del BOOLEAN, is_admin BOOLEAN,
  UNIQUE (user_id, guild_id)
);

CREATE TABLE videos (
  guild_id    INT REFERENCES guilds(id),
  video_name  TEXT NOT NULL,
  video_key   TEXT NOT NULL,
  size_bytes  BIGINT NOT NULL,          -- from storage after upload
  start_ms    BIGINT NOT NULL,
  unique_hash TEXT NOT NULL,
  protected   BOOLEAN NOT NULL DEFAULT FALSE,
  tag         TEXT,
  metadata    JSONB NOT NULL,           -- the posted object
  PRIMARY KEY (guild_id, video_name)
);

CREATE TABLE chats    (correlator TEXT PRIMARY KEY, guild_id INT, unique_key TEXT UNIQUE);
CREATE TABLE messages (id SERIAL PRIMARY KEY, correlator TEXT, user_name TEXT, message TEXT, timestamp_ms BIGINT);
CREATE TABLE links    (id TEXT PRIMARY KEY, guild_id INT, video_name TEXT, created_ms BIGINT);
```

Usage is `SUM(size_bytes)` per guild. Users, guilds and affiliations need no API from the app; create them with SQL or a small admin script.

## 8. Storage requirements and pitfalls

- **HTTPS for presigned GET URLs.** The player treats any source not starting with `https://` as a local file (`src/renderer/VideoPlayer.tsx`), so `http://` storage URLs will not play. Use TLS on the storage hostname, or ask me to relax that check if you only use the cloud on your LAN.
- **Range requests** must work on the GET URLs (seeking). S3-compatible stores support them.
- **Content type.** Uploads send `Content-Type: video/mp4` and `Content-Length`. Either include the content type when presigning or leave it out of the signature; a mismatch fails the upload with 403.
- **ETag.** UploadPart responses must include the `ETag` header (S3 does). The app is a Node process, not a browser, so CORS does not apply.
- **Part size** is fixed at 16 MiB by the client; S3 needs parts of at least 5 MiB except the last, which this satisfies.
- **URL lifetime.** The app fetches signed GET URLs when it connects and keeps them while it runs (it refetches on every WebSocket reconnect). Sign them for at least a day; sign PUT and part URLs for at least as long as a slow upload of a large file takes (an hour is safe with no rate limit set).
- **Quota at sign time.** Check `usage + bytes <= limit` (or let the housekeeper make room) in `upload` and `create-multipart-upload`; the client calls the housekeeper after each upload.
- **Key collisions.** Keys are file names; guildmates' files can collide only if they share a timestamp and suffix. Prefix keys with the user or guild to be safe; the app only needs `videoKey` and `signedVideoKey` to be consistent.

## 9. Minimal build order

1. Storage: MinIO (or similar) with TLS, one bucket per guild or one bucket with guild prefixes.
2. API skeleton with Basic auth, `/user/affiliations`, `/guild/<guild>`, `/usage`, `/limit`, and a WebSocket that accepts connections. Point the app at it: status should read "Connected".
3. `video` list (empty), `upload`, multipart create and complete, `POST video`, broadcasting `vc:`. Record something with upload enabled: it should appear as a cloud video and stream.
4. Delete, protect, tag, housekeeper, size (download), link.
5. Chat, keystone timers, a `/link/<id>` page.

Test the API without the app:

```bash
AUTH=$(printf 'me:secret' | base64)
curl -s -H "Authorization: Basic $AUTH" https://cloud.example.com/api/user/affiliations
curl -s -H "Authorization: Basic $AUTH" "https://cloud.example.com/api/guild/My%20Guild"
```

Logs: the app logs every cloud call with a `[CloudClient]` prefix in `~/Library/Logs/WarcraftRecorder/`, including HTTP status codes on failures.

## 10. Changes to the app when your server is ready

| Change | Required | Size |
| --- | --- | --- |
| Point `api`, `poll`, `website` in `CloudClient.ts` at your hosts, or make them settings | Yes | Small |
| Allow `http://` video URLs in the player | Only without TLS on storage | One line |
| Nothing else: the client has no Pro check, and the own-image overlay gate was removed (D-012) | | |
