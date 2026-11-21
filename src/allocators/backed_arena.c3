module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;
import std::math;

const BACKED_ARENA_HEADER_MAGIC @local = 0xBAA2E_A11C0C;

<*
 A growable arena that starts in a caller-owned buffer and obtains overflow
 payloads and descriptors from a backing allocator.

 The initial buffer is borrowed. Overflow allocations are owned by this arena
 and released by reset/clear or free. The arena and its backing allocator are
 not thread-safe.
*>
struct BackedArenaAllocator (Allocator) @mustinit
{
	char[] initial_data;
	Allocator backing_allocator;
	BackedArenaHeader* last_initial_header;
	BackedArenaPage* pages;
	BackedArenaPage* page_pool;
	sz initial_used;
	sz next_sequence;
	sz initial_total;
	sz overflow_total;
	sz pooled_count;
}

struct BackedArenaHeader @local
{
	ulong magic;
	BackedArenaAllocator* owner;
	BackedArenaHeader* previous;
	sz previous_used;
	sz sequence;
	sz size;
	void* payload;
	bool in_use;
}

struct BackedArenaPage @local
{
	BackedArenaPage* next;
	void* descriptor_block;
	void* payload;
	sz requested_size;
	sz sequence;
	sz allocation_alignment;
	sz block_size;
}

<*
 Initialize a growable arena with borrowed initial storage and a backing allocator.

 Allocations first use the supplied buffer. When it cannot satisfy a request,
 the arena obtains an overflow block from `backing_allocator`. Overflow blocks
 are owned by the arena and freed by `reset`, `clear`, or `free`.

 @param [&out] self : "The arena to initialize"
 @param initial_data : "The borrowed first buffer; it may be empty"
 @param backing_allocator : "Allocator used to obtain overflow blocks"
 @return "A pointer to the initialized arena"
*>
fn BackedArenaAllocator* BackedArenaAllocator.init(&self, char[] initial_data, Allocator backing_allocator)
{
	self.initial_data = initial_data;
	self.backing_allocator = backing_allocator;
	self.last_initial_header = null;
	self.pages = null;
	self.page_pool = null;
	self.initial_used = 0;
	self.next_sequence = 1;
	self.initial_total = 0;
	self.overflow_total = 0;
	self.pooled_count = 0;
	return self;
}

<*
 Return a mark representing the current allocation position.

 Marks are positions in this arena's allocation history, not identities of
 specific allocations. A mark remains usable after resetting to it, and may
 be reused to discard newer allocations again. If the arena is rewound and
 new allocations are made, an older mark at the same position now refers to
 the new history; resetting to it discards allocations made after that
 position. A mark must come from this arena and must not be ahead of the
 current position. Marks from another arena must not be used. This matches
 the positional mark/reset style used by the standard library arenas.

 @param [&in] self : "The arena to mark"
 @return "A mark for the current allocation position"
*>
fn sz BackedArenaAllocator.mark(&self) => self.next_sequence - 1;

<*
 Return the number of live overflow blocks owned by this arena.

 @param [&in] self : "The arena to inspect"
 @return "The live overflow-block count"
*>
fn sz BackedArenaAllocator.overflow_count(&self)
{
	sz count = 0;
	BackedArenaPage* page = self.pages;
	while (page)
	{
		count++;
		page = page.next;
	}
	return count;
}

<*
 Return the total requested payload size of all live allocations.

 This excludes headers, alignment padding, and backing allocator overhead.

 @param [&in] self : "The arena to inspect"
 @return "The number of live requested payload bytes"
*>
fn sz BackedArenaAllocator.bytes_used(&self)
{
	sz total = 0;
	BackedArenaHeader* header = self.last_initial_header;
	while (header)
	{
		if (header.in_use) total += header.size;
		header = header.previous;
	}

	BackedArenaPage* page = self.pages;
	while (page)
	{
		total += page.requested_size;
		page = page.next;
	}
	return total;
}

<*
 Return the number of bytes consumed in the borrowed initial buffer, including
 allocation headers and alignment padding.

 @param [&in] self : "The arena to inspect"
 @return "The current initial-buffer position"
*>
fn sz BackedArenaAllocator.initial_bytes_reserved(&self) => self.initial_used;

<*
 Return how many allocations were served from the borrowed initial buffer.

 This is a lifetime count, unaffected by `reset` or `clear`. Compare with
 `overflow_served` to see whether the initial buffer is well sized: a high
 overflow share means most requests miss the fast path.

 @param [&in] self : "The arena to query"
 @return "The lifetime initial-buffer allocation count"
