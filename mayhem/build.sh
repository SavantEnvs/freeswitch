#!/usr/bin/env bash
#
# mayhem/build.sh — builds FreeSWITCH (sanitized, in place), its unit tests (normal flags, separate copy),
# the fuzz targets and their standalone reproducers. Runs inside the commit image as `mayhem` in /mayhem,
# offline: spandsp and sofia-sip-ua are baked into the image by mayhem/Dockerfile.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC=${SRC:-/mayhem}
cd "$SRC"
B="$SRC/mayhem/build"
SAN="$B/install-san"       # sanitized FreeSWITCH install (what the fuzz targets link and load)
NORM="$B/norm-src"         # pristine copy of the tree, built with the project's normal flags (test oracle)
NORM_INSTALL="$B/norm-install"
mkdir -p "$B"

# run <logfile> <cmd...>: keep the build log out of the way, but show its tail when the step fails.
run() { local log="$1"; shift; "$@" >"$log" 2>&1 || { echo "FAILED: $* (log $log)" >&2; tail -60 "$log" >&2; return 1; }; }

# FreeSWITCH ignores a checked-in modules.conf (it is generated); enable only what the targets and tests need.
MODULES='applications/mod_commands
applications/mod_spandsp
formats/mod_native_file
formats/mod_sndfile
loggers/mod_console
loggers/mod_logfile'

# Sanitized binaries run during configure/make (libtool, conftest programs); leaks there are not a finding.
export ASAN_OPTIONS=detect_leaks=0

# 1) Test oracle build: normal flags, from a copy of the working tree taken BEFORE the sanitized in-place
#    build, so nothing sanitized or generated leaks into it. test.sh only runs what is built here.
rm -rf "$NORM" "$NORM_INSTALL"
mkdir -p "$NORM"
git ls-files -z --cached --others --exclude-standard --deduplicate | tar --null -T - --ignore-failed-read -c | tar -x -C "$NORM"
(
  cd "$NORM"
  printf '%s\n' "$MODULES" > modules.conf
  unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
  run bootstrap.log ./bootstrap.sh -j
  run configure.log ./configure --prefix="$NORM_INSTALL" CC="$CC" CXX="$CXX" CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
  run make.log make -j"$MAYHEM_JOBS"
  run install.log make install
)

# 2) The project itself, sanitized, in place.
#    -fsanitize=fuzzer-no-link: SanCov in the fuzzed code, or the harnesses see 0 edges.
#    -fno-sanitize=vptr: the C++ pieces (libfreeswitch's mod_* helpers) link against a C driver without the
#    ubsan vptr type cache. -fno-fast-math at link: otherwise GCC's DWARF-5 crtfastmath.o becomes the first CU.
rm -rf "$SAN"
printf '%s\n' "$MODULES" > modules.conf
(
  export CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
  export CXXFLAGS="$SANITIZER_FLAGS -fno-sanitize=vptr -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
  export LDFLAGS="$SANITIZER_FLAGS -fno-fast-math"
  run "$B/san-bootstrap.log" ./bootstrap.sh -j
  run "$B/san-configure.log" ./configure --prefix="$SAN"
  run "$B/san-make.log" make -j"$MAYHEM_JOBS"
  run "$B/san-install.log" make install
)
# The in-place build leaves untracked, non-ignored unit-test binaries behind; drop them.
make -C tests/unit clean >/dev/null 2>&1

FS_INC="-I$SAN/include/freeswitch -I$SRC/src/include -I$SRC/libs/libteletone/src -I/usr/include/uuid"
FS_LIBS="-L$SAN/lib -lfreeswitch -Wl,-rpath,$SAN/lib"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

# 3) fs-encode harness: upstream fs_encode.c's file -> codec -> file path, in-process (libFuzzer) with the core
#    initialised once. Link as C (libFuzzer's -lstdc++ comes with the driver); the standalone reproducer too.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $FS_INC -fPIC -c mayhem/fuzz_fs_encode.c -o "$B/fuzz_fs_encode.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/fuzz_fs_encode.o" "$B/lsan_off.o" $FS_LIBS -o /mayhem/fuzz_fs_encode
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$B/fuzz_fs_encode.o" "$B/standalone_main.o" "$B/lsan_off.o" $FS_LIBS -o /mayhem/fuzz_fs_encode-standalone

# 4) switch_u8_strlen harness: libFuzzer binary and standalone reproducer.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $FS_INC mayhem/fuzz_switch_u8_strlen.cpp "$B/lsan_off.o" $FS_LIBS \
    -o /mayhem/fuzz_switch_u8_strlen
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FS_INC mayhem/fuzz_switch_u8_strlen.cpp "$B/standalone_main.o" "$B/lsan_off.o" $FS_LIBS \
    -o /mayhem/fuzz_switch_u8_strlen-standalone

# 5) libvpx's own decoder fuzzer (libs/libvpx/examples/vpx_dec_fuzzer.cc). FreeSWITCH's in-place build above
#    already builds the in-tree libs/libvpx/libvpx.a with the sanitizer and SanCov flags; link against it.
VPX_A="$SRC/libs/libvpx/libvpx.a"
[ -f "$VPX_A" ] || { echo "missing $VPX_A (FreeSWITCH's own build should have produced it)" >&2; exit 1; }
for codec in vp8 vp9; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=gnu++11 -DDECODER=$codec $LIB_FUZZING_ENGINE -I"$SRC/libs/libvpx" \
      -Wl,--start-group "$SRC/libs/libvpx/examples/vpx_dec_fuzzer.cc" "$B/lsan_off.o" "$VPX_A" -Wl,--end-group \
      -o /mayhem/vpx_dec_fuzzer_$codec
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=gnu++11 -DDECODER=$codec -I"$SRC/libs/libvpx" \
      -Wl,--start-group "$SRC/libs/libvpx/examples/vpx_dec_fuzzer.cc" "$B/standalone_main.o" "$B/lsan_off.o" "$VPX_A" -Wl,--end-group \
      -o /mayhem/vpx_dec_fuzzer_$codec-standalone
done
