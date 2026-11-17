module c3_allocs::allocators <Type>;

import std::core::mem::alloc;
import std::core::mem;

<*
 A fixed-capacity pool whose slot layout is derived from a type.

 This is a thin generic wrapper over `PoolAllocator`: the block size and
 alignment come from `Type`, so callers never pass raw sizes. Slot reuse,
 ownership checks, and in-place resize semantics match the wrapped pool.
 The storage is borrowed and must outlive the pool. This pool is not
 thread-safe.
*>
struct TypedPool
{
	PoolAllocator pool;
}

<*
 Initialize the typed pool over caller-owned storage.

 The slot count is computed exactly as `PoolAllocator.init` would with
 `Type::size` and `Type::alignment`.

 @param [&out] self : "The pool to initialize"
 @param storage : "The caller-owned buffer for the pool slots"
 @return "A pointer to the initialized pool"
*>
fn TypedPool* TypedPool.init(&self, char[] storage)
{
	self.pool.init(storage, Type::size, Type::alignment);
	return self;
}

<*
 Return the total number of slots in the pool.

 @param [&in] self : "The pool to query"
 @return "The slot capacity"
*>
fn sz TypedPool.capacity(&self) => self.pool.capacity();

<*
 Return the number of free slots in constant time.

 @param [&in] self : "The pool to query"
 @return "The unused slot count"
*>
fn sz TypedPool.available(&self) => self.pool.available();

<*
 Acquire one slot and return it as a typed pointer.

 A zero initialization request clears only the `Type` bytes of the slot.

 @param [&inout] self : "The pool to allocate from"
 @param init_type : "Whether the slot should be zero-initialized"
 @return "A pointer to the new value"
 @return? mem::OUT_OF_MEMORY
*>
fn Type*? TypedPool.acquire(&self, AllocInitType init_type = NO_ZERO)
{
	void*? slot = self.pool.acquire(Type::size, init_type, Type::alignment);
	if (catch slot) return mem::OUT_OF_MEMORY~;
	return (Type*)slot;
}

<*
 Release a value back to the pool for reuse.

 Null, foreign, interior, and duplicate releases are ignored, matching
 `PoolAllocator.release`.

 @param [&inout] self : "The pool that owns the value"
 @param [drop] value : "The value to release, or null"
*>
fn void TypedPool.release(&self, Type* value)
{
	self.pool.release(value, false);
}

<*
 Check whether a pointer is a slot payload of this pool.

 @param [&in] self : "The pool to validate against"
 @param value : "A candidate value pointer"
 @return "True when the pointer is a slot of this pool"
*>
fn bool TypedPool.owns(&self, Type* value) => self.pool.owns(value);
