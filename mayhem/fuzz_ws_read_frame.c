/*
 * Fuzz mod_xml_rpc's WebSocket frame parser: the bytes a client sends after the HTTP upgrade go
 * through ws_read_frame() exactly as the mod_xml_rpc websocket handler calls it.
 */
#include "ws_conn_stub.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	TSession session;
	TConn conn;
	wsh_t *wsh;
	int i;

	jmp_buf bail;

	ws_stream_reset(data, size);
	wsh = ws_open(&session, &conn);
	if (!wsh) return 0;

	ws_bail = &bail;
	if (!setjmp(bail)) {
		for (i = 0; i < 4 && !wsh->down; i++) {
			ws_opcode_t oc;
			uint8_t *payload;

			if (ws_read_frame(wsh, &oc, &payload) <= 0) break;
		}
	}
	ws_bail = NULL;

	ws_destroy(wsh);
	free(wsh);
	return 0;
}
