.PHONY: help core build runtime test test-build test-runtime smoke labels test-scripts clean

# Without this, make does NOT delete a target whose recipe failed (e.g. a
# `resolve_pg.sh` 429 mid-write to $(RESOLVED)), so a truncated/empty
# .make/pg-<x>-<y>.env would be left behind and treated as up to date on
# every later run (Ruling 42).
.DELETE_ON_ERROR:

# Defaults come from versions.json so a bare `make runtime` builds the pair that
# gets the `latest` tag. Override any of them on the command line (SPEC R11):
#   make runtime POSTGRES=17.11 RDKIT=2023_09_6
#   make runtime POSTGRES=15    RDKIT=2025_03_6 DEBIAN=trixie
#
# Each `?=` stores the literal `$(shell ...)` text, which would otherwise
# re-fork scripts/matrix.py on every later reference. The `:=` immediately
# below freezes it to the computed value once. A command-line override (e.g.
# `DEBIAN=trixie`) still wins: make applies command-line variables before the
# makefile is read, so `?=` is a no-op and `:=` just re-assigns the override
# to itself.
DEBIAN        ?= $(shell scripts/matrix.py --format debian)
DEBIAN        := $(DEBIAN)
POSTGRES      ?= $(shell scripts/matrix.py --format latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["postgres_major"])')
POSTGRES      := $(POSTGRES)
RDKIT         ?= $(shell scripts/matrix.py --format latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["rdkit"])')
RDKIT         := $(RDKIT)
# Escape hatch for RDKit releases whose catch_tests.cpp calls
# Descriptors::GETAWAY unguarded (the whole 2025_03 family and 2025_09_1/_2).
# Local/on-demand lever only -- not wired into build_key.sh or any workflow.
DESCRIPTORS3D ?= OFF

# The matrix default suite, independent of any DEBIAN override -- used only to
# decide whether the local tag needs a suite suffix (see SUITE_SUFFIX below).
MATRIX_DEBIAN := $(shell scripts/matrix.py --format debian)

CACHE_DIR  := .make
RESOLVED   := $(CACHE_DIR)/pg-$(POSTGRES)-$(DEBIAN).env
LABELS     := $(CACHE_DIR)/labels-$(POSTGRES)-$(RDKIT)-$(DEBIAN).env
LABELS_TMP := $(CACHE_DIR)/labels-tmp-$(POSTGRES)-$(RDKIT)-$(DEBIAN)

# R7 (C1): the published rdkit-core image (Dockerfile.rdkit-core) cannot be
# pulled from ghcr.io in this session (no push/merge/PR access, and the tag
# doesn't exist yet regardless) -- Dockerfile's own `rdkit_core_image` ARG
# default points there only as the bare-`docker build .` fallback. Every
# local target instead builds and consumes a LOCAL core image, one per
# {RDKIT, DEBIAN} (not per POSTGRES/SUITE_SUFFIX -- that's the whole point
# of R7: one core tree shared across every PostgreSQL major).
#
# Ruling 46: R7 made `DESCRIPTORS3D` (the escape hatch for RDKit releases
# whose catch_tests.cpp calls Descriptors::GETAWAY unguarded, Ruling 35)
# unreachable -- every target now depends on `core`, and `core`'s
# Dockerfile.rdkit-core hardcoded RDK_BUILD_DESCRIPTORS3D=OFF, so `make core`
# died compiling catch_tests.cpp before `DESCRIPTORS3D=ON` ever got a chance
# to matter downstream. A DESCRIPTORS3D=ON core is a DIFFERENT compiled tree
# from the default (OFF) one, so it gets a DISTINCT local tag (`-d3d`
# suffix) rather than overwriting the shared `rdkit-core:<rdkit>-<debian>`
# tag every other build depends on -- this keeps `make core` (no override)
# and `make core DESCRIPTORS3D=ON` from clobbering each other's cache.
ifeq ($(DESCRIPTORS3D),OFF)
D3D_SUFFIX :=
else
D3D_SUFFIX := -d3d
endif
CORE_IMAGE := rdkit-core:$(RDKIT)-$(DEBIAN)$(D3D_SUFFIX)

# Make cannot pass a literal comma inside $(call); this is the standard escape.
COMMA := ,

# An on-demand build of a non-default Debian suite must not clobber the tag a
# default-suite build owns (owner ruling, amends SPEC R4's tag shape). Computed
# once here rather than duplicated at each use site.
ifeq ($(DEBIAN),$(MATRIX_DEBIAN))
SUITE_SUFFIX :=
else
SUITE_SUFFIX := -$(DEBIAN)
endif

$(CACHE_DIR):
	mkdir -p $(CACHE_DIR)

# resolve_pg.sh is a network call, so its output is cached per (ref, suite).
# Run `make clean` to force re-resolution.
$(RESOLVED): scripts/resolve_pg.sh | $(CACHE_DIR)
	scripts/resolve_pg.sh $(POSTGRES) $(DEBIAN) > $@

