module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

const FREE_LIST_BLOCK_MAGIC @local = 0xF2EEB10C5A11;
const FREE_LIST_NODE_MAGIC @local = 0xF2EE0C5A11F2EE;
const FREE_LIST_FOOTER_MAGIC @local = 0xF0075A110C5AF2EE;

<*
 A variable-size free-list allocator over caller-owned memory.

 The allocator borrows its buffer and manages variable-size blocks with
 first-fit or best-fit selection, splitting on allocate and coalescing on
 release. The free list is doubly linked and kept in most-recently-freed
 order, and every free range carries a boundary footer at its end storing
 the range size, following the classic Knuth boundary-tag design. Release
 therefore finds and merges free neighbours in constant time by reading the
 footer before the block and the node after it, instead of walking an
 address-ordered list.

 A free range costs 48 bytes: the 32-byte list node at its start and a
 16-byte footer at its end, so ranges smaller than that are consumed whole
 rather than split. The footer is only trusted together with the node at
 the implied range start, which makes false matches from user data
 vanishingly unlikely. Fully freeing the allocator restores one contiguous
 range (minus any initial alignment offset). The buffer must outlive the
 allocator and every pointer returned by it. This allocator is not
 thread-safe and never runs destructors.
*>
struct FreeListAllocator (Allocator) @mustinit
{
	char[] data;
	FreeListFreeBlock* free_head;
	sz free_bytes;
	bool best_fit;
}

<*
 Metadata for a free range. The node lives at the start of the free range
 and the list is doubly linked in most-recently-freed order, so unlinking
 during a merge is constant time. The footer at the range end mirrors the
 size and is what the next block's release reads to find this range.
*>
struct FreeListFreeBlock @local
{
	ulong magic;
	FreeListFreeBlock* next;
	FreeListFreeBlock* previous;
	sz size;
}

<*
 The boundary footer at the end of a free range. Its size lets a later
 release of the following block find this range's start in constant time.
*>
struct FreeListFooter @local
{
	ulong magic;
	sz size;
}

const FREE_LIST_MIN_RANGE @local = FreeListFreeBlock::size + FreeListFooter::size;

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
 Selection policy for `acquire`.

 FIRST FIT stops at the first range that fits: fastest, and pairs well
 with the boundary-tag release path. BEST FIT scans all ranges and picks
 the smallest fitting one, breaking ties by lower address: better for
 workloads with widely varying sizes, at the cost of a full scan on every
 miss.
*>
enum FreeListPolicy
{
	FIRST_FIT,
	BEST_FIT
}

