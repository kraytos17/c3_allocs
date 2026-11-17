module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

const BUDDY_MIN_BLOCK = 64;
const BUDDY_MAX_ORDERS = 64;
const BUDDY_BLOCK_MAGIC @local = 0xB0DD7A11CE;

<*
 A binary buddy allocator over caller-owned memory.

 The allocator carves the largest power-of-two, correctly aligned region
 from the borrowed buffer and manages it in block orders: order 0 blocks
 are `BUDDY_MIN_BLOCK` bytes, each higher order doubles the size. Requests
 round up to the smallest order that fits header, alignment padding, and
 payload. Splitting divides larger blocks on demand; release merges a
 block with its free buddy (found by address XOR), so fully freeing the
 allocator restores one contiguous block. Alignment beyond the block size
 is honored through padding, and the order grows to cover it.

 Leading and trailing bytes outside the carved region stay reserved but
 unused. This allocator is not thread-safe and never runs destructors.
*>
struct BuddyAllocator (Allocator) @mustinit
{
	BuddyFree*[BUDDY_MAX_ORDERS] free_heads;
	char[] data;
	uptr region_base;
	sz region_size;
	sz max_order;
	sz free_bytes;
}

<*
 An intrusive free-list node living at the start of a free buddy block.
 The block order is implied by the list it sits on.
*>
struct BuddyFree @local
{
	BuddyFree* next;
}

<*
 The header of a live buddy block, placed immediately before the payload.
 `block_offset` recovers the block start including leading padding, and
 `order` locates the block size and its buddy on release.
*>
struct BuddyUsedHeader @local
{
	ulong magic;
	BuddyAllocator* owner;
	sz order;
	sz block_offset;
	sz requested_size;
}

<*
 Initialize the buddy allocator over caller-owned storage.

 The buffer is borrowed, not copied. The largest power-of-two region that
 is aligned to its own size is carved out of it; the rest stays reserved
 but unused. Buffers smaller than `BUDDY_MIN_BLOCK` yield an empty
 allocator whose acquisitions all fail.

 @param [&out] self : "The allocator to initialize"
 @param storage : "The caller-owned buffer backing this allocator"
 @return "A pointer to the initialized allocator"
*>
fn BuddyAllocator* BuddyAllocator.init(&self, char[] storage)
{
	for (sz i = 0; i < BUDDY_MAX_ORDERS; i++) self.free_heads[i] = null;
	self.data = storage;
	self.region_base = 0;
	self.region_size = 0;
	self.max_order = 0;
	self.free_bytes = 0;
	if (storage.len < BUDDY_MIN_BLOCK || !storage.ptr) return self;

	uptr base_addr = (uptr)storage.ptr;
	uptr end_addr = base_addr + (uptr)storage.len;
	uptr region_base = 0;
	sz region_size = 0;
	sz candidate = allocator_floor_pow2(storage.len);
	while (candidate >= BUDDY_MIN_BLOCK)
	{
		uptr aligned = allocator_align_up_address(base_addr, candidate);
		if (aligned >= base_addr && aligned <= uptr::max - (uptr)candidate && aligned + (uptr)candidate <= end_addr)
		{
			region_base = aligned;
			region_size = candidate;
			break;
		}
		if (candidate == BUDDY_MIN_BLOCK) break;
		candidate >>= 1;
	}
	if (!region_size) return self;

	sz order = 0;
	sz size = BUDDY_MIN_BLOCK;
	while (size < region_size && order + 1 < BUDDY_MAX_ORDERS)
	{
		size <<= 1;
		order++;
	}

	BuddyFree* block = (BuddyFree*)region_base;
	block.next = null;
	self.free_heads[order] = block;
	self.region_base = region_base;
	self.region_size = region_size;
	self.max_order = order;
	self.free_bytes = region_size;
	return self;
}

<*
 Return the usable carved region size in bytes.

 Leading and trailing buffer bytes outside the power-of-two region are
 not counted.

 @param [&in] self : "The allocator to query"
 @return "The managed region byte count"
*>
fn sz BuddyAllocator.capacity(&self) => self.region_size;

<*
 Return the free bytes currently held in buddy free lists.

 @param [&in] self : "The allocator to query"
 @return "The reclaimable free byte count"
*>
fn sz BuddyAllocator.bytes_free(&self) => self.free_bytes;

