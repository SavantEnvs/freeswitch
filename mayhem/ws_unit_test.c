/* Known-answer tests for ws_read_frame()'s parsing: each case feeds bytes and checks what comes out. */
#include "ws_conn_stub.h"

static int passed, failed;

static void check(const char *name, int ok)
{
	if (ok) { printf("ok   %s\n", name); passed++; }
	else { printf("FAIL %s\n", name); failed++; }
}

static issize_t read_one(const uint8_t *in, size_t len, ws_opcode_t *oc, uint8_t *copy, size_t copy_len, size_t chunk)
{
	TSession session;
	TConn conn;
	wsh_t *wsh;
	uint8_t *payload = NULL;
	issize_t r;

	ws_stream_reset(in, len);
	ws_chunk = chunk;
	wsh = ws_open(&session, &conn);
	r = ws_read_frame(wsh, oc, &payload);
	if (payload && r > 0 && (size_t)r <= copy_len) memcpy(copy, payload, (size_t)r);
	ws_destroy(wsh);
	free(wsh);
	return r;
}

int main(void)
{
	static const uint8_t plain[] = { 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };
	static const uint8_t masked[] = { 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
	static const uint8_t ping[] = { 0x89, 0x03, 'a', 'b', 'c', 0x81, 0x02, 'o', 'k' };
	static const uint8_t toobig[] = { 0x82, 0x7f, 0, 0, 0, 0, 0, 1, 0, 0 };
	static const uint8_t badop[] = { 0x83, 0x00 };
	uint8_t big[4 + 300], copy[512];
	ws_opcode_t oc;
	issize_t r;
	int i, same;

	memset(copy, 0, sizeof(copy));
	r = read_one(plain, sizeof(plain), &oc, copy, sizeof(copy), BUFFER_SIZE);
	check("unmasked text frame", r == 5 && oc == WSOC_TEXT && !memcmp(copy, "Hello", 5));

	memset(copy, 0, sizeof(copy));
	r = read_one(masked, sizeof(masked), &oc, copy, sizeof(copy), BUFFER_SIZE);
	check("masked text frame (RFC 6455 5.7)", r == 5 && oc == WSOC_TEXT && !memcmp(copy, "Hello", 5));

	big[0] = 0x82; big[1] = 126; big[2] = 300 >> 8; big[3] = 300 & 0xff;
	for (i = 0; i < 300; i++) big[4 + i] = (uint8_t)(i * 7 + 1);
	memset(copy, 0, sizeof(copy));
	r = read_one(big, sizeof(big), &oc, copy, sizeof(copy), BUFFER_SIZE);
	for (same = 1, i = 0; i < 300; i++) if (copy[i] != (uint8_t)(i * 7 + 1)) same = 0;
	check("16-bit length binary frame", r == 300 && oc == WSOC_BINARY && same);

	memset(copy, 0, sizeof(copy));
	r = read_one(ping, sizeof(ping), &oc, copy, sizeof(copy), 5);
	check("ping (own read) is answered with a pong, then the next frame is returned",
		  r == 2 && oc == WSOC_TEXT && !memcmp(copy, "ok", 2) &&
		  ws_out_len == 5 && !memcmp(ws_out, "\x8a\x03" "abc", 5));

	r = read_one(toobig, sizeof(toobig), &oc, copy, sizeof(copy), BUFFER_SIZE);
	check("oversized 64-bit length is refused", r == -WS_DATA_TOO_BIG && oc == WSOC_CLOSE);

	r = read_one(badop, sizeof(badop), &oc, copy, sizeof(copy), BUFFER_SIZE);
	check("reserved opcode is a protocol error", r == -WS_PROTO_ERR && oc == WSOC_CLOSE);

	printf("RESULT passed=%d failed=%d\n", passed, failed);
	return failed ? 1 : 0;
}
