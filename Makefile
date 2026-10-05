.DEFAULT_GOAL := _default

MAKE_SELF ?= $(firstword $(MAKEFILE_LIST))
MAKE_RECURSE = $(MAKE) --no-print-directory -f "$(MAKE_SELF)"

ZIG ?= zig
OPTIMIZE ?= ReleaseSafe
BIN := zig-out/bin/tuppet
VERSION := $(shell sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon)
TARGETS := x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows aarch64-windows
DIST := zig-out/dist
E2E := test/cli_failures.sh test/dsr_reply.sh test/trace.sh test/daemon_resilience.sh test/supervised.sh test/protocol.sh test/store.sh test/picker.sh

.PHONY: _default help build run smoke test e2e fmt fmt-check check dist clean

_default:
	@printf 'hint: run `make help` to list available targets\n'
	@$(MAKE_RECURSE) build

help: ## List available targets.
	@awk 'BEGIN {FS = ":.*## "} /^[a-z][a-z0-9-]*:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build zig-out/bin/tuppet (ReleaseSafe; override with OPTIMIZE=Debug).
	$(ZIG) build -Doptimize=$(OPTIMIZE)

run: build ## Run tuppet with ARGS, e.g. make run ARGS="list".
	$(BIN) $(ARGS)

smoke: build ## Build and check that the binary starts.
	$(BIN) --version

test: ## Run the unit tests.
	$(ZIG) build test

e2e: build ## Run the end-to-end scripts against isolated daemons.
	@set -e; for t in $(E2E); do echo "$$t"; BIN=$(BIN) $$t; done

fmt: ## Format the sources (vendored src/input stays as upstream wrote it).
	$(ZIG) fmt src build.zig --exclude src/input

fmt-check: ## Check formatting without changing files.
	$(ZIG) fmt --check src build.zig --exclude src/input

check: fmt-check test e2e ## Run all local verification (no file changes).

dist: ## Build reproducible release archives and SHA256SUMS for all six targets in zig-out/dist.
	rm -rf zig-out/matrix $(DIST)
	$(ZIG) build matrix
	@set -e; host=$$(uname -m | sed 's/arm64/aarch64/')-$$(uname -s | tr A-Z a-z | sed 's/darwin/macos/'); \
	if [ -x zig-out/matrix/$$host/tuppet ]; then \
		echo "end-to-end tests against zig-out/matrix/$$host/tuppet"; \
		for t in $(E2E); do echo "  $$t"; BIN=zig-out/matrix/$$host/tuppet $$t >/dev/null; done; \
	fi
	@set -e; mkdir -p $(DIST); epoch=$$(git log -1 --format=%ct); \
	for t in $(TARGETS); do \
		name=tuppet-$(VERSION)-$$t; mkdir -p $(DIST)/$$name/docs; \
		cp zig-out/matrix/$$t/tuppet* README.md LICENSE THIRD_PARTY_NOTICES.md $(DIST)/$$name/; \
		cp docs/protocol.md $(DIST)/$$name/docs/; \
		find $(DIST)/$$name -exec touch -d @$$epoch {} +; \
		case $$t in \
			*-windows) (cd $(DIST) && find $$name | LC_ALL=C sort | TZ=UTC zip -qX $$name.zip -@) ;; \
			*) tar -C $(DIST) --sort=name --mtime=@$$epoch --owner=0 --group=0 --numeric-owner -cf - $$name \
				| gzip -n >$(DIST)/$$name.tar.gz ;; \
		esac; \
		rm -r $(DIST)/$$name; \
	done
	cd $(DIST) && sha256sum tuppet-* >SHA256SUMS && cat SHA256SUMS

clean: ## Remove build output and the Zig cache.
	rm -rf zig-out .zig-cache
