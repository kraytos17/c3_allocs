module c3_allocs::fuzz_common;

import std::core::mem;
import std::core::mem::alloc;
import std::io;
import c3_allocs::allocators;

const FUZZ_DEFAULT_SEED = 1;
const FUZZ_DEFAULT_ITERATIONS = 20000;
const FUZZ_DEFAULT_MAXLIVE = 64;
const FUZZ_MAXLIVE = 256;
const FUZZ_LOG_SIZE = 64;

struct FuzzOp
{
	sz kind;
	sz a;
	sz b;
}

const FUZZ_ACQUIRE_OK = 1;
const FUZZ_ACQUIRE_FAIL = 2;
const FUZZ_RELEASE = 3;
const FUZZ_RESIZE_OK = 4;
const FUZZ_RESIZE_FAIL = 5;
const FUZZ_GUARD = 6;
const FUZZ_HOSTILE = 7;
const FUZZ_RESET = 8;
const FUZZ_POLICY = 9;
const FUZZ_CLEAR = 10;

struct FuzzRng
{
	ulong s;
	char[] bytes;
	sz pos;
}

fn FuzzRng fuzz_rng_seed(ulong seed)
{
	FuzzRng rng;
	rng.s = seed;
	rng.pos = 0;
	return rng;
}

fn FuzzRng fuzz_rng_stream(ulong seed, char[] bytes)
{
	FuzzRng rng;
	rng.s = seed;
	rng.bytes = bytes;
	rng.pos = 0;
	return rng;
}

fn ulong fuzz_next(FuzzRng* rng) @local
{
	if (rng.pos + 8 <= rng.bytes.len)
	{
		ulong v = 0;
		for (sz i = 0; i < 8; i++) v |= (ulong)(rng.bytes[rng.pos + i] & 0xFF) << (i * 8);
		rng.pos += 8;
		return v;
	}

	rng.s ^= rng.s << 13;
	rng.s ^= rng.s >> 7;
	rng.s ^= rng.s << 17;
	return rng.s;
}

fn ulong fuzz_arg(String[] args, sz index, ulong fallback)
{
	if (index >= args.len) return fallback;

	int? parsed = args[index].to_int();
	if (catch parsed) return fallback;

	int value = parsed;
	if (value < 0) return fallback;
	return (ulong)value;
}

fn sz fuzz_size(FuzzRng* rng) @local
{
	sz[24] edges = {
		0, 1, 2, 7, 8, 9, 15, 16, 17, 23, 24, 25,
		31, 32, 33, 47, 48, 49, 63, 64, 65, 100, 128, 200
	};

	ulong r = fuzz_next(rng);
	if (r % 32 == 0) return 0;
	if (r % 4 == 0) return 1 + (sz)(fuzz_next(rng) % 256);
	return edges[r % 24];
}

fn sz fuzz_alignment(FuzzRng* rng) @local
{
	sz[7] aligns = { 0, 0, 8, 16, 16, 32, 64 };
	ulong r = fuzz_next(rng);
	if (r % 50 == 0) return 3;
	return aligns[r % 7];
}

fn alloc::AllocInitType fuzz_init_type(FuzzRng* rng) @local
{
	return fuzz_next(rng) % 3 == 0 ? alloc::AllocInitType.ZERO : alloc::AllocInitType.NO_ZERO;
}

fn FuzzRng fuzz_rng_hf_stream(ulong seed, char[] bytes, usz* mask)
{
	FuzzRng rng = fuzz_rng_stream(seed, bytes);
	if (bytes.len >= 8)
	{
		ulong m = fuzz_next(&rng);
		*mask = (usz)(m % 11);
	}
	else
	{
		*mask = 10;
	}
	return rng;
}

fn void fuzz_log(FuzzOp[] log, sz op, sz kind, sz a, sz b) @local
{
	log[op % FUZZ_LOG_SIZE].kind = kind;
	log[op % FUZZ_LOG_SIZE].a = a;
	log[op % FUZZ_LOG_SIZE].b = b;
}

fn void fuzz_dump(ulong seed, String who, sz op, FuzzOp[] log, String message) @local
{
	io::printf("FUZZ FAIL seed=%d %s op=%d: %s\n", (sz)seed, who, op, message);
	io::printn("--- last 64 ops (kind a b) ---");
	sz start = op > FUZZ_LOG_SIZE ? op - FUZZ_LOG_SIZE : 0;
	for (sz i = start; i < op; i++)
	{
		FuzzOp e = log[i % FUZZ_LOG_SIZE];
		io::printf("op=%d kind=%d a=%d b=%d\n", i, e.kind, e.a, e.b);
	}
}

