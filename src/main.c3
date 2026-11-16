module c3_allocs;

import std::io;
import std::core::mem::alloc;
import c3_allocs::allocators;

fn int main(String[] args)
{
	io::printn("c3_allocs demo");

	char[4096] arena_storage;
	allocators::ArenaAllocator arena;
	arena.init(arena_storage[..]);

	void* arena_item = alloc::malloc(&arena, 128);
	io::printf("arena: capacity=%d reserved=%d\n", arena.capacity(), arena.bytes_reserved());
	alloc::free(&arena, arena_item);
	arena.clear();
	io::printf("arena after clear: reserved=%d\n", arena.bytes_reserved());

	char[4096] pool_storage;
	allocators::PoolAllocator pool;
	pool.init(pool_storage[..], 64, 16);

	void* pool_item = alloc::malloc(&pool, 48);
	io::printf("pool: capacity=%d available=%d\n", pool.capacity(), pool.available());
	alloc::free(&pool, pool_item);
	io::printf("pool after free: available=%d\n", pool.available());

	char[1024] initial_storage;
	char[8192] backing_storage;
	allocators::ArenaAllocator backing;
	backing.init(backing_storage[..]);

	c3_allocs::allocators::BackedArenaAllocator backed;
	backed.init(initial_storage[..], &backing);
	sz backed_mark = backed.mark();

	void* backed_item = alloc::malloc(&backed, 2048);
	io::printf("backed arena: overflow=%d used=%d\n", backed.overflow_count(), backed.bytes_used());
	backed.reset(backed_mark);
	io::printf("backed arena after reset: overflow=%d\n", backed.overflow_count());
	backed.free();

	char[4096] freelist_storage;
	allocators::FreeListAllocator freelist;
	freelist.init(freelist_storage[..]);
	void* list_first = alloc::malloc(&freelist, 48);
	void* list_second = alloc::malloc(&freelist, 96);
	io::printf(
		"freelist: capacity=%d used=%d free=%d\n",
		freelist.capacity(),
		freelist.bytes_used(),
		freelist.bytes_free()
	);

	alloc::free(&freelist, list_first);
	alloc::free(&freelist, list_second);
	freelist.clear();
	io::printf("freelist after clear: free=%d\n", freelist.bytes_free());
	return 0;
}
