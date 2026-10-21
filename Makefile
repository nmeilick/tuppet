.DEFAULT_GOAL := _default

MAKE_SELF ?= $(firstword $(MAKEFILE_LIST))
MAKE_RECURSE = $(MAKE) --no-print-directory -f "$(MAKE_SELF)"

ZIG ?= zig
OPTIMIZE ?= ReleaseSafe
# Parallel compile jobs of `make dist`; each takes about 2 GB of memory at
# its peak, so set JOBS=2 on a machine with less than about 8 GB free.
# Empty: one job per CPU core.
JOBS ?=
BIN := zig-out/bin/tuppet
VERSION := $(shell sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon)
TARGETS := x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows aarch64-windows
# The font variants; lean and full add -lean and -full to the target in
# matrix directories and archive names.
VARIANTS := lean medium full
DIST := zig-out/dist
JOBS_FLAG := $(if $(JOBS),-j$(JOBS))
E2E := test/cli_failures.sh test/dsr_reply.sh test/trace.sh test/daemon_resilience.sh test/supervised.sh test/protocol.sh test/store.sh test/picker.sh test/names.sh test/wait.sh test/sample.sh test/input.sh test/events.sh test/alerts.sh test/sweep.sh test/shutdown.sh test/png.sh

# The emoji atlas's inputs: Noto Color Emoji 2.057 (release
# v2026-09-24-unicode18_0) and the Unicode 18.0 emoji sequence files.
EMOJI_SRC := zig-out/emoji-src
EMOJI_SIZE := 48
NOTO_URL := https://raw.githubusercontent.com/googlefonts/noto-emoji/v2026-09-24-unicode18_0/2D/fonts/NotoColorEmoji.ttf
NOTO_SHA256 := 15671215ab769fdc7162a045d56fd7d7e477c51b04e6b3c761d914d8fdd6cc44
SEQ_URL := https://www.unicode.org/Public/18.0.0/emoji/emoji-sequences.txt
SEQ_SHA256 := 1823dce71f3dd9cb0ad1976797baee4ffbdc1909756f43af8ce4c57f732843a4
ZWJ_URL := https://www.unicode.org/Public/18.0.0/emoji/emoji-zwj-sequences.txt
ZWJ_SHA256 := f61b5213bdf85a57741a9f903cb38d0f39a3d13be6ff4aca3b39857e859a9191

.PHONY: _default help build run smoke test e2e fmt fmt-check check static dist emoji clean

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
	@set -e; for t in $(E2E); do echo "$$t"; BIN=$(BIN) TUPPET_CONFIG= $$t; done

fmt: ## Format the sources (vendored src/input stays as upstream wrote it).
	$(ZIG) fmt src tools build.zig --exclude src/input

fmt-check: ## Check formatting without changing files.
	$(ZIG) fmt --check src tools build.zig --exclude src/input

check: fmt-check test e2e ## Run all local verification (no file changes).

static: ## Check that the binaries of `zig build matrix` in zig-out/matrix are self-contained.
	test/static.sh zig-out/matrix

dist: ## Build reproducible release archives and SHA256SUMS for all six targets and three font variants in zig-out/dist (JOBS=N limits parallel compiles).
	rm -rf zig-out/matrix $(DIST)
	@set -e; for v in $(VARIANTS); do echo "$(ZIG) build matrix -Dfonts=$$v $(JOBS_FLAG)"; $(ZIG) build matrix -Dfonts=$$v $(JOBS_FLAG); done
	test/static.sh zig-out/matrix
	@set -e; host=$$(uname -m | sed 's/arm64/aarch64/')-$$(uname -s | tr A-Z a-z | sed 's/darwin/macos/'); \
	if [ -x zig-out/matrix/$$host/tuppet ]; then \
		echo "end-to-end tests against zig-out/matrix/$$host/tuppet"; \
		for t in $(E2E); do echo "  $$t"; BIN=zig-out/matrix/$$host/tuppet TUPPET_CONFIG= $$t >/dev/null; done; \
		for v in lean full; do \
			echo "  test/png.sh against zig-out/matrix/$$host-$$v/tuppet"; \
			BIN=zig-out/matrix/$$host-$$v/tuppet TUPPET_CONFIG= test/png.sh >/dev/null; \
		done; \
	fi
	@set -e; mkdir -p $(DIST); epoch=$$(git log -1 --format=%ct); \
	for t in $(TARGETS); do for v in $(VARIANTS); do \
		if [ $$v = medium ]; then dir=$$t; else dir=$$t-$$v; fi; \
		name=tuppet-$(VERSION)-$$dir; mkdir -p $(DIST)/$$name/docs; \
		cp zig-out/matrix/$$dir/tuppet* README.md LICENSE THIRD_PARTY_NOTICES.md $(DIST)/$$name/; \
		cp docs/protocol.md $(DIST)/$$name/docs/; \
		find $(DIST)/$$name -exec touch -d @$$epoch {} +; \
		case $$t in \
			*-windows) (cd $(DIST) && find $$name | LC_ALL=C sort | TZ=UTC zip -qX $$name.zip -@) ;; \
			*) tar -C $(DIST) --sort=name --mtime=@$$epoch --owner=0 --group=0 --numeric-owner -cf - $$name \
				| gzip -n >$(DIST)/$$name.tar.gz ;; \
		esac; \
		rm -r $(DIST)/$$name; \
	done; done
	cd $(DIST) && sha256sum tuppet-* >SHA256SUMS && cat SHA256SUMS

emoji: ## Regenerate assets/emoji from the pinned Noto Color Emoji (downloads, checked by sha256).
	@set -e; mkdir -p $(EMOJI_SRC); \
	fetch() { \
		if [ ! -f "$(EMOJI_SRC)/$$1" ]; then \
			curl -fsSL -o "$(EMOJI_SRC)/$$1.part" "$$2"; \
			echo "$$3  $(EMOJI_SRC)/$$1.part" | sha256sum -c --quiet; \
			mv "$(EMOJI_SRC)/$$1.part" "$(EMOJI_SRC)/$$1"; \
		fi; \
		echo "$$3  $(EMOJI_SRC)/$$1" | sha256sum -c --quiet; \
	}; \
	fetch NotoColorEmoji.ttf $(NOTO_URL) $(NOTO_SHA256); \
	fetch emoji-sequences.txt $(SEQ_URL) $(SEQ_SHA256); \
	fetch emoji-zwj-sequences.txt $(ZWJ_URL) $(ZWJ_SHA256)
	$(ZIG) run -OReleaseFast tools/emoji/gen.zig -- $(EMOJI_SRC)/NotoColorEmoji.ttf \
		$(EMOJI_SRC)/emoji-sequences.txt $(EMOJI_SRC)/emoji-zwj-sequences.txt assets/emoji $(EMOJI_SIZE)

clean: ## Remove build output and the Zig cache.
	rm -rf zig-out .zig-cache