fn int fuzz_freelist(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::FreeListAllocator list;
	list.init(storage[..]);
	sz initial_free = list.bytes_free();
	char[64] foreign_storage;
	void* foreign = (void*)foreign_storage[..].ptr;

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x9E3779B97F4A7C15;

	void*[FUZZ_MAXLIVE] live = { };
	sz[FUZZ_MAXLIVE] reqs = { };
	sz live_count = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = fuzz_size(&rng);
			sz alignment = fuzz_alignment(&rng);
			sz free_before = list.bytes_free();
			void*? got = list.acquire(size, fuzz_init_type(&rng), alignment);
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, alignment);
				if (list.bytes_free() != free_before)
				{
					fuzz_dump(rng.s, "freelist", op, log[..], "failed acquire changed free bytes");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, alignment);
			sz effective = alignment == 0 ? mem::DEFAULT_MEM_ALIGNMENT : alignment;
			if (!mem::ptr_is_aligned(p, effective))
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "misaligned payload");
				return 1;
			}

			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;
			if (!list.canary_intact(p))
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "fresh canary not intact");
				return 1;
			}
			if (!list.owns(p))
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "owns rejects fresh payload");
				return 1;
			}

			live[live_count] = p;
			reqs[live_count] = size;
			live_count++;
		}
		else if (roll < 85 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz req = reqs[idx];
			// One percent of releases probe the canary guard first.
			if (fuzz_next(&rng) % 100 == 0 && req > 0)
			{
				char orig = ((char*)p)[req];
				((char*)p)[req] = 0x00;
				if (!list.canary_intact(p))
				{
					sz free_before = list.bytes_free();
					sz blocks_before = list.free_block_count();
					list.release(p, false);
					if (list.bytes_free() != free_before || list.free_block_count() != blocks_before)
					{
						fuzz_dump(rng.s, "freelist", op, log[..], "corrupt-canary release not ignored");
						return 1;
					}
					if (!list.owns(p))
					{
						fuzz_dump(rng.s, "freelist", op, log[..], "ignored release dropped ownership");
						return 1;
					}
					fuzz_log(log[..], op, FUZZ_GUARD, req, 0);
				}

				((char*)p)[req] = orig;
				if (!list.canary_intact(p) || !list.debug_verify())
				{
					fuzz_dump(rng.s, "freelist", op, log[..], "canary probe restore failed");
					return 1;
				}
			}

			list.release(p, false);
			fuzz_log(log[..], op, FUZZ_RELEASE, req, 0);
			live[idx] = live[live_count - 1];
			reqs[idx] = reqs[live_count - 1];
			live_count--;
		}
		else if (roll < 90 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz old_req = reqs[idx];
			sz new_size = fuzz_size(&rng);
			if (new_size <= 0) new_size = 1;
			sz alignment = fuzz_alignment(&rng);
			void*? grown = list.resize(p, new_size, alignment);
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, old_req, new_size);
				char* bytes = (char*)p;
				for (sz i = 0; i < old_req; i++)
				{
					if (bytes[i] != (char)i)
					{
						fuzz_dump(rng.s, "freelist", op, log[..], "failed resize damaged payload");
						return 1;
					}
				}
				continue;
			}

			void* q = grown;
			fuzz_log(log[..], op, FUZZ_RESIZE_OK, old_req, new_size);
			sz effective = alignment == 0 ? mem::DEFAULT_MEM_ALIGNMENT : alignment;
			if (alignment != 3 && !mem::ptr_is_aligned(q, effective))
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "resized payload misaligned");
				return 1;
			}

			char* qbytes = (char*)q;
			sz prefix = old_req < new_size ? old_req : new_size;
			for (sz i = 0; i < prefix; i++)
			{
				if (qbytes[i] != (char)i)
				{
					fuzz_dump(rng.s, "freelist", op, log[..], "resize lost prefix");
					return 1;
				}
			}
			for (sz i = 0; i < new_size; i++) qbytes[i] = (char)i;
			if (!list.canary_intact(q) || !list.owns(q))
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "resized payload not owned/intact");
				return 1;
			}

			live[idx] = q;
			reqs[idx] = new_size;
		}
		else if (roll < 93 && live_count > 0)
		{
			// Hostile releases must be ignored without state change.
			sz pick = (sz)(fuzz_next(&rng) % 6);
			if (pick == 0)
			{
				// Duplicate release: free a live block, then release it again.
				sz dup_idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
				void* dup = live[dup_idx];
				live[dup_idx] = live[live_count - 1];
				reqs[dup_idx] = reqs[live_count - 1];
				live_count--;
				list.release(dup, false);
				sz free_before = list.bytes_free();
				list.release(dup, true);
				fuzz_log(log[..], op, FUZZ_HOSTILE, pick, 0);
				if (list.bytes_free() != free_before)
				{
					fuzz_dump(rng.s, "freelist", op, log[..], "duplicate release changed state");
					return 1;
				}
			}
			else
			{
				sz free_before = list.bytes_free();
				if (pick == 1)
				{
					list.release((char*)live[0] + 1, false);
				}
				else if (pick == 2)
				{
					list.release(foreign, false);
				}
				else if (pick == 4)
				{
					list.release((char*)live[0] + 7, false);
				}
				else if (pick == 5 && reqs[0] > 1)
				{
					list.release((char*)live[0] + reqs[0] - 1, false);
				}
				else
				{
					list.release(null, false);
				}

				fuzz_log(log[..], op, FUZZ_HOSTILE, pick, 0);
				if (list.bytes_free() != free_before)
				{
					fuzz_dump(rng.s, "freelist", op, log[..], "hostile release changed state");
					return 1;
				}
			}
		}
		else if (roll < 95)
		{
			// Flip the selection policy; both must keep the list valid.
			bool best = fuzz_next(&rng) % 2 == 0;
			list.set_policy(best ? allocators::FreeListPolicy.BEST_FIT : allocators::FreeListPolicy.FIRST_FIT);
			fuzz_log(log[..], op, FUZZ_POLICY, best ? 1 : 0, 0);
			if (!list.debug_verify())
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "policy switch broke invariants");
				return 1;
			}
		}
		else if (roll < 97)
		{
			// Bulk clear must restore one contiguous range.
			for (sz i = 0; i < live_count; i++) list.release(live[i], false);
			live_count = 0;
			list.clear();
			fuzz_log(log[..], op, FUZZ_CLEAR, 0, 0);
			if (list.bytes_free() != initial_free || list.free_block_count() != 1 || !list.debug_verify())
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "clear did not restore single range");
				return 1;
			}
		}
		else
		{
			// Periodic full audit.
			fuzz_log(log[..], op, FUZZ_RESET, live_count, 0);
			if (!list.debug_verify())
			{
				fuzz_dump(rng.s, "freelist", op, log[..], "invariant violation");
				return 1;
			}
			for (sz i = 0; i < live_count; i++)
			{
				if (!list.canary_intact(live[i]) || !list.owns(live[i]))
				{
					fuzz_dump(rng.s, "freelist", op, log[..], "live payload not intact/owned");
					return 1;
				}
			}
		}
		if (op % 8 == 0 && !list.debug_verify())
		{
			fuzz_dump(rng.s, "freelist", op, log[..], "invariant violation");
			return 1;
		}
	}
	for (sz i = 0; i < live_count; i++) list.release(live[i], false);
	if (list.bytes_free() != initial_free || list.free_block_count() != 1 || list.largest_free() != initial_free)
	{
		fuzz_dump(rng.s, "freelist", iterations, log[..], "final restore failed");
		return 1;
	}
	if (!list.debug_verify())
	{
		fuzz_dump(rng.s, "freelist", iterations, log[..], "final verify failed");
		return 1;
	}
	return 0;
}