*>
fn sz BackedArenaAllocator.initial_served(&self) => self.initial_total;

<*
 Return how many allocations were served as overflow blocks.

 This is a lifetime count, unaffected by `reset` or `clear`.

 @param [&in] self : "The arena to query"
 @return "The lifetime overflow allocation count"
*>
fn sz BackedArenaAllocator.overflow_served(&self) => self.overflow_total;

<*
 Return the number of overflow pages parked in the reuse pool.

 Pages enter the pool through `reset_retaining` and leave it when a new
 overflow request reuses one, or when `prune_pool` or `free` drains it.
 Pooled pages still count against the backing allocator's live memory.

 @param [&in] self : "The arena to query"
 @return "The pooled page count"
*>
fn sz BackedArenaAllocator.page_pool_count(&self) => self.pooled_count;

<*
 Return every pooled overflow page to the backing allocator.

 @param [&inout] self : "The arena whose pool is drained"
*>
fn void BackedArenaAllocator.prune_pool(&self)
{
	while (self.page_pool)
	{
		BackedArenaPage* page = self.page_pool;
		self.page_pool = page.next;
		self.pooled_count--;
		backed_arena_free_page(self.backing_allocator, page);
	}
}

<*
 Check whether a pointer is a live allocation of this arena.

 The check validates the initial-buffer header or overflow page payload, so
 only exact payload pointers report true; interior and foreign pointers
 report false.

 @param [&in] self : "The arena to validate against"
 @param pointer : "A candidate payload pointer"
 @return "True when the pointer is a live payload of this arena"
*>
fn bool BackedArenaAllocator.owns(&self, void* pointer)
{
	if (!pointer) return false;
	if (backed_arena_initial_header(self, pointer)) return true;
	return backed_arena_find_page_link(self, pointer) != null;
}

<*
 Reset to a mark, invalidating allocations made after it.

 Overflow blocks created after the mark are returned to the backing allocator.
 Initial-buffer allocations made after the mark are rewound. Allocations freed
 before reset are not resurrected. Resetting to the same mark repeatedly is
 allowed. Because marks are positional, resetting to an older mark after new
 allocations were made discards those newer allocations. This does not run
 object destructors.

 @param [&inout] self : "The arena to reset"
 @param mark : "A mark previously returned by this arena"
 @require mark < self.next_sequence : "The mark must not be ahead of the current arena position"
*>
fn void BackedArenaAllocator.reset(&self, sz mark)
{
	assert(mark < self.next_sequence, "Backed arena mark is from a future or discarded history.");
	backed_arena_rewind_to(self, mark);
	BackedArenaPage** current = &self.pages;
	while (*current)
	{
		BackedArenaPage* page = *current;
		if (page.sequence > mark)
		{
			*current = page.next;
			backed_arena_free_page(self.backing_allocator, page);
		}
		else
		{
			current = &page.next;
		}
	}
	self.next_sequence = mark + 1;
}

<*
 Reset to a mark, parking overflow pages for reuse instead of freeing them.

 Same semantics as `reset`, except overflow pages created after the mark are
 moved to an internal pool. Later overflow requests reuse a pooled page when
 its backing block is large enough and its alignment is sufficient, so
 steady-state frame loops stop hitting the backing allocator. Pooled pages
 still hold backing memory until reused or drained with `prune_pool`.

 @param [&inout] self : "The arena to reset"
 @param mark : "A mark previously returned by this arena"
 @require mark < self.next_sequence : "The mark must not be ahead of the current arena position"
*>
fn void BackedArenaAllocator.reset_retaining(&self, sz mark)
{
	assert(mark < self.next_sequence, "Backed arena mark is from a future or discarded history.");
	backed_arena_rewind_to(self, mark);
	BackedArenaPage** current = &self.pages;
	while (*current)
	{
		BackedArenaPage* page = *current;
		if (page.sequence > mark)
		{
			*current = page.next;
			page.next = self.page_pool;
			self.page_pool = page;
			self.pooled_count++;
		}
		else
		{
			current = &page.next;
		}
	}
	self.next_sequence = mark + 1;
}

<*
 Reset the arena to its initial state while retaining the initial borrowed buffer.

 All overflow blocks are freed, all initial-buffer allocations are invalidated,
 and the mark sequence restarts. The initial buffer is not zeroed and no object
 destructors are run.

 @param [&inout] self : "The arena to clear"