<*
 Return the managed bytes not currently free.

 @param [&in] self : "The allocator to query"
 @return "The reserved byte count within the region"
*>
fn sz BuddyAllocator.bytes_used(&self) => self.region_size - self.free_bytes;

<*
 Return the number of free buddy blocks across all orders.

 @param [&in] self : "The allocator to query"
 @return "The free block count"
*>
fn sz BuddyAllocator.free_block_count(&self)
{
	sz count = 0;
	for (sz i = 0; i <= self.max_order; i++)
	{
		BuddyFree* block = self.free_heads[i];
		while (block)
		{
			count++;
			block = block.next;
		}
	}
	return count;
}

<*
 Return the largest single contiguous free block in bytes.

 @param [&in] self : "The allocator to query"
 @return "The largest free block size, or zero when full"
*>
fn sz BuddyAllocator.largest_free(&self)
{
	for (sz i = self.max_order; i >= 0; i--)
	{
		if (self.free_heads[i]) return ((sz)BUDDY_MIN_BLOCK << i);
	}
	return 0;
}

<*
 Check whether a pointer is a live allocation of this allocator.

 The check validates the allocation header, so only exact payload pointers
 report true; interior and foreign pointers report false.

 @param [&in] self : "The allocator to validate against"
 @param pointer : "A candidate payload pointer"
 @return "True when the pointer is a live payload of this allocator"
*>
fn bool BuddyAllocator.owns(&self, void* pointer) => buddy_used_header((BuddyAllocator*)self, pointer) != null;

<*
 Discard all allocations and restore one contiguous free block.

 The carved region is retained. Previously returned pointers must not be
 used afterwards. No memory is cleared and no destructors run.

 @param [&inout] self : "The allocator to clear"
*>
fn void BuddyAllocator.clear(&self)
{
	for (sz i = 0; i < BUDDY_MAX_ORDERS; i++) self.free_heads[i] = null;
	self.free_bytes = 0;
	if (self.region_size)
	{
		BuddyFree* block = (BuddyFree*)self.region_base;
		block.next = null;
		self.free_heads[self.max_order] = block;
		self.free_bytes = self.region_size;
	}
}

<*
 Compute the leaf order for a request, honoring header and alignment.

 The leaf covers the header, the worst-case alignment padding, and the
 payload, and is at least as large as the effective alignment so the
 block start alignment keeps the payload offset position-independent.

 @param size : "The requested payload size"
 @param effective_alignment : "The validated payload alignment"
 @param order : "Receives the leaf order on success"
 @return "True when the order fit in the order table"
*>
fn bool buddy_leaf_order(sz size, sz effective_alignment, sz* order) @local
{
	sz payload_offset = allocator_align_up_size(BuddyUsedHeader::size, effective_alignment);
	if (payload_offset < 0) return false;

	sz total_needed;
	if (!allocator_checked_add(payload_offset, size, &total_needed)) return false;

	sz leaf_size = allocator_ceil_pow2(total_needed);
	if (!leaf_size) return false;
	if (leaf_size < effective_alignment) leaf_size = effective_alignment;
	if (leaf_size < BUDDY_MIN_BLOCK) leaf_size = BUDDY_MIN_BLOCK;

	sz leaf_order = 0;
	sz probe = BUDDY_MIN_BLOCK;
	while (probe < leaf_size)
	{
		if (leaf_order + 1 >= BUDDY_MAX_ORDERS) return false;

		probe <<= 1;
		leaf_order++;
	}

	*order = leaf_order;
	return true;
}

<*
 Validate a payload pointer and return its allocation header.

 @param [&in] self : "The allocator that may own the pointer"
 @param pointer : "A candidate payload pointer"
 @return "The live header for an exact payload pointer, or null"