fn int fuzz_pool(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::PoolAllocator pool;
	pool.init(storage[..], 64, 32);
	sz initial_available = pool.available();
	sz capacity = pool.capacity();
	char[64] foreign_storage;
	void* foreign = (void*)foreign_storage[..].ptr;

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x2545F4914F6CDD1D;
	void*[FUZZ_MAXLIVE] live = { };
	sz[FUZZ_MAXLIVE] reqs = { };
	sz live_count = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (pool.available() + live_count != capacity)
		{
			fuzz_dump(rng.s, "pool", op, log[..], "slot accounting drift");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = fuzz_size(&rng) % 96;
			if (size <= 0) size = 1;
			sz free_before = pool.available();
			void*? got = pool.acquire(size, fuzz_init_type(&rng));
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, 0);
				if (pool.available() != free_before)
				{
					fuzz_dump(rng.s, "pool", op, log[..], "failed acquire consumed slot");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, 0);
			if (!mem::ptr_is_aligned(p, 32) || !pool.canary_intact(p) || !pool.owns(p))
			{
				fuzz_dump(rng.s, "pool", op, log[..], "bad fresh slot");
				return 1;
			}

			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;
			live[live_count] = p;
			reqs[live_count] = size;
			live_count++;
		}
		else if (roll < 90 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz req = reqs[idx];
			if (fuzz_next(&rng) % 100 == 0 && req < 64)
			{
				char orig = ((char*)p)[req];
				((char*)p)[req] = 0x00;
				if (!pool.canary_intact(p))
				{
					sz available_before = pool.available();
					pool.release(p, false);
					if (pool.available() != available_before)
					{
						fuzz_dump(rng.s, "pool", op, log[..], "corrupt-canary release recycled slot");
						return 1;
					}
					fuzz_log(log[..], op, FUZZ_GUARD, req, 0);
				}
				((char*)p)[req] = orig;
			}

			pool.release(p, false);
			fuzz_log(log[..], op, FUZZ_RELEASE, req, 0);
			live[idx] = live[live_count - 1];
			reqs[idx] = reqs[live_count - 1];
			live_count--;
		}
		else if (roll < 95 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz old_req = reqs[idx];
			sz new_size = 1 + (sz)(fuzz_next(&rng) % 96);
			void*? shrunk = pool.resize(p, new_size, fuzz_alignment(&rng));
			if (catch shrunk)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, old_req, new_size);
				if (!pool.canary_intact(p) || !pool.owns(p))
				{
					fuzz_dump(rng.s, "pool", op, log[..], "failed resize damaged slot");
					return 1;
				}
				continue;
			}

			fuzz_log(log[..], op, FUZZ_RESIZE_OK, old_req, new_size);
			if (shrunk != p || !pool.canary_intact(p))
			{
				fuzz_dump(rng.s, "pool", op, log[..], "pool resize moved or broke canary");
				return 1;
			}
			reqs[idx] = new_size;
		}
		else if (live_count > 0)
		{
			sz pick = (sz)(fuzz_next(&rng) % 4);
			if (pick == 0)
			{
				// Duplicate release: free a live slot, then release it again.
				sz dup_idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
				void* dup = live[dup_idx];
				live[dup_idx] = live[live_count - 1];
				reqs[dup_idx] = reqs[live_count - 1];
				live_count--;
				pool.release(dup, false);
				sz available_before = pool.available();
				pool.release(dup, true);
				fuzz_log(log[..], op, FUZZ_HOSTILE, pick, 0);
				if (pool.available() != available_before)
				{
					fuzz_dump(rng.s, "pool", op, log[..], "duplicate release changed state");
					return 1;
				}
			}
			else
			{
				sz available_before = pool.available();
				if (pick == 1)
				{
					pool.release((char*)live[0] + 1, false);
				}
				else if (pick == 2)
				{
					pool.release(foreign, false);
				}
				else
				{
					pool.release(null, false);
				}

				fuzz_log(log[..], op, FUZZ_HOSTILE, pick, 0);
				if (pool.available() != available_before)
				{
					fuzz_dump(rng.s, "pool", op, log[..], "hostile release changed state");
					return 1;
				}
			}
		}
	}
	for (sz i = 0; i < live_count; i++) pool.release(live[i], false);
	if (pool.available() != initial_available)
	{
		fuzz_dump(rng.s, "pool", iterations, log[..], "final restore failed");
		return 1;
	}
	return 0;
}

