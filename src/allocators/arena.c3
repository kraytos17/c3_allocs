module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

<*
 A fixed-capacity arena allocator backed by caller-owned memory.

 Individual releases reclaim memory only when the released allocation is the
 most recent allocation. Use mark/reset or clear to release groups of
 allocations. The backing buffer must outlive the allocator and every pointer
 returned by it. This allocator is not thread-safe. Resetting or clearing the
 arena invalidates all allocations made after the chosen position; no object
 destructors are run.
*>
struct ArenaAllocator (Allocator) @mustinit
{
	char[] data;
	sz used;
}

struct ArenaHeader @local
{
	sz previous_used;
	sz size;
}

<*
 Initialize this arena with caller-owned storage.

 The supplied slice is borrowed, not copied or freed. Its backing memory must
 remain valid for the lifetime of the arena and all allocations from it.

 @param [&out] self : "The arena to initialize"
 @param data : "The caller-owned buffer used for allocations"
 @return "A pointer to the initialized arena"
*>
fn ArenaAllocator* ArenaAllocator.init(&self, char[] data)
{
	self.data = data;
	self.used = 0;
	return self;
}

<*
 Return the capacity of the borrowed arena buffer in bytes.

 @param [&in] self : "The arena to query"
 @return "The total size of the borrowed buffer"
*>
fn sz ArenaAllocator.capacity(&self) => self.data.len;

<*
 Return the number of bytes reserved in the arena, including alignment padding
 and allocation headers.

 @param [&in] self : "The arena to query"
 @return "The current arena position"
*>
fn sz ArenaAllocator.bytes_reserved(&self) => self.used;

<*
 Check whether a pointer lies inside the arena's live storage.

 Like the standard library's fixed-buffer allocator, this is a range check:
 any pointer between the first possible payload and the current arena
 position reports true, including interior pointers. It cannot detect
 whether the pointer is an exact payload.

 @param [&in] self : "The arena to validate against"
 @param pointer : "A candidate pointer"
 @return "True when the pointer lies within live arena storage"
*>
fn bool ArenaAllocator.owns(&self, void* pointer)
{
	if (!pointer || self.used < ArenaHeader::size) return false;

	uptr base_addr = (uptr)self.data.ptr;
	uptr pointer_addr = (uptr)pointer;
	if (pointer_addr < base_addr + (uptr)ArenaHeader::size) return false;
	return pointer_addr < base_addr + (uptr)self.used;
}

<*
 Check whether a payload pointer is the arena's most recent allocation.

 The pointer must be a payload returned by this arena; behavior is
 unspecified for other pointers.

 @param [&in] self : "The arena to validate against"
 @param pointer : "A candidate payload pointer"
 @return "True when the payload is the newest allocation"
*>
fn bool ArenaAllocator.is_last(&self, void* pointer)
{
	if (!pointer || self.used < ArenaHeader::size) return false;

	uptr base_addr = (uptr)self.data.ptr;
	uptr pointer_addr = (uptr)pointer;
	if (pointer_addr < base_addr + (uptr)ArenaHeader::size) return false;
	if (pointer_addr >= base_addr + (uptr)self.used) return false;

	ArenaHeader* header = pointer - ArenaHeader::size;
	return pointer_addr + (uptr)header.size == base_addr + (uptr)self.used;
}

<*
 Discard all allocations made from this arena.

 All previously returned pointers become invalid. This does not clear the
 backing bytes or run destructors for values stored in the arena.

 @param [&inout] self : "The arena to clear"
*>
fn void ArenaAllocator.clear(&self) => self.used = 0;

<*
 Save the current arena position for a later reset.

 @param [&in] self : "The arena to mark"
 @return "A mark that may be passed to reset"
*>
fn sz ArenaAllocator.mark(&self) => self.used;

<*
 Reset the arena to a mark previously returned by `mark`, invalidating all
 allocations made after that position. The mark must not be greater than the
 arena's current used position.

 @param [&inout] self : "The arena to reset"
 @param mark : "A saved arena position"
 @require mark <= self.used : "The mark must not be beyond the current arena position"
*>
fn void ArenaAllocator.reset(&self, sz mark)
{
	assert(mark <= self.used, "Arena mark is beyond the current allocation position.");
	self.used = mark;
}