*>
fn void BackedArenaAllocator.clear(&self) => self.reset(0);

<*
 Free all overflow blocks owned by the arena and detach its borrowed buffer.

 The arena must not be used after this call until reinitialized. The borrowed
 initial buffer itself is never freed. Pooled pages are returned to the
 backing allocator.

 @param [&inout] self : "The arena to free"
*>
fn void BackedArenaAllocator.free(&self)
{
	self.prune_pool();
	self.clear();
	self.initial_data = { };
	self.backing_allocator = { };
}

<*
 Rewind initial-buffer headers and released tails down to a mark.

 Shared by `reset` and `reset_retaining`; page disposition happens after.

 @param [&inout] self : "The arena being rewound"
 @param mark : "The validated target mark"
*>
fn void backed_arena_rewind_to(BackedArenaAllocator* self, sz mark) @local
{
	while (self.last_initial_header && self.last_initial_header.sequence > mark)
	{
		BackedArenaHeader* header = self.last_initial_header;
		self.last_initial_header = header.previous;
		self.initial_used = header.previous_used;
		header.magic = 0;
	}
	backed_arena_rewind_freed_initial(self);
}

<*
 Acquire memory from the initial buffer, or use the backing allocator for an
 overflow block.

 Alignment zero requests the default C3 alignment. `ZERO` clears the requested
 payload bytes. Failure does not advance the initial buffer or publish an
 overflow page.

 @param [&inout] self : "The arena to allocate from"
 @param size : "The requested size; must be greater than zero"
 @param init_type : "Whether the requested bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated bytes"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? BackedArenaAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	if (size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (self.next_sequence == sz::max) return mem::INVALID_ALLOC_SIZE~;

	sz effective_alignment = allocator_effective_alignment_min(alignment, BackedArenaHeader::alignment);

	void*? initial = backed_arena_acquire_initial(self, size, init_type, effective_alignment);
	if (catch initial)
	{
		return backed_arena_acquire_page(self, size, init_type, effective_alignment);
	}

	self.next_sequence++;
	return initial;
}

<*
 Acquire from the initial buffer when the requested block fits.

 @param [&inout] self : "The arena whose initial buffer is used"
 @param size : "The requested payload size"
 @param init_type : "Whether the payload should be zero-initialized"
 @param alignment : "The validated effective alignment"
 @return "A pointer to the allocated payload"
 @return? mem::OUT_OF_MEMORY
*>
fn void*? backed_arena_acquire_initial(
	BackedArenaAllocator* self,
	sz size,
	AllocInitType init_type,
	sz alignment
) @local
{
	if (self.initial_used > self.initial_data.len || self.initial_data.len < BackedArenaHeader::size)
	{
		return mem::OUT_OF_MEMORY~;
	}
	if (self.initial_used > self.initial_data.len - BackedArenaHeader::size) return mem::OUT_OF_MEMORY~;

	uptr base_addr = (uptr)self.initial_data.ptr;
	uptr block_start_addr = base_addr + (uptr)self.initial_used;
	if (block_start_addr < base_addr) return mem::OUT_OF_MEMORY~;
	if (block_start_addr > uptr::max - (uptr)BackedArenaHeader::size) return mem::OUT_OF_MEMORY~;

	uptr unaligned_addr = block_start_addr + (uptr)BackedArenaHeader::size;
	if (unaligned_addr < block_start_addr) return mem::OUT_OF_MEMORY~;
	if (unaligned_addr > uptr::max - ((uptr)alignment - 1)) return mem::OUT_OF_MEMORY~;

	uptr payload_addr = allocator_payload_address(block_start_addr, BackedArenaHeader::size, alignment);
	if (payload_addr < base_addr) return mem::OUT_OF_MEMORY~;

	sz payload_offset = (sz)(payload_addr - base_addr);
	if (payload_offset > self.initial_data.len || size > self.initial_data.len - payload_offset)
	{
		return mem::OUT_OF_MEMORY~;
	}

	BackedArenaHeader* header = (BackedArenaHeader*)(payload_addr - BackedArenaHeader::size);
	header.magic = BACKED_ARENA_HEADER_MAGIC;
	header.owner = self;
	header.previous = self.last_initial_header;
	header.previous_used = self.initial_used;
	header.sequence = self.next_sequence;
	header.size = size;
	header.payload = (void*)payload_addr;
	header.in_use = true;
	self.last_initial_header = header;
	self.initial_used = payload_offset + size;
	self.initial_total++;
	allocator_zero_if(header.payload, size, init_type);
	return header.payload;
}

