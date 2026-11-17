module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

const FREE_LIST_BLOCK_MAGIC @local = 0xF2EEB10C5A11;

<*
 A variable-size free-list allocator over caller-owned memory.

 The allocator borrows its buffer and manages variable-size blocks with
 first-fit selection, splitting on allocate and coalescing on release.
 Released neighbours are merged, so freeing all allocations restores one
 contiguous free range (minus any initial alignment offset). The buffer must
 outlive the allocator and every pointer returned by it. This allocator is
 not thread-safe. Releasing or clearing the allocator never runs destructors.
*>
struct FreeListAllocator (Allocator) @mustinit
{
	char[] data;
	FreeListFreeBlock* free_head;
	sz free_bytes;
	bool best_fit;
}

<*
 Selection policy for `acquire`.

 FIRST FIT stops at the first range that fits: fastest, and pairs well
 with address-ordered release and coalescing. BEST FIT scans all ranges
 and picks the smallest fitting one: better for workloads with widely
 varying sizes, at the cost of a full scan on every miss.
*>
enum FreeListPolicy
{
	FIRST_FIT,
	BEST_FIT
}

<*
 Metadata for a free range. The node lives at the start of the free range,
 so `size` is the total byte count from this node through the end of the
 range.
*>
struct FreeListFreeBlock @local
{
	FreeListFreeBlock* next;
	sz size;
}

<*
 Header for a live allocation. The header sits immediately before the
 payload, so release and resize can locate it from the payload pointer
 alone. `block_offset` is the distance from the start of the whole block
 to this header, which lets release recover the block start including any
 leading alignment padding.
*>
struct FreeListUsedHeader @local
{
	ulong magic;
	FreeListAllocator* owner;
	sz block_size;
	sz block_offset;
	sz requested_size;
	bool in_use;
}

<*
 Initialize the free list over caller-owned storage.

 The buffer is borrowed, not copied. Its start is aligned up to the free
 block alignment; any leading bytes before that address stay reserved. When
 the usable remainder cannot hold a free node, the allocator starts empty
 and every acquisition fails until it is cleared over a larger buffer.
 Selection defaults to `FIRST_FIT`; switch with `set_policy`.

 @param [&out] self : "The allocator to initialize"
 @param storage : "The caller-owned buffer managed by this allocator"
 @return "A pointer to the initialized allocator"
*>
fn FreeListAllocator* FreeListAllocator.init(&self, char[] storage)
{
	self.data = storage;
	self.free_head = null;
	self.free_bytes = 0;
	self.best_fit = false;
	if (storage.len >= FreeListFreeBlock::size)
	{
		uptr base_addr = (uptr)storage.ptr;
		uptr block_align = (uptr)FreeListFreeBlock::alignment;
		uptr aligned_addr = (base_addr + block_align - 1) & ~(block_align - 1);
		if (aligned_addr >= base_addr)
		{
			sz offset = (sz)(aligned_addr - base_addr);
			if (offset <= storage.len && storage.len - offset >= FreeListFreeBlock::size)
			{
				FreeListFreeBlock* block = (FreeListFreeBlock*)aligned_addr;
				block.next = null;
				block.size = storage.len - offset;
				self.free_head = block;
				self.free_bytes = block.size;
			}
		}
	}
	return self;
}

<*
 Return the total size of the borrowed buffer in bytes.

 @param [&in] self : "The allocator to query"
 @return "The borrowed buffer length"
*>
fn sz FreeListAllocator.capacity(&self) => self.data.len;

<*
 Return the number of free bytes currently managed as free ranges.

 Free headers are counted as free because their ranges can be reused.
 Leading alignment waste from initialization is not counted as free.

 @param [&in] self : "The allocator to query"
 @return "The reclaimable free byte count"
*>
fn sz FreeListAllocator.bytes_free(&self) => self.free_bytes;

<*
 Return the number of borrowed bytes not currently free.

 This includes payloads, headers, padding, and any initial alignment
 offset. It is the complement of `bytes_free` within `capacity`.

 @param [&in] self : "The allocator to query"
 @return "The reserved byte count"
*>
fn sz FreeListAllocator.bytes_used(&self) => self.data.len - self.free_bytes;

