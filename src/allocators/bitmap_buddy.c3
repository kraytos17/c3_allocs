module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

const BITMAP_BUDDY_LEAF = 16;
const BITMAP_BUDDY_LEAF_SHIFT = 4;
$assert (1 << BITMAP_BUDDY_LEAF_SHIFT) == BITMAP_BUDDY_LEAF;
const BITMAP_BUDDY_MAX_ORDERS = 64;

<*
 A headerless binary buddy allocator over caller-owned memory.

 Instead of a per-block header, per-order `alloc` and `split` bitmaps carved
 from the front of the region track block state, following the design of
 bitmap buddy allocators. Every byte of a block is payload, so a 16-byte
 request uses a whole 16-byte leaf block with zero per-allocation metadata
 overhead. The block order of a pointer is recovered by walking the split
 bits upward, which is what release, resize, and ownership checks use
 instead of a header.

 Blocks per order are indexed from the managed base; the buddy of a block is
 found by flipping the index's lowest bit. Merging stops when the buddy is
 allocated, split, or outside the managed range. Because there is no header,
 a per-request trailing canary is impossible; test builds poison whole freed
 blocks instead. The allocator is not thread-safe and never runs destructors.
*>
struct BitmapBuddyAllocator (Allocator) @mustinit
{
	BitmapBuddyFree*[BITMAP_BUDDY_MAX_ORDERS] free_heads;
	sz[BITMAP_BUDDY_MAX_ORDERS] free_counts;
	char*[BITMAP_BUDDY_MAX_ORDERS] alloc_bits;
	char*[BITMAP_BUDDY_MAX_ORDERS] split_bits;
	char[] data;
	uptr buddy_base;
	sz buddy_bytes;
	sz max_order;
	sz managed_bytes;
	sz free_bytes;
}

<*
 An intrusive free-list node living at the start of a free block. The block
 order is implied by the list it sits on.
*>
struct BitmapBuddyFree @local
{
	BitmapBuddyFree* next;
}

<*
 Read one bit from a bitmap array.

 @param bits : "The bitmap array for one order"
 @param index : "The block index within that order"
 @return "The bit value"
*>
fn bool bitmap_buddy_bit(char* bits, sz index) @local
{
	return (bits[index >> 3] >> (index & 7)) & 1 != 0;
}

<*
 Set one bit in a bitmap array.

 @param bits : "The bitmap array for one order"
 @param index : "The block index within that order"
*>
fn void bitmap_buddy_set_bit(char* bits, sz index) @local => bits[index >> 3] |= (char)(1 << (index & 7));

<*
 Clear one bit in a bitmap array.

 @param bits : "The bitmap array for one order"
 @param index : "The block index within that order"
*>
fn void bitmap_buddy_clear_bit(char* bits, sz index) @local => bits[index >> 3] &= (char)~(1 << (index & 7));

<*
 Compute the metadata byte budget for the region's order range.

 @param region_size : "The carved power-of-two region size"
 @param region_orders : "The highest block order the region could hold"
 @return "The total bytes needed for both bitmap arrays"
*>
fn sz bitmap_buddy_meta_bytes(sz region_size, sz region_orders) @local
{
	sz total = 0;
	for (sz k = 0; k <= region_orders; k++)
	{
		sz nblock = (region_size / BITMAP_BUDDY_LEAF) >> k;
		total += (nblock + 7) / 8;
	}

	total *= 2;
	return allocator_align_up_size(total, BITMAP_BUDDY_LEAF);
}

<*
 Initialize the bitmap buddy over caller-owned storage.

 The largest self-aligned power-of-two region is carved from the buffer as
 in `BuddyAllocator`. Per-order `alloc` and `split` bitmaps are carved from
 the region's front; the remainder is the managed area, filled greedily with
 the largest blocks that fit so small buffers waste little. Parents of
 even-index blocks are marked split and allocated so ownership lookups and
 merges stay consistent with the greedy layout. Buffers too small for the
 bitmaps plus one leaf block leave the allocator empty.

 @param [&out] self : "The allocator to initialize"
 @param storage : "The caller-owned buffer backing this allocator"
 @return "A pointer to the initialized allocator"