<*
 Allocate a dedicated overflow block through the backing allocator, or reuse
 a pooled page.

 A pooled page is reused when its backing block is large enough for the new
 payload and its allocation alignment is at least as strict as the request;
 otherwise the next pooled page is considered. The descriptor and payload
 share one backing allocation. The descriptor is initialized and linked into
 the arena only after the block is secured.

 @param [&inout] self : "The arena that owns the new overflow page"
 @param size : "The requested payload size"
 @param init_type : "Whether the payload should be zero-initialized"
 @param alignment : "The validated effective alignment"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? backed_arena_acquire_page(BackedArenaAllocator* self, sz size, AllocInitType init_type, sz alignment) @local
{
	if (alignment < BackedArenaPage::alignment) alignment = BackedArenaPage::alignment;
	if (alignment > sz::max - BackedArenaPage::size) return mem::INVALID_ALLOC_SIZE~;

	sz payload_offset = allocator_align_up_size(BackedArenaPage::size, alignment);
	if (size > sz::max - payload_offset) return mem::INVALID_ALLOC_SIZE~;

	sz total_size = allocator_align_up_size(payload_offset + size, BackedArenaPage::alignment);
	BackedArenaPage** pool_link = &self.page_pool;
	while (*pool_link)
	{
		BackedArenaPage* pooled = *pool_link;
		if (pooled.allocation_alignment >= alignment && pooled.block_size < total_size)
		{
			// A pooled page holds no live data, so growing its backing block
			// through the backing allocator is safe even if the block moves.
			void*? grown_opt = self.backing_allocator.resize(
				pooled.descriptor_block,
				total_size,
				pooled.allocation_alignment
			);
			if (catch grown_opt)
			{
				pool_link = &(*pool_link).next;
				continue;
			}

			void* grown = grown_opt;
			BackedArenaPage* moved = grown;
			if (grown != pooled.descriptor_block)
			{
				*moved = *pooled;
				*pool_link = pooled.next;
				pooled = moved;
				pooled.descriptor_block = grown;
			}

			pooled.block_size = total_size;
			*pool_link = pooled.next;
			self.pooled_count--;

			void* payload = (char*)grown + payload_offset;
			sz sequence = self.next_sequence;
			self.next_sequence++;
			pooled.next = self.pages;
			pooled.payload = payload;
			pooled.requested_size = size;
			pooled.sequence = sequence;
			self.pages = pooled;
			self.overflow_total++;
			allocator_fill_canary(
				(char*)payload + size,
				(sz)(((uptr)grown + (uptr)pooled.block_size) - ((uptr)payload + (uptr)size))
			);

			allocator_zero_if(payload, size, init_type);
			return payload;
		}
		if (pooled.block_size >= total_size && pooled.allocation_alignment >= alignment)
		{
			*pool_link = pooled.next;
			self.pooled_count--;
			void* block = pooled.descriptor_block;

			void* payload = (char*)block + payload_offset;
			sz sequence = self.next_sequence;
			self.next_sequence++;
			pooled.next = self.pages;
			pooled.payload = payload;
			pooled.requested_size = size;
			pooled.sequence = sequence;
			self.pages = pooled;
			self.overflow_total++;
			allocator_fill_canary(
				(char*)payload + size,
				(sz)(((uptr)block + (uptr)pooled.block_size) - ((uptr)payload + (uptr)size))
			);

			allocator_zero_if(payload, size, init_type);
			return payload;
		}
		pool_link = &(*pool_link).next;
	}

	void*? block_opt = self.backing_allocator.acquire(total_size, NO_ZERO, alignment);
	if (catch block_opt) return mem::OUT_OF_MEMORY~;

	void* block = block_opt;
	BackedArenaPage* page = block;
	void* payload = (char*)block + payload_offset;
	sz sequence = self.next_sequence;
	self.next_sequence++;
	page.next = self.pages;
	page.descriptor_block = block;
	page.payload = payload;
	page.requested_size = size;
	page.sequence = sequence;
	page.allocation_alignment = alignment;
	page.block_size = total_size;
	self.pages = page;
	self.overflow_total++;
	allocator_fill_canary(
		(char*)payload + size,
		(sz)(((uptr)block + (uptr)page.block_size) - ((uptr)payload + (uptr)size))
	);

	allocator_zero_if(payload, size, init_type);
	return payload;
}

