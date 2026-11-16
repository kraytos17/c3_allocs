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
fn bool allocator_valid_alignment(sz alignment) @private => !alignment || mem::is_valid_alignment(alignment);

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
) @private => alignment < mem::DEFAULT_MEM_ALIGNMENT ? mem::DEFAULT_MEM_ALIGNMENT : alignment;

<*
 Return the effective alignment with an additional minimum.

 The result is at least `minimum`, which lets allocators with internal
 headers raise the floor to cover their own alignment requirements.

 @param alignment : "The requested alignment, or zero for the default"
 @param minimum : "The minimum alignment the caller can accept"
 @return "The alignment to use for layout calculations"
*>
fn sz allocator_effective_alignment_min(sz alignment, sz minimum) @private
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
fn sz allocator_padding(uptr address, sz alignment) @private => (sz)((-address) & ((uptr)alignment - 1));

<*
 Round an address up to the requested alignment.

 @param address : "The address to round up"
 @param alignment : "The target alignment, which must be a valid power of two"
 @return "The smallest address at or after `address` with the alignment"
*>
fn uptr allocator_align_up_address(
	uptr address,
	sz alignment
) @private => (address + (uptr)alignment - 1) & ~((uptr)alignment - 1);

<*
 Round a byte count up to the requested alignment.

 @param value : "The byte count to round up"
 @param alignment : "The target alignment, which must be a valid power of two"
 @return "The smallest multiple of `alignment` at or above `value`"
*>
fn sz allocator_align_up_size(sz value, sz alignment) @private => mem::aligned_offset(value, alignment);
