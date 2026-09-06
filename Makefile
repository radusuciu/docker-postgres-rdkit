.PHONY: help core build runtime test test-build test-runtime smoke labels test-scripts test-scripts-offline clean

# Without this, make does not delete a target whose recipe failed (a registry
# error mid-write to $(RESOLVED)), so a truncated .make/pg-<x>-<y>.env would be
# left behind and treated as up to date on every later run.
.DELETE_ON_ERROR:

# Defaults come from versions.json so a bare `make runtime` builds the pair that
# gets the `latest` tag. Override any of them on the command line:
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

# The matrix default suite, independent of any DEBIAN override -- used only to
# decide whether the local tag needs a suite suffix (see SUITE_SUFFIX below).
MATRIX_DEBIAN := $(shell scripts/matrix.py --format debian)

CACHE_DIR  := .make
RESOLVED   := $(CACHE_DIR)/pg-$(POSTGRES)-$(DEBIAN).env
LABELS     := $(CACHE_DIR)/labels-$(POSTGRES)-$(RDKIT)-$(DEBIAN).env
LABELS_TMP := $(CACHE_DIR)/labels-tmp-$(POSTGRES)-$(RDKIT)-$(DEBIAN)

# Every local target builds and consumes a local core image, one per
# {RDKIT, DEBIAN}, shared across every PostgreSQL major.
CORE_IMAGE := rdkit-core:$(RDKIT)-$(DEBIAN)

# Make cannot pass a literal comma inside $(call); this is the standard escape.
COMMA := ,

# An on-demand build of a non-default Debian suite must not clobber the tag a
# default-suite build owns.
ifeq ($(DEBIAN),$(MATRIX_DEBIAN))
SUITE_SUFFIX :=
else
SUITE_SUFFIX := -$(DEBIAN)
endif

$(CACHE_DIR):
	mkdir -p $(CACHE_DIR)

# Resolving PostgreSQL is a network call, so its output is cached per (ref,
# suite). Run `make clean` to force re-resolution.
$(RESOLVED): scripts/resolve_matrix.py | $(CACHE_DIR)
	scripts/resolve_matrix.py resolve-pg $(POSTGRES) $(DEBIAN) > $@

# $(call docker_build,<target>,<extra docker build flags>)
# Recipes source $(RESOLVED) so a local image gets the same labels a CI build
# would.
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
		--build-arg vcs_ref=$$(git rev-parse HEAD) \
		$(2) \
		.
endef

# The image name matches the registry tag shape, with a suite suffix for any
# non-default suite.
image_name = postgres-rdkit:postgres-$$postgres_point_version-rdkit-$(RDKIT)$(SUITE_SUFFIX)

help:
	@echo "Targets: core build runtime test test-build test-runtime smoke labels test-scripts clean"
	@echo "Variables: POSTGRES=$(POSTGRES) RDKIT=$(RDKIT) DEBIAN=$(DEBIAN)"

# Build the PostgreSQL-independent RDKit core image locally. Not a file target
# (docker build is its own cache), so it always re-runs, but with an unchanged
# Dockerfile.rdkit-core Docker's layer cache makes it near-instant. Every
# target that builds the builder stage depends on it.
core:
	docker build \
		-f Dockerfile.rdkit-core \
		--target rdkit-core \
		--build-arg debian_version=$(DEBIAN) \
		--build-arg rdkit_version=$(RDKIT) \
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

# The fully offline subset of test-scripts, safe for CI (no Docker daemon, no
# network). test_install_boost.sh, test_runtime_packages.sh and
# test_smoke_test.sh need a live `docker run` and are excluded; SKIP_LIVE=1
# turns off test_resolve_matrix.py's one live-registry case.
OFFLINE_TESTS := tests/test_matrix.py tests/test_rdkit_labels.sh tests/test_resolve_matrix.py

test-scripts-offline:
	@fail=0; for t in $(OFFLINE_TESTS); do echo "=== $$t ==="; \
	  case "$$t" in *.py) SKIP_LIVE=1 python3 "$$t";; *) SKIP_LIVE=1 bash "$$t";; esac || fail=1; \
	done; exit $$fail

clean:
	rm -rf $(CACHE_DIR)
