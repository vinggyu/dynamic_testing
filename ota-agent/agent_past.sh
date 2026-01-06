#!/usr/bin/env bash
set -euo pipefail

IN_TAR="${IN_TAR:-}"
LISTEN_PORT="${LISTEN_PORT:-8080}"

OUT_DIR="/out"
ART_DIR="$OUT_DIR/artifacts"

mkdir -p "$ART_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

###############################################
# 0) OTA 이미지 tar → load
###############################################
if [[ -z "$IN_TAR" ]]; then
    IN_TAR="$(ls -1t /in/*.tar 2>/dev/null | head -n1 || true)"
fi

LOADED_IMG=""

if [[ -s "$IN_TAR" ]]; then
    log "Found tar: $IN_TAR → loading image"
    podman load -i "$IN_TAR" | tee "$OUT_DIR/podman_load.log"

    LOADED_IMG=$(grep -Eo 'Loaded image: .+' "$OUT_DIR/podman_load.log" \
                | sed 's/Loaded image: //g' \
                | tail -n1 || true)
else
    log "No tar found (IN_TAR not set or file missing)."
fi
    
# TEST_IMG가 주어지면: 로드된 이미지를 TEST_IMG로 retag 해서 실행 태그를 통일
if [[ -n "$TEST_IMG" ]]; then
    TEST_IMG="${TEST_IMG:-}"
    if [[ -n "$LOADED_IMG" && "$LOADED_IMG" != "$TEST_IMG" ]]; then
        log "Retagging loaded image: $LOADED_IMG -> $TEST_IMG"
        podman tag "$LOADED_IMG" "$TEST_IMG"
    fi
else
    # TEST_IMG 미지정이면: 로드된 이미지명을 사용, 없으면 fallback
    if [[ -n "$LOADED_IMG" && "$LOADED_IMG" != "null" ]]; then
        TEST_IMG="$LOADED_IMG"
    else
        log "WARN: Could not detect loaded image, fallback → localhost/ivi-theme:0.1"
        TEST_IMG="localhost/ivi-theme:0.1"
    fi
fi

log "Using test image: $TEST_IMG"

###############################################
# 1) 기존 컨테이너 제거
###############################################
podman rm -f ivi-ng >/dev/null 2>&1 || true

###############################################
# 2) 테스트 컨테이너 실행
###############################################
log "Starting test container..."
podman run -d --name ivi-ng \
    --user 0 \
    -p "${LISTEN_PORT}:80" \
    "$TEST_IMG" | tee "$OUT_DIR/run_id.txt"

###############################################
# 3) D1: health check
###############################################
log "Running D1 (health check)"
sleep 2
if curl -fsSL "http://127.0.0.1:${LISTEN_PORT}/assets/" >/dev/null; then
    echo "[D1 PASS] health OK" | tee -a "$OUT_DIR/report.txt"
else
    echo "[D1 FAIL] health check failed" | tee -a "$OUT_DIR/report.txt"
fi

###############################################
# 4) D4: 파일시스템 제약 확인
###############################################
log "Running D4 (filesystem test)"
podman exec ivi-ng sh -lc \
    'echo ok >/tmp/x && echo "[D4] /tmp OK" || echo "[D4] /tmp FAIL"' \
    | tee -a "$OUT_DIR/report.txt"

podman exec ivi-ng sh -lc \
    'echo bad >/etc/shadow && echo "[D4] should-not-write" || echo "[D4 PASS] RO root"' \
    | tee -a "$OUT_DIR/report.txt"

###############################################
# 5) D7: 프로세스 목록 확인
###############################################
log "Running D7 (process list)"
podman exec ivi-ng ps aux \
    | tee "$ART_DIR/proc_list.log" >/dev/null

echo "[D7] Process list saved -> $ART_DIR/proc_list.log" \
    | tee -a "$OUT_DIR/report.txt"

###############################################
# 6) MIBRoot Dynamic Verification (컨테이너 내부)
###############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo " MIBRoot Dynamic Verification Test"
echo "========================================"
echo ""

TOTAL=0
PASSED=0
FAILED=0

# 컨테이너 안에 /usr/bin/MIBRoot 있는지 먼저 확인
if ! podman exec ivi-ng test -x /usr/bin/MIBRoot; then
    echo -e "${RED}❌ /usr/bin/MIBRoot not found or not executable in container${NC}"
    TOTAL=1
    FAILED=1
    echo "[MIBRoot] ERROR: /usr/bin/MIBRoot not found in container" >> "$OUT_DIR/report.txt"
else
    run_test() {
        local test_name="$1"
        local args="$2"
        local expected_output="$3"
        local expected_exit="$4"

        TOTAL=$((TOTAL + 1))
        echo -n "TEST $TOTAL: $test_name ... "

        # 컨테이너 내부에서 /usr/bin/MIBRoot 실행
        output=$(podman exec ivi-ng /usr/bin/MIBRoot $args 2>&1)
        exit_code=$?

        if [[ "$output" == "$expected_output" && "$exit_code" == "$expected_exit" ]]; then
            echo -e "${GREEN}PASS${NC}"
            PASSED=$((PASSED + 1))
        else
            echo -e "${RED}FAIL${NC}"
            FAILED=$((FAILED + 1))
        fi

        echo "  Output: $output"
        echo "  Exit:   $exit_code"
        echo ""
    }

    echo "========================================"
    echo " Test 1: Signature Verification"
    echo "========================================"
    echo ""

    run_test "Valid signature should return 1"   "sig-valid"   "1"  "0"
    run_test "Invalid signature should return 0" "sig-invalid" "0"  "0"

    echo "========================================"
    echo " Test 2: VCRN Verification"
    echo "========================================"
    echo ""

    run_test "Valid VCRN should return 1"        "vcrn-valid"   "1" "0"
    run_test "Invalid VCRN should return 0"      "vcrn-invalid" "0" "0"

    echo "========================================"
    echo " Test 3: Developer Mode Check"
    echo "========================================"
    echo ""

    run_test "Active Developer Mode should return 0"   "dev-active"   "0"  "0"
    run_test "Inactive Developer Mode should return -1" "dev-inactive" "-1" "0"
fi

echo "========================================"
echo " Test Summary"
echo "========================================"
echo ""
echo "Total tests:  $TOTAL"
echo -e "${GREEN}Passed:       $PASSED${NC}"
echo -e "${RED}Failed:       $FAILED${NC}"
echo ""

echo "[MIBRoot] Total=$TOTAL Passed=$PASSED Failed=$FAILED" >> "$OUT_DIR/report.txt"

final_exit=0
if [[ $FAILED -ne 0 ]]; then
    final_exit=1
fi

###############################################
# 7) 컨테이너 종료 처리
###############################################
log "Stopping test container"
podman rm -f ivi-ng >/dev/null 2>&1 || true

if [[ $final_exit -eq 0 ]]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
else
    echo -e "${RED}❌ SOME TESTS FAILED (MIBRoot)${NC}"
fi

log "DONE. Results stored in $OUT_DIR"
exit "$final_exit"

