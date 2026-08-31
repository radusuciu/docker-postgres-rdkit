.PHONY: build runtime test test-build test-runtime test-scripts

DEBIAN_VERSION ?= bookworm
PG_IMAGE_TAG ?= 17.2
PG_MAJOR_VERSION ?= 17
RDKIT_VERSION ?= 2024_09_5

IMAGE_TAG = postgres-rdkit:pg$(PG_IMAGE_TAG)-rdkit-$(RDKIT_VERSION)
BUILD_ARGS = \
	--build-arg debian_version=$(DEBIAN_VERSION) \
	--build-arg PG_IMAGE_TAG=$(PG_IMAGE_TAG) \
	--build-arg PG_MAJOR_VERSION=$(PG_MAJOR_VERSION) \
	--build-arg RDKIT_VERSION=$(RDKIT_VERSION)

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
