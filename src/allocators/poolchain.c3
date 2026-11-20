module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

const POOL_CHAIN_MAX = 8;

<*
 A chain of fixed-slot pools sharing one maximum size and alignment.

 A single pool fails once its slots are exhausted. A chain keeps
 several pools over caller-provided buffers and serves each request
 from the first pool with a free slot, so capacity grows by attaching
 more buffers instead of failing. Release returns the slot to whatever
 link owns it, so blocks never move and pointers stay stable.

 Every link has identical slots, so unlike the size-class dispatcher
 there is no waste gap between links: the only overhead is whole
 unused buffers when the tail link is empty. The chain borrows its
 buffers; they must outlive the chain and its allocations. This
 allocator is not thread-safe and never runs destructors.
*>
struct PoolChainAllocator (Allocator) @mustinit
{
	PoolAllocator[POOL_CHAIN_MAX] pools;
	sz num_links;
	sz block_size;
	sz alignment;
}

<*
 Initialize the chain over caller-provided storage.

 Each buffer becomes one link sized for `block_size` byte payloads at
 up to `alignment`. Buffers beyond `POOL_CHAIN_MAX` are ignored; the
 chain reports how many links it holds. Invalid sizes, alignments, or
 an empty buffer list leaves the chain with zero links, so every
 acquisition fails cleanly instead of indexing out of bounds.

 @param [&out] self : "The chain to initialize"
 @param buffers : "One borrowed buffer per link, up to POOL_CHAIN_MAX"
 @param block_size : "The maximum requested size of each allocation"
 @param alignment : "The maximum supported request alignment, or zero for default"
 @return "A pointer to the initialized chain"
*>
fn PoolChainAllocator* PoolChainAllocator.init(&self, char[][] buffers, sz block_size, sz alignment = 0)
{
	if (block_size <= 0 || !allocator_valid_alignment(alignment) || buffers.len <= 0 || buffers.len > POOL_CHAIN_MAX)
	{
		PoolAllocator[POOL_CHAIN_MAX] empty_pools;
		char[1] empty_storage;
		for (sz i = 0; i < POOL_CHAIN_MAX; i++)
		{
			empty_pools[i].init(empty_storage[..], 1, 0);
		}

		self.pools = empty_pools;
		self.num_links = 0;
		self.block_size = 0;
		self.alignment = mem::DEFAULT_MEM_ALIGNMENT;
		return self;
	}

	sz count = buffers.len;
	PoolAllocator[POOL_CHAIN_MAX] pools;
	for (sz i = 0; i < count; i++)
	{
		pools[i].init(buffers[i], block_size, alignment);
	}

	char[1] empty_storage;
	for (sz i = count; i < POOL_CHAIN_MAX; i++)
	{
		pools[i].init(empty_storage[..], 1, 0);
	}

	self.pools = pools;
	self.num_links = count;
	self.block_size = block_size;
	self.alignment = alignment;
	return self;
}

<*
 Attach another buffer as a new link at the end of the chain.

 The new link serves the same block size and alignment as the chain.
 Returns false without changing the chain when it already holds
 `POOL_CHAIN_MAX` links. Attached buffers must outlive the chain like
 the initial ones.

 @param [&inout] self : "The chain to extend"
 @param storage : "The caller-owned buffer for the new link"
 @return "True when the link was attached"
*>
fn bool PoolChainAllocator.attach(&self, char[] storage)
{
	if (self.num_links < 0 || self.num_links >= POOL_CHAIN_MAX) return false;

	self.pools[self.num_links].init(storage, self.block_size, self.alignment);
	self.num_links++;
	return true;
}

<*
 Return the number of links currently in the chain.

 @param [&in] self : "The chain to query"
 @return "The configured link count"
*>
fn sz PoolChainAllocator.link_count(&self) => self.num_links;

<*
 Return the slot capacity of one link.

 @param [&in] self : "The chain to query"
 @param index : "The link index, below `link_count`"
 @return "The link's total slot count, or zero for a bad index"
*>
fn sz PoolChainAllocator.link_capacity(&self, sz index)
{
	if (index < 0 || index >= self.num_links) return 0;
	return self.pools[index].capacity();
}

<*
 Return the free slots of one link.

 @param [&in] self : "The chain to query"
 @param index : "The link index, below `link_count`"
 @return "The link's free slot count, or zero for a bad index"
*>
fn sz PoolChainAllocator.link_available(&self, sz index)
{
	if (index < 0 || index >= self.num_links) return 0;
	return self.pools[index].available();
}

<*
 Return the total slots across all links.

 @param [&in] self : "The chain to query"
 @return "The total slot capacity"
*>
fn sz PoolChainAllocator.capacity(&self)
{
	sz total = 0;
	for (sz i = 0; i < self.num_links; i++) total += self.pools[i].capacity();
	return total;
}

<*
 Return the total free slots across all links.

 @param [&in] self : "The chain to query"
 @return "The total free slot count"
