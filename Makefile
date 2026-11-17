SHELL := /bin/sh

C3C ?= c3c
C3FMT ?= c3fmt
SOURCES := src test fuzz
BENCH_SOURCES := src/allocators/common.c3 src/allocators/arena.c3 \
	src/allocators/pool.c3 src/allocators/backed_arena.c3 \
	src/allocators/freelist.c3 src/allocators/buddy.c3 \
	src/allocators/bitmap_buddy.c3 \
	src/allocators/sizeclass.c3 src/allocators/scratch.c3 \
	src/allocators/typed.c3 src/allocators/tracking.c3 \
	src/allocators/poolchain.c3 \
	bench/allocators_bench.c3
FUZZ_SOURCES := src/allocators/common.c3 src/allocators/arena.c3 \
	src/allocators/pool.c3 src/allocators/backed_arena.c3 \
	src/allocators/freelist.c3 src/allocators/buddy.c3 \
	src/allocators/bitmap_buddy.c3 \
	src/allocators/sizeclass.c3 src/allocators/scratch.c3 \
	src/allocators/tracking.c3 src/allocators/poolchain.c3 \
	fuzz/fuzz_common.c3 fuzz/fuzz.c3
HF_SOURCES := src/allocators/common.c3 src/allocators/arena.c3 \
	src/allocators/pool.c3 src/allocators/backed_arena.c3 \
	src/allocators/freelist.c3 src/allocators/buddy.c3 \
	src/allocators/bitmap_buddy.c3 \
	src/allocators/sizeclass.c3 src/allocators/scratch.c3 \
	src/allocators/tracking.c3 src/allocators/poolchain.c3 \
	fuzz/fuzz_common.c3 fuzz/fuzz_hf.c3

.DEFAULT_GOAL := help
.NOTPARALLEL:

.PHONY: help all prepare build run test fmt fmt-check check bench fuzz fuzz-long clean fuzz-hf-deps fuzz-hf-corpus fuzz-hf fuzz-hf-cov

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN { FS = ":.*?## " } { printf "%-12s %s\n", $$1, $$2 }'

all: build ## Build the project

prepare: ## Ensure configured dependency directories exist
	@mkdir -p lib

build: prepare ## Compile the executable with c3c
	$(C3C) build

run: prepare ## Build and run the executable
	$(C3C) run

test: prepare ## Run the C3 test suite
	$(C3C) test

fmt: ## Format C3 source and test files in place
	$(C3FMT) --in-place $(SOURCES)

fmt-check: ## Check formatting without changing files
	$(C3FMT) --check $(SOURCES)

check: ## Run formatting check, tests, and build in sequence
	$(MAKE) fmt-check
	$(MAKE) test
	$(MAKE) build

bench: ## Run allocator benchmarks via c3c compile-benchmark
	$(C3C) -O2 compile-benchmark $(BENCH_SOURCES)

fuzz: ## Run fuzzer smoke: fixed seeds across all allocators
	@mkdir -p out
	$(C3C) -O2 compile $(FUZZ_SOURCES) -o out/fuzzrun
	./out/fuzzrun 1
	./out/fuzzrun 2
	./out/fuzzrun 3

fuzz-long: ## Deep fuzz run: SEED, ITERATIONS, MAXLIVE overrides
	@mkdir -p out
	$(C3C) -O2 compile $(FUZZ_SOURCES) -o out/fuzzrun
	./out/fuzzrun $(SEED) $(ITERATIONS) $(MAXLIVE)

HF ?= honggfuzz
HF_DIR ?= build/honggfuzz
HF_N ?= 20000
HF_THREADS ?= 2
HF_TIMEOUT ?= 10
# Prefer a system honggfuzz, otherwise use the local build.
HF_BIN = $(shell command -v $(HF) 2>/dev/null || echo $(HF_DIR)/honggfuzz)
HF_LINK_C3C = -z $(HF_DIR)/libhfuzz/libhfuzz.a -z $(HF_DIR)/libhfcommon/libhfcommon.a \
	-l unwind -l bfd -l opcodes -l lzma -l dl -l rt -l m -l atomic
HF_LINK = $(HF_DIR)/libhfuzz/libhfuzz.a $(HF_DIR)/libhfcommon/libhfcommon.a \
	-lunwind -lbfd -lopcodes -llzma -ldl -lrt -lm -latomic

$(HF_DIR)/honggfuzz:
	git clone --depth 1 https://github.com/google/honggfuzz.git $(HF_DIR)
	make -C $(HF_DIR) -j$(shell nproc)

fuzz-hf-deps: $(HF_DIR)/honggfuzz ## Check for honggfuzz and clang
	@command -v clang >/dev/null || (echo "clang not found; honggfuzz needs it" && exit 1)
	@test -x $(HF_BIN) || (echo "honggfuzz not found" && exit 1)

fuzz-hf-corpus: fuzz/corpus/.complete ## Generate deterministic honggfuzz seed corpus

fuzz/corpus/.complete: fuzz/make_corpus.py
	@mkdir -p fuzz/corpus
	@rm -f fuzz/corpus/*
	@python3 fuzz/make_corpus.py fuzz/corpus
	@touch fuzz/corpus/.complete

fuzz-hf: fuzz-hf-deps fuzz/corpus/.complete ## Run honggfuzz (persistent mode) against the ASan harness
	@mkdir -p out out/hf_new
	clang -O2 -c fuzz/hf_shim.c -o out/shim.o
	$(C3C) -O2 --sanitize=address compile $(HF_SOURCES) out/shim.o $(HF_LINK_C3C) -o out/fuzz_hf
	$(HF_BIN) -P -f fuzz/corpus -o out/hf_new -N $(HF_N) -t $(HF_TIMEOUT) -n $(HF_THREADS) -- ./out/fuzz_hf

fuzz-hf-cov: fuzz-hf-deps fuzz/corpus/.complete ## Run honggfuzz with clang coverage feedback
	@mkdir -p out out/hf_new out/ll out/llobj out/obj
	clang -O2 -fsanitize-coverage=trace-pc-guard -c fuzz/hf_shim.c -o out/shim_cov.o
	$(C3C) -O2 --emit-llvm --llvm-out out/ll --obj-out out/obj compile-only $(HF_SOURCES)
	@for f in out/ll/*.ll; do b=$$(basename $$f .ll); clang -O2 -fsanitize-coverage=trace-pc-guard -c $$f -o out/llobj/$$b.o || exit 1; done
	clang -O2 -fsanitize=address -fsanitize-coverage=trace-pc-guard out/llobj/*.o out/shim_cov.o $(HF_LINK) -rdynamic -pthread -ldl -lm -o out/fuzz_hf_cov
	$(HF_BIN) -P -f fuzz/corpus -o out/hf_new -N $(HF_N) -t $(HF_TIMEOUT) -n $(HF_THREADS) -- ./out/fuzz_hf_cov

clean: ## Remove C3 build artifacts
	$(C3C) clean
