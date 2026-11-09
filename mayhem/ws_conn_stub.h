/*
 * In-memory stand-in for the abyss connection that mod_xml_rpc's ws.c reads WebSocket frames from.
 * ws.c reaches the network only through ConnRead / ConnReadInit / ConnWrite (via ws_raw_read /
 * ws_raw_write); everything else it runs is the real src/mod/xml_int/mod_xml_rpc/ws.c.
 *
 * The "peer" sends the input bytes, ws_chunk at a time at most (as socket reads would), then closes.
 * A peer that has gone makes ws_read_frame()'s header loop spin forever (a hang fixed together with
 * the overflow); after WS_MAX_EOF_READS reads past the end the stand-in leaves through ws_bail so a
 * short input does not stall the whole campaign.
 */
#include "ws.h"

#include <setjmp.h>

#define WS_MAX_EOF_READS 100

static const uint8_t *ws_in;
static size_t ws_in_len;
static size_t ws_sent;
static size_t ws_chunk = BUFFER_SIZE;
static unsigned ws_eof_reads;
static jmp_buf *ws_bail;
static uint8_t ws_out[4096];
static size_t ws_out_len;

static void ws_stream_reset(const uint8_t *data, size_t size)
{
	ws_in = data;
	ws_in_len = size;
	ws_sent = 0;
	ws_out_len = 0;
	ws_eof_reads = 0;
}

void ConnReadInit(TConn *connectionP)
{
	if (connectionP->buffersize > connectionP->bufferpos) {
		connectionP->buffersize -= connectionP->bufferpos;
		memmove(connectionP->buffer.b, connectionP->buffer.b + connectionP->bufferpos, connectionP->buffersize);
		connectionP->bufferpos = 0;
	} else {
		connectionP->buffersize = connectionP->bufferpos = 0;
	}
	connectionP->buffer.b[connectionP->buffersize] = '\0';
}

void ConnRead(TConn *connectionP, uint32_t timeout, bool *eofP, bool *timedOutP, const char **errorP)
{
	size_t room = BUFFER_SIZE - connectionP->buffersize - 1;
	size_t n = ws_in_len - ws_sent;

	(void)timeout; (void)eofP; (void)timedOutP;

	if (n > room) n = room;
	if (n > ws_chunk) n = ws_chunk;
	if (n == 0) {
		if (++ws_eof_reads > WS_MAX_EOF_READS && ws_bail) longjmp(*ws_bail, 1);
		*errorP = strdup("connection closed");
		return;
	}

	for (size_t i = 0; i < n; i++) {
		connectionP->buffer.b[connectionP->buffersize + i] = ws_in[ws_sent + i];
	}
	connectionP->buffersize += (uint32_t)n;
	ws_sent += n;
	*errorP = NULL;
}

bool ConnWrite(TConn *connectionP, const void *buffer, uint32_t size)
{
	(void)connectionP;
	if (size <= sizeof(ws_out) - ws_out_len) {
		memcpy(ws_out + ws_out_len, buffer, size);
		ws_out_len += size;
	}
	return 1;
}

static wsh_t *ws_open(TSession *session, TConn *conn)
{
	wsh_t *wsh;

	memset(session, 0, sizeof(*session));
	memset(conn, 0, sizeof(*conn));
	session->connP = conn;
	wsh = ws_init(session);
	if (wsh) wsh->handshake = 1;
	return wsh;
}
