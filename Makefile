SHELL := /bin/sh

C3C ?= c3c
C3FMT ?= c3fmt
SOURCES := src test
BENCH_SOURCES := src/allocators/common.c3 src/allocators/arena.c3 \
	src/allocators/pool.c3 src/allocators/backed_arena.c3 \
	src/allocators/freelist.c3 src/allocators/buddy.c3 \
	src/allocators/sizeclass.c3 src/allocators/scratch.c3 \
	src/allocators/typed.c3 bench/allocators_bench.c3

.DEFAULT_GOAL := help
.NOTPARALLEL:

.PHONY: help all prepare build run test fmt fmt-check check bench clean

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
	$(C3C) compile-benchmark $(BENCH_SOURCES)

clean: ## Remove C3 build artifacts
	$(C3C) clean
