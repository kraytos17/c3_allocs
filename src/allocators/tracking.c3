module c3_allocs::allocators;

import std::collections;
import std::core::mem::alloc;
import std::core::mem;
import std::io;

const TRACKING_UNKNOWN @local = "<direct>";

<*
 A debug wrapper that records every acquire, resize, and release made
 through it.

 The wrapped allocator is stored as an `Allocator` interface value, so any
 allocator can be tracked without generics. Each live allocation carries
 the source location of the tracked call, captured by the `trk_*` macros
 through the `$$FILE` / `$$FUNC` / `$$LINE` builtins. Direct interface
 calls are still tracked, but with an unknown location.

 Pointer lookups are O(1): a `HashMap{ulong, sz}` from the standard
 library, keyed by the allocation pointer, maps to the record array index,
 so release and resize do not scan the records. The record array is served
 by the wrapped allocator itself; the map is bookkeeping and uses the
 global allocator, so an exhausted backing never breaks the tracker. This
 wrapper is not thread-safe.
*>
struct TrackingAllocator (Allocator) @mustinit
{
	Allocator backing;
	TrackingRecord* entries;
	HashMap{ulong, sz} index;
	sz count;
	sz capacity;
	sz live_total;
	sz live_byte_total;
	sz total_allocs;
	sz unmatched_releases;
}

<*
 One tracked allocation: the live pointer plus the tracked call site.

 The site strings point at static source data and are not copied.
*>
struct TrackingRecord @local
{
	void* pointer;
	sz requested_size;
	String file;
	String func;
	int line;
}

<*
 Initialize the tracker over a wrapped allocator.

 The record array is served by `backing` itself, so the tracker must be
 initialized after its backing allocator. The lookup map uses the global
 allocator.

 @param [&out] self : "The tracker to initialize"
 @param backing : "The allocator to wrap and to serve the records"
 @return "A pointer to the initialized tracker"
*>
fn TrackingAllocator* TrackingAllocator.init(&self, Allocator backing)
{
	self.backing = backing;
	self.entries = null;
	self.index.init(mem);
	self.count = 0;
	self.capacity = 0;
	self.live_total = 0;
	self.live_byte_total = 0;
	self.total_allocs = 0;
	self.unmatched_releases = 0;
	return self;
}

<*
 Return the number of allocations currently live.

 @param [&in] self : "The tracker to query"
 @return "The live allocation count"
*>
fn sz TrackingAllocator.live_count(&self) => self.live_total;

<*
 Return the requested bytes of the currently live allocations.

 @param [&in] self : "The tracker to query"
 @return "The live requested byte count"
*>
fn sz TrackingAllocator.live_bytes(&self) => self.live_byte_total;

<*
 Return how many allocations were ever made through the tracker.

 @param [&in] self : "The tracker to query"
 @return "The lifetime allocation count"
*>
fn sz TrackingAllocator.total_count(&self) => self.total_allocs;

<*
 Return how many releases did not match a live tracked pointer.

 A nonzero count means a double release of a tracked pointer or a release
 of a pointer that never came from this tracker.

 @param [&in] self : "The tracker to query"
 @return "The unmatched release count"
*>
fn sz TrackingAllocator.double_releases(&self) => self.unmatched_releases;

<*
 Find the record index for a tracked pointer through the hash table.

 @param [&in] self : "The tracker to search"
 @param pointer : "The candidate pointer"
 @return "The record index, or -1 when the pointer is not tracked"
*>
fn sz tracking_find(TrackingAllocator* self, void* pointer) @local
{
	sz? index_opt = self.index.get((ulong)(uptr)pointer);
	if (catch index_opt) return -1;
	return index_opt;
}

<*
 Grow the record array through the wrapped allocator.

 @param [&inout] self : "The tracker whose array grows"
 @return "False when the backing allocator failed"