*>
fn BitmapBuddyAllocator* BitmapBuddyAllocator.init(&self, char[] storage)
{
	self.data = storage;
	self.buddy_base = 0;
	self.buddy_bytes = 0;
	self.max_order = 0;
	self.managed_bytes = 0;
	self.free_bytes = 0;
	for (sz i = 0; i < BITMAP_BUDDY_MAX_ORDERS; i++)
	{
		self.free_heads[i] = null;
		self.free_counts[i] = 0;
		self.alloc_bits[i] = null;
		self.split_bits[i] = null;
	}
	if (storage.len < BITMAP_BUDDY_LEAF * 4 || !storage.ptr) return self;

	BitmapBuddyFree*[BITMAP_BUDDY_MAX_ORDERS] heads;
	sz[BITMAP_BUDDY_MAX_ORDERS] counts;
	char*[BITMAP_BUDDY_MAX_ORDERS] alloc_bits;
	char*[BITMAP_BUDDY_MAX_ORDERS] split_bits;
	for (sz i = 0; i < BITMAP_BUDDY_MAX_ORDERS; i++)
	{
		heads[i] = null;
		counts[i] = 0;
		alloc_bits[i] = null;
		split_bits[i] = null;
	}

	uptr base_addr = (uptr)storage.ptr;
	uptr end_addr = base_addr + (uptr)storage.len;
	uptr region_base = 0;
	sz region_size = 0;
	sz candidate = allocator_floor_pow2(storage.len);
	while (candidate >= BITMAP_BUDDY_LEAF)
	{
		uptr aligned = allocator_align_up_address(base_addr, candidate);
		if (aligned >= base_addr && aligned <= uptr::max - (uptr)candidate && aligned + (uptr)candidate <= end_addr)
		{
			region_base = aligned;
			region_size = candidate;
			break;
		}
		if (candidate == BITMAP_BUDDY_LEAF) break;
		candidate >>= 1;
	}
	if (!region_size) return self;

	sz region_orders = 0;
	sz probe = region_size / BITMAP_BUDDY_LEAF;
	while (probe > 1 && region_orders + 1 < BITMAP_BUDDY_MAX_ORDERS)
	{
		probe >>= 1;
		region_orders++;
	}

	sz meta_bytes = bitmap_buddy_meta_bytes(region_size, region_orders);
	if (meta_bytes >= region_size) return self;

	uptr meta_addr = region_base;
	uptr first_base = allocator_align_up_address(region_base + (uptr)meta_bytes, BITMAP_BUDDY_LEAF);
	sz first_usable = (sz)(region_base + (uptr)region_size - first_base);
	if (first_usable < BITMAP_BUDDY_LEAF) return self;
	sz first_managed = allocator_floor_pow2(first_usable / BITMAP_BUDDY_LEAF) * BITMAP_BUDDY_LEAF;

	// Blocks start at base + index * order size, so the base must itself be
	// aligned to the largest served order; otherwise no block can satisfy
	// alignments at or above the base's misalignment. Align up to the first
	// managed size, halving the target when the aligned base would not fit.
	uptr buddy_base = 0;
	sz usable = 0;
	sz target = first_managed;
	while (target >= BITMAP_BUDDY_LEAF)
	{
		uptr aligned_base = allocator_align_up_address(first_base, target);
		if (aligned_base + (uptr)target <= region_base + (uptr)region_size)
		{
			buddy_base = aligned_base;
			usable = (sz)(region_base + (uptr)region_size - buddy_base);
			break;
		}
		target >>= 1;
	}
	if (!buddy_base) return self;

	sz managed = allocator_floor_pow2(usable / BITMAP_BUDDY_LEAF) * BITMAP_BUDDY_LEAF;
	sz max_order = 0;
	while ((managed >> (max_order + 1)) >= BITMAP_BUDDY_LEAF && max_order + 1 < BITMAP_BUDDY_MAX_ORDERS) max_order++;

	managed = ((sz)BITMAP_BUDDY_LEAF) << max_order;
	char* cursor = (char*)meta_addr;
	for (sz k = 0; k <= max_order; k++)
	{
		sz nblock = managed / (((sz)BITMAP_BUDDY_LEAF) << k);
		alloc_bits[k] = cursor;
		for (sz i = 0; i < (nblock + 7) / 8; i++) cursor[i] = 0;
		cursor += (nblock + 7) / 8;
	}
	for (sz k = 0; k <= max_order; k++)
	{
		sz nblock = managed / (((sz)BITMAP_BUDDY_LEAF) << k);
		split_bits[k] = cursor;
		for (sz i = 0; i < (nblock + 7) / 8; i++) cursor[i] = 0;
		cursor += (nblock + 7) / 8;
	}

	// Greedily fill the managed area with the largest fitting blocks.
	// Parents of even-index blocks are marked split and allocated so that
	// ownership lookups find the right order and merges respect the layout.
	uptr pos = buddy_base;
	for (sz k = max_order; k >= 0; k--)
	{
		sz block_size = ((sz)BITMAP_BUDDY_LEAF) << k;
		while (pos + (uptr)block_size <= buddy_base + (uptr)managed)
		{
			sz index = (sz)((pos - buddy_base) / (uptr)block_size);
			BitmapBuddyFree* block = (BitmapBuddyFree*)pos;
			block.next = heads[k];
			heads[k] = block;
			counts[k]++;
			if (index % 2 == 0 && k < max_order)
			{
				bitmap_buddy_set_bit(split_bits[k + 1], index >> 1);
				bitmap_buddy_set_bit(alloc_bits[k + 1], index >> 1);
			}
			pos += (uptr)block_size;
		}
	}

	self.free_heads = heads;
	self.free_counts = counts;
	self.alloc_bits = alloc_bits;
	self.split_bits = split_bits;
	self.buddy_base = buddy_base;
	self.buddy_bytes = usable;
	self.managed_bytes = managed;
	self.max_order = max_order;
	self.free_bytes = managed;
	return self;
}