fn int fuzz_buddy(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::BuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x369DEA0F31A53F85;
	void*[FUZZ_MAXLIVE] live = { };
	sz[FUZZ_MAXLIVE] reqs = { };
	sz live_count = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (buddy.bytes_used() + buddy.bytes_free() != buddy.capacity())
		{
			fuzz_dump(rng.s, "buddy", op, log[..], "byte accounting drift");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = 1 + (sz)(fuzz_next(&rng) % 512);
			sz free_before = buddy.bytes_free();
			void*? got = buddy.acquire(size, fuzz_init_type(&rng));
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, 0);
				if (buddy.bytes_free() != free_before)
				{
					fuzz_dump(rng.s, "buddy", op, log[..], "failed acquire changed state");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, 0);
			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;
			if (!buddy.canary_intact(p) || !buddy.owns(p))
			{
				fuzz_dump(rng.s, "buddy", op, log[..], "bad fresh block");
				return 1;
			}

			live[live_count] = p;
			reqs[live_count] = size;
			live_count++;
		}
		else if (roll < 90 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz req = reqs[idx];
			if (fuzz_next(&rng) % 100 == 0 && req > 0)
			{
				char orig = ((char*)p)[req];
				((char*)p)[req] = 0x00;
				if (!buddy.canary_intact(p))
				{
					sz free_before = buddy.bytes_free();
					buddy.release(p, false);
					if (buddy.bytes_free() != free_before)
					{
						fuzz_dump(rng.s, "buddy", op, log[..], "corrupt-canary release merged block");
						return 1;
					}
					fuzz_log(log[..], op, FUZZ_GUARD, req, 0);
				}
				((char*)p)[req] = orig;
			}

			buddy.release(p, false);
			fuzz_log(log[..], op, FUZZ_RELEASE, req, 0);
			live[idx] = live[live_count - 1];
			reqs[idx] = reqs[live_count - 1];
			live_count--;
		}
		else if (live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz old_req = reqs[idx];
			sz new_size = 1 + (sz)(fuzz_next(&rng) % 512);
			void*? grown = buddy.resize(p, new_size, 0);
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, old_req, new_size);
				char* bytes = (char*)p;
				for (sz i = 0; i < old_req; i++)
				{
					if (bytes[i] != (char)i)
					{
						fuzz_dump(rng.s, "buddy", op, log[..], "failed resize damaged payload");
						return 1;
					}
				}
				continue;
			}

			fuzz_log(log[..], op, FUZZ_RESIZE_OK, old_req, new_size);
			void* q = grown;
			char* qbytes = (char*)q;
			sz prefix = old_req < new_size ? old_req : new_size;
			for (sz i = 0; i < prefix; i++)
			{
				if (qbytes[i] != (char)i)
				{
					fuzz_dump(rng.s, "buddy", op, log[..], "resize lost prefix");
					return 1;
				}
			}
			for (sz i = 0; i < new_size; i++) qbytes[i] = (char)i;

			live[idx] = q;
			reqs[idx] = new_size;
		}
	}

	for (sz i = 0; i < live_count; i++) buddy.release(live[i], false);
	if (buddy.bytes_free() != initial_free || buddy.free_block_count() != 1)
	{
		fuzz_dump(rng.s, "buddy", iterations, log[..], "final restore failed");
		return 1;
	}
	return 0;
}

fn int fuzz_bitmap_buddy(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::BitmapBuddyAllocator buddy;
	buddy.init(storage[..]);
	sz initial_free = buddy.bytes_free();

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x5A17F4A7C3F59B71;
	void*[FUZZ_MAXLIVE] live = { };
	sz live_count = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (buddy.bytes_used() + buddy.bytes_free() != buddy.capacity())
		{
			fuzz_dump(rng.s, "bitmap", op, log[..], "byte accounting drift");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = 1 + (sz)(fuzz_next(&rng) % 128);
			sz free_before = buddy.bytes_free();
			void*? got = buddy.acquire(size, fuzz_init_type(&rng));
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, 0);
				if (buddy.bytes_free() != free_before)
				{
					fuzz_dump(rng.s, "bitmap", op, log[..], "failed acquire changed state");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, 0);
			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;
			if (!buddy.owns(p))
			{
				fuzz_dump(rng.s, "bitmap", op, log[..], "owns rejects fresh block");
				return 1;
			}

			live[live_count] = p;
			live_count++;
		}
		else if (roll < 90 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			buddy.release(live[idx], false);
			fuzz_log(log[..], op, FUZZ_RELEASE, 0, 0);
			live[idx] = live[live_count - 1];
			live_count--;
		}
		else if (live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz new_size = 1 + (sz)(fuzz_next(&rng) % 128);
			void*? grown = buddy.resize(p, new_size, 0);
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, new_size, 0);
				continue;
			}

			fuzz_log(log[..], op, FUZZ_RESIZE_OK, new_size, 0);
			if (!buddy.owns(grown))
			{
				fuzz_dump(rng.s, "bitmap", op, log[..], "resized block not owned");
				return 1;
			}
			live[idx] = grown;
		}
	}
	for (sz i = 0; i < live_count; i++) buddy.release(live[i], false);
	if (buddy.bytes_free() != initial_free)
	{
		fuzz_dump(rng.s, "bitmap", iterations, log[..], "final restore failed");
		return 1;
	}
	return 0;
}

fn int fuzz_sizeclass(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::SizeClassAllocator classes;
	classes.init_preset(storage[..], 5);
	sz capacity = classes.capacity();

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x6C8E9CF570932BAB;
	void*[FUZZ_MAXLIVE] live = { };
	sz live_count = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (classes.available() + live_count != capacity)
		{
			fuzz_dump(rng.s, "sizeclass", op, log[..], "slot accounting drift");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = 1 + (sz)(fuzz_next(&rng) % 400);
			sz available_before = classes.available();
			void*? got = classes.acquire(size, fuzz_init_type(&rng));
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, 0);
				if (classes.available() != available_before)
				{
					fuzz_dump(rng.s, "sizeclass", op, log[..], "failed acquire changed state");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, 0);
			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;
			live[live_count] = p;
			live_count++;
		}
		else if (roll < 90 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			classes.release(live[idx], false);
			fuzz_log(log[..], op, FUZZ_RELEASE, 0, 0);
			live[idx] = live[live_count - 1];
			live_count--;
		}
		else if (live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz new_size = 1 + (sz)(fuzz_next(&rng) % 400);
			void*? grown = classes.resize(p, new_size, 0);
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, new_size, 0);
				continue;
			}

			fuzz_log(log[..], op, FUZZ_RESIZE_OK, new_size, 0);
			live[idx] = grown;
		}
	}
	for (sz i = 0; i < live_count; i++) classes.release(live[i], false);
	if (classes.available() != capacity)
	{
		fuzz_dump(rng.s, "sizeclass", iterations, log[..], "final restore failed");
		return 1;
	}
	return 0;
}

