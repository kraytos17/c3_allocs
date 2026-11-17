// Strong definition of the libhfuzz entry point that forwards to the C3
// harness. Needed because c3c currently emits @cname functions as weak
// symbols, which would otherwise lose to libhfuzz's weak default stub.
#include <stddef.h>
#include <stdint.h>

extern int c3_fuzz_one_input(const char* buf, size_t len);

int LLVMFuzzerTestOneInput(const uint8_t* buf, size_t len)
{
	return c3_fuzz_one_input((const char*)buf, len);
}