<*
 Return the number of disjoint free ranges currently managed.

 A freshly cleared allocator has one range. Each split increases the count
 and each coalescing release decreases it. Comparing this with
 `largest_free` shows whether free bytes are contiguous enough for a large
 request.

 @param [&in] self : "The allocator to query"
 @return "The free range count"
*>
fn sz FreeListAllocator.free_block_count(&self)
{
	sz count = 0;
	FreeListFreeBlock* block = self.free_head;
	while (block)
	{
		count++;
		block = block.next;
	}
	return count;
}

<*
 Return the largest single contiguous free range in bytes.

 Allocations larger than this fail even when `bytes_free` is bigger,
 because first-fit selection cannot span ranges. After freeing everything,
 this equals `bytes_free`.

 @param [&in] self : "The allocator to query"
 @return "The largest free range byte count, or zero when full"
*>
fn sz FreeListAllocator.largest_free(&self)
{
	sz largest = 0;
	FreeListFreeBlock* block = self.free_head;
	while (block)
	{
		if (block.size > largest) largest = block.size;
		block = block.next;
	}
	return largest;
}

<*
 Check whether a pointer is a live allocation of this allocator.

 The check validates the allocation header, so only exact payload pointers
 report true; interior and foreign pointers report false.

 @param [&in] self : "The allocator to validate against"
 @param pointer : "A candidate payload pointer"
 @return "True when the pointer is a live payload of this allocator"
*>
fn bool FreeListAllocator.owns(&self, void* pointer) => freelist_used_header((FreeListAllocator*)self, pointer) != null;

<*
 Discard all allocations and restore one contiguous free range.

 The borrowed buffer is retained. Pointers returned before the call must
 not be used afterwards. No memory is cleared and no destructors run.

 @param [&inout] self : "The allocator to clear"
*>
fn void FreeListAllocator.clear(&self)
{
	self.free_head = null;
	self.free_bytes = 0;
	if (self.data.len >= FreeListFreeBlock::size && self.data.ptr)
	{
		uptr base_addr = (uptr)self.data.ptr;
		uptr block_align = (uptr)FreeListFreeBlock::alignment;
		uptr aligned_addr = (base_addr + block_align - 1) & ~(block_align - 1);
		if (aligned_addr >= base_addr)
		{
			sz offset = (sz)(aligned_addr - base_addr);
			if (offset <= self.data.len && self.data.len - offset >= FreeListFreeBlock::size)
			{
				FreeListFreeBlock* block = (FreeListFreeBlock*)aligned_addr;
				block.next = null;
				block.size = self.data.len - offset;
				self.free_head = block;
				self.free_bytes = block.size;
			}
		}
	}
}

<*
 Validate a payload pointer and return its allocation header.

 @param [&in] self : "The allocator that may own the pointer"
 @param pointer : "A candidate payload pointer"
 @return "The live header for an exact payload pointer, or null"
*>
fn FreeListUsedHeader* freelist_used_header(FreeListAllocator* self, void* pointer) @local
{
	if (!pointer || !self.data.ptr) return null;
	if (self.data.len < FreeListUsedHeader::size) return null;

	uptr base_addr = (uptr)self.data.ptr;
	uptr pointer_addr = (uptr)pointer;
	if (pointer_addr < base_addr) return null;
	if (pointer_addr - base_addr < (uptr)FreeListUsedHeader::size) return null;
	if (pointer_addr - base_addr >= (uptr)self.data.len) return null;

	FreeListUsedHeader* header = pointer - FreeListUsedHeader::size;
	if (header.magic != FREE_LIST_BLOCK_MAGIC) return null;
	if (header.owner != self) return null;
	if (!header.in_use) return null;
	if ((void*)((char*)header + FreeListUsedHeader::size) != pointer) return null;

	uptr header_addr = (uptr)header;
	if (header.block_offset > header.block_size) return null;
	if (header_addr < base_addr + (uptr)header.block_offset) return null;

	uptr block_start = header_addr - (uptr)header.block_offset;
	if (!allocator_contains(base_addr, self.data.len, block_start, header.block_size)) return null;
	if (header.requested_size > header.block_size) return null;
	return header;
}