fn int fuzz_backed_arena(char[] initial, char[] backing_storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::ArenaAllocator backing;
	backing.init(backing_storage[..]);
	allocators::BackedArenaAllocator arena;
	arena.init(initial[..], &backing);

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x78DDE6E5FD29E471;

	void*[FUZZ_MAXLIVE] live = { };
	sz[FUZZ_MAXLIVE] reqs = { };
	sz[FUZZ_MAXLIVE] seqs = { };
	sz live_count = 0;
	sz seq_next = 0;
	sz saved_mark = 0;
	sz saved_seq = 0;
	bool have_mark = false;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 60 && live_count < max_live)
		{
			sz size = 1 + (sz)(fuzz_next(&rng) % 1024);
			void*? got = arena.acquire(size, fuzz_init_type(&rng));
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, 0);
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, 0);
			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;
			if (!arena.owns(p))
			{
				fuzz_dump(rng.s, "backed", op, log[..], "owns rejects fresh block");
				return 1;
			}

			live[live_count] = p;
			reqs[live_count] = size;
			seqs[live_count] = seq_next;
			seq_next++;
			live_count++;
		}
		else if (roll < 85 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			arena.release(live[idx], false);
			fuzz_log(log[..], op, FUZZ_RELEASE, reqs[idx], 0);
			live[idx] = live[live_count - 1];
			reqs[idx] = reqs[live_count - 1];
			seqs[idx] = seqs[live_count - 1];
			live_count--;
		}
		else if (roll < 90)
		{
			// Positional rewind machinery: marks, pooled-page reset, prune.
			sz sub = (sz)(fuzz_next(&rng) % 3);
			if (sub == 0 || !have_mark)
			{
				saved_mark = arena.mark();
				saved_seq = seq_next;
				have_mark = true;
				fuzz_log(log[..], op, FUZZ_RESET, 1, 0);
			}
			else if (sub == 1)
			{
				arena.reset_retaining(saved_mark);
				sz kept = 0;
				for (sz i = 0; i < live_count; i++)
				{
					if (seqs[i] < saved_seq)
					{
						live[kept] = live[i];
						reqs[kept] = reqs[i];
						seqs[kept] = seqs[i];
						kept++;
					}
				}

				live_count = kept;
				fuzz_log(log[..], op, FUZZ_RESET, 2, 0);
				for (sz i = 0; i < live_count; i++)
				{
					if (!arena.owns(live[i]))
					{
						fuzz_dump(rng.s, "backed", op, log[..], "reset kept a dead block");
						return 1;
					}
				}
			}
			else
			{
				arena.prune_pool();
				fuzz_log(log[..], op, FUZZ_RESET, 3, 0);
			}
			if (op % 64 == 0)
			{
				arena.prune_pool();
				if (arena.page_pool_count() != 0)
				{
					fuzz_dump(rng.s, "backed", op, log[..], "prune did not drain pool");
					return 1;
				}
			}
		}
		else if (roll < 95)
		{
			// Reclaim everything at once, then keep going.
			for (sz i = 0; i < live_count; i++) arena.release(live[i], false);
			live_count = 0;
			have_mark = false;
			arena.clear();
			fuzz_log(log[..], op, FUZZ_RESET, 0, 0);
			if (arena.overflow_count() != 0)
			{
				fuzz_dump(rng.s, "backed", op, log[..], "clear kept overflow pages");
				return 1;
			}
		}
		else if (live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz old_req = reqs[idx];
			sz new_size = 1 + (sz)(fuzz_next(&rng) % 1024);
			void*? grown = arena.resize(p, new_size, 0);
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, old_req, new_size);
				continue;
			}

			fuzz_log(log[..], op, FUZZ_RESIZE_OK, old_req, new_size);
			void* q = grown;
			char* qbytes = (char*)q;
			sz prefix = old_req < new_size ? old_req : new_size;
			for (sz i = 0; i < prefix; i++)
			{
				if (qbytes[i] != (char)i)
				{
					fuzz_dump(rng.s, "backed", op, log[..], "resize lost prefix");
					return 1;
				}
			}
			for (sz i = 0; i < new_size; i++) qbytes[i] = (char)i;

			live[idx] = q;
			reqs[idx] = new_size;
			seqs[idx] = seq_next;
			seq_next++;
		}
	}
	for (sz i = 0; i < live_count; i++) arena.release(live[i], false);

	arena.clear();
	arena.free();
	if (arena.overflow_count() != 0 || arena.page_pool_count() != 0)
	{
		fuzz_dump(rng.s, "backed", iterations, log[..], "free kept pages");
		return 1;
	}
	return 0;
}

