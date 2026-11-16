module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

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
	sz initial_used;
	sz next_sequence;
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
	self.initial_used = 0;
	self.next_sequence = 1;
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
	while (self.last_initial_header && self.last_initial_header.sequence > mark)
	{
		BackedArenaHeader* header = self.last_initial_header;
		self.last_initial_header = header.previous;
		self.initial_used = header.previous_used;
		header.magic = 0;
	}

	backed_arena_rewind_freed_initial(self);
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
 initial buffer itself is never freed.

 @param [&inout] self : "The arena to free"
*>
fn void BackedArenaAllocator.free(&self)
{
	self.clear();
	self.initial_data = { };
	self.backing_allocator = { };
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
	if (!backed_arena_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (self.next_sequence == sz::max) return mem::INVALID_ALLOC_SIZE~;

	sz effective_alignment = allocators::alignment_for_allocation(alignment);
	if (effective_alignment < BackedArenaHeader::alignment) effective_alignment = BackedArenaHeader::alignment;

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

	sz after_header = self.initial_used + BackedArenaHeader::size;
	uptr base_addr = (uptr)self.initial_data.ptr;
	if (base_addr > uptr::max - (uptr)after_header) return mem::OUT_OF_MEMORY~;

	uptr unaligned_addr = base_addr + (uptr)after_header;
	uptr uptr_alignment = (uptr)alignment;
	if (unaligned_addr > uptr::max - (uptr_alignment - 1)) return mem::OUT_OF_MEMORY~;

	uptr payload_addr = (unaligned_addr + uptr_alignment - 1) & ~(uptr_alignment - 1);
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
	if (init_type == ZERO) mem::clear(header.payload, size, mem::DEFAULT_MEM_ALIGNMENT);
	return header.payload;
}

<*
 Allocate a dedicated overflow block through the backing allocator.

 The descriptor and payload share one backing allocation. The descriptor is
 initialized and linked into the arena only after allocation succeeds.

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

	sz payload_offset = mem::aligned_offset(BackedArenaPage::size, alignment);
	if (size > sz::max - payload_offset) return mem::INVALID_ALLOC_SIZE~;

	sz total_size = payload_offset + size;
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
	self.pages = page;
	return payload;
}

<*
 Resize a block allocated by this backed arena while preserving its prefix.

 Initial-buffer allocations are resized in place when they are newest, satisfy
 the requested alignment, and fit. Other cases allocate a replacement first,
 copy the common prefix, and only then release/reclaim the old block. If the
 replacement fails, the original block remains valid and arena state is
 unchanged.

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
	if (!backed_arena_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;

	sz effective_alignment = allocators::alignment_for_allocation(alignment);
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
		sz copy_size = initial_header.size < new_size ? initial_header.size : new_size;
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
		old_page.requested_size = new_size;
		return old_pointer;
	}

	void*? replacement_opt = self.acquire(new_size, NO_ZERO, effective_alignment);
	if (catch replacement_opt) return mem::OUT_OF_MEMORY~;

	void* replacement = replacement_opt;
	sz copy_size = old_page.requested_size < new_size ? old_page.requested_size : new_size;
	mem::copy(replacement, old_pointer, copy_size, mem::DEFAULT_MEM_ALIGNMENT, mem::DEFAULT_MEM_ALIGNMENT);
	page_link = backed_arena_find_page_link(self, old_pointer);
	assert(page_link, "Resized page disappeared from the arena page list.");
	*page_link = old_page.next;
	backed_arena_free_page(self.backing_allocator, old_page);
	return replacement;
}

<*
 Release an allocation from this backed arena.

 Overflow allocations return their backing block immediately. Initial-buffer
 allocations reclaim space only when they are the newest initial-buffer block.
 Null and non-owned pointers are ignored.

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
	*page_link = page.next;
	backed_arena_free_page(self.backing_allocator, page);
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

<*
 Check whether an optional allocation alignment is valid.

 @param alignment : "The requested alignment, or zero for default"
 @return "True when the alignment is supported by C3's memory API"
*>
fn bool backed_arena_valid_alignment(sz alignment) @local => !alignment || mem::is_valid_alignment(alignment);
