#!/usr/bin/env bash
# fix-9router-docker.sh - Patch the compiled OpenCode Free executor inside a
# running 9Router Docker container.
#
# Unlike the sibling fix-9router.sh (which targets the npm-installed layout),
# this targets the pre-compiled Next standalone bundle that the official
# decolua/9router image actually serves from: /app/.next/server/chunks/318.js.
# The readable source under /app/open-sse/executors/ is NOT what the image runs.
#
# It injects the client-identity headers the real opencode CLI sends
# (x-opencode-session / x-opencode-project / x-opencode-request + User-Agent),
# which stops anonymous requests from landing in a shared bucket that fails
# with "Free usage exceeded" after a couple of calls.
#
# Safe: backs up the chunk to <file>.bak, aborts if the exact buildHeaders
# signature is missing (version changed), validates syntax with node --check,
# and is idempotent (skips if already patched).
#
# Usage:
#   chmod +x fix-9router-docker.sh
#   ./fix-9router-docker.sh [container]
#
# Args:
#   container = 9Router container name/id (default: 9router)
#
# Note: the container's filesystem is ephemeral. `docker compose down` /
# `docker compose up` (recreate) wipes this patch. For persistence across
# recreates, either run this after every `up`, or bind-mount the patched chunk
# (see README).

set -euo pipefail

CONTAINER="${1:-9router}"
CHUNK="/app/.next/server/chunks/318.js"
BAK="${CHUNK}.bak"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found on host." >&2; exit 1; }

# Fail early if the container/chunk isn't there.
docker exec "$CONTAINER" test -f "$CHUNK" 2>/dev/null \
  || { echo "ERROR: $CONTAINER missing $CHUNK. Is that the 9Router container?" >&2; exit 1; }

# Idempotent - already patched?
if docker exec "$CONTAINER" grep -qF -- '"x-opencode-session"' "$CHUNK"; then
  echo "Already patched - nothing to do."
  exit 0
fi

# Backup once.
if ! docker exec "$CONTAINER" test -f "$BAK"; then
  docker exec "$CONTAINER" cp "$CHUNK" "$BAK"
  echo "Backup: $BAK"
fi

# The exact minified buildHeaders signature we patch. If a 9Router update
# changes it, this fails closed (no changes) and you send us the new chunk.
# Passed into the container via docker exec -e (host env does not forward).
SIG_VALUE='buildHeaders(){return{"Content-Type":"application/json",Authorization:"Bearer public","x-opencode-client":"desktop",Accept:"text/event-stream"}}'

docker exec -e SIG="$SIG_VALUE" -e CHUNK="$CHUNK" "$CONTAINER" node -e '
const fs = require("fs");
const c = fs.readFileSync(process.env.CHUNK, "utf8");
const sig = process.env.SIG;
const inject = "var _s=this._sid||(this._sid=\"ses_\"+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)),_p=this._pid||(this._pid=\"p_\"+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2));";
const extra = "\"x-opencode-session\":_s,\"x-opencode-project\":_p,\"x-opencode-request\":_s+\":\"+Date.now()+\":\"+Math.random().toString(36).slice(2),\"User-Agent\":\"opencode/1.17.0\",";
const i = c.indexOf(sig);
if (i < 0) {
  console.error("buildHeaders signature not found - 9Router version may have changed");
  process.exit(2);
}
const rep = "buildHeaders(){" + inject + "return{\"Content-Type\":\"application/json\",Authorization:\"Bearer public\",\"x-opencode-client\":\"desktop\"," + extra + "Accept:\"text/event-stream\"}}";
const out = c.slice(0, i) + rep + c.slice(i + sig.length);
fs.writeFileSync(process.env.CHUNK, out, "utf8");
'

# Validate syntax with the node that ships in the image, then restart.
docker exec "$CONTAINER" node --check "$CHUNK"
echo "Syntax check: OK"
echo "PATCHED. Restarting $CONTAINER..."
docker restart "$CONTAINER"
echo "Done."
echo "Verify: docker exec $CONTAINER grep -c 'x-opencode-session' $CHUNK"
