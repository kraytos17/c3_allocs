SHELL := /bin/sh

C3C ?= c3c
C3FMT ?= c3fmt
SOURCES := src test

.DEFAULT_GOAL := help
.NOTPARALLEL:

.PHONY: help all prepare build run test fmt fmt-check check clean

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

clean: ## Remove C3 build artifacts
	$(C3C) clean