<*
 Return the usable managed byte count after metadata carving.

 @param [&in] self : "The allocator to query"
 @return "The managed area size in bytes"
*>
fn sz BitmapBuddyAllocator.capacity(&self) => self.managed_bytes;

<*
 Return the free bytes currently held in the buddy free lists.

 @param [&in] self : "The allocator to query"
 @return "The reclaimable free byte count"
*>
fn sz BitmapBuddyAllocator.bytes_free(&self) => self.free_bytes;

<*
 Return the managed bytes not currently free.

 @param [&in] self : "The allocator to query"
 @return "The reserved byte count within the managed area"
*>
fn sz BitmapBuddyAllocator.bytes_used(&self) => self.managed_bytes - self.free_bytes;

<*
 Return the number of free buddy blocks across all orders.

 @param [&in] self : "The allocator to query"
 @return "The free block count"
*>
fn sz BitmapBuddyAllocator.free_block_count(&self)
{
	sz count = 0;
	for (sz i = 0; i <= self.max_order; i++) count += self.free_counts[i];
	return count;
}

<*
 Return the largest single contiguous free block in bytes.

 @param [&in] self : "The allocator to query"
 @return "The largest free block size, or zero when full"
*>
fn sz BitmapBuddyAllocator.largest_free(&self)
{
	for (sz i = self.max_order; i >= 0; i--)
	{
		if (self.free_counts[i] > 0) return ((sz)BITMAP_BUDDY_LEAF << i);
	}
	return 0;
}

<*
 Discard all allocations and restore the greedy initial layout.

 The managed area is retained; previously returned pointers must not be
 used afterwards. No memory is cleared and no destructors run.

 @param [&inout] self : "The allocator to clear"
*>
fn void BitmapBuddyAllocator.clear(&self)
{
	$if env::TESTING:
		defer assert(self.debug_verify(), "BitmapBuddyAllocator invariant violated.");
	$endif

	for (sz i = 0; i <= self.max_order; i++)
	{
		sz nblock = self.managed_bytes / (((sz)BITMAP_BUDDY_LEAF) << i);
		for (sz j = 0; j < (nblock + 7) / 8; j++)
		{
			self.alloc_bits[i][j] = 0;
			self.split_bits[i][j] = 0;
		}

		self.free_heads[i] = null;
		self.free_counts[i] = 0;
	}

	self.free_bytes = 0;
	uptr pos = self.buddy_base;
	for (sz k = self.max_order; k >= 0; k--)
	{
		sz block_size = ((sz)BITMAP_BUDDY_LEAF) << k;
		while (pos + (uptr)block_size <= self.buddy_base + (uptr)self.managed_bytes)
		{
			sz index = (sz)((pos - self.buddy_base) / (uptr)block_size);
			BitmapBuddyFree* block = (BitmapBuddyFree*)pos;
			block.next = self.free_heads[k];
			self.free_heads[k] = block;
			self.free_counts[k]++;
			if (index % 2 == 0 && k < self.max_order)
			{
				bitmap_buddy_set_bit(self.split_bits[k + 1], index >> 1);
				bitmap_buddy_set_bit(self.alloc_bits[k + 1], index >> 1);
			}
			pos += (uptr)block_size;
		}
	}
	self.free_bytes = self.managed_bytes;
}

