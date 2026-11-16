module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;

<*
 A fixed-capacity pool allocator for blocks with a common maximum size and
 alignment. It reuses individual blocks when they are released.

 The pool borrows its storage and is not thread-safe. The storage must outlive
 the pool and every allocation from it.
*>
struct PoolAllocator (Allocator)
{
	char[] data;
	PoolSlot* free_head;
	sz block_size;
	sz alignment;
	sz payload_offset;
	sz slot_stride;
	sz first_slot_offset;
	sz slot_count;
	sz free_count;
}

struct PoolSlot @local
{
	PoolSlot* next;
	sz requested_size;
	bool in_use;
}

<*
 Initialize the pool over caller-owned storage.

 Each slot can serve requests up to `block_size` bytes. `alignment` is the
 maximum supported alignment; it is raised as needed to satisfy C3's default
 alignment and the alignment required by the slot metadata. The buffer is
 divided into as many whole slots as fit; any trailing remainder is unused.

 @param [&out] self : "The pool to initialize"
 @param storage : "The caller-owned buffer for the pool slots"
 @param block_size : "The maximum requested size of each allocation"
 @param alignment : "The maximum supported request alignment, or zero for default"
 @return "A pointer to the initialized pool"
 @require block_size > 0 : "Pool block size must be positive"
 @require !alignment || mem::is_valid_alignment(alignment) : "Pool alignment must be a valid power of two"
*>
fn PoolAllocator* PoolAllocator.init(&self, char[] storage, sz block_size, sz alignment = 0)
{
	assert(block_size > 0, "Pool block size must be positive.");
	assert(!alignment || mem::is_valid_alignment(alignment), "Pool alignment must be valid.");

	if (alignment < mem::DEFAULT_MEM_ALIGNMENT) alignment = mem::DEFAULT_MEM_ALIGNMENT;
	if (alignment < PoolSlot::alignment) alignment = PoolSlot::alignment;

	assert(mem::is_valid_alignment(alignment), "Effective pool alignment must be valid.");
	sz payload_offset = mem::aligned_offset(PoolSlot::size, alignment);
	assert(block_size <= sz::max - payload_offset, "Pool block size overflows slot size.");
	sz slot_size = payload_offset + block_size;
	assert(slot_size <= sz::max - (alignment - 1), "Pool slot stride overflows.");
	sz slot_stride = mem::aligned_offset(slot_size, alignment);

	uptr base_addr = (uptr)storage.ptr;
	uptr uptr_alignment = (uptr)alignment;
	assert(base_addr <= uptr::max - (uptr_alignment - 1), "Pool buffer address overflows.");
	uptr aligned_addr = (base_addr + uptr_alignment - 1) & ~(uptr_alignment - 1);
	sz first_slot_offset = (sz)(aligned_addr - base_addr);
	sz capacity = first_slot_offset <= storage.len ? (storage.len - first_slot_offset) / slot_stride : 0;

	self.data = storage;
	self.block_size = block_size;
	self.alignment = alignment;
	self.payload_offset = payload_offset;
	self.slot_stride = slot_stride;
	self.first_slot_offset = first_slot_offset;
	self.slot_count = capacity;
	self.free_count = capacity;
	PoolSlot* free_head = null;
	for (sz i = capacity; i > 0; i--)
	{
		PoolSlot* slot = (PoolSlot*)(aligned_addr + (uptr)((i - 1) * slot_stride));
		slot.next = free_head;
		slot.requested_size = 0;
		slot.in_use = false;
		free_head = slot;
	}

	self.free_head = free_head;
	return self;
}

<*
 Return the number of fixed-size slots available in the pool.

 @param [&in] self : "The pool to inspect"
 @return "The total slot capacity"
*>
fn sz PoolAllocator.capacity(&self) => self.slot_count;

<*
 Return the number of currently available slots in constant time.

 @param [&in] self : "The pool to inspect"
 @return "The number of unused slots"
*>
fn sz PoolAllocator.available(&self)
{
	return self.free_count;
}