<*
 Initialize the free list over caller-owned storage.

 The buffer is borrowed, not copied. Its start is aligned up to the free
 block alignment; any leading bytes before that address stay reserved. When
 the usable remainder cannot hold a free node plus its footer, the
 allocator starts empty and every acquisition fails until it is cleared
 over a larger buffer. Selection defaults to `FIRST_FIT`; switch with
 `set_policy`.

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
	if (storage.len >= FREE_LIST_MIN_RANGE && storage.ptr)
	{
		uptr base_addr = (uptr)storage.ptr;
		uptr block_align = (uptr)FreeListFreeBlock::alignment;
		uptr aligned_addr = (base_addr + block_align - 1) & ~(block_align - 1);
		if (aligned_addr >= base_addr)
		{
			sz offset = (sz)(aligned_addr - base_addr);
			if (offset <= storage.len && storage.len - offset >= FREE_LIST_MIN_RANGE)
			{
				sz range = storage.len - offset;
				FreeListFreeBlock* node = (FreeListFreeBlock*)aligned_addr;
				node.magic = FREE_LIST_NODE_MAGIC;
				node.next = null;
				node.previous = null;
				node.size = range;
				self.free_head = node;
				FreeListFooter* footer = (FreeListFooter*)(aligned_addr + (uptr)range - (uptr)FreeListFooter::size);
				footer.magic = FREE_LIST_FOOTER_MAGIC;
				footer.size = range;
				self.free_bytes = range;
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
 because selection cannot span ranges. After freeing everything, this
 equals `bytes_free`.

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
 Set the range selection policy.

 @param [&inout] self : "The allocator to retune"
 @param policy : "`FIRST_FIT` or `BEST_FIT`"
*>
fn void FreeListAllocator.set_policy(&self, FreeListPolicy policy) => self.best_fit = policy == BEST_FIT;

<*
 Unlink a free range from the doubly linked free list.

 @param [&inout] self : "The allocator owning the free list"
 @param block : "The range node to unlink"
*>
fn void freelist_unlink(FreeListAllocator* self, FreeListFreeBlock* block) @local
{
	FreeListFreeBlock* next = block.next;
	FreeListFreeBlock* previous = block.previous;
	if (previous)
	{
		previous.next = next;
	}
	else
	{
		self.free_head = next;
	}
	if (next)
	{
		next.previous = previous;
	}
}

<*
 Push a free range onto the head of the free list.

 @param [&inout] self : "The allocator owning the free list"
 @param block : "The initialized range node to push"
*>
fn void freelist_push(FreeListAllocator* self, FreeListFreeBlock* block) @local
{
	block.next = self.free_head;
	block.previous = null;
	if (self.free_head) self.free_head.previous = block;
	self.free_head = block;
}

<*
 Publish a free range: merge with free neighbours through the boundary
 tags, then link the merged range with its node and footer.

 The backward neighbour is found through the footer preceding the range
 and validated against the node at the implied start; the forward
 neighbour is checked through the node magic at the range end. Both
 neighbours are unlinked before the merged range is pushed, so every
 release is constant time regardless of list length.

 @param [&inout] self : "The allocator publishing the range"
 @param start : "The start of the newly freed range"
 @param size : "The byte count of the newly freed range"
*>
fn void freelist_publish(FreeListAllocator* self, void* start, sz size) @local
{
	uptr base_addr = (uptr)self.data.ptr;
	uptr buffer_end = base_addr + (uptr)self.data.len;
	uptr merged_start = (uptr)start;
	sz merged_size = size;
	if (merged_start >= base_addr + (uptr)FreeListFooter::size)
	{
		FreeListFooter* footer = (FreeListFooter*)(merged_start - (uptr)FreeListFooter::size);
		if (footer.magic == FREE_LIST_FOOTER_MAGIC)
		{
			uptr previous_start = merged_start - (uptr)footer.size;
			FreeListFreeBlock* previous = (FreeListFreeBlock*)previous_start;
			if (previous.magic == FREE_LIST_NODE_MAGIC && previous.size == footer.size)
			{
				freelist_unlink(self, previous);
				merged_start = previous_start;
				merged_size += footer.size;
				// The merged range's own footer now lives at its new end;
				// the previous range's footer is interior stale data.
				footer.magic = 0;
				footer.size = 0;
			}
		}
	}

	uptr merged_end = merged_start + (uptr)merged_size;
	if (merged_end + (uptr)FreeListFreeBlock::size <= buffer_end)
	{
		FreeListFreeBlock* next = (FreeListFreeBlock*)merged_end;
		if (next.magic == FREE_LIST_NODE_MAGIC)
		{
			freelist_unlink(self, next);
			// The absorbed range's footer is interior stale data now.
			FreeListFooter* absorbed = (FreeListFooter*)(merged_end + (uptr)next.size - (uptr)FreeListFooter::size);
			absorbed.magic = 0;
			absorbed.size = 0;
			merged_size += next.size;
		}
	}

	FreeListFreeBlock* node = (FreeListFreeBlock*)merged_start;
	node.magic = FREE_LIST_NODE_MAGIC;
	node.size = merged_size;
	node.next = null;
	node.previous = null;
	freelist_push(self, node);
	FreeListFooter* footer = (FreeListFooter*)(merged_start + (uptr)merged_size - (uptr)FreeListFooter::size);
	footer.magic = FREE_LIST_FOOTER_MAGIC;
	footer.size = merged_size;
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
 Acquire a variable-size block using the configured selection policy.

 The payload meets `alignment`, or the default C3 alignment when zero.
 `ZERO` clears only the requested payload bytes. A free range is split when
 the remainder can still hold a free node and its footer; otherwise the
 whole range is used, consuming its boundary footer. `FIRST_FIT` stops at
 the first fitting range in most-recently-freed order; `BEST_FIT` scans all
 ranges and picks the smallest fitting one, breaking ties by lower
 address. Failure leaves allocator state unchanged.

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
	FreeListFreeBlock* chosen = null;
	FreeListFreeBlock* cursor = self.free_head;
	while (cursor)
	{
		uptr start = (uptr)cursor;
		sz free_size = cursor.size;
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
								chosen = cursor;
								break;
							}
							if (!chosen || free_size < chosen.size
								|| (free_size == chosen.size && start < (uptr)chosen))
							{
								chosen = cursor;
							}
						}
					}
				}
			}
		}
		cursor = cursor.next;
	}
	if (!chosen) return mem::OUT_OF_MEMORY~;
	freelist_unlink(self, chosen);
	// The chosen range's node bytes would otherwise linger inside the used
	// block and later reads (a release's forward check) could mistake them
	// for a live free node.
	chosen.magic = 0;

	uptr start = (uptr)chosen;
	uptr payload_addr = (start + (uptr)FreeListUsedHeader::size + eff - 1) & ~(eff - 1);
	uptr payload_offset = payload_addr - start;
	sz free_size = chosen.size;
	sz alloc_size = allocator_split_size(
		(sz)payload_offset + size,
		FreeListFreeBlock::alignment,
		free_size,
		FREE_LIST_MIN_RANGE
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
		// The consumed range's footer at the old end is stale; the
		// remainder gets a fresh one at the same address.
		FreeListFooter* old_footer = (FreeListFooter*)(start + (uptr)free_size - (uptr)FreeListFooter::size);
		old_footer.magic = 0;
		old_footer.size = 0;
		void* rest = (void*)(start + (uptr)alloc_size);
		freelist_publish(self, rest, free_size - alloc_size);
		self.free_bytes -= alloc_size;
	}
	else
	{
		// The consumed range's boundary footer would otherwise linger as
		// stale data inside the used block. Only clear it when it does not
		// overlap the used header's own tail fields.
		if (free_size >= (sz)FreeListFooter::size && free_size - (sz)FreeListFooter::size >= (sz)payload_offset)
		{
			FreeListFooter* stale = (FreeListFooter*)(start + (uptr)free_size - (uptr)FreeListFooter::size);
			stale.magic = 0;
			stale.size = 0;
		}
		self.free_bytes -= free_size;
	}

	allocator_fill_canary((char*)result + size, (sz)((start + (uptr)alloc_size) - (payload_addr + (uptr)size)));
	allocator_zero_if(result, size, init_type);
	return result;
}