<*
 Insert a free range into the address-ordered free list and coalesce neighbours.

 The caller accounts `size` in `free_bytes` before calling. Adjacent ranges
 before and after the inserted range are merged when they touch exactly.

 @param [&inout] self : "The allocator receiving the free range"
 @param start : "The start of the range to insert"
 @param size : "The byte count of the range to insert"
*>
fn void freelist_insert_coalesce(FreeListAllocator* self, void* start, sz size) @local
{
	FreeListFreeBlock* node = (FreeListFreeBlock*)start;
	node.next = null;
	node.size = size;
	uptr node_addr = (uptr)start;
	FreeListFreeBlock** link = &self.free_head;
	while (*link && (uptr)*link < node_addr)
	{
		link = &(*link).next;
	}

	node.next = *link;
	*link = node;
	if (node.next && node_addr + (uptr)node.size == (uptr)node.next)
	{
		node.size += node.next.size;
		node.next = node.next.next;
	}
	if (link != &self.free_head)
	{
		FreeListFreeBlock* prev = self.free_head;
		while (prev && prev.next != node) prev = prev.next;
		if (prev && (uptr)prev + (uptr)prev.size == node_addr)
		{
			prev.size += node.size;
			prev.next = node.next;
		}
	}
}

<*
 Set the range selection policy.

 @param [&inout] self : "The allocator to retune"
 @param policy : "`FIRST_FIT` or `BEST_FIT`"
*>
fn void FreeListAllocator.set_policy(&self, FreeListPolicy policy) => self.best_fit = policy == BEST_FIT;

<*
 Acquire a variable-size block using the configured selection policy.

 The payload meets `alignment`, or the default C3 alignment when zero.
 `ZERO` clears only the requested payload bytes. A free range is split when
 the remainder can still hold a free node; otherwise the whole range is used.
 `FIRST_FIT` stops at the first fitting range; `BEST_FIT` scans all ranges
 and picks the smallest fitting one. Failure leaves allocator state unchanged.

 @param [&inout] self : "The allocator to allocate from"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the payload bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero to use the default"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? FreeListAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	if (size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (!self.free_head || !self.data.ptr) return mem::OUT_OF_MEMORY~;

	sz effective = allocator_effective_alignment(alignment);
	if (effective < FreeListFreeBlock::alignment) effective = FreeListFreeBlock::alignment;
	if (effective < FreeListUsedHeader::alignment) effective = FreeListUsedHeader::alignment;
	if (size > sz::max - FreeListUsedHeader::size - effective) return mem::INVALID_ALLOC_SIZE~;

	uptr eff = (uptr)effective;
	FreeListFreeBlock** chosen_link = null;
	FreeListFreeBlock* chosen_free = null;
	FreeListFreeBlock* chosen_next = null;
	FreeListFreeBlock** link = &self.free_head;
	while (*link)
	{
		FreeListFreeBlock* free = *link;
		uptr start = (uptr)free;
		sz free_size = free.size;
		FreeListFreeBlock* free_next = free.next;
		if (free_size >= FreeListUsedHeader::size)
		{
			uptr header_min = start + (uptr)FreeListUsedHeader::size;
			if (header_min >= start && header_min <= uptr::max - (eff - 1))
			{
				uptr payload_addr = (header_min + eff - 1) & ~(eff - 1);
				if (payload_addr >= header_min && payload_addr >= start)
				{
					uptr payload_offset = payload_addr - start;
					if (payload_offset <= (uptr)sz::max && size <= sz::max - (sz)payload_offset)
					{
						sz total_needed = (sz)payload_offset + size;
						if (free_size >= total_needed)
						{
							if (!self.best_fit)
							{
								chosen_link = link;
								chosen_free = free;
								chosen_next = free_next;
								break;
							}
							if (!chosen_free || free_size < chosen_free.size)
							{
								chosen_link = link;
								chosen_free = free;
								chosen_next = free_next;
							}
						}
					}
				}
			}
		}
		link = &(*link).next;
	}
	if (!chosen_free) return mem::OUT_OF_MEMORY~;

	uptr start = (uptr)chosen_free;
	uptr payload_addr = (start + (uptr)FreeListUsedHeader::size + eff - 1) & ~(eff - 1);
	uptr payload_offset = payload_addr - start;
	sz free_size = chosen_free.size;
	sz alloc_size = allocator_split_size(
		(sz)payload_offset + size,
		FreeListFreeBlock::alignment,
		free_size,
		FreeListFreeBlock::size
	);

	bool split = alloc_size != free_size;
	uptr header_addr = payload_addr - (uptr)FreeListUsedHeader::size;
	FreeListUsedHeader* header = (FreeListUsedHeader*)header_addr;
	header.magic = FREE_LIST_BLOCK_MAGIC;
	header.owner = self;
	header.block_size = alloc_size;
	header.block_offset = (sz)(header_addr - start);
	header.requested_size = size;
	header.in_use = true;
	void* result = (void*)payload_addr;
	if (split)
	{
		void* rest = (void*)(start + (uptr)alloc_size);
		*chosen_link = (FreeListFreeBlock*)rest;
		(*chosen_link).next = chosen_next;
		(*chosen_link).size = free_size - alloc_size;
		self.free_bytes -= alloc_size;
	}
	else
	{
		*chosen_link = chosen_next;
		self.free_bytes -= free_size;
	}

	allocator_fill_canary((char*)result + size, (sz)(start + (uptr)alloc_size) - ((sz)payload_addr + size));
	allocator_zero_if(result, size, init_type);
	return result;
}

