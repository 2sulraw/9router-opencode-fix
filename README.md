# 9Router "Free usage exceeded" Fix "OutDated"

Patches 9Router's compiled opencode free executor so anonymous free requests carry
the client identity headers the real opencode CLI sends. Without them, requests land
in a shared anonymous bucket and fail with **"Free usage exceeded"** after a couple
of calls.

## Why this happens

9Router forwards your chat to opencode.ai/zen. The real opencode CLI identifies every
request with:

| Header | Value |
|---|---|
| `x-opencode-session` | `ses_<random>` — stable per app run |
| `x-opencode-project` | `p_<random>` — stable per project |
| `x-opencode-request` | `ses_<id>:<timestamp>:<random>` — unique per call |
| `User-Agent` | `opencode/1.17.0` |

9Router's compiled executor sends **none of these** (only `Authorization: Bearer public`),
so zen lumps all anonymous traffic into one sessionless bucket that throttles after a
couple of calls → "Free usage exceeded".

## What the fix does

The scripts find the opencode executor chunk (e.g. `318.js` under
`app\.next-cli-build\server\chunks\`), then rewrite its `buildHeaders()` to synthesize
the real-client identity:

```js
// injected, stable per app run
this._sid = "ses_" + Math.random()...   // session
this._pid = "p_"  + Math.random()...   // project
// per request
"x-opencode-request": this._sid + ":" + Date.now() + ":" + Math.random()...
"User-Agent": "opencode/1.17.0"
```

Resulting headers look exactly like the real CLI's:

```
x-opencode-session: ses_k73b27pdbv7x9ur1ry6rjfw96ctvbvirrxbk87npj4cb
x-opencode-project: p_cnd42xu0s91tz6l1qnr8p
x-opencode-request: ses_k73b27pdbv7x9ur1ry6rjfw96ctvbvirrxbk87npj4cb:1786654211941:01h20qh79fb9
User-Agent: opencode/1.17.0
```

Session and project are **stable** across calls (cached on the executor instance), the
request id changes every call — exactly the identity zen's free quota keys on.

## Usage

**Windows** — double-click `fix-9router.bat`, or run in a terminal:

```
powershell -ExecutionPolicy Bypass -File fix-9router.ps1
```

**Linux / macOS / Windows (Git Bash)** — run `fix-9router.sh` (needs `node`, `grep`, `bash`):

```
chmod +x fix-9router.sh
./fix-9router.sh
```

Then **restart 9Router** (the chunk is loaded at startup).

### Docker container

If you run 9Router in a container (`decolua/9router:latest`), the npm scripts
above won't find your install — the image serves a pre-compiled Next standalone
bundle, not the npm layout. Use **`fix-9router-docker.sh`** instead, which
patches the compiled executor chunk directly inside the running container:

```sh
chmod +x fix-9router-docker.sh
./fix-9router-docker.sh          # patches container named "9router"
./fix-9router-docker.sh myname    # or pass a different container name/id
```

It backs up the chunk to `318.js.bak`, aborts if the buildHeaders signature
doesn't match (version changed), validates syntax with `node --check`, and
restarts the container when done.

> The container filesystem is ephemeral — `docker compose down` / `docker compose up`
> (recreate) wipes the patch. Re-run the script after each recreate, or bind-mount
> the patched chunk (e.g. `-v ./318.js:/app/.next/server/chunks/318.js:ro`) for
> persistence.

### On another machine / fresh install

Requirements:

- **Windows**: PowerShell 5.1+ (built in) or bash for .sh — or **Linux/macOS**: bash + `grep`
- **Node.js** — used for the patch replacement and `node --check` syntax validation;
  the Windows script warns and still applies the patch if node is absent, but the
  Linux script requires it
- **9Router installed via npm** (`npm i -g 9router`) so the scripts can locate it
  through `npm root -g`

> If 9Router is installed somewhere unusual (e.g. under a local `node_modules` or a
> different npm root), the scripts' fallback paths may miss it — check the paths in
> `Get-9RouterInstall` (Windows) or `get_9router_install` (Linux) and add the actual
> location.

## Safety

- Backs up the chunk to for e.g. `318.js.bak` before touching it
- Patches only the exact `buildHeaders()` signature — if the pattern isn't found
  (version changed), it aborts with **no changes**
- Runs `node --check` after writing; on failure it **restores the backup**
- Idempotent: if `x-opencode-session` is already present, it exits without touching

## Files

| File | Purpose |
|---|---|
| `fix-9router.ps1` | Patch logic (Windows) |
| `fix-9router.bat` | One-click launcher for the .ps1 (Windows) |
| `fix-9router.sh` | Same fix as a bash script (Linux / macOS / Windows Git Bash) |
| `fix-9router-docker.sh` | Patches the compiled executor chunk inside a running Docker container |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: 9Router install not found` | Install via `npm i -g 9router`, or edit `Get-9RouterInstall` (Windows) / `get_9router_install` (Linux) paths in the scripts |
| `ERROR: opencode executor chunk not found` | The marker `Authorization:"Bearer public"` wasn't found in any chunk under `app\.next-cli-build\server\chunks` — check the folder exists and the chunk content marker is still there |
| `ERROR: buildHeaders signature not found` | 9Router version changed the executor code — send the new executor chunk (`app\.next-cli-build\server\chunks\*.js` containing `Authorization:"Bearer public"`) for a pattern refresh |
| Still "Free usage exceeded" after patching | Restart 9Router; also try restarting the tray app |

## Note on updates

`npm i -g 9router@latest` **overwrites the patched chunk** — re-run the relevant script after
any 9Router update.
