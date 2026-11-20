module c3_allocs::allocators;

import std::core::mem::alloc;
import std::core::mem;
import std::thread;

<*
 A thread-safe wrapper making any allocator safe for shared use.

 All allocators in this module are single-threaded. This wrapper
 serializes every operation through one non-recursive mutex, so the
 wrapped allocator can be shared across threads. Calls never re-enter
 the wrapper while holding the lock (no operation calls back into it),
 so no lock-order cycle is possible; the wrapper itself must not be
 re-entered from within a call, as the mutex is not recursive.

 The wrapper holds no allocation metadata of its own: introspection
 such as ownership or canary queries cannot pass through the erased
 `Allocator` interface, so use the backing allocator directly for
 those, after quiescing concurrent users. The wrapper never runs
 destructors.
*>
struct SynchronizedAllocator (Allocator) @mustinit
{
	Allocator backing;
	Mutex mutex;
	bool valid;
}

<*
 Initialize the wrapper over another allocator.

 The mutex is initialized here. If that initialization ever fails, the
 wrapper is left invalid and every operation fails closed instead of
 using an uninitialized lock.

 @param [&out] self : "The wrapper to initialize"
 @param backing : "The allocator to serialize access to"
 @return "A pointer to the initialized wrapper"
*>
fn SynchronizedAllocator* SynchronizedAllocator.init(&self, Allocator backing)
{
	self.backing = backing;
	self.valid = false;
	if (catch self.mutex.init())
	{
		return self;
	}

	self.valid = true;
	return self;
}

<*
 Check whether the wrapper is usable.

 A wrapper is usable after a successful initialization and until
 `free` is called.

 @param [&in] self : "The wrapper to query"
 @return "True when operations may proceed"
*>
fn bool SynchronizedAllocator.is_valid(&self) => self.valid;

<*
 Release the wrapper's mutex.

 After this call the wrapper must be reinitialized before further use.
 Releasing an already-freed or never-initialized wrapper is a no-op.

 @param [&inout] self : "The wrapper to free"
*>
fn void SynchronizedAllocator.free(&self)
{
	if (!self.valid) return;

	self.valid = false;
	self.mutex.destroy();
}

<*
 Acquire a block, serialized against concurrent users.

 A lock failure reports `OUT_OF_MEMORY`. Otherwise the request is
 forwarded to the backing allocator unchanged.

 @param [&inout] self : "The wrapper to allocate from"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the requested bytes should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? SynchronizedAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	if (!self.valid) return mem::OUT_OF_MEMORY~;
	if (catch self.mutex.lock()) return mem::OUT_OF_MEMORY~;

	defer self.mutex.unlock();
	return self.backing.acquire(size, init_type, alignment);
}

<*
 Release a block, serialized against concurrent users.

 A lock failure ignores the release. Otherwise the pointer is
 forwarded to the backing allocator unchanged.

 @param [&inout] self : "The wrapper that owns the block"
 @param [drop] old_pointer : "The payload to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void SynchronizedAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	if (!self.valid) return;
	if (!old_pointer) return;
	if (catch self.mutex.lock()) return;

	defer self.mutex.unlock();
	self.backing.release(old_pointer, aligned);
}

<*
 Resize a block, serialized against concurrent users.

 A lock failure reports `OUT_OF_MEMORY`. Otherwise the request is
 forwarded to the backing allocator unchanged.

 @param [&inout] self : "The wrapper that owns the block"
 @param [drop] old_pointer : "The payload pointer to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero for the default"
 @return "The resized payload, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? SynchronizedAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	if (!self.valid) return mem::OUT_OF_MEMORY~;
	if (catch self.mutex.lock()) return mem::OUT_OF_MEMORY~;

	defer self.mutex.unlock();
	return self.backing.resize(old_pointer, new_size, alignment);
}