# $(call docker_build,<target>,<extra docker build flags>)
# Recipes source $(RESOLVED) so a local image gets the same labels a CI build
# would (SPEC R4, R9).
define docker_build
	set -eu; . $(RESOLVED); \
	docker build \
		-f Dockerfile \
		--target $(1) \
		--build-arg debian_version=$(DEBIAN) \
		--build-arg rdkit_version=$(RDKIT) \
		--build-arg rdkit_core_image=$(CORE_IMAGE) \
		--build-arg postgres_major_version=$$postgres_major_version \
		--build-arg postgres_point_version=$$postgres_point_version \
		--build-arg postgres_base_image=$$postgres_base_image \
		--build-arg postgres_base_digest=$$postgres_base_digest \
		--build-arg rdk_build_descriptors3d=$(DESCRIPTORS3D) \
		--build-arg vcs_ref=$$(git rev-parse HEAD) \
		$(2) \
		.
endef

# The image name matches the registry tag shape (SPEC R4), with a suite suffix
# for any non-default suite (owner ruling).
image_name = postgres-rdkit:postgres-$$postgres_point_version-rdkit-$(RDKIT)$(SUITE_SUFFIX)

help:
	@echo "Targets: core build runtime test test-build test-runtime smoke labels test-scripts clean"
	@echo "Variables: POSTGRES=$(POSTGRES) RDKIT=$(RDKIT) DEBIAN=$(DEBIAN)"

# R7 (C1): build the PostgreSQL-independent RDKit core image locally and tag
# it $(CORE_IMAGE). Not tracked via a file target (docker build is its own
# cache), so this always re-runs, but with an unchanged Dockerfile.rdkit-core
# and build context Docker's own layer cache makes it near-instant. Every
# target below that ultimately builds `builder` (build, labels, runtime,
# test-build, test-runtime) depends on this, since the builder stage's first
# steps now COPY --from=rdkit-core-provider rather than cloning and
# compiling RDKit itself.
core:
	docker build \
		-f Dockerfile.rdkit-core \
		--target rdkit-core \
		--build-arg debian_version=$(DEBIAN) \
		--build-arg rdkit_version=$(RDKIT) \
		--build-arg rdk_build_descriptors3d=$(DESCRIPTORS3D) \
		-t $(CORE_IMAGE) \
		.

build: core $(RESOLVED)
	@$(call docker_build,builder,-t postgres-rdkit-builder:$(RDKIT))

labels: core $(RESOLVED)
	@$(call docker_build,label-values-export,--output type=local$(COMMA)dest=$(LABELS_TMP))
	@mv $(LABELS_TMP)/labels.env $(LABELS)
	@rmdir $(LABELS_TMP)
	@cat $(LABELS)

# Two passes: build the image, then export the source-derived label values from
# the now-warm cache and rebuild with them stamped on. The second pass is near
# instant because every layer is cached.
runtime: core $(RESOLVED) labels
	@set -eu; . $(RESOLVED); . $(LABELS); \
	docker build \
		-f Dockerfile \
		--target runtime \
		--build-arg debian_version=$(DEBIAN) \
		--build-arg rdkit_version=$(RDKIT) \
		--build-arg rdkit_core_image=$(CORE_IMAGE) \
		--build-arg postgres_major_version=$$postgres_major_version \
		--build-arg postgres_point_version=$$postgres_point_version \
		--build-arg postgres_base_image=$$postgres_base_image \
		--build-arg postgres_base_digest=$$postgres_base_digest \
		--build-arg rdk_build_descriptors3d=$(DESCRIPTORS3D) \
		--build-arg rdkit_pickle_version=$$rdkit_pickle_version \
		--build-arg rdkit_cartridge_version=$$rdkit_cartridge_version \
		--build-arg boost_version=$$boost_version \
		--build-arg vcs_ref=$$(git rev-parse HEAD) \
		-t $(image_name) \
		. \
	&& docker image inspect $(image_name) --format 'Built {{index .RepoTags 0}} -- {{.Size}} bytes'

test-build: core $(RESOLVED)
	@$(call docker_build,test-build,)

test-runtime: core $(RESOLVED)
	@$(call docker_build,test-runtime,)

smoke: runtime
	@set -eu; . $(RESOLVED); scripts/smoke_test.sh $(image_name)

test: test-build test-runtime smoke

test-scripts:
	@fail=0; \
	for t in tests/test_*.sh; do \
		[ -e "$$t" ] || continue; \
		echo "=== $$t ==="; \
		bash "$$t" || fail=1; \
	done; \
	for t in tests/test_*.py; do \
		[ -e "$$t" ] || continue; \
		echo "=== $$t ==="; \
		python3 "$$t" || fail=1; \
	done; \
	exit $$fail

clean:
	rm -rf $(CACHE_DIR)