fn int fuzz_scratch(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::ScratchAllocator scratch;
	scratch.init(storage[..]);

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x8BADF00DCAFEBABE;

	void*[FUZZ_MAXLIVE] live = { };
	sz live_count = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (scratch.peak() < scratch.bytes_reserved())
		{
			fuzz_dump(rng.s, "scratch", op, log[..], "peak below reserved");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 70 && live_count < FUZZ_MAXLIVE)
		{
			sz size = 1 + (sz)(fuzz_next(&rng) % 256);
			void*? got = scratch.acquire(size, fuzz_init_type(&rng));
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, 0);
				scratch.clear();
				live_count = 0;
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, 0);
			if (!scratch.owns(p))
			{
				fuzz_dump(rng.s, "scratch", op, log[..], "owns rejects fresh block");
				return 1;
			}

			live[live_count] = p;
			live_count++;
		}
		else if (roll < 85 && live_count > 0)
		{
			if (scratch.is_last(live[live_count - 1]))
			{
				scratch.release(live[live_count - 1], false);
				fuzz_log(log[..], op, FUZZ_RELEASE, 0, 0);
				live_count--;
			}
			else
			{
				// A non-last release must be ignored without state change.
				sz reserved_before = scratch.bytes_reserved();
				scratch.release(live[0], false);
				fuzz_log(log[..], op, FUZZ_HOSTILE, 0, 0);
				if (scratch.bytes_reserved() != reserved_before)
				{
					fuzz_dump(rng.s, "scratch", op, log[..], "non-last release changed state");
					return 1;
				}
			}
		}
		else
		{
			scratch.clear();
			fuzz_log(log[..], op, FUZZ_RESET, 0, 0);
			live_count = 0;
		}
	}

	scratch.clear();
	return 0;
}

fn int fuzz_arena(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::ArenaAllocator arena;
	arena.init(storage[..]);

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0xA1E4A1E4A1E4A1E4;

	void*[FUZZ_MAXLIVE] live = { };
	sz[FUZZ_MAXLIVE] reqs = { };
	sz[FUZZ_MAXLIVE] seqs = { };
	sz live_count = 0;
	sz seq_next = 0;
	sz saved_mark = 0;
	sz saved_seq = 0;
	bool have_mark = false;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (arena.bytes_reserved() > arena.capacity())
		{
			fuzz_dump(rng.s, "arena", op, log[..], "reserved exceeds capacity");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = fuzz_size(&rng);
			sz alignment = fuzz_alignment(&rng);
			sz reserved_before = arena.bytes_reserved();
			void*? got = arena.acquire(size, fuzz_init_type(&rng), alignment);
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, alignment);
				if (arena.bytes_reserved() != reserved_before)
				{
					fuzz_dump(rng.s, "arena", op, log[..], "failed acquire moved position");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, alignment);
			if (!arena.owns(p) || !arena.is_last(p))
			{
				fuzz_dump(rng.s, "arena", op, log[..], "fresh block not owned/last");
				return 1;
			}

			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;
			live[live_count] = p;
			reqs[live_count] = size;
			seqs[live_count] = seq_next;
			seq_next++;
			live_count++;
		}
		else if (roll < 80 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz reserved_before = arena.bytes_reserved();
			if (arena.is_last(p))
			{
				arena.release(p, false);
				fuzz_log(log[..], op, FUZZ_RELEASE, reqs[idx], 0);
				if (arena.bytes_reserved() >= reserved_before)
				{
					fuzz_dump(rng.s, "arena", op, log[..], "last release did not reclaim");
					return 1;
				}

				live[idx] = live[live_count - 1];
				reqs[idx] = reqs[live_count - 1];
				seqs[idx] = seqs[live_count - 1];
				live_count--;
			}
			else
			{
				arena.release(p, false);
				fuzz_log(log[..], op, FUZZ_HOSTILE, reqs[idx], 0);
				if (arena.bytes_reserved() != reserved_before)
				{
					fuzz_dump(rng.s, "arena", op, log[..], "non-last release changed state");
					return 1;
				}
			}
		}
		else if (roll < 85)
		{
			sz sub = (sz)(fuzz_next(&rng) % 2);
			if (sub == 0 || !have_mark)
			{
				saved_mark = arena.mark();
				saved_seq = seq_next;
				have_mark = true;
				fuzz_log(log[..], op, FUZZ_RESET, 1, 0);
			}
			else
			{
				arena.reset(saved_mark);
				sz kept = 0;
				for (sz i = 0; i < live_count; i++)
				{
					if (seqs[i] < saved_seq)
					{
						live[kept] = live[i];
						reqs[kept] = reqs[i];
						seqs[kept] = seqs[i];
						kept++;
					}
				}

				live_count = kept;
				fuzz_log(log[..], op, FUZZ_RESET, 2, 0);
				for (sz i = 0; i < live_count; i++)
				{
					if (!arena.owns(live[i]))
					{
						fuzz_dump(rng.s, "arena", op, log[..], "reset kept a dead block");
						return 1;
					}
				}
			}
		}
		else if (roll < 88)
		{
			arena.clear();
			live_count = 0;
			have_mark = false;
			fuzz_log(log[..], op, FUZZ_CLEAR, 0, 0);
			if (arena.bytes_reserved() != 0)
			{
				fuzz_dump(rng.s, "arena", op, log[..], "clear did not reset position");
				return 1;
			}
		}
		else if (roll < 93 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz old_req = reqs[idx];
			sz new_size = fuzz_size(&rng);
			sz alignment = fuzz_alignment(&rng);
			void*? grown = arena.resize(p, new_size, alignment);
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, old_req, new_size);
				char* bytes = (char*)p;
				for (sz i = 0; i < old_req; i++)
				{
					if (bytes[i] != (char)i)
					{
						fuzz_dump(rng.s, "arena", op, log[..], "failed resize damaged payload");
						return 1;
					}
				}
				continue;
			}

			void* q = grown;
			fuzz_log(log[..], op, FUZZ_RESIZE_OK, old_req, new_size);
			if (!arena.owns(q))
			{
				fuzz_dump(rng.s, "arena", op, log[..], "resized block not owned");
				return 1;
			}

			char* qbytes = (char*)q;
			sz prefix = old_req < new_size ? old_req : new_size;
			for (sz i = 0; i < prefix; i++)
			{
				if (qbytes[i] != (char)i)
				{
					fuzz_dump(rng.s, "arena", op, log[..], "resize lost prefix");
					return 1;
				}
			}
			for (sz i = 0; i < new_size; i++) qbytes[i] = (char)i;

			live[idx] = q;
			reqs[idx] = new_size;
			seqs[idx] = seq_next;
			seq_next++;
		}
		else
		{
			fuzz_log(log[..], op, FUZZ_RESET, live_count, 0);
			for (sz i = 0; i < live_count; i++)
			{
				if (!arena.owns(live[i]))
				{
					fuzz_dump(rng.s, "arena", op, log[..], "live block not owned");
					return 1;
				}
			}
		}
	}

	arena.clear();
	if (arena.bytes_reserved() != 0)
	{
		fuzz_dump(rng.s, "arena", iterations, log[..], "final clear failed");
		return 1;
	}
	return 0;
}