<*
 Resize a block previously acquired from this allocator.

 The common prefix is preserved. A block grows in place when the payload
 already meets the requested alignment and either fits in its current range
 or can absorb an immediately adjacent free range. It shrinks in place when
 the smaller payload fits, splitting the tail when the remainder can hold a
 free node. Otherwise a replacement is acquired first and the old contents
 are copied; the old block is released only after the copy succeeds. On any
 failure the old block and allocator state remain unchanged.

 @param [&inout] self : "The allocator that owns the block"
 @param [drop] old_pointer : "The payload pointer to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero to use the default"
 @return "The resized payload, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? FreeListAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	if (!old_pointer || new_size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;

	FreeListUsedHeader* header = freelist_used_header(self, old_pointer);
	if (!header) return mem::INVALID_ALLOC_SIZE~;

	sz effective = allocator_effective_alignment(alignment);
	if (effective < FreeListFreeBlock::alignment) effective = FreeListFreeBlock::alignment;

	uptr old_addr = (uptr)old_pointer;
	uptr header_addr = (uptr)header;
	uptr block_start = header_addr - (uptr)header.block_offset;
	sz block_size = header.block_size;
	sz old_requested = header.requested_size;
	uptr payload_offset = old_addr - block_start;
	if (payload_offset > (uptr)block_size) return mem::INVALID_ALLOC_SIZE~;

	sz max_fit = block_size - (sz)payload_offset;
	if (mem::ptr_is_aligned(old_pointer, effective))
	{
		if (new_size <= max_fit)
		{
			assert(allocator_canary_intact(
				(char*)old_pointer + old_requested,
				(sz)(block_start + (uptr)block_size) - ((sz)old_addr + old_requested)
			), "Free-list trailing canary was corrupted before resize.");

			sz total_needed = (sz)payload_offset + new_size;
			sz alloc_size = allocator_split_size(
				total_needed,
				FreeListFreeBlock::alignment,
				block_size,
				FreeListFreeBlock::size
			);
			if (alloc_size != block_size)
			{
				void* tail = (void*)(block_start + (uptr)alloc_size);
				sz tail_size = block_size - alloc_size;
				header.block_size = alloc_size;
				header.requested_size = new_size;
				self.free_bytes += tail_size;
				freelist_insert_coalesce(self, tail, tail_size);
			}
			else
			{
				header.requested_size = new_size;
			}

			allocator_fill_canary(
				(char*)old_pointer + new_size,
				(sz)(block_start + (uptr)header.block_size) - ((sz)old_addr + new_size)
			);
			return old_pointer;
		}

		uptr block_end = block_start + (uptr)block_size;
		FreeListFreeBlock** link = &self.free_head;
		while (*link)
		{
			FreeListFreeBlock* free = *link;
			uptr free_start = (uptr)free;
			if (free_start == block_end)
			{
				sz combined = block_size + free.size;
				if (combined >= block_size && payload_offset <= (uptr)combined
					&& combined - (sz)payload_offset >= new_size)
				{
					assert(allocator_canary_intact(
						(char*)old_pointer + old_requested,
						(sz)(block_start + (uptr)block_size) - ((sz)old_addr + old_requested)
					), "Free-list trailing canary was corrupted before resize.");

					sz total_needed = (sz)payload_offset + new_size;
					sz alloc_size = allocator_split_size(
						total_needed,
						FreeListFreeBlock::alignment,
						combined,
						FreeListFreeBlock::size
					);

					FreeListFreeBlock* next = free.next;
					*link = next;
					self.free_bytes -= free.size;
					if (alloc_size != combined)
					{
						void* tail = (void*)(block_start + (uptr)alloc_size);
						sz tail_size = combined - alloc_size;
						header.block_size = alloc_size;
						header.requested_size = new_size;
						self.free_bytes += tail_size;
						freelist_insert_coalesce(self, tail, tail_size);
					}
					else
					{
						header.block_size = combined;
						header.requested_size = new_size;
					}

					allocator_fill_canary(
						(char*)old_pointer + new_size,
						(sz)(block_start + (uptr)header.block_size) - ((sz)old_addr + new_size)
					);
					return old_pointer;
				}
				break;
			}
			if (free_start > block_end) break;
			link = &(*link).next;
		}
	}

	void*? replacement_opt = self.acquire(new_size, NO_ZERO, effective == mem::DEFAULT_MEM_ALIGNMENT ? 0 : effective);
	if (catch replacement_opt) return mem::OUT_OF_MEMORY~;

	void* replacement = replacement_opt;
	sz copy_size = old_requested < new_size ? old_requested : new_size;
	mem::copy(replacement, old_pointer, copy_size, mem::DEFAULT_MEM_ALIGNMENT, mem::DEFAULT_MEM_ALIGNMENT);
	self.release(old_pointer, alignment > mem::DEFAULT_MEM_ALIGNMENT);
	return replacement;
}