<*
 Acquire one slot from the pool.

 The request must fit in the configured block size and must not request more
 alignment than the pool supports. Released slots are reused. A zero
 initialization request clears only the requested byte range.

 @param [&inout] self : "The pool to allocate from"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the requested bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated slot payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? PoolAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	if (size <= 0 || size > self.block_size) return mem::INVALID_ALLOC_SIZE~;
	if (alignment && !mem::is_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if ((alignment ?: mem::DEFAULT_MEM_ALIGNMENT) > self.alignment) return mem::INVALID_ALLOC_SIZE~;
	if (!self.free_head) return mem::OUT_OF_MEMORY~;

	PoolSlot* slot = self.free_head;
	self.free_head = slot.next;
	self.free_count--;
	slot.next = null;
	slot.requested_size = size;
	slot.in_use = true;
	void* result = (char*)slot + self.payload_offset;
	if (init_type == ZERO) mem::clear(result, size, mem::DEFAULT_MEM_ALIGNMENT);
	return result;
}

<*
 Resize a currently allocated pool block in place.

 Pool blocks never move during resize. The new size must fit the configured
 block size, and the requested alignment must be supported. Existing contents
 are preserved up to the smaller of the old and new sizes. Failure leaves the
 allocation unchanged.

 @param [&inout] self : "The pool that acquired the block"
 @param [drop] old_pointer : "The allocation to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero for the default"
 @return "The same pointer with the updated requested size"
 @return? mem::INVALID_ALLOC_SIZE
*>
fn void*? PoolAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	if (!old_pointer || new_size <= 0 || new_size > self.block_size) return mem::INVALID_ALLOC_SIZE~;
	if (alignment && !mem::is_valid_alignment(alignment)) return mem::INVALID_ALLOC_SIZE~;
	if ((alignment ?: mem::DEFAULT_MEM_ALIGNMENT) > self.alignment) return mem::INVALID_ALLOC_SIZE~;

	PoolSlot* slot = pool_slot_for_pointer(self, old_pointer);
	if (!slot || !slot.in_use) return mem::INVALID_ALLOC_SIZE~;

	slot.requested_size = new_size;
	return old_pointer;
}

<*
 Return a pointer's slot metadata when it is exactly a payload pointer in this pool.

 @param [&in] self : "The pool to validate against"
 @param pointer : "A candidate payload pointer"
 @return "The corresponding slot, or null when the pointer is outside the pool"
*>
fn PoolSlot* pool_slot_for_pointer(PoolAllocator* self, void* pointer) @local
{
	if (!pointer || !self.slot_stride || !self.slot_count) return null;

	uptr base_addr = (uptr)self.data.ptr;
	uptr pointer_addr = (uptr)pointer;
	uptr first_payload_addr = base_addr + (uptr)(self.first_slot_offset + self.payload_offset);
	if (pointer_addr < first_payload_addr) return null;

	uptr displacement = pointer_addr - first_payload_addr;
	if (displacement % (uptr)self.slot_stride != 0) return null;

	sz slot_index = (sz)(displacement / (uptr)self.slot_stride);
	if (slot_index >= self.slot_count) return null;
	return (PoolSlot*)(base_addr + (uptr)self.first_slot_offset + (uptr)(slot_index * self.slot_stride));
}

<*
 Release a slot acquired from this pool so it can be reused.

 Null, foreign, interior, and already-released pointers are ignored. The
 `aligned` parameter is accepted to satisfy the Allocator interface; all pool
 payloads meet the configured alignment.

 @param [&inout] self : "The pool that acquired the block"
 @param [drop] old_pointer : "The allocation to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void PoolAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	PoolSlot* slot = pool_slot_for_pointer(self, old_pointer);
	if (!slot || !slot.in_use || self.free_count >= self.slot_count) return;

	slot.in_use = false;
	slot.requested_size = 0;
	slot.next = self.free_head;
	self.free_head = slot;
	self.free_count++;
}