fn int fuzz_tracking(char[] storage, FuzzRng base, sz iterations, sz max_live)
{
	allocators::FreeListAllocator backing;
	backing.init(storage[..]);
	allocators::TrackingAllocator tracker;
	tracker.init(&backing);
	char[64] foreign_storage;
	void* foreign = (void*)foreign_storage[..].ptr;

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0x71AC9EDBAC71AC;

	void*[FUZZ_MAXLIVE] live = { };
	sz[FUZZ_MAXLIVE] reqs = { };
	sz live_count = 0;
	sz expected_sum = 0;
	sz expected_unmatched = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (tracker.live_count() != live_count || tracker.live_bytes() != expected_sum)
		{
			fuzz_dump(rng.s, "tracking", op, log[..], "bookkeeping drift");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = fuzz_size(&rng);
			sz alignment = fuzz_alignment(&rng);
			sz backing_before = backing.bytes_free();
			void*? got = tracker.acquire(size, fuzz_init_type(&rng), alignment);
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, alignment);
				if (backing.bytes_free() != backing_before)
				{
					fuzz_dump(rng.s, "tracking", op, log[..], "failed acquire touched backing");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, alignment);
			char* bytes = (char*)p;
			for (sz i = 0; i < size; i++) bytes[i] = (char)i;

			live[live_count] = p;
			reqs[live_count] = size;
			live_count++;
			expected_sum += size;
		}
		else if (roll < 80 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			tracker.release(live[idx], false);
			fuzz_log(log[..], op, FUZZ_RELEASE, reqs[idx], 0);
			expected_sum -= reqs[idx];
			live[idx] = live[live_count - 1];
			reqs[idx] = reqs[live_count - 1];
			live_count--;
		}
		else if (roll < 85 && live_count > 0)
		{
			// Duplicate release: remove from the set, release, then
			// release again. The second must be counted and not
			// forwarded to the backing allocator.
			sz dup_idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* dup = live[dup_idx];
			expected_sum -= reqs[dup_idx];
			live[dup_idx] = live[live_count - 1];
			reqs[dup_idx] = reqs[live_count - 1];
			live_count--;
			tracker.release(dup, false);
			sz backing_before = backing.bytes_free();
			tracker.release(dup, false);
			expected_unmatched++;
			fuzz_log(log[..], op, FUZZ_HOSTILE, 0, 0);
			if (tracker.double_releases() != expected_unmatched || backing.bytes_free() != backing_before)
			{
				fuzz_dump(rng.s, "tracking", op, log[..], "duplicate release forwarded or miscounted");
				return 1;
			}
		}
		else if (roll < 90 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz old_req = reqs[idx];
			sz new_size = fuzz_size(&rng);
			sz alignment = fuzz_alignment(&rng);
			void*? grown = tracker.resize(p, new_size, alignment);
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, old_req, new_size);
				char* bytes = (char*)p;
				for (sz i = 0; i < old_req; i++)
				{
					if (bytes[i] != (char)i)
					{
						fuzz_dump(rng.s, "tracking", op, log[..], "failed resize damaged payload");
						return 1;
					}
				}
				continue;
			}

			fuzz_log(log[..], op, FUZZ_RESIZE_OK, old_req, new_size);
			void* q = grown;
			char* qbytes = (char*)q;
			sz prefix = old_req < new_size ? old_req : new_size;
			for (sz i = 0; i < prefix; i++)
			{
				if (qbytes[i] != (char)i)
				{
					fuzz_dump(rng.s, "tracking", op, log[..], "resize lost prefix");
					return 1;
				}
			}
			for (sz i = 0; i < new_size; i++) qbytes[i] = (char)i;

			expected_sum += new_size - old_req;
			live[idx] = q;
			reqs[idx] = new_size;
		}
		else if (roll < 95)
		{
			// Hostile releases must not reach the backing allocator.
			sz backing_before = backing.bytes_free();
			tracker.release(foreign, false);
			tracker.release(null, false);
			expected_unmatched++;
			fuzz_log(log[..], op, FUZZ_HOSTILE, 0, 0);
			if (backing.bytes_free() != backing_before || tracker.live_count() != live_count)
			{
				fuzz_dump(rng.s, "tracking", op, log[..], "hostile release changed state");
				return 1;
			}
		}
		else
		{
			// Audit through the backing allocator's invariants.
			fuzz_log(log[..], op, FUZZ_RESET, live_count, 0);
			if (!backing.debug_verify())
			{
				fuzz_dump(rng.s, "tracking", op, log[..], "backing invariant violation");
				return 1;
			}
		}
	}
	for (sz i = 0; i < live_count; i++) tracker.release(live[i], false);
	if (!tracker.check_no_leaks() || tracker.live_count() != 0 || tracker.live_bytes() != 0)
	{
		fuzz_dump(rng.s, "tracking", iterations, log[..], "leaks remain");
		return 1;
	}

	tracker.free();
	return 0;
}