<*
 Acquire a block of memory from the arena.

 Allocations are aligned to `alignment`, or to the allocator's default when
 alignment is zero. The `ZERO` initialization type clears the requested bytes;
 `NO_ZERO` leaves them uninitialized. This allocator does not grow the supplied
 buffer. Failure leaves the arena's used position unchanged.

 @param [&inout] self : "The arena to allocate from"
 @param size : "The number of bytes to allocate; must be greater than zero"
 @param init_type : "Whether the allocated bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero to use the default"
 @return "A pointer to the allocated block"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	if (size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (self.used > self.data.len) return mem::OUT_OF_MEMORY~;
	if (size > self.data.len) return mem::INVALID_ALLOC_SIZE~;
	if (self.data.len < ArenaHeader::size) return mem::OUT_OF_MEMORY~;
	sz after_header_check;
	if (!allocator_checked_add(self.used, ArenaHeader::size, &after_header_check)) return mem::OUT_OF_MEMORY~;

	sz previous_used = self.used;
	alignment = allocator_effective_alignment(alignment);
	if (self.used > self.data.len - ArenaHeader::size) return mem::OUT_OF_MEMORY~;

	uptr base_addr = (uptr)self.data.ptr;
	uptr block_start_addr = base_addr + (uptr)self.used;
	if (block_start_addr < base_addr) return mem::OUT_OF_MEMORY~;
	if (block_start_addr > uptr::max - (uptr)ArenaHeader::size) return mem::OUT_OF_MEMORY~;

	uptr unaligned_addr = block_start_addr + (uptr)ArenaHeader::size;
	if (unaligned_addr < block_start_addr) return mem::OUT_OF_MEMORY~;
	if (unaligned_addr > uptr::max - ((uptr)alignment - 1)) return mem::OUT_OF_MEMORY~;

	uptr aligned_addr = allocator_payload_address(block_start_addr, ArenaHeader::size, alignment);
	if (aligned_addr < base_addr) return mem::OUT_OF_MEMORY~;

	sz result_offset = (sz)(aligned_addr - base_addr);
	if (result_offset > self.data.len || size > self.data.len - result_offset)
	{
		return mem::OUT_OF_MEMORY~;
	}

	void* result = (void*)aligned_addr;
	ArenaHeader* header = result - ArenaHeader::size;
	header.previous_used = previous_used;
	header.size = size;
	self.used = result_offset + size;
	allocator_zero_if(result, size, init_type);
	return result;
}

<*
 Resize a block previously acquired from this arena.

 The common prefix of the old and new blocks is preserved. The most recent
 allocation is resized in place when it already satisfies the requested
 alignment and the new size fits. Otherwise, a new block is acquired and the
 common prefix is copied; the old block remains reserved unless it was the
 most recent block and can later be reclaimed. In particular, if the most
 recent block cannot grow in place, this operation fails without invalidating
 the old block. On any failure, the old block and arena state remain unchanged.

 @param [&inout] self : "The arena that acquired the block"
 @param [drop] old_pointer : "The pointer to resize"
 @param new_size : "The new size in bytes; must be greater than zero"
 @param alignment : "The required alignment, or zero to use the default"
 @return "A pointer to the resized block, which may differ from `old_pointer`"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	if (!old_pointer || new_size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (self.used > self.data.len) return mem::INVALID_ALLOC_SIZE~;

	uptr base_addr = (uptr)self.data.ptr;
	uptr old_addr = (uptr)old_pointer;
	if (base_addr > uptr::max - (uptr)self.used) return mem::INVALID_ALLOC_SIZE~;
	if (old_addr < base_addr || old_addr - base_addr < ArenaHeader::size) return mem::INVALID_ALLOC_SIZE~;

	sz old_offset = (sz)(old_addr - base_addr);
	if (old_offset >= self.used) return mem::INVALID_ALLOC_SIZE~;

	ArenaHeader* header = old_pointer - ArenaHeader::size;
	sz old_size = header.size;
	if (old_size > self.used - old_offset) return mem::INVALID_ALLOC_SIZE~;

	bool is_last = old_offset + old_size == self.used;
	alignment = allocator_effective_alignment(alignment);
	if (is_last && mem::ptr_is_aligned(old_pointer, alignment))
	{
		if (new_size <= self.data.len - old_offset)
		{
			header.size = new_size;
			self.used = old_offset + new_size;
			return old_pointer;
		}
		return mem::OUT_OF_MEMORY~;
	}

	void*? new_pointer_opt = self.acquire(new_size, NO_ZERO, alignment);
	if (catch new_pointer_opt) return mem::OUT_OF_MEMORY~;

	void* new_pointer = new_pointer_opt;
	sz copy_size = old_size < new_size ? old_size : new_size;
	mem::copy(new_pointer, old_pointer, copy_size, mem::DEFAULT_MEM_ALIGNMENT, mem::DEFAULT_MEM_ALIGNMENT);
	return new_pointer;
}

<*
 Release a block acquired from this arena.

 Because this is an arena, only the most recently allocated block can reclaim
 space. Releasing any earlier block is a no-op; use `reset` or `clear` to
 reclaim a group of allocations. Passing null is also a no-op. The `aligned`
 argument is accepted to satisfy the Allocator interface; arena metadata makes
 it unnecessary here.

 @param [&inout] self : "The arena that acquired the block"
 @param [drop] old_pointer : "The pointer to release, or null"
 @param aligned : "Whether the block was acquired with an explicit alignment"
*>
fn void ArenaAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	if (!old_pointer || !self.used) return;
	if (self.used > self.data.len) return;

	uptr base_addr = (uptr)self.data.ptr;
	uptr old_addr = (uptr)old_pointer;
	if (base_addr > uptr::max - (uptr)self.used) return;
	if (old_addr < base_addr || old_addr - base_addr < ArenaHeader::size) return;

	sz offset = (sz)(old_addr - base_addr);
	if (offset >= self.used) return;

	ArenaHeader* header = old_pointer - ArenaHeader::size;
	if (header.size <= self.used - offset && offset + header.size == self.used
		&& header.previous_used <= offset - ArenaHeader::size)
	{
		self.used = header.previous_used;
	}
}
