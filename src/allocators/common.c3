<*
 Shared alignment, layout, and validation helpers for this module's allocators.

 Error contract shared by every allocator here: invalid sizes (zero or
 negative), invalid alignments, and sizes that overflow layout arithmetic
 report `INVALID_ALLOC_SIZE`. Exhaustion of the borrowed buffer or failure
 of a backing allocator reports `OUT_OF_MEMORY`. A failed `acquire` or
 `resize` leaves the allocator state unchanged and preserves the original
 block.
*>
module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

<*
 Check whether an optional allocation alignment is valid.

 Alignment zero requests the default alignment. Non-zero alignments must
 satisfy the standard memory alignment rules.

 @param alignment : "The requested alignment, or zero for the default"
 @return "True when the alignment is zero or a valid C3 alignment"
*>
fn bool allocator_valid_alignment(sz alignment) => !alignment || mem::is_valid_alignment(alignment);

<*
 Return the effective alignment for a request.

 A zero alignment and any alignment below the default memory alignment both
 resolve to the default memory alignment. Callers needing a higher floor
 should use `allocator_effective_alignment_min`.

 @param alignment : "The requested alignment, or zero for the default"
 @return "The alignment to use for layout calculations"
*>
fn sz allocator_effective_alignment(
	sz alignment
) => alignment < mem::DEFAULT_MEM_ALIGNMENT ? mem::DEFAULT_MEM_ALIGNMENT : alignment;

<*
 Return the effective alignment with an additional minimum.

 The result is at least `minimum`, which lets allocators with internal
 headers raise the floor to cover their own alignment requirements.

 @param alignment : "The requested alignment, or zero for the default"
 @param minimum : "The minimum alignment the caller can accept"
 @return "The alignment to use for layout calculations"
*>
fn sz allocator_effective_alignment_min(sz alignment, sz minimum)
{
	sz effective = allocator_effective_alignment(alignment);
	return effective < minimum ? minimum : effective;
}

<*
 Compute the padding needed to align an address upwards.

 @param address : "The unaligned address as an integer"
 @param alignment : "The target alignment, which must be a valid power of two"
 @return "The number of bytes to advance the address"
*>
fn sz allocator_padding(uptr address, sz alignment) => (sz)((-address) & ((uptr)alignment - 1));

<*
 Round an address up to the requested alignment.

 @param address : "The address to round up"
 @param alignment : "The target alignment, which must be a valid power of two"
 @return "The smallest address at or after `address` with the alignment"
*>
fn uptr allocator_align_up_address(
	uptr address,
	sz alignment
) => (address + (uptr)alignment - 1) & ~((uptr)alignment - 1);

<*
 Round a byte count up to the requested alignment.

 @param value : "The byte count to round up"
 @param alignment : "The target alignment, which must be a valid power of two"
 @return "The smallest multiple of `alignment` at or above `value`"
*>
fn sz allocator_align_up_size(sz value, sz alignment) => mem::aligned_offset(value, alignment);

<*
 Add two byte counts with overflow and negativity checks.

 @param a : "The first byte count, must not be negative"
 @param b : "The second byte count, must not be negative"
 @param out : "Receives the sum when the addition is valid"
 @return "True when the sum fit, false on overflow or negative input"
*>
fn bool allocator_checked_add(sz a, sz b, sz* out)
{
	if (a < 0 || b < 0) return false;
	if (a > sz::max - b) return false;

	*out = a + b;
	return true;
}

<*
 Return the smallest power of two at or above `value`.

 Values at or below zero yield zero. Values whose ceiling exceeds the
 maximum signed size yield zero to signal overflow.

 @param value : "The byte count to round up"
 @return "The ceiling power of two, or zero for invalid or overflowing input"
*>
fn sz allocator_ceil_pow2(sz value)
{
	if (value <= 1) return value <= 0 ? 0 : 1;

	uptr v = (uptr)value - 1;
	if (v >= (uptr)1 << 63) return 0;

	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	v |= v >> 32;
	v++;
	return (sz)v;
}

<*
 Return the largest power of two at or below `value`.

 @param value : "The byte count to round down"
 @return "The floor power of two, or zero for non-positive input"
*>
fn sz allocator_floor_pow2(sz value)
{
	if (value <= 0) return 0;

	uptr v = (uptr)value;
	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	v |= v >> 32;
	return (sz)(v - (v >> 1));
}

<*
 Check whether a value is a positive power of two.

 @param value : "The value to test"
 @return "True when the value is a positive power of two"
*>
fn bool allocator_is_pow2(sz value) => value > 0 && ((uptr)value & ((uptr)value - 1)) == 0;

<*
 Check whether a `[address, address + size)` range lies in a borrowed buffer.

 @param base : "The start of the borrowed buffer"
 @param len : "The length of the borrowed buffer"
 @param address : "The candidate range start"
 @param size : "The candidate range byte count, must not be negative"
 @return "True when the whole range is inside the buffer"
*>
fn bool allocator_contains(uptr base, sz len, uptr address, sz size)
{
	if (size < 0) return false;
	if (len < 0) return false;
	if (address < base) return false;

	uptr offset = address - base;
	if (offset > (uptr)len) return false;
	if (size > len - (sz)offset) return false;
	return true;
}

<*
 Zero a payload when the caller requested zero initialization.

 @param payload : "The payload to conditionally clear"
 @param size : "The requested payload byte count"
 @param init_type : "Whether the payload must be zero-initialized"
*>
fn void allocator_zero_if(void* payload, sz size, AllocInitType init_type)
{
	if (init_type == ZERO) mem::clear(payload, size, mem::DEFAULT_MEM_ALIGNMENT);
}

<*
 Compute the payload address for a block starting at `block_start`.

 The payload follows a header of `header_size` bytes and meets
 `effective_alignment`. The caller must have validated sizes so that
 `block_start + header_size` cannot overflow.

 @param block_start : "The start of the whole block"
 @param header_size : "The header byte count at the start of the block"
 @param effective_alignment : "The validated payload alignment"
 @return "The aligned payload address"
*>
fn uptr allocator_payload_address(
	uptr block_start,
	sz header_size,
	sz effective_alignment
) => allocator_align_up_address(block_start + (uptr)header_size, effective_alignment);

<*
 Decide the allocated size for a free range, splitting only when useful.

 The total is rounded up to `split_alignment` so later ranges stay aligned.
 The remainder becomes a new free range only when it can hold at least
 `min_remainder` bytes; otherwise the whole free range is consumed, which
 avoids unusable splinters.

 @param total_needed : "The bytes needed including header, padding, and payload"
 @param split_alignment : "The alignment the remainder start must keep"
 @param free_size : "The available free range byte count"
 @param min_remainder : "The smallest useful remainder range"
 @return "The bytes to allocate from the front of the free range"
*>
fn sz allocator_split_size(sz total_needed, sz split_alignment, sz free_size, sz min_remainder)
{
	sz alloc_size = allocator_align_up_size(total_needed, split_alignment);
	if (alloc_size <= free_size && free_size - alloc_size >= min_remainder) return alloc_size;
	return free_size;
}