<*
 Release a block acquired from this allocator.

 The range is inserted back into the address-ordered free list and merged
 with adjacent free neighbours. Null, foreign, interior, and duplicate
 releases are ignored. The `aligned` argument satisfies the Allocator
 interface; alignment is recovered from the allocation header.

 @param [&inout] self : "The allocator that owns the block"
 @param [drop] old_pointer : "The payload to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void FreeListAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	if (!old_pointer) return;

	(void)aligned;
	FreeListUsedHeader* header = freelist_used_header(self, old_pointer);
	if (!header) return;

	uptr header_addr = (uptr)header;
	uptr block_start = header_addr - (uptr)header.block_offset;
	sz block_size = header.block_size;
	if (block_size < FreeListFreeBlock::size) return;

	assert(allocator_canary_intact(
		(char*)old_pointer + header.requested_size,
		(sz)((block_start + (uptr)block_size) - ((uptr)old_pointer + (uptr)header.requested_size))
	), "Free-list trailing canary was corrupted before release.");

	allocator_poison_if_testing(old_pointer, header.requested_size);
	header.in_use = false;
	header.magic = 0;
	self.free_bytes += block_size;
	freelist_insert_coalesce(self, (void*)block_start, block_size);
}

<*
 Check whether a payload's trailing canary is intact.

 @param [&in] self : "The allocator that owns the block"
 @param pointer : "A live payload pointer"
 @return "True when no bytes were written past the requested size"
*>
fn bool FreeListAllocator.canary_intact(&self, void* pointer)
{
	FreeListUsedHeader* header = freelist_used_header(self, pointer);
	if (!header) return false;

	uptr block_start = (uptr)header - (uptr)header.block_offset;
	return allocator_canary_intact(
		(char*)pointer + header.requested_size,
		(sz)((block_start + (uptr)header.block_size) - ((uptr)pointer + (uptr)header.requested_size))
	);
}
