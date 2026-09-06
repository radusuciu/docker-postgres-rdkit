**NOTE**: I'm still experimenting with things in this repo!

# docker-postgres-rdkit

This project creates PostgreSQL docker images with the RDKit cartridge built and installed. A single `main` branch and a declarative matrix in `versions.json` drive the builds; GitHub Actions rebuilds the matrix daily and skips anything whose inputs have not changed. Images are pushed to the GitHub Container Registry (GHCR).

The image is based on the Dockerfile by [rvianello](https://github.com/rvianello/docker-postgres-rdkit/blob/master/Dockerfile).

## How to Use

Assuming you have docker installed, you can pull the image using:

```bash
docker pull ghcr.io/radusuciu/docker-postgres-rdkit/postgres-rdkit:<tag>
```

Tags follow these rules. For the default Debian suite (the `debian` key in `versions.json`, currently `bookworm`):

| Tag | Meaning |
| --- | --- |
| `postgres-<pg_point>-rdkit-<rdkit>` | Reproducible pin, e.g. `postgres-17.11-rdkit-2026_03_6`. |
| `postgres-<pg_major>-rdkit-<rdkit>-<build_key>` | Immutable; dedup/provenance. |
| `postgres-<pg_major>-rdkit-<rdkit>` | Moving; pushed only when the build's point release is the current one for that major. |
| `latest` | Only the newest (RDKit, PostgreSQL) pair, and only when it is current. |

For a build of any other Debian suite, the point tag gains a `-<suite>` suffix, and no moving major tag and no `latest` are pushed:

| Tag | Meaning |
| --- | --- |
| `postgres-<pg_point>-rdkit-<rdkit>-<suite>` | Reproducible pin for that suite. |
| `postgres-<pg_major>-rdkit-<rdkit>-<build_key>` | Immutable; dedup/provenance. |

This is deliberate: an on-demand build must never re-point a tag the automatic matrix owns. The automatic matrix itself is single-suite, so a non-default suite is only reachable through `make ... DEBIAN=<suite>` locally or the `Build images` workflow's `debian` `workflow_dispatch` input.

You can find every available tag either in the "Available Versions" table below (regenerated daily) or on this repository's GHCR package page, linked from the "Packages" section in the repository sidebar.

Every image also carries provenance labels -- notably `org.rdkit.pickle-version`, which is the actual client/server compatibility contract: your client's RDKit must be at least the cartridge's RDKit, or a newer pickle format will be read with only a warning and produce corrupt results. Inspect the labels with `docker image inspect --format '{{json .Config.Labels}}' <image>`.

To run the Docker container, use:

```bash
docker run -d -e POSTGRES_PASSWORD=<password> -p 5432:5432 ghcr.io/radusuciu/docker-postgres-rdkit/postgres-rdkit:<tag>
```

Replace <tag> with the version tag of the Docker image.

## Available Versions

<!-- start automatically generated version matrix -->
| PostgreSQL | RDKit | Tag |
| --- | --- | --- |
| 18.6 | 2026_03_6 | `postgres-18-rdkit-2026_03_6` |
| 17.11 | 2026_03_6 | `postgres-17-rdkit-2026_03_6` |
| 16.15 | 2026_03_6 | `postgres-16-rdkit-2026_03_6` |
| 15.19 | 2026_03_6 | `postgres-15-rdkit-2026_03_6` |
| 14.24 | 2026_03_6 | `postgres-14-rdkit-2026_03_6` |
| 18.6 | 2025_09_6 | `postgres-18-rdkit-2025_09_6` |
| 17.11 | 2025_09_6 | `postgres-17-rdkit-2025_09_6` |
| 16.15 | 2025_09_6 | `postgres-16-rdkit-2025_09_6` |
| 15.19 | 2025_09_6 | `postgres-15-rdkit-2025_09_6` |
| 14.24 | 2025_09_6 | `postgres-14-rdkit-2025_09_6` |
<!-- end automatically generated version matrix -->

## Configuration

This image is based on the official postgres image, see [here](https://hub.docker.com/_/postgres) for details on configuration.

For details on use of the rdkit cartridge, refer to the [rdkit docs on the matter](https://www.rdkit.org/docs/Cartridge.html).

## Building the Docker Image

Builds are driven by `versions.json`, which declares the Debian suite, the PostgreSQL majors and the RDKit releases that are rebuilt automatically by the `Build images` GitHub Actions workflow. A single-line edit to that file adds or removes a pair; nothing else changes.

Any (PostgreSQL, RDKit) pair can also be built on demand without editing `versions.json`, either through the `Build images` workflow's `workflow_dispatch` inputs or locally with `make`:

```bash
make runtime POSTGRES=17.11 RDKIT=2026_03_6
make runtime POSTGRES=15    RDKIT=2025_09_6 DEBIAN=trixie
make test    POSTGRES=17.11 RDKIT=2026_03_6
```

`POSTGRES` accepts a major (`17`, which resolves to the current point release at build time) or a point release (`17.11`, which pins an immutable base image). Run `make help` to see the full target and variable surface: targets `core build runtime test test-build test-runtime smoke labels test-scripts clean`, and variables `POSTGRES`, `RDKIT`, `DEBIAN` (defaults come from `versions.json`, so a bare `make runtime` builds the pair that gets the `latest` tag). `make core` builds the PostgreSQL-independent RDKit compile (`Dockerfile.rdkit-core`) that every other target depends on, shared across every `POSTGRES` value for the same `RDKIT`/`DEBIAN` -- `build`/`runtime`/`test-build`/`test-runtime` all run it as a prerequisite, so it is rarely invoked directly. `make smoke` runs this project's functional smoke test against a built runtime image; `make test-scripts` runs this repo's own shell/Python test suite under `tests/` and does not need Docker; `make clean` clears the `.make/` cache that memoizes `scripts/resolve_pg.sh`'s network lookups.

### Which RDKit releases build

Not every RDKit release compiles cleanly with this Dockerfile's default configuration (`RDK_BUILD_DESCRIPTORS3D=OFF`, `RDK_BUILD_CHEMDRAW_SUPPORT=OFF`, `RDK_BUILD_INCHI_SUPPORT=ON`):

| RDKit release | builds with the defaults? | note |
| --- | --- | --- |
| 2023_09_6, 2024_09_5 | yes | |
| 2025_03_1 … 2025_03_6 | **no** | unguarded `Descriptors::GETAWAY` in `Code/GraphMol/Descriptors/catch_tests.cpp` |
| 2025_09_1, 2025_09_2 | **no** | same, plus `Code/Bench/inchi.cpp` |
| 2025_09_3 and newer | yes | upstream guarded the GETAWAY calls |
| 2026_03_* | yes | |

The releases marked "no" fail a roughly 20-minute compile at around 77%. That is an upstream test-file defect in those specific releases, fixed in the next patch release, so the fix is to build that patch release instead.

To invoke `docker build` directly: since R7, the main `Dockerfile`'s builder stage starts `FROM` a separately-built, PostgreSQL-independent RDKit compile (`Dockerfile.rdkit-core`) rather than cloning and compiling RDKit itself, so a bare invocation needs that image to exist somewhere `rdkit_core_image` can resolve. The default points at this project's own published `ghcr.io/radusuciu/docker-postgres-rdkit/rdkit-core:<rdkit>-<debian>`, which requires network access and only exists for pairs the automatic matrix (or a `workflow_dispatch`) has actually built; `make`'s targets instead always build and consume a local `rdkit-core` image first (see `make core`, above), which is what you want for a fork or an unpublished pair:

```bash
docker build -t <your_tag> \
  --build-arg debian_version=bookworm \
  --build-arg postgres_major_version=17 \
  --build-arg rdkit_version=2026_03_6 \
  .
```

Build arguments:

* `debian_version`: the Debian suite of the base image. Formatted like `bookworm`.
* `postgres_major_version`: the major version of PostgreSQL. Formatted like `17`.
* `postgres_point_version`: optional, labels only. Formatted like `17.11`.
* `postgres_base_image`: optional; defaults to `docker.io/postgres:<major>-<suite>`. Set it to pin a point release or a digest.
* `rdkit_core_image`: optional; defaults to `ghcr.io/radusuciu/docker-postgres-rdkit/rdkit-core:<rdkit_version>-<debian_version>`. The PostgreSQL-independent RDKit compile the builder stage reuses (R7, `Dockerfile.rdkit-core`). Set it to a locally-built tag (what `make` does) to avoid a network pull.
* `rdkit_version`: an RDKit release tag suffix. Formatted like `2026_03_6`.

There is no build argument that selects a Boost version. Instead, the Boost package family is chosen automatically at build time from RDKit's own declared floor (`RDK_BOOST_VERSION`), picking the lowest family in the Debian suite that satisfies it.

If no family in the suite satisfies the floor, the build fails with a message naming the floor and listing what the suite offers. The fix in that case is to raise `debian` in `versions.json`.

## Credits and other projects

The image is based on the Dockerfile by [rvianello](https://github.com/rvianello/docker-postgres-rdkit/blob/master/Dockerfile).

Here is a non-exhaustive list of other projects that do something similar:
* [`docker-postgres-rdkit`](https://github.com/rvianello/docker-postgres-rdkit) by rvianello
* [`docker-postgres-rdkit`](https://github.com/mcs07/docker-postgres-rdkit) by mcs07
* [`docker-postgres-rdkit`](https://github.com/v-kamerdinerov/docker-postgres-rdkit) by v-kamerdinerov
* [`docker-postgres-rdkit`](https://github.com/joelduerksen/docker-postgres-rdkit) by joelduerksen

The main difference between these projects and this one is that I'm attempting to automate the creation of images as much as possible, to ensure that all version combinations going forward (and a few historical) are covered.

This project was put together with a lot of prodding of ChatGPT.