<*
 Compute the smallest block order covering a payload size and alignment.

 @param size : "The requested payload size"
 @param effective_alignment : "The validated payload alignment"
 @param order : "Receives the order on success"
 @return "False when the order exceeds the table or overflows"
*>
fn bool bitmap_buddy_leaf_order(sz size, sz effective_alignment, sz* order) @local
{
	sz wanted = size > effective_alignment ? size : effective_alignment;
	if (wanted < 0) return false;

	sz leaf_order = 0;
	sz probe = (sz)BITMAP_BUDDY_LEAF;
	while (probe < wanted)
	{
		if (leaf_order + 1 >= BITMAP_BUDDY_MAX_ORDERS) return false;
		probe <<= 1;
		leaf_order++;
	}

	*order = leaf_order;
	return true;
}

<*
 Recover the block order of a managed block address by walking split bits.

 The smallest order whose parent block is marked split is the block's own
 order; a block with no split ancestors is the top block.

 @param [&in] self : "The allocator owning the bitmaps"
 @param address : "A managed block-aligned address"
 @return "The recovered block order"
*>
fn sz bitmap_buddy_find_order(BitmapBuddyAllocator* self, uptr address) @local
{
	for (sz k = 0; k < self.max_order; k++)
	{
		// The parent block size is a power of two, so this shift
		// is the division by it.
		sz parent_index = (sz)((address - self.buddy_base) >> ((k + 1) + BITMAP_BUDDY_LEAF_SHIFT));
		if (bitmap_buddy_bit(self.split_bits[k + 1], parent_index)) return k;
	}
	return self.max_order;
}

<*
 Validate a payload pointer and recover its order and block start.

 @param [&in] self : "The allocator that may own the pointer"
 @param pointer : "A candidate payload pointer"
 @param order : "Receives the recovered order"
 @param block_start : "Receives the block start address"
 @return "True when the pointer is a live block payload"
*>
fn bool bitmap_buddy_locate(BitmapBuddyAllocator* self, void* pointer, sz* order, uptr* block_start) @local
{
	if (!pointer || !self.managed_bytes) return false;

	uptr address = (uptr)pointer;
	if (address < self.buddy_base) return false;

	uptr offset = address - self.buddy_base;
	if (offset >= (uptr)self.managed_bytes) return false;
	if (offset % (uptr)BITMAP_BUDDY_LEAF != 0) return false;

	sz k = bitmap_buddy_find_order(self, address);
	sz block_size = ((sz)BITMAP_BUDDY_LEAF) << k;
	sz index = (sz)(offset >> (k + BITMAP_BUDDY_LEAF_SHIFT));
	uptr start = self.buddy_base + ((uptr)index * (uptr)block_size);
	if (start != address) return false;
	if (!bitmap_buddy_bit(self.alloc_bits[k], index)) return false;

	*order = k;
	*block_start = start;
	return true;
}

<*
 Find a free block meeting the effective alignment, scanning outward.

 Higher-order blocks start at multiples of their size relative to the base,
 which itself is only leaf-aligned, so blocks may need skipping until one
 address happens to satisfy the requested alignment. Alignments at or
 below the leaf size skip the walk: the first block always qualifies.

 @param [&in] self : "The allocator whose free lists are searched"
 @param from_order : "The lowest order to scan"
 @param effective_alignment : "The validated payload alignment"
 @param order_out : "Receives the found order when a block is returned"
 @return "The free-list link of the fitting block, or null"
