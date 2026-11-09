#!/usr/bin/env bash
#
# mayhem/build.sh — builds the WebSocket frame parser of mod_xml_rpc (src/mod/xml_int/mod_xml_rpc/ws.c) into a
# sanitized fuzz harness and standalone reproducer, plus a normal-flags unit test that test.sh runs.
# Only ws.c and a connection stand-in are compiled: the FreeSWITCH core and the rest of xmlrpc-c are not needed.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE

SRC=${SRC:-/mayhem}
cd "$SRC"
B="$SRC/mayhem/build"
mkdir -p "$B/include/xmlrpc-c"

# xmlrpc-c's configure step generates this header from config.h.in; the abyss headers ws.h pulls in need it.
sed 's/@HAVE_WCHAR_H_DEFINE@/1/' libs/xmlrpc-c/include/xmlrpc-c/config.h.in > "$B/include/xmlrpc-c/config.h"

X=libs/xmlrpc-c
INC="-I$B/include -I$X/include -I$X/lib/abyss/src -I$X/lib/util/include -I$SRC/src/mod/xml_int/mod_xml_rpc -I$SRC/mayhem"
DEFS="-D_THREAD -D_GNU_SOURCE -w"
WS=src/mod/xml_int/mod_xml_rpc/ws.c

# Unit test: the project's normal flags, no sanitizers, no fuzzer.
$CC -O1 $DEBUG_FLAGS $DEFS $INC mayhem/ws_unit_test.c $WS -lssl -lcrypto -o "$B/ws_unit_test"

# Fuzz harness: ws.c is the fuzzed code, so it carries the sanitizers and SanCov.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"
$CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 $DEFS $INC -c "$WS" -o "$B/ws.o"
$CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 $DEFS $INC -c mayhem/fuzz_ws_read_frame.c -o "$B/fuzz_ws_read_frame.o"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/fuzz_ws_read_frame.o" "$B/ws.o" "$B/lsan_off.o" -lssl -lcrypto \
    -o /mayhem/fuzz_ws_read_frame
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$B/fuzz_ws_read_frame.o" "$B/ws.o" "$B/standalone_main.o" "$B/lsan_off.o" -lssl -lcrypto \
    -o /mayhem/fuzz_ws_read_frame-standalone
