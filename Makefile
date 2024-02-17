.PHONY: build
build:
	docker build \
		-f Dockerfile \
		--target builder \
		--build-arg PG_IMAGE_TAG=16.1 \
		--build-arg PG_MAJOR_VERSION=16 \
		--build-arg RDKIT_VERSION=2023_09_4 \
		-t build \
		.