fn int fuzz_poolchain(char[] storage, char[] spare, FuzzRng base, sz iterations, sz max_live)
{
	char[][2] bufs = { storage[0:storage.len / 2], storage[storage.len / 2:storage.len / 2] };
	allocators::PoolChainAllocator chain;
	chain.init(bufs[..], 64, 0);
	sz spare_next = 0;

	FuzzRng rng = base;
	if (rng.s == 0) rng.s = 0xC4A17AC4A17;

	void*[FUZZ_MAXLIVE] live = { };
	sz[FUZZ_MAXLIVE] reqs = { };
	sz live_count = 0;
	FuzzOp[FUZZ_LOG_SIZE] log = { };
	for (sz op = 0; op < iterations && (rng.bytes.len == 0 || rng.pos < rng.bytes.len); op++)
	{
		if (chain.available() + live_count != chain.capacity())
		{
			fuzz_dump(rng.s, "poolchain", op, log[..], "slot accounting drift");
			return 1;
		}

		ulong roll = fuzz_next(&rng) % 100;
		if (roll < 55 && live_count < max_live)
		{
			sz size = fuzz_size(&rng);
			if (size <= 0) size = 1;

			sz alignment = fuzz_alignment(&rng);
			sz available_before = chain.available();
			void*? got = chain.acquire(size, fuzz_init_type(&rng), alignment);
			if (catch got)
			{
				fuzz_log(log[..], op, FUZZ_ACQUIRE_FAIL, size, alignment);
				if (chain.available() != available_before)
				{
					fuzz_dump(rng.s, "poolchain", op, log[..], "failed acquire changed state");
					return 1;
				}
				continue;
			}

			void* p = got;
			fuzz_log(log[..], op, FUZZ_ACQUIRE_OK, size, alignment);
			if (!chain.owns(p) || !chain.canary_intact(p))
			{
				fuzz_dump(rng.s, "poolchain", op, log[..], "bad fresh slot");
				return 1;
			}

			char* bytes = (char*)p;
			for (sz i = 0; i < size && i < 64; i++) bytes[i] = (char)i;

			live[live_count] = p;
			reqs[live_count] = size;
			live_count++;
		}
		else if (roll < 85 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			chain.release(live[idx], false);
			fuzz_log(log[..], op, FUZZ_RELEASE, reqs[idx], 0);
			live[idx] = live[live_count - 1];
			reqs[idx] = reqs[live_count - 1];
			live_count--;
		}
		else if (roll < 90 && live_count > 0)
		{
			sz idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* p = live[idx];
			sz old_req = reqs[idx];
			sz new_size = 1 + (sz)(fuzz_next(&rng) % 96);
			void*? grown = chain.resize(p, new_size, fuzz_alignment(&rng));
			if (catch grown)
			{
				fuzz_log(log[..], op, FUZZ_RESIZE_FAIL, old_req, new_size);
				if (!chain.canary_intact(p) || !chain.owns(p))
				{
					fuzz_dump(rng.s, "poolchain", op, log[..], "failed resize damaged slot");
					return 1;
				}
				continue;
			}

			fuzz_log(log[..], op, FUZZ_RESIZE_OK, old_req, new_size);
			if (grown != p)
			{
				fuzz_dump(rng.s, "poolchain", op, log[..], "chain resize moved");
				return 1;
			}
			reqs[idx] = new_size;
		}
		else if (roll < 93 && live_count > 0)
		{
			sz dup_idx = (sz)(fuzz_next(&rng) % (ulong)live_count);
			void* dup = live[dup_idx];
			live[dup_idx] = live[live_count - 1];
			reqs[dup_idx] = reqs[live_count - 1];
			live_count--;
			chain.release(dup, false);
			sz available_before = chain.available();
			chain.release(dup, false);
			fuzz_log(log[..], op, FUZZ_HOSTILE, 0, 0);
			if (chain.available() != available_before)
			{
				fuzz_dump(rng.s, "poolchain", op, log[..], "duplicate release changed state");
				return 1;
			}
		}
		else if (roll < 95)
		{
			// Attach a fresh spare buffer as a new link. Past the link
			// limit attach must refuse without changing the chain.
			if (chain.link_count() >= allocators::POOL_CHAIN_MAX)
			{
				char[64] dummy;
				sz links_before = chain.link_count();
				sz available_before = chain.available();
				if (chain.attach(dummy[..]))
				{
					fuzz_dump(rng.s, "poolchain", op, log[..], "attach past limit succeeded");
					return 1;
				}

				fuzz_log(log[..], op, FUZZ_RESET, 0, 0);
				if (chain.link_count() != links_before || chain.available() != available_before)
				{
					fuzz_dump(rng.s, "poolchain", op, log[..], "refused attach changed state");
					return 1;
				}
			}
			else if (spare_next + 1024 <= spare.len)
			{
				sz links_before = chain.link_count();
				if (!chain.attach(spare[spare_next:1024]))
				{
					fuzz_dump(rng.s, "poolchain", op, log[..], "attach with room failed");
					return 1;
				}

				spare_next += 1024;
				fuzz_log(log[..], op, FUZZ_RESET, 1, 0);
				if (chain.link_count() != links_before + 1 || !chain.debug_verify())
				{
					fuzz_dump(rng.s, "poolchain", op, log[..], "attach misbehaved");
					return 1;
				}
			}
			else
			{
				fuzz_log(log[..], op, FUZZ_RESET, 2, 0);
			}
		}
		else
		{
			fuzz_log(log[..], op, FUZZ_RESET, live_count, 0);
			if (!chain.debug_verify())
			{
				fuzz_dump(rng.s, "poolchain", op, log[..], "invariant violation");
				return 1;
			}
		}
	}
	for (sz i = 0; i < live_count; i++) chain.release(live[i], false);
	if (chain.available() != chain.capacity() || !chain.debug_verify())
	{
		fuzz_dump(rng.s, "poolchain", iterations, log[..], "final restore failed");
		return 1;
	}
	return 0;
}
