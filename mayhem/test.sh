#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Unit tests that FreeSWITCH's tests/unit builds against the minimal module set (built by build.sh in
# mayhem/build/norm-src with normal flags). Each prints "PASSED (n/n tests ...)" or "FAILED (p/t tests ...)".
UNIT="$SRC/mayhem/build/norm-src/tests/unit"
UNIT_TESTS="switch_console switch_core_db switch_event switch_hash switch_packetizer switch_stun switch_timer switch_utils switch_vad switch_vpx switch_xml"
passed=0 failed=0

[ -d "$UNIT" ] || { echo "missing $UNIT (build.sh did not build the oracle tree)" >&2; emit_ctrf freeswitch-unit 0 1; exit 1; }
cd "$UNIT"
for t in $UNIT_TESTS; do
  if [ ! -x "./$t" ]; then echo "FAIL $t: not built" >&2; failed=$((failed + 1)); continue; fi
  out=$(timeout 300 "./$t" 2>&1); rc=$?
  line=$(printf '%s\n' "$out" | grep -E '^(PASSED|FAILED) \([0-9]+/[0-9]+ tests' | tail -1)
  if [ "$rc" -eq 0 ] && [[ "$line" =~ ^PASSED\ \(([0-9]+)/([0-9]+)\ tests ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
    echo "ok   $t: $line"; passed=$((passed + BASH_REMATCH[1]))
  else
    echo "FAIL $t (rc=$rc): ${line:-no summary line}" >&2; printf '%s\n' "$out" | tail -20 >&2; failed=$((failed + 1))
  fi
done

# fs_encode known-answer: encode a fixed 440 Hz, 100 ms, 8 kHz 16-bit mono WAV with G.711 (deterministic)
# and compare size and md5 of the encoded stream.
ENC="$SRC/mayhem/build/norm-install/bin/fs_encode"
SEED="$SRC/mayhem/fs-encode/testsuite/sine.wav"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$SEED" input.wav
check_encode() {   # <ext> <bytes> <md5>
  local ext="$1" size="$2" md5="$3" got_size got_md5
  rm -f "out.$ext"
  timeout 120 "$ENC" -k . input.wav "out.$ext" >enc.log 2>&1
  got_size=$(stat -c %s "out.$ext" 2>/dev/null || echo missing)
  got_md5=$(md5sum "out.$ext" 2>/dev/null | cut -d' ' -f1)
  if [ "$got_size" = "$size" ] && [ "$got_md5" = "$md5" ]; then
    echo "ok   fs_encode $ext: $got_size bytes $got_md5"; passed=$((passed + 1))
  else
    echo "FAIL fs_encode $ext: got $got_size bytes md5 ${got_md5:-none}, want $size bytes $md5" >&2; tail -5 enc.log >&2; failed=$((failed + 1))
  fi
}
[ -x "$ENC" ] || { echo "missing $ENC" >&2; failed=$((failed + 1)); }
check_encode PCMU 800 dc1730df62ec015f651c8c98380a0702
check_encode PCMA 800 0ba7ae98ad71637564f5e0a959381283
check_encode G722 400 e5182958e309dbe21093b9daf7285b8d
check_encode GSM 165 17c69e166400b53d7dc6c284925b3a2c

emit_ctrf freeswitch-unit "$passed" "$failed"
