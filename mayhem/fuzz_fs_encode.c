/*
 * In-process version of src/fs_encode.c: open the fuzz input as a WAV file (mod_sndfile), encode it frame
 * by frame with one of four G.711/G.722/GSM codecs, and write the result through mod_native_file. The core
 * is initialised once; fs_encode's own main() pays ~0.4 s of core init and module loading per run, which
 * left Mayhem's file-input target at 0.09 execs/s and its behavior-testing phase failing.
 *
 * The codec is picked by the last input byte, so the seed WAVs stay valid WAVs.
 */
#include <switch.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

static char in_path[4096];
static char scratch[4096];
static const char *const formats[] = { "PCMU", "PCMA", "G722", "GSM" };

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	const char *tmp = getenv("TMPDIR");
	const char *err = NULL;

	(void) argc;
	(void) argv;

	snprintf(scratch, sizeof(scratch), "%s/fsenc-XXXXXX", tmp && *tmp ? tmp : "/tmp");
	if (!mkdtemp(scratch)) abort();
	snprintf(in_path, sizeof(in_path), "%s/in.wav", scratch);

	/* FreeSWITCH writes its generated freeswitch.xml.fsxml into log_dir; keep it in scratch. */
	SWITCH_GLOBAL_dirs.log_dir = strdup(scratch);
	switch_core_set_globals();

	if (switch_core_init(SCF_MINIMAL, SWITCH_FALSE, &err) != SWITCH_STATUS_SUCCESS) abort();
	switch_loadable_module_init(SWITCH_FALSE);
	switch_loadable_module_load_module("", "CORE_PCM_MODULE", SWITCH_TRUE, &err);
	switch_loadable_module_load_module("", "CORE_SPEEX_MODULE", SWITCH_TRUE, &err);
	switch_loadable_module_load_module("", "CORE_SOFTTIMER_MODULE", SWITCH_TRUE, &err);
	if (switch_loadable_module_load_module((char *) SWITCH_GLOBAL_dirs.mod_dir, (char *) "mod_spandsp", SWITCH_TRUE, &err) != SWITCH_STATUS_SUCCESS) abort();
	if (switch_loadable_module_load_module((char *) SWITCH_GLOBAL_dirs.mod_dir, (char *) "mod_sndfile", SWITCH_TRUE, &err) != SWITCH_STATUS_SUCCESS) abort();
	if (switch_loadable_module_load_module((char *) SWITCH_GLOBAL_dirs.mod_dir, (char *) "mod_native_file", SWITCH_TRUE, &err) != SWITCH_STATUS_SUCCESS) abort();
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const char *format;
	char out_path[4096];
	switch_file_handle_t fh_input = { 0 }, fh_output = { 0 };
	switch_codec_t codec = { 0 };
	switch_memory_pool_t *pool = NULL;
	const int rate = 8000, ptime = 20, channels = 1;
	char buf[2048];
	char encode_buf[2048];
	switch_size_t len, blocksize;
	FILE *f;

	if (size < 2) return 0;
	format = formats[data[size - 1] % 4];
	size--;

	if (!(f = fopen(in_path, "wb"))) abort();
	if (fwrite(data, 1, size, f) != size) abort();
	fclose(f);
	snprintf(out_path, sizeof(out_path), "%s/out.%s", scratch, format);
	unlink(out_path);

	switch_core_new_memory_pool(&pool);

	if (switch_core_file_open(&fh_input, in_path, channels, rate, SWITCH_FILE_FLAG_READ | SWITCH_FILE_DATA_SHORT, NULL) != SWITCH_STATUS_SUCCESS) goto end;
	if (switch_core_codec_init_with_bitrate(&codec, format, NULL, "", rate, ptime, channels, 0, SWITCH_CODEC_FLAG_ENCODE, NULL, pool) != SWITCH_STATUS_SUCCESS) goto end;
	if (switch_core_file_open(&fh_output, out_path, channels, codec.implementation->actual_samples_per_second, SWITCH_FILE_FLAG_WRITE | SWITCH_FILE_NATIVE, NULL) != SWITCH_STATUS_SUCCESS) goto end;

	blocksize = len = (rate * ptime) / 1000;
	while (switch_core_file_read(&fh_input, buf, &len) == SWITCH_STATUS_SUCCESS) {
		uint32_t encoded_len = sizeof(encode_buf);
		uint32_t encoded_rate = rate;
		unsigned int flags = 0;

		if (switch_core_codec_encode(&codec, NULL, buf, len * 2, rate, encode_buf, &encoded_len, &encoded_rate, &flags) != SWITCH_STATUS_SUCCESS) break;
		len = encoded_len;
		if (switch_core_file_write(&fh_output, encode_buf, &len) != SWITCH_STATUS_SUCCESS) break;
		len = blocksize;
	}

end:
	if (codec.implementation) switch_core_codec_destroy(&codec);
	if (fh_input.file_interface) switch_core_file_close(&fh_input);
	if (fh_output.file_interface) switch_core_file_close(&fh_output);
	switch_core_destroy_memory_pool(&pool);
	unlink(out_path);
	return 0;
}