*>
fn sz PoolChainAllocator.available(&self)
{
	sz total = 0;
	for (sz i = 0; i < self.num_links; i++) total += self.pools[i].available();
	return total;
}

<*
 Return the maximum payload size one slot can serve.

 @param [&in] self : "The chain to query"
 @return "The configured block size"
*>
fn sz PoolChainAllocator.payload_size(&self) => self.block_size;

<*
 Check whether a pointer is a slot payload of any link.

 Only exact payload pointers report true; interior and foreign
 pointers report false.

 @param [&in] self : "The chain to validate against"
 @param pointer : "A candidate payload pointer"
 @return "True when some link owns the pointer"
*>
fn bool PoolChainAllocator.owns(&self, void* pointer)
{
	for (sz i = 0; i < self.num_links; i++)
	{
		if (self.pools[i].owns(pointer)) return true;
	}
	return false;
}

<*
 Find the link owning a payload pointer.

 @param [&in] self : "The chain that may own the pointer"
 @param pointer : "A candidate payload pointer"
 @return "The owning link index, or -1 for foreign pointers"
*>
fn sz poolchain_owner(PoolChainAllocator* self, void* pointer) @local
{
	for (sz i = 0; i < self.num_links; i++)
	{
		if (self.pools[i].owns(pointer)) return i;
	}
	return -1;
}

<*
 Acquire a slot from the first link with a free one.

 Requests larger than the configured payload size report
 `INVALID_ALLOC_SIZE`; exhaustion of every link reports
 `OUT_OF_MEMORY`. Failure leaves allocator state unchanged.

 @param [&inout] self : "The chain to allocate from"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the requested bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated slot payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? PoolChainAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	$if env::TESTING:
		defer assert(self.debug_verify(), "PoolChainAllocator invariant violated.");
	$endif
	if (size <= 0 || size > self.block_size) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	for (sz i = 0; i < self.num_links; i++)
	{
		if (self.pools[i].available() == 0) continue;
		return self.pools[i].acquire(size, init_type, alignment);
	}
	return mem::OUT_OF_MEMORY~;
}

<*
 Release a slot back to the link that owns it.

 Null, foreign, interior, and duplicate releases are ignored; the
 owning link's own rules apply otherwise.

 @param [&inout] self : "The chain that acquired the block"
 @param [drop] old_pointer : "The allocation to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void PoolChainAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	$if env::TESTING:
		defer assert(self.debug_verify(), "PoolChainAllocator invariant violated.");
	$endif
	if (!old_pointer) return;
	for (sz i = 0; i < self.num_links; i++)
	{
		if (self.pools[i].release_if_owned(old_pointer, aligned)) return;
	}
}

<*
 Resize a slot in place within its owning link.

 The new size must fit the configured block size and meet the
 supported alignment. Blocks never move between links. Failure leaves
 the allocation unchanged; a corrupted trailing canary fails the
 resize with `INVALID_ALLOC_SIZE` and preserves the block.

 @param [&inout] self : "The chain that acquired the block"
 @param [drop] old_pointer : "The allocation to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero for the default"
 @return "The same pointer with the updated requested size"
 @return? mem::INVALID_ALLOC_SIZE
*>
fn void*? PoolChainAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	$if env::TESTING:
		defer assert(self.debug_verify(), "PoolChainAllocator invariant violated.");
	$endif
	if (!old_pointer) return mem::INVALID_ALLOC_SIZE~;

	sz owner = poolchain_owner(self, old_pointer);
	if (owner < 0) return mem::INVALID_ALLOC_SIZE~;
	return self.pools[owner].resize(old_pointer, new_size, alignment);
}

<*
 Check whether a slot payload's trailing canary is intact.

 @param [&in] self : "The chain that owns the slot"
 @param pointer : "A live slot payload"
 @return "True when no bytes were written past the requested size"
*>
fn bool PoolChainAllocator.canary_intact(&self, void* pointer)
{
	sz owner = poolchain_owner((PoolChainAllocator*)self, pointer);
	if (owner < 0) return false;
	return self.pools[owner].canary_intact(pointer);
}

<*
 Verify the chain's structural invariants.

 Every link must verify on its own, and the summed link capacities
 must match the chain totals. Returns false instead of proceeding on
 a corrupt chain. Runs automatically at the end of every mutating
 operation in test builds; call it directly in tests after hand-rolled
 operation sequences.

 @param [&in] self : "The chain to verify"
 @return "True when all invariants hold"
*>
fn bool PoolChainAllocator.debug_verify(&self)
{
	if (self.num_links < 0 || self.num_links > POOL_CHAIN_MAX) return false;
	if (self.num_links == 0) return self.block_size == 0;
	for (sz i = 0; i < self.num_links; i++)
	{
		if (!self.pools[i].debug_verify()) return false;
		if (self.pools[i].payload_size() != self.block_size) return false;
	}
	return true;
}
