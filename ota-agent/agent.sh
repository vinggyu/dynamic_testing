#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config (env)
# -----------------------------
IN_TAR="${IN_TAR:-}"
TEST_IMG="${TEST_IMG:-}"
LISTEN_PORT="${LISTEN_PORT:-8080}"

CONTAINER_NAME="${CONTAINER_NAME:-target-app}"

# optional checks (blank = skip)
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"               # e.g., http://127.0.0.1:8080/health
VECTORS_DIR="${VECTORS_DIR:-/in/vectors}"            # inside agent pod (/in mounted)
SENSITIVE_WRITE_PATH="${SENSITIVE_WRITE_PATH:-}"     # e.g., /etc/shadow or /etc/hostname

# verification probe
KEY_FILE="${KEY_FILE:-/in/key.txt}"
VERIFY_CMD="${VERIFY_CMD:-/usr/local/bin/verify-probe}"

STARTUP_WAIT="${STARTUP_WAIT:-2}"

OUT_DIR="/out"
ART_DIR="$OUT_DIR/artifacts"
mkdir -p "$ART_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
append_report() { echo "$1" | tee -a "$OUT_DIR/report.txt" >/dev/null; }

# -----------------------------
# Housekeeping (reset outputs)
# -----------------------------
: > "$OUT_DIR/report.txt"
rm -rf "$ART_DIR"
mkdir -p "$ART_DIR"

# -----------------------------
# Cleanup on exit
# -----------------------------
cleanup() {
  # best-effort cleanup
  podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

save_debug_artifacts() {
  # best-effort debug artifacts
  set +e
  podman logs "$CONTAINER_NAME" > "$ART_DIR/container.log" 2>&1
  podman inspect "$CONTAINER_NAME" > "$ART_DIR/inspect.json" 2>&1
  set -e
}

container_is_running() {
  local r
  r="$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$r" == "true" ]]
}

# -----------------------------
# 0) Select tar & load image
# -----------------------------
if [[ -z "$IN_TAR" ]]; then
  IN_TAR="$(ls -1t /in/*.tar 2>/dev/null | head -n1 || true)"
fi

LOADED_IMG=""
if [[ -n "$IN_TAR" && -s "$IN_TAR" ]]; then
  log "Found tar: $IN_TAR → loading image"
  podman load -i "$IN_TAR" | tee "$OUT_DIR/podman_load.log"

  LOADED_IMG=$(grep -Eo 'Loaded image(\(s\))?: .+' "$OUT_DIR/podman_load.log" \
              | sed -E 's/Loaded image(\(s\))?: //g' \
              | tail -n1 || true)
else
  log "No tar found (IN_TAR not set or file missing)."
fi

# If TEST_IMG is provided, retag loaded image to unify the run target
if [[ -n "$TEST_IMG" ]]; then
  if [[ -n "$LOADED_IMG" && "$LOADED_IMG" != "$TEST_IMG" ]]; then
    log "Retagging loaded image: $LOADED_IMG -> $TEST_IMG"
    podman tag "$LOADED_IMG" "$TEST_IMG"
  fi
else
  if [[ -n "$LOADED_IMG" && "$LOADED_IMG" != "null" ]]; then
    TEST_IMG="$LOADED_IMG"
  else
    log "WARN: Could not detect loaded image, fallback → localhost/ivi-theme:0.1"
    TEST_IMG="localhost/ivi-theme:0.1"
  fi
fi

log "Using test image: $TEST_IMG"

# -----------------------------
# 1) Cleanup old container
# -----------------------------
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# -----------------------------
# 2) Start container (keep as-is conceptually)
# -----------------------------
log "Starting test container..."
podman run -d --name "$CONTAINER_NAME" \
  --user 0 \
  -p "${LISTEN_PORT}:80" \
  "$TEST_IMG" | tee "$OUT_DIR/run_id.txt" >/dev/null

sleep "$STARTUP_WAIT"

# 컨테이너가 바로 죽는 경우를 분리해서 처리
if ! container_is_running; then
  append_report "[FAIL] container did not stay running after startup wait"
  save_debug_artifacts
  append_report "[INFO] artifacts saved: artifacts/container.log, artifacts/inspect.json"
  exit 1
fi

# -----------------------------
# 3) Check: optional health endpoint
# -----------------------------
if [[ -n "$HEALTHCHECK_URL" ]]; then
  log "Checking health endpoint: $HEALTHCHECK_URL"
  if curl -fsSL "$HEALTHCHECK_URL" >/dev/null; then
    append_report "[PASS] health endpoint reachable"
  else
    append_report "[FAIL] health endpoint not reachable"
  fi
else
  append_report "[SKIP] health endpoint (HEALTHCHECK_URL not set)"
fi

# -----------------------------
# 4) Observation: process snapshot
# -----------------------------
log "Collecting process snapshot"
if podman exec "$CONTAINER_NAME" ps aux > "$ART_DIR/processes.log" 2>/dev/null; then
  append_report "[PASS] process snapshot saved: artifacts/processes.log"