*>
fn BitmapBuddyFree** bitmap_buddy_find_fit(
	BitmapBuddyAllocator* self,
	sz from_order,
	sz effective_alignment,
	sz* order_out
) @local
{
	if (effective_alignment > 0 && (uptr)effective_alignment <= (uptr)BITMAP_BUDDY_LEAF)
	{
		for (sz k = from_order; k <= self.max_order; k++)
		{
			if (!self.free_counts[k]) continue;
			*order_out = k;
			return &self.free_heads[k];
		}
		return null;
	}

	sz found_order = -1;
	BitmapBuddyFree** found_link = null;
	for (sz k = from_order; k <= self.max_order; k++)
	{
		if (!self.free_counts[k]) continue;

		BitmapBuddyFree** link = &self.free_heads[k];
		while (*link)
		{
			if ((uptr)*link % (uptr)effective_alignment == 0)
			{
				found_order = k;
				found_link = link;
				break;
			}
			link = &(*link).next;
		}
		if (found_order >= 0) break;
	}
	if (found_order < 0) return null;

	*order_out = found_order;
	return found_link;
}

<*
 Acquire a whole buddy block, splitting larger blocks on demand.

 The payload occupies the block from its start; the block order covers the
 payload size and the effective alignment. Failure leaves the allocator
 unchanged.

 @param [&inout] self : "The allocator to allocate from"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the payload bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero to use the default"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? BitmapBuddyAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	$if env::TESTING:
		defer assert(self.debug_verify(), "BitmapBuddyAllocator invariant violated.");
	$endif
	if (size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (!self.managed_bytes) return mem::OUT_OF_MEMORY~;
	sz effective = allocator_effective_alignment(alignment);
	if (effective > ((sz)BITMAP_BUDDY_LEAF) << self.max_order) return mem::INVALID_ALLOC_SIZE~;

	sz leaf_order = 0;
	if (!bitmap_buddy_leaf_order(size, effective, &leaf_order)) return mem::INVALID_ALLOC_SIZE~;
	if (leaf_order > self.max_order) return mem::OUT_OF_MEMORY~;

	sz found_order = 0;
	BitmapBuddyFree** found_link = bitmap_buddy_find_fit(self, leaf_order, effective, &found_order);
	if (!found_link) return mem::OUT_OF_MEMORY~;

	uptr block_start = (uptr)*found_link;
	sz block_size = ((sz)BITMAP_BUDDY_LEAF) << found_order;
	sz index = (sz)((block_start - self.buddy_base) >> (found_order + BITMAP_BUDDY_LEAF_SHIFT));
	*found_link = (*found_link).next;
	self.free_counts[found_order]--;
	for (sz k = found_order; k > leaf_order; k--)
	{
		sz half = ((sz)BITMAP_BUDDY_LEAF) << (k - 1);
		bitmap_buddy_set_bit(self.split_bits[k], index);
		uptr buddy_start = block_start + (uptr)half;
		BitmapBuddyFree* buddy = (BitmapBuddyFree*)buddy_start;
		buddy.next = self.free_heads[k - 1];
		self.free_heads[k - 1] = buddy;
		self.free_counts[k - 1]++;
		index <<= 1;
	}

	bitmap_buddy_set_bit(self.alloc_bits[leaf_order], index);
	void* result = (void*)block_start;
	self.free_bytes -= ((sz)BITMAP_BUDDY_LEAF) << leaf_order;
	allocator_zero_if(result, size, init_type);
	return result;
}

<*
 Remove a specific free block from its order list.

 @param [&inout] self : "The allocator owning the free lists"
 @param order : "The order list to search"
 @param block_start : "The block address to remove"
 @return "True when the block was present and removed"
*>
fn bool bitmap_buddy_remove_free(BitmapBuddyAllocator* self, sz order, uptr block_start) @local
{
	BitmapBuddyFree** link = &self.free_heads[order];
	while (*link)
	{
		if ((uptr)*link == block_start)
		{
			*link = (*link).next;
			self.free_counts[order]--;
			return true;
		}
		link = &(*link).next;
	}
	return false;
}