*>
fn bool tracking_grow(TrackingAllocator* self) @local
{
	sz new_capacity = self.capacity == 0 ? 16 : self.capacity * 2;
	void*? grown_opt = self.backing.acquire(new_capacity * TrackingRecord::size, NO_ZERO, TrackingRecord::alignment);
	if (catch grown_opt) return false;

	TrackingRecord* grown = grown_opt;
	if (self.count > 0)
	{
		mem::copy(
			grown,
			self.entries,
			self.count * TrackingRecord::size,
			mem::DEFAULT_MEM_ALIGNMENT,
			mem::DEFAULT_MEM_ALIGNMENT
		);
	}
	if (self.entries) self.backing.release(self.entries, false);

	self.entries = grown;
	self.capacity = new_capacity;
	return true;
}

<*
 Record an acquisition with an explicit source location.

 @param [&inout] self : "The tracker recording the allocation"
 @param pointer : "The acquired pointer"
 @param size : "The requested byte count"
 @param file : "The tracked call site file"
 @param func : "The tracked call site function"
 @param line : "The tracked call site line"
 @return "False when recording failed, in which case the caller must release"
*>
fn bool tracking_record(TrackingAllocator* self, void* pointer, sz size, String file, String func, int line) @local
{
	if (self.count == self.capacity && !tracking_grow(self)) return false;

	self.index.set((ulong)(uptr)pointer, self.count);
	self.entries[self.count] = { pointer, size, file, func, line };
	self.count++;
	self.live_total++;
	self.live_byte_total += size;
	self.total_allocs++;
	return true;
}

<*
 Acquire memory and record the allocation under the given location.

 @param [&inout] self : "The tracker to allocate through"
 @param file : "The tracked call site file"
 @param func : "The tracked call site function"
 @param line : "The tracked call site line"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the payload should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? TrackingAllocator.acquire_at(
	&self,
	String file,
	String func,
	int line,
	sz size,
	AllocInitType init_type = NO_ZERO,
	sz alignment = 0
)
{
	void*? result_opt = self.backing.acquire(size, init_type, alignment);
	if (catch result_opt) return result_opt;
	if (!tracking_record(self, result_opt, size, file, func, line))
	{
		self.backing.release(result_opt, alignment > mem::DEFAULT_MEM_ALIGNMENT);
		return mem::OUT_OF_MEMORY~;
	}
	return result_opt;
}

<*
 Acquire memory through the wrapped allocator, tracked with an unknown site.

 @param [&inout] self : "The tracker to allocate through"
 @param size : "The number of bytes requested; must be greater than zero"
 @param init_type : "Whether the payload should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? TrackingAllocator.acquire(
	&self,
	sz size,
	AllocInitType init_type,
	sz alignment = 0
) @dynamic => self.acquire_at(TRACKING_UNKNOWN, "", 0, size, init_type, alignment);


<*
 Resize a tracked allocation, keeping the original call site.

 @param [&inout] self : "The tracker that owns the block"
 @param [drop] old_pointer : "The payload to resize"
 @param new_size : "The new requested size; must be greater than zero"
 @param alignment : "The required alignment, or zero for the default"
 @return "The resized payload, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? TrackingAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment = 0) @dynamic
{
	void*? result_opt = self.backing.resize(old_pointer, new_size, alignment);
	if (catch result_opt) return result_opt;

	void* result = result_opt;
	sz index = tracking_find(self, old_pointer);
	if (index >= 0)
	{
		self.live_byte_total -= self.entries[index].requested_size;
		self.entries[index].pointer = result;
		self.entries[index].requested_size = new_size;
		self.live_byte_total += new_size;
		self.index.remove((ulong)(uptr)old_pointer);
		self.index.set((ulong)(uptr)result, index);
	}
	return result;
}

<*
 Release a tracked allocation, removing its record.

 Releasing a pointer that is not currently tracked counts as an unmatched
 release and is not forwarded, which keeps a double release from reaching
 the wrapped allocator a second time.

 @param [&inout] self : "The tracker that owns the block"
 @param [drop] old_pointer : "The payload to release, or null"
 @param aligned : "Whether the original request specified alignment"
