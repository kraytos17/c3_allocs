module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

<*
 A single-frame scratch allocator over caller-owned memory.

 This is a thin wrapper over `ArenaAllocator` with the same bump, release,
 mark, and reset semantics, plus a high-water mark for tuning frame
 budgets. The intended pattern is one scratch buffer per frame or scope:
 allocate freely, then `clear()` once at the frame boundary. Like an
 arena, only the most recent allocation reclaims space on release; use
 `mark`/`reset` or `clear` for bulk reclamation. The buffer is borrowed
 and must outlive the allocator. This allocator is not thread-safe and
 never runs destructors.
*>
struct ScratchAllocator (Allocator) @mustinit
{
	ArenaAllocator arena;
	sz peak_bytes;
}

<*
 Initialize the scratch allocator with caller-owned storage.

 @param [&out] self : "The allocator to initialize"
 @param storage : "The caller-owned buffer used for allocations"
 @return "A pointer to the initialized allocator"
*>
fn ScratchAllocator* ScratchAllocator.init(&self, char[] storage)
{
	self.arena.init(storage);
	self.peak_bytes = 0;
	return self;
}

<*
 Return the capacity of the borrowed buffer in bytes.

 @param [&in] self : "The allocator to query"
 @return "The total size of the borrowed buffer"
*>
fn sz ScratchAllocator.capacity(&self) => self.arena.capacity();

<*
 Return the bytes currently reserved, including headers and padding.

 @param [&in] self : "The allocator to query"
 @return "The current scratch position"
*>
fn sz ScratchAllocator.bytes_reserved(&self) => self.arena.bytes_reserved();

<*
 Return the highest reserved byte count observed since init or `reset_peak`.

 Use this to size the frame buffer: if `peak` approaches `capacity`,
 grow the buffer; if it stays far below, shrink it.

 @param [&in] self : "The allocator to query"
 @return "The high-water mark in bytes"
*>
fn sz ScratchAllocator.peak(&self) => self.peak_bytes;

<*
 Reset the high-water mark to the current position.

 @param [&inout] self : "The allocator to retune"
*>
fn void ScratchAllocator.reset_peak(&self) => self.peak_bytes = self.arena.bytes_reserved();

<*
 Record the high-water mark after the reserved count grew.

 @param [&inout] self : "The allocator to update"
*>
fn void scratch_note_peak(ScratchAllocator* self) @local
{
	sz reserved = self.arena.bytes_reserved();
	if (reserved > self.peak_bytes) self.peak_bytes = reserved;
}

<*
 Check whether a pointer lies inside the scratch allocator's live storage.

 Range semantics match `ArenaAllocator.owns`; interior pointers count.

 @param [&in] self : "The allocator to validate against"
 @param pointer : "A candidate pointer"
 @return "True when the pointer lies within live scratch storage"
*>
fn bool ScratchAllocator.owns(&self, void* pointer) => self.arena.owns(pointer);

<*
 Check whether a payload pointer is the most recent scratch allocation.

 @param [&in] self : "The allocator to validate against"
 @param pointer : "A candidate payload pointer"
 @return "True when the payload is the newest allocation"
*>
fn bool ScratchAllocator.is_last(&self, void* pointer) => self.arena.is_last(pointer);

<*
 Discard all scratch allocations at once.

 The high-water mark is retained so frame sizing survives across frames.
 All previously returned pointers become invalid.

 @param [&inout] self : "The allocator to clear"
*>
fn void ScratchAllocator.clear(&self) => self.arena.clear();

<*
 Save the current scratch position for a later reset.

 @param [&in] self : "The allocator to mark"
 @return "A mark that may be passed to reset"
*>
fn sz ScratchAllocator.mark(&self) => self.arena.mark();

<*
 Reset to a mark, invalidating allocations made after it.

 The mark is forwarded to the backing arena, whose reset ignores marks
 beyond the used position.

 @param [&inout] self : "The allocator to reset"
 @param mark : "A saved scratch position"
*>
fn void ScratchAllocator.reset(&self, sz mark) => self.arena.reset(mark);

<*
 Acquire a block of scratch memory.

 Semantics match `ArenaAllocator.acquire`: fixed capacity, alignment and
 zero-init support, failure without state change.

 @param [&inout] self : "The allocator to allocate from"
 @param size : "The number of bytes to allocate; must be greater than zero"
 @param init_type : "Whether the allocated bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero to use the default"
 @return "A pointer to the allocated block"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ScratchAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	void*? result = self.arena.acquire(size, init_type, alignment);
	if (catch result) return result;

	scratch_note_peak(self);
	return result;
}

<*
 Resize a scratch block, preserving the common prefix.

 Semantics match `ArenaAllocator.resize`, including in-place growth for
 the most recent block and allocate-copy-release otherwise.

 @param [&inout] self : "The allocator that acquired the block"
 @param [drop] old_pointer : "The pointer to resize"
 @param new_size : "The new size in bytes; must be greater than zero"
 @param alignment : "The required alignment, or zero to use the default"
 @return "A pointer to the resized block, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ScratchAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	void*? result = self.arena.resize(old_pointer, new_size, alignment);
	if (catch result) return result;

	scratch_note_peak(self);
	return result;
}

<*
 Release a scratch block.

 Only the most recent allocation reclaims space, matching arena semantics.
 Null and non-latest pointers are no-ops.

 @param [&inout] self : "The allocator that acquired the block"
 @param [drop] old_pointer : "The pointer to release, or null"
 @param aligned : "Whether the block was acquired with an explicit alignment"
*>
fn void ScratchAllocator.release(
	&self,
	void* old_pointer,
	bool aligned
) @dynamic => self.arena.release(old_pointer, aligned);