<*
 Resize a block previously acquired from this allocator.

 The common prefix is preserved. A block grows in place when the payload
 already meets the requested alignment and either fits in its current range
 or can absorb an immediately adjacent free range, which the boundary node
 at the block end identifies in constant time. It shrinks in place when the
 smaller payload fits, publishing the tail as a free range. Otherwise a
 replacement is acquired first and the old contents are copied; the old
 block is released only after the copy succeeds. On any failure the old
 block and allocator state remain unchanged.

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
				(sz)((block_start + (uptr)block_size) - ((uptr)old_addr + (uptr)old_requested))
			), "Free-list trailing canary was corrupted before resize.");

			sz total_needed = (sz)payload_offset + new_size;
			sz alloc_size = allocator_split_size(
				total_needed,
				FreeListFreeBlock::alignment,
				block_size,
				FREE_LIST_MIN_RANGE
			);
			if (alloc_size != block_size)
			{
				void* tail = (void*)(block_start + (uptr)alloc_size);
				sz tail_size = block_size - alloc_size;
				header.block_size = alloc_size;
				header.requested_size = new_size;
				self.free_bytes += tail_size;
				freelist_publish(self, tail, tail_size);
			}
			else
			{
				header.requested_size = new_size;
			}

			allocator_fill_canary(
				(char*)old_pointer + new_size,
				(sz)((block_start + (uptr)header.block_size) - ((uptr)old_addr + (uptr)new_size))
			);
			return old_pointer;
		}

		uptr block_end = block_start + (uptr)block_size;
		uptr buffer_end = (uptr)self.data.ptr + (uptr)self.data.len;
		if (block_end + (uptr)FreeListFreeBlock::size <= buffer_end)
		{
			FreeListFreeBlock* next = (FreeListFreeBlock*)block_end;
			if (next.magic == FREE_LIST_NODE_MAGIC && block_size <= sz::max - next.size)
			{
				sz combined = block_size + next.size;
				if (combined - (sz)payload_offset >= new_size)
				{
					assert(allocator_canary_intact(
						(char*)old_pointer + old_requested,
						(sz)((block_start + (uptr)block_size) - ((uptr)old_addr + (uptr)old_requested))
					), "Free-list trailing canary was corrupted before resize.");

					freelist_unlink(self, next);
					self.free_bytes -= next.size;
					sz total_needed = (sz)payload_offset + new_size;
					sz alloc_size = allocator_split_size(
						total_needed,
						FreeListFreeBlock::alignment,
						combined,
						FREE_LIST_MIN_RANGE
					);

					if (alloc_size != combined)
					{
						void* tail = (void*)(block_start + (uptr)alloc_size);
						sz tail_size = combined - alloc_size;
						header.block_size = alloc_size;
						header.requested_size = new_size;
						self.free_bytes += tail_size;
						freelist_publish(self, tail, tail_size);
					}
					else
					{
						header.block_size = combined;
						header.requested_size = new_size;
					}

					allocator_fill_canary(
						(char*)old_pointer + new_size,
						(sz)((block_start + (uptr)header.block_size) - ((uptr)old_addr + (uptr)new_size))
					);
					return old_pointer;
				}
			}
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

 The range is published through its boundary tags, merging with free
 neighbours in constant time. Null, foreign, interior, and duplicate
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
	freelist_publish(self, (void*)block_start, block_size);
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
	if (self.data.len >= FREE_LIST_MIN_RANGE && self.data.ptr)
	{
		uptr base_addr = (uptr)self.data.ptr;
		uptr block_align = (uptr)FreeListFreeBlock::alignment;
		uptr aligned_addr = (base_addr + block_align - 1) & ~(block_align - 1);
		if (aligned_addr >= base_addr)
		{
			sz offset = (sz)(aligned_addr - base_addr);
			if (offset <= self.data.len && self.data.len - offset >= FREE_LIST_MIN_RANGE)
			{
				sz range = self.data.len - offset;
				FreeListFreeBlock* node = (FreeListFreeBlock*)aligned_addr;
				node.magic = FREE_LIST_NODE_MAGIC;
				node.next = null;
				node.previous = null;
				node.size = range;
				self.free_head = node;
				FreeListFooter* footer = (FreeListFooter*)(aligned_addr + (uptr)range - (uptr)FreeListFooter::size);
				footer.magic = FREE_LIST_FOOTER_MAGIC;
				footer.size = range;
				self.free_bytes = range;
			}
		}
	}
}