else
  append_report "[FAIL] process snapshot failed"
  save_debug_artifacts
fi

# -----------------------------
# 5) Observation: network snapshot (optional, best-effort)
# -----------------------------
log "Collecting network snapshot (best-effort)"
if podman exec "$CONTAINER_NAME" sh -lc 'command -v ss >/dev/null && ss -lntup || (command -v netstat >/dev/null && netstat -lntup) || exit 3' \
  > "$ART_DIR/network.log" 2>/dev/null; then
  append_report "[PASS] network snapshot saved: artifacts/network.log"
else
  append_report "[SKIP] network snapshot (ss/netstat not available)"
fi

# -----------------------------
# 6) Verification probe (simple key/vector)
# -----------------------------
mkdir -p "$VECTORS_DIR"

# 파이프라인 확인용: 없으면 기본 키/벡터 생성
if [[ ! -f "$KEY_FILE" ]]; then
  echo "1" > "$KEY_FILE"
  log "Created default key file: $KEY_FILE (=1)"
fi
if [[ ! -f "$VECTORS_DIR/valid.vec" ]]; then
  echo "EXPECTED_KEY=1" > "$VECTORS_DIR/valid.vec"
  log "Created default valid vector: $VECTORS_DIR/valid.vec (EXPECTED_KEY=1)"
fi
if [[ ! -f "$VECTORS_DIR/invalid.vec" ]]; then
  echo "EXPECTED_KEY=2" > "$VECTORS_DIR/invalid.vec"
  log "Created default invalid vector: $VECTORS_DIR/invalid.vec (EXPECTED_KEY=2)"
fi

# verify-probe 존재 확인
if ! podman exec "$CONTAINER_NAME" sh -lc "test -x '$VERIFY_CMD'"; then
  append_report "[SKIP] verification probe (not found/executable): $VERIFY_CMD"
else
  log "Injecting key/vectors into container and running verification probe"

  set +e
  podman cp "$KEY_FILE" "$CONTAINER_NAME:/tmp/key.txt" >/dev/null 2>&1
  rc_cp1=$?
  podman cp "$VECTORS_DIR/valid.vec" "$CONTAINER_NAME:/tmp/valid.vec" >/dev/null 2>&1
  rc_cp2=$?
  podman cp "$VECTORS_DIR/invalid.vec" "$CONTAINER_NAME:/tmp/invalid.vec" >/dev/null 2>&1
  rc_cp3=$?
  set -e

  if [[ $rc_cp1 -ne 0 || $rc_cp2 -ne 0 || $rc_cp3 -ne 0 ]]; then
    append_report "[FAIL] verification probe injection failed (cp_rcs=$rc_cp1,$rc_cp2,$rc_cp3)"
    save_debug_artifacts
  else
    # 정상 벡터: rc==0 기대
    set +e
    podman exec "$CONTAINER_NAME" "$VERIFY_CMD" --key /tmp/key.txt --vector /tmp/valid.vec \
      > "$ART_DIR/verify_valid.log" 2>&1
    rc_valid=$?

    # 비정상 벡터: rc!=0 기대
    podman exec "$CONTAINER_NAME" "$VERIFY_CMD" --key /tmp/key.txt --vector /tmp/invalid.vec \
      > "$ART_DIR/verify_invalid.log" 2>&1
    rc_invalid=$?
    set -e

    if [[ $rc_valid -eq 0 && $rc_invalid -ne 0 ]]; then
      append_report "[PASS] verification probe (valid=pass, invalid=fail)"
    else
      append_report "[FAIL] verification probe (valid_rc=$rc_valid, invalid_rc=$rc_invalid)"
      append_report "[INFO] logs: artifacts/verify_valid.log, artifacts/verify_invalid.log"
      save_debug_artifacts
    fi
  fi
fi

# -----------------------------
# 7) Check: optional sensitive write attempt (generic)
# -----------------------------
if [[ -n "$SENSITIVE_WRITE_PATH" ]]; then
  log "Checking sensitive write behavior: $SENSITIVE_WRITE_PATH"
  set +e
  podman exec "$CONTAINER_NAME" sh -lc "echo test > '$SENSITIVE_WRITE_PATH'" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    append_report "[WARN] sensitive write succeeded: $SENSITIVE_WRITE_PATH"
  else
    append_report "[PASS] sensitive write blocked (or failed as expected): $SENSITIVE_WRITE_PATH"
  fi
else
  append_report "[SKIP] sensitive write check (SENSITIVE_WRITE_PATH not set)"
fi

# -----------------------------
# 8) Summary (cleanup happens via trap)
# -----------------------------
log "DONE. Results stored in $OUT_DIR"

# FAIL이 하나라도 있으면 exit 1
if grep -q '^\[FAIL\]' "$OUT_DIR/report.txt"; then
  exit 1
fi
exit 0