*>
fn void TrackingAllocator.release(&self, void* old_pointer, bool aligned) @dynamic
{
	if (!old_pointer) return;

	sz index = tracking_find(self, old_pointer);
	if (index < 0)
	{
		self.unmatched_releases++;
		return;
	}

	self.backing.release(old_pointer, aligned);
	self.live_byte_total -= self.entries[index].requested_size;
	self.index.remove((ulong)(uptr)old_pointer);
	sz moved_index = self.count - 1;
	if (moved_index != index)
	{
		TrackingRecord moved = self.entries[moved_index];
		self.entries[index] = moved;
		self.index.remove((ulong)(uptr)moved.pointer);
		self.index.set((ulong)(uptr)moved.pointer, index);
	}

	self.count--;
	self.live_total--;
}

<*
 Print one line per live allocation with its tracked call site.

 @param [&in] self : "The tracker to inspect"
 @return "The number of leaked allocations"
*>
fn sz TrackingAllocator.report_leaks(&self)
{
	for (sz i = 0; i < self.count; i++)
	{
		TrackingRecord* record = &self.entries[i];
		io::printf(
			"tracking leak: %d bytes at %s:%s:%d\n",
			record.requested_size,
			record.file,
			record.func,
			record.line
		);
	}
	return self.count;
}

<*
 Check whether every tracked allocation was released.

 @param [&in] self : "The tracker to inspect"
 @return "True when no live allocations remain"
*>
fn bool TrackingAllocator.check_no_leaks(&self) => self.count == 0;

<*
 Release the record array and the hash table itself.

 Check for leaks before calling; the records are not preserved.

 @param [&inout] self : "The tracker to free"
*>
fn void TrackingAllocator.free(&self)
{
	if (self.entries) self.backing.release(self.entries, false);

	self.index.free();
	self.entries = null;
	self.count = 0;
	self.capacity = 0;
	self.live_total = 0;
	self.live_byte_total = 0;
}

<*
 Allocate and track with the call site recorded automatically.

 @param t : "The tracker to allocate through"
 @param size : "The number of bytes requested"
 @param init : "Whether the payload should be zero-initialized"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the allocated payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
macro void*? trk_malloc(
	TrackingAllocator* t,
	sz size,
	AllocInitType init = NO_ZERO,
	sz alignment = 0
) => t.acquire_at($$FILE, $$FUNC, (int)$$LINE, size, init, alignment);

<*
 Allocate zeroed and track with the call site recorded automatically.

 @param t : "The tracker to allocate through"
 @param size : "The number of bytes requested"
 @param alignment : "The required alignment, or zero for the default"
 @return "A pointer to the zeroed payload"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
macro void*? trk_calloc(
	TrackingAllocator* t,
	sz size,
	sz alignment = 0
) => t.acquire_at($$FILE, $$FUNC, (int)$$LINE, size, ZERO, alignment);

<*
 Resize a tracked allocation with the call site recorded automatically.

 @param t : "The tracker that owns the block"
 @param pointer : "The payload to resize, or null to allocate"
 @param new_size : "The new requested size"
 @param alignment : "The required alignment, or zero for the default"
 @return "The resized payload, which may have moved"
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
macro void*? trk_realloc(TrackingAllocator* t, void* pointer, sz new_size, sz alignment = 0)
{
	if (!new_size)
	{
		trk_free(t, pointer);
		return null;
	}
	if (!pointer) return trk_malloc(t, new_size);

	void*? result_opt = t.resize(pointer, new_size, alignment);
	if (catch result_opt) return result_opt;

	sz index = tracking_find(t, result_opt);
	if (index >= 0)
	{
		t.entries[index].file = $$FILE;
		t.entries[index].func = $$FUNC;
		t.entries[index].line = (int)$$LINE;
	}
	return result_opt;
}

<*
 Release a tracked allocation with the call site recorded automatically.

 @param t : "The tracker that owns the block"
 @param pointer : "The payload to release, or null"
*>
macro void trk_free(TrackingAllocator* t, void* pointer) => t.release(pointer, false);