*>
fn BuddyUsedHeader* buddy_used_header(BuddyAllocator* self, void* pointer) @local
{
	if (!pointer || !self.region_size) return null;

	uptr pointer_addr = (uptr)pointer;
	if (pointer_addr < self.region_base) return null;
	if (pointer_addr - self.region_base >= (uptr)self.region_size) return null;
	if (pointer_addr - self.region_base < (uptr)BuddyUsedHeader::size) return null;

	BuddyUsedHeader* header = pointer - BuddyUsedHeader::size;
	if (header.magic != BUDDY_BLOCK_MAGIC) return null;
	if (header.owner != self) return null;
	if ((void*)((char*)header + BuddyUsedHeader::size) != pointer) return null;
	if (header.order < 0 || header.order > self.max_order) return null;

	sz block_size = ((sz)BUDDY_MIN_BLOCK << header.order);
	uptr header_addr = (uptr)header;
	if (header.block_offset < 0 || header.block_offset > block_size) return null;
	if (header_addr < self.region_base + (uptr)header.block_offset) return null;

	uptr block_start = header_addr - (uptr)header.block_offset;
	if (block_start < self.region_base) return null;
	if (!allocator_contains(self.region_base, self.region_size, block_start, block_size)) return null;
	if ((block_start - self.region_base) % (uptr)block_size != 0) return null;
	if (header.requested_size < 0 || header.requested_size > block_size) return null;
	return header;
}

<*
 Acquire a buddy block, splitting larger blocks on demand.

 First fit scans orders from the leaf upward. Splitting publishes the
 right-hand buddies and descends with the left half. Failure leaves the
 allocator unchanged.

 @param [&inout] self : "The allocator to allocate from"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the payload bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero to use the default"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? BuddyAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	if (size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (!self.region_size) return mem::OUT_OF_MEMORY~;

	sz effective = allocator_effective_alignment(alignment);
	if (effective < BuddyUsedHeader::alignment) effective = BuddyUsedHeader::alignment;
	if (size > self.region_size) return mem::INVALID_ALLOC_SIZE~;

	sz leaf_order = 0;
	if (!buddy_leaf_order(size, effective, &leaf_order)) return mem::INVALID_ALLOC_SIZE~;
	if (leaf_order > self.max_order) return mem::OUT_OF_MEMORY~;

	sz found_order = -1;
	for (sz k = leaf_order; k <= self.max_order; k++)
	{
		if (self.free_heads[k])
		{
			found_order = k;
			break;
		}
	}
	if (found_order < 0) return mem::OUT_OF_MEMORY~;

	uptr block_start = (uptr)self.free_heads[found_order];
	self.free_heads[found_order] = self.free_heads[found_order].next;
	for (sz k = found_order; k > leaf_order; k--)
	{
		sz half = ((sz)BUDDY_MIN_BLOCK << (k - 1));
		uptr buddy_start = block_start + (uptr)half;
		BuddyFree* buddy = (BuddyFree*)buddy_start;
		buddy.next = self.free_heads[k - 1];
		self.free_heads[k - 1] = buddy;
	}

	sz leaf_size = ((sz)BUDDY_MIN_BLOCK << leaf_order);
	uptr payload_addr = allocator_payload_address(block_start, BuddyUsedHeader::size, effective);
	BuddyUsedHeader* header = (BuddyUsedHeader*)(payload_addr - BuddyUsedHeader::size);
	header.magic = BUDDY_BLOCK_MAGIC;
	header.owner = self;
	header.order = leaf_order;
	header.block_offset = (sz)(payload_addr - BuddyUsedHeader::size - block_start);
	header.requested_size = size;
	void* result = (void*)payload_addr;
	self.free_bytes -= leaf_size;
	allocator_fill_canary((char*)result + size, (sz)((block_start + (uptr)leaf_size) - (payload_addr + (uptr)size)));
	allocator_zero_if(result, size, init_type);
	return result;
}

<*
 Remove a buddy block from its order free list.

 @param [&inout] self : "The allocator owning the free lists"
 @param order : "The order list to search"
 @param block_start : "The block address to remove"
 @return "True when the block was present and removed"
*>
fn bool buddy_remove_free(BuddyAllocator* self, sz order, uptr block_start) @local
{
	BuddyFree** link = &self.free_heads[order];
	while (*link)
	{
		if ((uptr)*link == block_start)
		{
			*link = (*link).next;
			return true;
		}
		link = &(*link).next;
	}
	return false;
}

