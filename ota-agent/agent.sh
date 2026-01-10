#!/usr/bin/env bash
set -euo pipefail

IN_TAR="${IN_TAR:-}"
TEST_IMG="${TEST_IMG:-}"
CONTAINER_NAME="${CONTAINER_NAME:-target-app}"

# headless Qt (no X11)
QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-software}"
QT_OPENGL="${QT_OPENGL:-software}"
LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
DISPLAY="${DISPLAY:-}"

# verification probe inputs (host-mounted in /in)
KEY_FILE="${KEY_FILE:-/in/key.txt}"
VECTORS_DIR="${VECTORS_DIR:-/in/vectors}"
VERIFY_CMD="${VERIFY_CMD:-/usr/local/bin/verify-probe}"

# detection policies
# - suspicious process patterns should match what you inject in malicious images
SUSPICIOUS_PROC_REGEX="${SUSPICIOUS_PROC_REGEX:-evil-daemon|miner|cryptominer|xmrig|kdevtmpfsi|kinsing|backdoor|nc -l|socat}"
SENSITIVE_WRITE_PATH="${SENSITIVE_WRITE_PATH:-/etc/hostname}"

STARTUP_WAIT="${STARTUP_WAIT:-3}"
KEEPALIVE_FALLBACK_SECS="${KEEPALIVE_FALLBACK_SECS:-600}"

OUT_DIR="/out"
ART_DIR="$OUT_DIR/artifacts"
mkdir -p "$ART_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
append_report() { echo "$1" | tee -a "$OUT_DIR/report.txt" >/dev/null; }

# reset outputs
: > "$OUT_DIR/report.txt"
rm -rf "$ART_DIR"
mkdir -p "$ART_DIR"

cleanup() {
  podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  chown -R 1000:1000 /out 2>/dev/null || true
}
trap cleanup EXIT

container_exists() { podman container exists "$CONTAINER_NAME" 2>/dev/null; }
container_is_running() {
  local r
  r="$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$r" == "true" ]]
}

save_debug_artifacts() {
  set +e
  if container_exists; then
    podman logs "$CONTAINER_NAME" > "$ART_DIR/container.log" 2>&1
    podman inspect "$CONTAINER_NAME" > "$ART_DIR/inspect.json" 2>&1
  fi
  set -e
}

# -----------------------------
# 0) Select tar & load image
# -----------------------------
if [[ -z "$IN_TAR" ]]; then
  IN_TAR="$(ls -1t /in/*.tar 2>/dev/null | head -n1 || true)"