<*
 Release a whole block, merging with its free buddy while possible.

 The block order is recovered from the split bits, so no header is needed.
 Null, foreign, interior, and duplicate releases are ignored.

 @param [&inout] self : "The allocator that owns the block"
 @param [drop] old_pointer : "The payload to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void BitmapBuddyAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	$if env::TESTING:
		defer assert(self.debug_verify(), "BitmapBuddyAllocator invariant violated.");
	$endif
	if (!old_pointer) return;

	sz order = 0;
	uptr block_start = 0;
	if (!bitmap_buddy_locate(self, old_pointer, &order, &block_start)) return;

	sz index = (sz)((block_start - self.buddy_base) >> (order + BITMAP_BUDDY_LEAF_SHIFT));
	bitmap_buddy_clear_bit(self.alloc_bits[order], index);
	allocator_poison_if_testing(old_pointer, ((sz)BITMAP_BUDDY_LEAF) << order);
	self.free_bytes += ((sz)BITMAP_BUDDY_LEAF) << order;

	uptr merged_start = block_start;
	sz merged_order = order;
	sz merged_size = ((sz)BITMAP_BUDDY_LEAF) << order;
	sz merged_index = index;
	while (merged_order < self.max_order)
	{
		sz buddy_index = merged_index ^ 1;
		sz nblock = self.managed_bytes / (((sz)BITMAP_BUDDY_LEAF) << merged_order);
		if (buddy_index >= nblock) break;
		if (bitmap_buddy_bit(self.alloc_bits[merged_order], buddy_index)) break;
		if (bitmap_buddy_bit(self.split_bits[merged_order], buddy_index)) break;
		uptr buddy_start = self.buddy_base + ((uptr)buddy_index * (uptr)(((sz)BITMAP_BUDDY_LEAF) << merged_order));
		if (!bitmap_buddy_remove_free(self, merged_order, buddy_start)) break;
		if (buddy_start < merged_start) merged_start = buddy_start;
		bitmap_buddy_clear_bit(self.split_bits[merged_order + 1], merged_index >> 1);
		merged_index >>= 1;
		merged_order++;
		merged_size <<= 1;
	}

	BitmapBuddyFree* block = (BitmapBuddyFree*)merged_start;
	block.next = self.free_heads[merged_order];
	self.free_heads[merged_order] = block;
	self.free_counts[merged_order]++;
}

<*
 Check whether a pointer is a live block payload of this allocator.

 The pointer must be the exact start of a live block; interior pointers and
 foreign addresses report false.

 @param [&in] self : "The allocator to validate against"
 @param pointer : "A candidate payload pointer"
 @return "True when the pointer is a live block payload"
*>
fn bool BitmapBuddyAllocator.owns(&self, void* pointer)
{
	sz order = 0;
	uptr block_start = 0;
	return bitmap_buddy_locate(self, pointer, &order, &block_start);
}

<*
 Verify the bitmap buddy allocator's structural invariants.

 Walks every order's free list and checks each block: containment in
 the managed region, alignment to its block size, a clear `alloc` bit
 for its index, and that the walk length matches the order's free
 count; the size sum must match `free_bytes`. Returns false instead of
 crashing on a corrupt list, and caps each walk so a cycled list
 terminates. Runs automatically at the end of every mutating operation
 in test builds; call it directly in tests after hand-rolled operation
 sequences.

 @param [&in] self : "The allocator to verify"
 @return "True when all invariants hold"
*>
fn bool BitmapBuddyAllocator.debug_verify(&self)
{
	if (self.max_order < 0 || self.max_order >= BITMAP_BUDDY_MAX_ORDERS) return false;
	if (self.free_bytes < 0) return false;
	if (self.managed_bytes <= 0)
	{
		for (sz order = 0; order <= self.max_order; order++)
		{
			if (self.free_heads[order] != null || self.free_counts[order] != 0) return false;
		}
		return self.free_bytes == 0;
	}
	if (self.free_bytes > self.managed_bytes) return false;

	uptr managed_end = self.buddy_base + (uptr)self.managed_bytes;
	sz sum = 0;
	for (sz order = 0; order <= self.max_order; order++)
	{
		sz block_size = ((sz)BITMAP_BUDDY_LEAF << order);
		if (block_size <= 0 || block_size > self.managed_bytes) return false;
		if (self.alloc_bits[order] == null)
		{
			if (self.free_heads[order] != null || self.free_counts[order] != 0) return false;
			continue;
		}

		sz nblock = self.managed_bytes / block_size;
		sz count = 0;
		BitmapBuddyFree* block = self.free_heads[order];
		while (block)
		{
			count++;
			if (count > nblock)
			{
				return false;
			}

			uptr addr = (uptr)block;
			if (addr < self.buddy_base) return false;
			if (addr > uptr::max - (uptr)block_size) return false;
			if (addr + (uptr)block_size > managed_end) return false;
			if (((addr - self.buddy_base) & ((uptr)block_size - 1)) != 0) return false;

			sz index = (sz)((addr - self.buddy_base) >> (order + BITMAP_BUDDY_LEAF_SHIFT));
			if (bitmap_buddy_bit(self.alloc_bits[order], index)) return false;
			if (sum > self.managed_bytes - block_size) return false;

			sum += block_size;
			block = block.next;
		}
		if (count != self.free_counts[order]) return false;
	}
	return sum == self.free_bytes;
}

