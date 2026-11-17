module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

const SIZE_CLASS_MAX = 8;

<*
 A dispatcher over fixed-size pools for mixed allocation sizes.

 Each class is a `PoolAllocator` over caller-owned storage, so every block
 has a bounded size and release is O(1) with no coalescing pass. `acquire`
 routes to the smallest class that fits the request and has a free slot,
 which bounds internal fragmentation to the gap between adjacent classes.
 Classes the workload never uses still reserve their whole buffer (pool
 superblock fragmentation), so only configure sizes you actually allocate.

 A stepped table (equal steps between small sizes, factored growth after)
 keeps the gaps small where most requests land. For example: 24, 48, 96,
 192, 384. The buffers, sizes, and alignment are caller-owned choices made
 at `init` time. This allocator is not thread-safe.
*>
struct SizeClassAllocator (Allocator) @mustinit
{
	PoolAllocator[SIZE_CLASS_MAX] pools;
	sz num_classes;
}

<*
 Initialize the dispatcher over caller-owned class buffers.

 Each buffer is divided into slots sized for the matching entry in
 `block_sizes`, exactly as `PoolAllocator.init` would. The buffers and the
 size table are borrowed, not copied. Every size must be positive and the
 two arrays must have equal, non-zero length within `SIZE_CLASS_MAX`.
 Invalid configurations leave zero classes configured, so every
 acquisition fails cleanly instead of indexing out of bounds.

 @param [&out] self : "The dispatcher to initialize"
 @param buffers : "One borrowed buffer per size class"
 @param block_sizes : "The maximum payload size per class; every size must be positive"
 @param alignment : "The maximum supported alignment for all classes, or zero for default"
 @return "A pointer to the initialized dispatcher"
*>
fn SizeClassAllocator* SizeClassAllocator.init(&self, char[][] buffers, sz[] block_sizes, sz alignment = 0)
{
	if (buffers.len != block_sizes.len || buffers.len <= 0 || buffers.len > SIZE_CLASS_MAX
		|| !allocator_valid_alignment(
		alignment
	))
	{
		PoolAllocator[SIZE_CLASS_MAX] empty_pools;
		char[1] empty_storage;
		for (sz i = 0; i < SIZE_CLASS_MAX; i++)
		{
			empty_pools[i].init(empty_storage[..], 1, 0);
		}

		self.pools = empty_pools;
		self.num_classes = 0;
		return self;
	}

	sz count = buffers.len;
	PoolAllocator[SIZE_CLASS_MAX] pools;
	for (sz i = 0; i < count; i++)
	{
		pools[i].init(buffers[i], block_sizes[i], alignment);
	}
	for (sz i = count; i < SIZE_CLASS_MAX; i++)
	{
		pools[i].init(buffers[0][0..0], 1, alignment);
	}

	self.pools = pools;
	self.num_classes = count;
	return self;
}

<*
 Initialize a dispatcher with a built-in stepped size table over one buffer.

 The stepped table covers common small mixed allocations: 24, 48, 96, 192,
 and 384 bytes for five classes, and 24, 48, 96, 192, 384, 768, 1536, and
 3072 bytes for eight classes (the smaller prefixes repeat the last listed
 step pattern: sizes always follow 24 * 2^k, doubling per class). The
 buffer is divided equally among classes in order; each class gets
 `buffer_len / class_count` bytes. Remaining classes beyond the requested
 count stay empty and never serve requests.

 @param [&out] self : "The dispatcher to initialize"
 @param storage : "The single borrowed buffer divided across classes"
 @param class_count : "How many size classes to configure, 1..SIZE_CLASS_MAX"
 @param alignment : "The maximum supported alignment for all classes, or zero for default"
 @return "A pointer to the initialized dispatcher"
*>
fn SizeClassAllocator* SizeClassAllocator.init_preset(&self, char[] storage, sz class_count, sz alignment = 0)
{
	if (class_count < 1 || class_count > SIZE_CLASS_MAX || !allocator_valid_alignment(alignment))
	{
		PoolAllocator[SIZE_CLASS_MAX] empty_pools;
		char[1] empty_storage;
		for (sz i = 0; i < SIZE_CLASS_MAX; i++)
		{
			empty_pools[i].init(empty_storage[..], 1, 0);
		}

		self.pools = empty_pools;
		self.num_classes = 0;
		return self;
	}

	sz share = storage.len / class_count;
	char[][SIZE_CLASS_MAX] slices;
	for (sz i = 0; i < class_count; i++)
	{
		sz begin = i * share;
		sz end = (i + 1) * share;
		if (end > storage.len) end = storage.len;
		slices[i] = storage[begin:end - begin];
	}

	sz count = class_count;
	PoolAllocator[SIZE_CLASS_MAX] pools;
	for (sz i = 0; i < count; i++)
	{
		pools[i].init(slices[i], (sz)24 << i, alignment);
	}

	self.pools = pools;
	self.num_classes = count;
	return self;
}