fi
if [[ -n "$IN_TAR" && "$IN_TAR" != /* ]]; then
  IN_TAR="/in/$IN_TAR"
fi
if [[ -n "$IN_TAR" && ! -s "$IN_TAR" ]]; then
  log "IN_TAR missing: $IN_TAR -> fallback to newest /in/*.tar"
  IN_TAR="$(ls -1t /in/*.tar 2>/dev/null | head -n1 || true)"
fi
log "Debug: resolved IN_TAR='${IN_TAR:-}'"

LOADED_IMG=""
if [[ -n "$IN_TAR" && -s "$IN_TAR" ]]; then
  t0=$(date +%s)
  log "Loading image from tar: $IN_TAR"
  podman load -i "$IN_TAR" | tee "$OUT_DIR/podman_load.log"
  t1=$(date +%s)
  append_report "[INFO] podman load seconds=$((t1-t0))"

  LOADED_IMG="$(grep -Eo 'Loaded image(\(s\))?: .+' "$OUT_DIR/podman_load.log" \
    | sed -E 's/Loaded image(\(s\))?: //g' \
    | tail -n1 || true)"
else
  append_report "[FAIL] No tar found in /in (IN_TAR not set or file missing)"
  exit 1
fi

if [[ -n "$TEST_IMG" ]]; then
  if [[ -n "$LOADED_IMG" && "$LOADED_IMG" != "$TEST_IMG" ]]; then
    log "Retagging loaded image: $LOADED_IMG -> $TEST_IMG"
    podman tag "$LOADED_IMG" "$TEST_IMG"
  fi
else
  TEST_IMG="$LOADED_IMG"
fi
append_report "[INFO] test image: $TEST_IMG"

# -----------------------------
# 1) Start target container
# - read-only rootfs (policy)
# - tmpfs for runtime dirs
# - headless Qt env
# -----------------------------
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

log "Starting target container (headless, read-only policy)"
set +e
t2=$(date +%s)
podman run -d --name "$CONTAINER_NAME" \
  --user 0 \
  --pull=never \
  --read-only \
  --tmpfs /tmp:rw,size=64m \
  --tmpfs /run:rw,size=32m \
  --tmpfs /var/tmp:rw,size=64m \
  -e DISPLAY= \
  -e QT_QPA_PLATFORM="$QT_QPA_PLATFORM" \
  -e QT_QUICK_BACKEND="$QT_QUICK_BACKEND" \
  -e QT_OPENGL="$QT_OPENGL" \
  -e LIBGL_ALWAYS_SOFTWARE="$LIBGL_ALWAYS_SOFTWARE" \
  "$TEST_IMG" \
  > "$OUT_DIR/run_id.txt" 2> "$ART_DIR/podman_run.err"
rc=$?
t3=$(date +%s)
append_report "[INFO] podman run seconds=$((t3-t2))"
set -e

if [[ $rc -ne 0 ]]; then
  append_report "[FAIL] podman run failed (rc=$rc)"
  append_report "[INFO] see artifacts/podman_run.err"
  podman info --debug > "$ART_DIR/podman_info.log" 2>&1 || true
  podman ps -a > "$ART_DIR/podman_ps_a.log" 2>&1 || true
  podman images > "$ART_DIR/podman_images.log" 2>&1 || true
  exit 1
fi

sleep "$STARTUP_WAIT"
if ! container_is_running; then
  append_report "[FAIL] container did not stay running after startup wait"
  save_debug_artifacts
  exit 1
fi

# always save logs/inspect
save_debug_artifacts

# -----------------------------
# 2) Process snapshot + suspicious process detection
# -----------------------------
log "Collecting processes"
if podman exec "$CONTAINER_NAME" ps aux > "$ART_DIR/processes.log" 2>/dev/null; then
  append_report "[PASS] process snapshot saved: artifacts/processes.log"
else
  append_report "[FAIL] process snapshot failed"
  exit 1
fi

if grep -Eiq "$SUSPICIOUS_PROC_REGEX" "$ART_DIR/processes.log"; then
  append_report "[FAIL] suspicious process detected (pattern=$SUSPICIOUS_PROC_REGEX)"
else
  append_report "[PASS] no suspicious process detected"
fi

# -----------------------------
# 3) Verification probe (key/vector)
# -----------------------------
mkdir -p "$VECTORS_DIR"
[[ -f "$KEY_FILE" ]] || echo "1" > "$KEY_FILE"
[[ -f "$VECTORS_DIR/valid.vec" ]] || echo "EXPECTED_KEY=1" > "$VECTORS_DIR/valid.vec"
[[ -f "$VECTORS_DIR/invalid.vec" ]] || echo "EXPECTED_KEY=2" > "$VECTORS_DIR/invalid.vec"

if ! podman exec "$CONTAINER_NAME" sh -lc "test -x '$VERIFY_CMD'"; then
  append_report "[FAIL] verification probe missing/not executable: $VERIFY_CMD"
else
  podman cp "$KEY_FILE" "$CONTAINER_NAME:/tmp/key.txt" >/dev/null 2>&1 || true
  podman cp "$VECTORS_DIR/valid.vec" "$CONTAINER_NAME:/tmp/valid.vec" >/dev/null 2>&1 || true
  podman cp "$VECTORS_DIR/invalid.vec" "$CONTAINER_NAME:/tmp/invalid.vec" >/dev/null 2>&1 || true

  set +e
  podman exec "$CONTAINER_NAME" "$VERIFY_CMD" --key /tmp/key.txt --vector /tmp/valid.vec \
    > "$ART_DIR/verify_valid.log" 2>&1
  rc_valid=$?
  podman exec "$CONTAINER_NAME" "$VERIFY_CMD" --key /tmp/key.txt --vector /tmp/invalid.vec \
    > "$ART_DIR/verify_invalid.log" 2>&1
  rc_invalid=$?
  set -e

  if [[ $rc_valid -eq 0 && $rc_invalid -ne 0 ]]; then
    append_report "[PASS] verification probe (valid=pass, invalid=fail)"
  else
    append_report "[FAIL] verification probe (valid_rc=$rc_valid, invalid_rc=$rc_invalid)"
    append_report "[INFO] logs: artifacts/verify_valid.log, artifacts/verify_invalid.log"
  fi
fi

# -----------------------------
# 4) Sensitive write (policy violation)
# -----------------------------
log "Checking sensitive write behavior: $SENSITIVE_WRITE_PATH"
set +e
podman exec "$CONTAINER_NAME" sh -lc "echo test > '$SENSITIVE_WRITE_PATH'" >/dev/null 2>&1
rcw=$?
set -e

if [[ $rcw -eq 0 ]]; then
  append_report "[FAIL] sensitive write succeeded: $SENSITIVE_WRITE_PATH"
else
  append_report "[PASS] sensitive write blocked (expected under read-only policy): $SENSITIVE_WRITE_PATH"
fi

# -----------------------------
# 5) Summary
# -----------------------------
log "DONE. Results stored in $OUT_DIR"
if grep -q '^\[FAIL\]' "$OUT_DIR/report.txt"; then
  exit 1
fi
exit 0