<*
 Compute the canary byte count for an overflow page payload.

 @param page : "The page owning the payload"
 @param payload : "The page payload pointer"
 @return "The canary region byte count"
*>
fn sz backed_arena_page_canary_len(BackedArenaPage* page, void* payload) @local
{
	uptr block_end = (uptr)page.descriptor_block + (uptr)page.block_size;
	uptr canary_end = block_end;
	uptr canary_start = (uptr)payload + (uptr)page.requested_size;
	if (canary_start >= canary_end) return 0;
	return (sz)(canary_end - canary_start);
}

<*
 Resize a block allocated by this backed arena while preserving its prefix.

 Initial-buffer allocations are resized in place when they are newest, satisfy
 the requested alignment, and fit. Other cases allocate a replacement first,
 copy the common prefix, and only then release/reclaim the old block. If the
 replacement fails, the original block remains valid and arena state is
 unchanged. A corrupted trailing canary fails the resize with
 `INVALID_ALLOC_SIZE` and preserves the block.

 @param [&inout] self : "The arena that owns the block"
 @param [drop] old_pointer : "The allocation to resize"
 @param new_size : "The new size; must be greater than zero"
 @param alignment : "The required alignment, or zero for the default"
 @return "The resized allocation, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? BackedArenaAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	if (!old_pointer || new_size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;

	sz effective_alignment = allocator_effective_alignment(alignment);
	BackedArenaHeader* initial_header = backed_arena_initial_header(self, old_pointer);
	if (initial_header)
	{
		if (!initial_header.in_use) return mem::INVALID_ALLOC_SIZE~;

		bool is_last = self.last_initial_header == initial_header;
		if (is_last && mem::ptr_is_aligned(
			old_pointer,
			effective_alignment
		) && new_size <= self.initial_data.len - (sz)((uptr)old_pointer - (uptr)self.initial_data.ptr))
		{
			initial_header.size = new_size;
			self.initial_used = (sz)((uptr)old_pointer - (uptr)self.initial_data.ptr) + new_size;
			return old_pointer;
		}

		void*? replacement_opt = self.acquire(new_size, NO_ZERO, effective_alignment);
		if (catch replacement_opt) return mem::OUT_OF_MEMORY~;

		void* replacement = replacement_opt;
		sz copy_size = math::min(initial_header.size, new_size);
		mem::copy(replacement, old_pointer, copy_size, mem::DEFAULT_MEM_ALIGNMENT, mem::DEFAULT_MEM_ALIGNMENT);
		initial_header.in_use = false;
		if (self.last_initial_header == initial_header) backed_arena_rewind_freed_initial(self);
		return replacement;
	}

	BackedArenaPage** page_link = backed_arena_find_page_link(self, old_pointer);
	if (!page_link) return mem::INVALID_ALLOC_SIZE~;

	BackedArenaPage* old_page = *page_link;
	if (new_size <= old_page.requested_size && mem::ptr_is_aligned(old_pointer, effective_alignment))
	{
		if (!allocator_canary_intact(
			(char*)old_pointer + old_page.requested_size,
			backed_arena_page_canary_len(old_page, old_pointer)
		)) return mem::INVALID_ALLOC_SIZE~;

		old_page.requested_size = new_size;
		allocator_fill_canary((char*)old_pointer + new_size, backed_arena_page_canary_len(old_page, old_pointer));
		return old_pointer;
	}

	void*? replacement_opt = self.acquire(new_size, NO_ZERO, effective_alignment);
	if (catch replacement_opt) return mem::OUT_OF_MEMORY~;

	void* replacement = replacement_opt;
	sz copy_size = math::min(old_page.requested_size, new_size);
	mem::copy(replacement, old_pointer, copy_size, mem::DEFAULT_MEM_ALIGNMENT, mem::DEFAULT_MEM_ALIGNMENT);
	page_link = backed_arena_find_page_link(self, old_pointer);

	// Acquire never removes pages, so the link must still exist
	if (!page_link) return mem::OUT_OF_MEMORY~;
	*page_link = old_page.next;
	backed_arena_free_page(self.backing_allocator, old_page);
	return replacement;
}

<*
 Release an allocation from this backed arena.

 Overflow allocations return their backing block immediately. Initial-buffer
 allocations reclaim space only when they are the newest initial-buffer block.
 Null and non-owned pointers are ignored, as is a block whose trailing
 canary is corrupted.

 @param [&inout] self : "The arena that owns the block"
 @param [drop] old_pointer : "The block to release, or null"
 @param aligned : "Whether the request used explicit alignment"