<*
 Release a buddy block, merging with its free buddy while possible.

 The buddy address comes from XOR with the block size, which works
 because every block is aligned to its size within the carved region.
 Null, foreign, interior, and duplicate releases are ignored.

 @param [&inout] self : "The allocator that owns the block"
 @param [drop] old_pointer : "The payload to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void BuddyAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	if (!old_pointer) return;

	BuddyUsedHeader* header = buddy_used_header(self, old_pointer);
	if (!header) return;

	uptr block_start = (uptr)header - (uptr)header.block_offset;
	sz order = header.order;
	sz block_size = ((sz)BUDDY_MIN_BLOCK << order);
	assert(allocator_canary_intact(
		(char*)old_pointer + header.requested_size,
		(sz)((block_start + (uptr)block_size) - ((uptr)old_pointer + (uptr)header.requested_size))
	), "Buddy trailing canary was corrupted before release.");

	allocator_poison_if_testing(old_pointer, header.requested_size);
	header.magic = 0;
	self.free_bytes += block_size;

	uptr merged_start = block_start;
	sz merged_order = order;
	sz merged_size = block_size;
	while (merged_order < self.max_order)
	{
		uptr buddy_start = merged_start ^ (uptr)merged_size;
		if (!buddy_remove_free(self, merged_order, buddy_start)) break;
		if (buddy_start < merged_start) merged_start = buddy_start;

		merged_order++;
		merged_size <<= 1;
	}

	BuddyFree* block = (BuddyFree*)merged_start;
	block.next = self.free_heads[merged_order];
	self.free_heads[merged_order] = block;
}

<*
 Check whether a payload's trailing canary is intact.

 @param [&in] self : "The allocator that owns the block"
 @param pointer : "A live payload pointer"
 @return "True when no bytes were written past the requested size"
*>
fn bool BuddyAllocator.canary_intact(&self, void* pointer)
{
	BuddyUsedHeader* header = buddy_used_header(self, pointer);
	if (!header) return false;

	uptr block_start = (uptr)header - (uptr)header.block_offset;
	sz block_size = ((sz)BUDDY_MIN_BLOCK << header.order);
	return allocator_canary_intact(
		(char*)pointer + header.requested_size,
		(sz)((block_start + (uptr)block_size) - ((uptr)pointer + (uptr)header.requested_size))
	);
}

<*
 Resize a block previously acquired from this allocator.

 The block shrinks in place when the smaller payload fits. Growth
 allocates a replacement first, copies the common prefix, and releases
 the old block only after the copy succeeds. On any failure the old
 block and allocator state remain unchanged.

 @param [&inout] self : "The allocator that owns the block"
 @param [drop] old_pointer : "The payload pointer to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero to use the default"
 @return "The resized payload, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? BuddyAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	if (!old_pointer || new_size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;

	BuddyUsedHeader* header = buddy_used_header(self, old_pointer);
	if (!header) return mem::INVALID_ALLOC_SIZE~;

	sz effective = allocator_effective_alignment(alignment);
	uptr header_addr = (uptr)header;
	uptr block_start = header_addr - (uptr)header.block_offset;
	sz block_size = ((sz)BUDDY_MIN_BLOCK << header.order);
	uptr old_addr = (uptr)old_pointer;
	if (old_addr < block_start) return mem::INVALID_ALLOC_SIZE~;

	sz max_fit = block_size - (sz)(old_addr - block_start);
	if (mem::ptr_is_aligned(old_pointer, effective) && new_size <= max_fit)
	{
		assert(allocator_canary_intact(
			(char*)old_pointer + header.requested_size,
			(sz)((block_start + (uptr)block_size) - ((uptr)old_pointer + (uptr)header.requested_size))
		), "Buddy trailing canary was corrupted before resize.");

		header.requested_size = new_size;
		allocator_fill_canary(
			(char*)old_pointer + new_size,
			(sz)((block_start + (uptr)block_size) - ((uptr)old_pointer + (uptr)new_size))
		);
		return old_pointer;
	}

	sz old_requested = header.requested_size;
	void*? replacement_opt = self.acquire(new_size, NO_ZERO, effective == mem::DEFAULT_MEM_ALIGNMENT ? 0 : effective);
	if (catch replacement_opt) return mem::OUT_OF_MEMORY~;

	void* replacement = replacement_opt;
	sz copy_size = old_requested < new_size ? old_requested : new_size;
	mem::copy(replacement, old_pointer, copy_size, mem::DEFAULT_MEM_ALIGNMENT, mem::DEFAULT_MEM_ALIGNMENT);
	self.release(old_pointer, alignment > mem::DEFAULT_MEM_ALIGNMENT);
	return replacement;
}
