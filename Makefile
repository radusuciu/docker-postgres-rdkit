.PHONY: build runtime test test-build test-runtime test-scripts

DEBIAN ?= bookworm
PG_MAJOR ?= 17
RDKIT ?= 2026_03_6

IMAGE_TAG = postgres-rdkit:postgres-$(PG_MAJOR)-rdkit-$(RDKIT)
BUILD_ARGS = \
	--build-arg debian_version=$(DEBIAN) \
	--build-arg postgres_major_version=$(PG_MAJOR) \
	--build-arg rdkit_version=$(RDKIT)

build:
	docker build \
		-f Dockerfile \
		--target builder \
		$(BUILD_ARGS) \
		-t $(IMAGE_TAG)-builder \
		.

runtime:
	docker build \
		-f Dockerfile \
		--target runtime \
		$(BUILD_ARGS) \
		-t $(IMAGE_TAG) \
		.

test-build:
	docker build \
		-f Dockerfile \
		--target test-build \
		$(BUILD_ARGS) \
		.

test-runtime:
	docker build \
		-f Dockerfile \
		--target test-runtime \
		$(BUILD_ARGS) \
		.

test: test-build test-runtime

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