<*
 Return the number of configured size classes.

 @param [&in] self : "The dispatcher to query"
 @return "The class count"
*>
fn sz SizeClassAllocator.class_count(&self) => self.num_classes;

<*
 Return the maximum payload size of a class.

 @param [&in] self : "The dispatcher to query"
 @param index : "The class index, below `class_count`"
 @return "The class block size"
*>
fn sz SizeClassAllocator.class_block_size(&self, sz index)
{
	assert(index >= 0 && index < self.num_classes, "Size class index out of range.");
	return self.pools[index].block_size;
}

<*
 Return the free slots of one class.

 @param [&in] self : "The dispatcher to query"
 @param index : "The class index, below `class_count`"
 @return "The class free-slot count"
*>
fn sz SizeClassAllocator.class_available(&self, sz index)
{
	assert(index >= 0 && index < self.num_classes, "Size class index out of range.");
	return self.pools[index].available();
}

<*
 Return the total slots across all classes.

 @param [&in] self : "The dispatcher to query"
 @return "The total slot capacity"
*>
fn sz SizeClassAllocator.capacity(&self)
{
	sz total = 0;
	for (sz i = 0; i < self.num_classes; i++) total += self.pools[i].capacity();
	return total;
}

<*
 Return the total free slots across all classes.

 @param [&in] self : "The dispatcher to query"
 @return "The total free-slot count"
*>
fn sz SizeClassAllocator.available(&self)
{
	sz total = 0;
	for (sz i = 0; i < self.num_classes; i++) total += self.pools[i].available();
	return total;
}

<*
 Route an allocation to the smallest fitting class with a free slot.

 The request must fit at least one class and meet the configured alignment.
 Requests larger than every class report `INVALID_ALLOC_SIZE`; exhaustion
 of the fitting classes reports `OUT_OF_MEMORY` without consuming a slot.

 @param [&inout] self : "The dispatcher to allocate from"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the requested bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated slot payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? SizeClassAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	if (size <= 0) return mem::INVALID_ALLOC_SIZE~;
	if (!allocator_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if (!self.num_classes) return mem::OUT_OF_MEMORY~;

	sz effective = allocator_effective_alignment(alignment);
	if (effective > self.pools[0].alignment) return mem::INVALID_ALLOC_SIZE~;

	sz best = -1;
	sz largest = 0;
	for (sz i = 0; i < self.num_classes; i++)
	{
		sz class_size = self.pools[i].block_size;
		if (class_size > largest) largest = class_size;
		if (class_size >= size && self.pools[i].available() > 0)
		{
			if (best == -1 || class_size < self.pools[best].block_size) best = i;
		}
	}
	if (best == -1)
	{
		if (size > largest) return mem::INVALID_ALLOC_SIZE~;
		return mem::OUT_OF_MEMORY~;
	}
	return self.pools[best].acquire(size, init_type, alignment);
}

<*
 Find the class owning an exact payload pointer.

 @param [&in] self : "The dispatcher to search"
 @param pointer : "A candidate payload pointer"
 @return "The owning class index, or -1 when no class owns it"
*>
fn sz sizeclass_owner(SizeClassAllocator* self, void* pointer) @local
{
	for (sz i = 0; i < self.num_classes; i++)
	{
		if (self.pools[i].owns(pointer)) return i;
	}
	return -1;
}

<*
 Resize a block in its owning class pool.

 Pools never move, so the pointer is stable and only the requested size
 changes. Failure leaves the allocation unchanged.

 @param [&inout] self : "The dispatcher that owns the block"
 @param [drop] old_pointer : "The allocation to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero for the default"
 @return "The same pointer with the updated requested size"
 @return? mem::INVALID_ALLOC_SIZE
*>
fn void*? SizeClassAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	if (!old_pointer) return mem::INVALID_ALLOC_SIZE~;

	sz owner = sizeclass_owner(self, old_pointer);
	if (owner < 0) return mem::INVALID_ALLOC_SIZE~;
	return self.pools[owner].resize(old_pointer, new_size, alignment);
}

<*
 Release a slot back to its owning class pool.

 Null, foreign, interior, and duplicate releases are ignored.

 @param [&inout] self : "The dispatcher that owns the block"
 @param [drop] old_pointer : "The allocation to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void SizeClassAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	if (!old_pointer) return;

	sz owner = sizeclass_owner(self, old_pointer);
	if (owner < 0) return;
	self.pools[owner].release(old_pointer, aligned);
}