*>
fn void BackedArenaAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	if (!old_pointer) return;

	BackedArenaHeader* initial_header = backed_arena_initial_header(self, old_pointer);
	if (initial_header)
	{
		if (!initial_header.in_use) return;

		initial_header.in_use = false;
		if (self.last_initial_header == initial_header) backed_arena_rewind_freed_initial(self);
		return;
	}

	BackedArenaPage** page_link = backed_arena_find_page_link(self, old_pointer);
	if (!page_link) return;

	BackedArenaPage* page = *page_link;
	if (!allocator_canary_intact(
		(char*)old_pointer + page.requested_size,
		backed_arena_page_canary_len(page, old_pointer)
	)) return;

	allocator_poison_if_testing(old_pointer, page.requested_size);
	*page_link = page.next;
	backed_arena_free_page(self.backing_allocator, page);
}

<*
 Check whether an overflow payload's trailing canary is intact.

 Initial-buffer payloads have no trailing slack and always report true.

 @param [&in] self : "The arena that owns the block"
 @param pointer : "A live payload pointer"
 @return "True when no bytes were written past the requested size"
*>
fn bool BackedArenaAllocator.canary_intact(&self, void* pointer)
{
	BackedArenaPage** page_link = backed_arena_find_page_link(self, pointer);
	if (!page_link) return true;
	return allocator_canary_intact(
		(char*)pointer + (*page_link).requested_size,
		backed_arena_page_canary_len(*page_link, pointer)
	);
}

<*
 Return an overflow page's payload and descriptor allocations to the backing allocator.

 Save the backing addresses and alignment before releasing either allocation,
 because the descriptor itself may be stored in the returned memory.

 @param backing_allocator : "The allocator that owns the page's backing blocks"
 @param [drop] page : "The page descriptor and payload to release"
*>
fn void backed_arena_free_page(Allocator backing_allocator, BackedArenaPage* page) @local
{
	void* allocation = page.descriptor_block;
	sz allocation_alignment = page.allocation_alignment;
	backing_allocator.release(allocation, allocation_alignment > mem::DEFAULT_MEM_ALIGNMENT);
}

<*
 Validate and return the initial-buffer allocation header for an exact payload pointer.

 @param [&in] self : "The arena to validate against"
 @param pointer : "A candidate allocation pointer"
 @return "The allocation header, or null if it is not an initial-buffer payload"
*>
fn BackedArenaHeader* backed_arena_initial_header(BackedArenaAllocator* self, void* pointer) @local
{
	if (!pointer || self.initial_used < BackedArenaHeader::size) return null;

	uptr base_addr = (uptr)self.initial_data.ptr;
	uptr pointer_addr = (uptr)pointer;
	if (pointer_addr < base_addr || pointer_addr - base_addr >= (uptr)self.initial_used) return null;
	if (pointer_addr - base_addr < BackedArenaHeader::size) return null;

	BackedArenaHeader* header = pointer - BackedArenaHeader::size;
	if (header.magic != BACKED_ARENA_HEADER_MAGIC || header.owner != self || header.payload != pointer) return null;
	return header;
}

<*
 Find the link pointing to an overflow page owning an exact payload pointer.

 @param [&in] self : "The arena to search"
 @param pointer : "A candidate allocation pointer"
 @return "The link to the matching page, or null when not found"
*>
fn BackedArenaPage** backed_arena_find_page_link(BackedArenaAllocator* self, void* pointer) @local
{
	BackedArenaPage** current = &self.pages;
	while (*current)
	{
		if ((*current).payload == pointer) return current;
		current = &(*current).next;
	}
	return null;
}

<*
 Rewind the initial-buffer stack through its newest header.

 @param [&inout] self : "The arena being rewound"
 @param header : "The newest initial-buffer header to pop"
*>
fn void backed_arena_pop_initial(BackedArenaAllocator* self, BackedArenaHeader* header) @local
{
	self.initial_used = header.previous_used;
	self.last_initial_header = header.previous;
	header.magic = 0;
}

<*
 Reclaim any released initial-buffer allocations at the top of the allocation chain.

 @param [&inout] self : "The arena whose initial-buffer chain is rewound"
*>
fn void backed_arena_rewind_freed_initial(BackedArenaAllocator* self) @local
{
	while (self.last_initial_header && !self.last_initial_header.in_use)
	{
		backed_arena_pop_initial(self, self.last_initial_header);
	}
}