<*
 Resize a block previously acquired from this allocator.

 Shrinks stay in place when the smaller order covers the requested size:
 the block is re-marked at the smaller order and the right-hand buddies are
 published as free. Otherwise a replacement is acquired first, the block
 contents are copied, and the old block is released only after the copy
 succeeds. On any failure the old block and allocator state remain
 unchanged.

 @param [&inout] self : "The allocator that owns the block"
 @param [drop] old_pointer : "The payload pointer to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero to use the default"
 @return "The resized payload, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? BitmapBuddyAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	$if env::TESTING:
		defer assert(self.debug_verify(), "BitmapBuddyAllocator invariant violated.");
	$endif
	if (!old_pointer || new_size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;

	sz order = 0;
	uptr block_start = 0;
	if (!bitmap_buddy_locate(self, old_pointer, &order, &block_start)) return mem::INVALID_ALLOC_SIZE~;

	sz effective = allocator_effective_alignment(alignment);
	sz new_order = 0;
	if (!bitmap_buddy_leaf_order(new_size, effective, &new_order)) return mem::INVALID_ALLOC_SIZE~;
	if (new_order > self.max_order) return mem::OUT_OF_MEMORY~;

	sz old_size = ((sz)BITMAP_BUDDY_LEAF) << order;
	sz new_block_size = ((sz)BITMAP_BUDDY_LEAF) << new_order;
	if (new_order < order)
	{
		sz index = (sz)((block_start - self.buddy_base) >> (order + BITMAP_BUDDY_LEAF_SHIFT));
		bitmap_buddy_clear_bit(self.alloc_bits[order], index);
		// Poison before publishing: the tail region below becomes free
		// ranges, and publishing afterwards overwrites the node headers
		// with valid links instead of the poison overwriting them.
		allocator_poison_if_testing((char*)block_start + (uptr)new_block_size, old_size - new_block_size);
		sz cursor_index = index;
		for (sz k = order; k > new_order; k--)
		{
			sz half = ((sz)BITMAP_BUDDY_LEAF) << (k - 1);
			bitmap_buddy_set_bit(self.split_bits[k], cursor_index);
			uptr buddy_start = block_start + (uptr)half;
			BitmapBuddyFree* buddy = (BitmapBuddyFree*)buddy_start;
			buddy.next = self.free_heads[k - 1];
			self.free_heads[k - 1] = buddy;
			self.free_counts[k - 1]++;
			cursor_index <<= 1;
		}

		bitmap_buddy_set_bit(self.alloc_bits[new_order], cursor_index);
		self.free_bytes += old_size - new_block_size;
		return old_pointer;
	}
	if (new_order == order) return old_pointer;

	void*? replacement_opt = self.acquire(new_size, NO_ZERO, effective == mem::DEFAULT_MEM_ALIGNMENT ? 0 : effective);
	if (catch replacement_opt) return mem::OUT_OF_MEMORY~;

	void* replacement = replacement_opt;
	sz copy_size = old_size < new_block_size ? old_size : new_block_size;
	mem::copy(replacement, old_pointer, copy_size, mem::DEFAULT_MEM_ALIGNMENT, mem::DEFAULT_MEM_ALIGNMENT);
	self.release(old_pointer, alignment > mem::DEFAULT_MEM_ALIGNMENT);
	return replacement;
}
