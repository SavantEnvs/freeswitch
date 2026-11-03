#include <stdint.h>
#include <stdio.h>
#include <climits>
#include <string>

#include <fuzzer/FuzzedDataProvider.h>

extern "C" {
#include "switch_utf8.h"
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    FuzzedDataProvider provider(data, size);
    std::string str = provider.ConsumeRandomLengthString();
    const char* cstr = str.c_str();

    switch_u8_strlen((char*) cstr);

    return 0;
}
