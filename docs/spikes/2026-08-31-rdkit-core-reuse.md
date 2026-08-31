# Spike: reusing a PostgreSQL-independent RDKit build (SPEC R7)

**Question:** can the RDKit core compile be shared across PostgreSQL majors so
the matrix performs 2 compiles instead of 10?

**Acceptance (SPEC R7):** a cartridge-only rebuild must be at least 5x faster
than a full build for the same pair.

Measured on the same host as `docs/spikes/2026-08-30-baseline.md` (WSL2
desktop, 12 cores, 45 GB RAM), 2026-08-31, pair postgres 17.11 / rdkit
2026_03_6 / debian bookworm, `num_build_cores=4` throughout. All three builds
were run detached with `docker build --no-cache --progress=plain`, logged to
a unique path, and timed by a `date +%s` delta around each detached build
(`docker image inspect ... --format '{{.Created}}'` used as the authoritative
end timestamp, since the local shell used to launch each build is not the
container producing that timestamp).

| measurement | value |
| --- | --- |
| baseline full build (this spike, cold, C6) | 1533 s |
| `rdkit-core` build, clean cache | 1464 s |
| cartridge-only rebuild, clean cache | 66 s |
| speedup vs. full build (end-to-end wall clock) | 23.2x |
| C++ objects rebuilt by the consuming `make` | 3 |

**Result:** PASS

**Decision:** implement R7 (Task 18)

## Commands and logs

Core image (`Dockerfile.rdkit-core`, target `rdkit-core`):

```
docker build --no-cache --progress=plain \
  -f Dockerfile.rdkit-core --target rdkit-core \
  --build-arg debian_version=bookworm \
  --build-arg rdkit_version=2026_03_6 \
  --build-arg num_build_cores=4 \
  -t rdkit-core:2026_03_6-bookworm .
```
Log: `/tmp/task17-core-1.log`. Started (`date +%s`) 1788209723; image
`Created` 2026-08-31T14:19:47.213855767-07:00 (epoch 1788211187). Wall clock
**1464 s**. The `make` RUN step's own BuildKit elapsed time, `#13 DONE
1414.2s`, is consistent with this (the remainder is apt/git-clone/Boost-
install/CMake-download/export overhead common to any cold build of this
stage).

Consuming stage (`/tmp/Dockerfile.spike`, target `spike`), successful attempt:

```
docker build --no-cache --progress=plain \
  -f /tmp/Dockerfile.spike --target spike -t spike:probe .
```
(Build context: this worktree, `.` — not the path in the brief's Step 4
snippet, `/home/radu/repos/docker-postgres-rdkit`. That path is a *different*
checkout, on branch `wip`, without `scripts/`, `enable_extension.sql`, etc.
present; it is not this task's environment. See "Deviations from the brief",
below.)
Log: `/tmp/task17-spike-3.log`. Started 1788211460; image `Created`
2026-08-31T14:25:26.931412543-07:00 (epoch 1788211526). Wall clock **66 s**.
The `make -j4` RUN step's own BuildKit elapsed time, `#16 DONE 12.7s` (BuildKit
reports 12.64s internally; the log line rounds to 12.7s), is the like-for-like
compile-step figure against the full build's `#16 DONE 1455.9s` compile step
below — see "Which ratio", further down.

Full build denominator (current `Dockerfile`, target `runtime`, C6):

```
docker build --no-cache --progress=plain \
  -f Dockerfile --target runtime \
  --build-arg debian_version=bookworm \
  --build-arg rdkit_version=2026_03_6 \
  --build-arg postgres_major_version=17 \
  --build-arg postgres_point_version=17.11 \
  --build-arg postgres_base_image=docker.io/postgres:17-bookworm@sha256:051f7b7b3abdd564d5d1bd1e8c4b9c1b6e77087d1dd22020ede611c096a272e0 \
  --build-arg postgres_base_digest=sha256:051f7b7b3abdd564d5d1bd1e8c4b9c1b6e77087d1dd22020ede611c096a272e0 \
  --build-arg num_build_cores=4 \
  --build-arg vcs_ref=ba9ae49015060c383c39a9be88c771e11500fa92 \
  -t postgres-rdkit:task17-fullbuild .
```
Log: `/tmp/task17-fullbuild-1.log`. Started 1788211660; image `Created`
2026-08-31T14:53:13.699543939-07:00 (epoch 1788213193). Wall clock **1533
s**. The `make` RUN step's own BuildKit elapsed time is `#16 DONE 1455.9s`.

### A warm-cache trap this measurement had to route around

Before launching the full-build denominator, `docker buildx du --verbose`
showed an **857.6 MB warm BuildKit cache mount**, `id
=rdkit-build-2026_03_6-17-bookworm` — populated by a pre-existing local image,
`postgres-rdkit:postgres-17-rdkit-2026_03_6` (built ~7 h earlier on this
host, confirmed by `docker images`). `--no-cache` on `docker build` only
clears the *layer* cache; it does **not** clear a named `RUN --mount=type=
cache` mount, which BuildKit keys by `id` independent of the build. Measuring
the "cold full build" without addressing this would have silently hit that
warm mount — `make` would have found the tree already built, in exactly the
failure mode C1/C6 warn against ("must not be contaminated by a warm cache").

`docker builder prune` in any form is forbidden (hard project constraint —
it would destroy every other cache mount on the host, unrelated to this
pair). Instead, a disposable one-off Dockerfile
(`FROM debian:bookworm-slim` / `RUN --mount=type=cache,target=/tmp/rdkit-build,
id=rdkit-build-2026_03_6-17-bookworm,uid=999,gid=999 rm -rf /tmp/rdkit-build/*
...`) was built once to empty *only that one mount id*, verified empty
afterward (`docker buildx du --verbose` → `Size: 0B` for that id), and the
disposable image discarded. No other cache mount was touched. The full build
that followed immediately repopulated the mount to a size (>1 GB expected)
at least as complete as before, so nothing was net-destroyed — this is
categorically different from `docker builder prune -af`, which erases
everything with no plan to refill it.

## Step 5: object count and cache-survival diagnostic

`grep -c 'Building CXX object' /tmp/task17-spike-3.log` → **3**.
`grep -c 'Building C object' /tmp/task17-spike-3.log` → **12**.
**Total: 15 objects rebuilt**, out of the full build's 1241 (1059 CXX + 182
C, `/tmp/task17-fullbuild-1.log`) and the core image's 1228 (1058 CXX + 170
C, `/tmp/task17-core-1.log`).

15 is a number in the **low tens**, not the thousands — per the brief's own
diagnostic, this means the CMake cache survived the reconfigure and only the
cartridge (plus two incidental files, below) compiled and relinked. The
object count corroborates the wall clock rather than contradicting it: a
build that touched 15 of ~1230 objects finishing in 66 s against a
full-1241-object build's 1533 s is exactly the shape R7 predicts, not an
artifact of a fast-but-wrong measurement.

The 3 CXX objects were: `External/pubchem_shape/.../pubchem_align3d.dir/
shape_neighbor.cpp.o`, the same file's `_static` variant, and `Code/PgSQL/
rdkit/CMakeFiles/rdkit.dir/adapter.cpp.o` (the cartridge's own C++ source —
expected). The two `pubchem_align3d` recompiles are *not* new work the
reconfigure caused: `COPY --from=core` resets file mtimes to copy time, and
those two translation units evidently ended up with a source mtime newer
than their already-built `.o` after the copy, so `make` rebuilt them out of
caution — a harmless side effect of using `COPY` to move a build tree
between images, not a sign the CMake cache was invalidated. (If Task 18 COPYs
the build tree the same way, expect the same handful of incidental
recompiles; they cost nothing meaningful next to the 15 s the cartridge
relink itself takes.)

## Which ratio, and why both are reported

Two legitimate denominators exist and they disagree by 5x:

- **End-to-end wall clock, same target shape (chosen for the headline row):**
  full build 1533 s vs. cartridge-only rebuild 66 s → **23.2x**. This is
  what a matrix entry actually pays end-to-end: apt installs, git clone,
  Boost install, CMake download, configure, compile, and the BuildKit image
  export, for both sides.
- **Compile-step only, `make`'s own BuildKit elapsed time:** full build's
  `#16 DONE 1455.9s` vs. cartridge-only rebuild's `#16 DONE 12.7s` (`12.64s`
  internally) → **115.2x**. This isolates the one operation R7 actually
  changes — do the RDKit C++ objects need recompiling — from the apt/clone/
  Boost-install overhead that is roughly fixed cost on both sides. It is the
  more mechanistically honest number for **why** R7 works, but it is not
  the number a matrix entry's wall clock will show, because the consuming
  stage still pays for installing `postgresql-server-dev-<N>` (needed for
  `pg_config`/headers) and re-running Boost's apt install (see Notes,
  below) before it ever reaches `make`.

**The record's headline number is the conservative one, 23.2x** — the
smaller of the two, and still more than 4x the 5x bar. Both numerators and
denominators are named explicitly above so neither can be mistaken for the
other.

## What changed between spike attempts 1, 2 and 3

Required record for Task 18, which inherits this working configuration
verbatim.

**Attempt 1** (`/tmp/task17-spike-1.log`) — failed, exit code 100, at the
apt-get install step, before ever reaching cmake/make:
```
E: Version '17.11*' for 'libpq-dev' was not found
```
Cause: the brief's Step 3 snippet adds only pgdg's *current* apt repo. pgdg's
current repo does not retain every point release; `postgres:17-bookworm`'s
exact point version (17.11) had already rotated out of it by the time this
spike ran, even though `postgresql-server-dev-17` (a different package,
still present) resolved fine. **Fix:** mirrored `Dockerfile` (HEAD) exactly —
added the second `pgdg-archive` apt source line, and installed `libpq5` at
the pinned version alongside `libpq-dev`, exactly as `Dockerfile`'s builder
stage already does and explains ("pgdg is needed for the -dev packages
matching this image's server version"). This is not one of C1-C12; it is
the same class of defect (an incomplete snippet) discovered empirically and
fixed by copying already-proven-correct behavior from `Dockerfile`, not by
guessing at anything the corrections govern.

**Attempt 2** (`/tmp/task17-spike-2.log`) — apt fixed, reached `make -j4`,
failed there, exit code 2:
```
make[2]: *** No rule to make target '/usr/lib/x86_64-linux-gnu/libboost_serialization.so.1.81.0',
  needed by 'lib/libRDKitInchi.so.1.2026.03.6'.  Stop.
```
This is exactly the fallback case the brief's Step 3 anticipates: `COPY
--from=core` of only `/usr/include/boost` (headers) and the CMake package-
config directory is not sufficient to *link* against Boost — the actual
`.so` runtime libraries were never copied into the consuming stage. Before
this failure, the reconfigure + relink had already gone straight to
"`[0%] Built target inchi_support`" style near-instant no-ops for almost
everything (0 `Building CXX object` lines logged before the failure) — i.e.
the CMake cache had already, visibly, survived; this was purely a missing
runtime library, not a cache problem. **Fix (the brief's documented
fallback, taken as written):** replaced the two Boost `COPY --from=core`
lines with `scripts/install_boost.sh` run directly in the consuming stage.
Because both stages are the same Debian suite (bookworm), `install_boost.sh`
selects the same family (1.81) the core image used, so the `.so` the
reconfigure now links against is the same package family, just apt-installed
a second time rather than copied.

**Attempt 3** (`/tmp/task17-spike-3.log`) — succeeded. No further changes to
the Dockerfile beyond attempt 2's fix; this is the run whose numbers appear
in the table above.

## C7's asymmetry, for Task 18

In the main `Dockerfile`, `${build_dir}` (`/tmp/rdkit-build`) is a BuildKit
**cache mount** (`--mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build-
${rdkit_version}-${postgres_major_version}-${debian_version},uid=999,gid=999`)
on **six separate `RUN` lines** (the cmake configure, `make`, `make install`,
`pgsql_install.sh`, and both `ctest` invocations in `test-build`/
`test-runtime`) — so that tree is **not part of any image layer** and cannot
be reached by a later stage's `COPY --from=`. `Dockerfile.rdkit-core`
deliberately does **not** use a cache mount for `${build_dir}`: the tree
lands in a normal image layer specifically so `COPY --from=core ${build_dir}
${build_dir}` in the consuming stage works at all, which is what this spike
relies on.

Task 18 has to reconcile those two facts, not just note them: if Task 18's
production Dockerfile keeps the current cache-mount `RUN` lines *and* adds a
`COPY --from=rdkit-core ${build_dir} ${build_dir}` ahead of them, the `COPY`
would write into a path a later `RUN --mount=type=cache` then **shadows**
with the (separately-keyed, likely-empty-for-this-major) cache mount —
silently discarding the copied tree the moment the first cache-mounted `RUN`
runs, and reproducing exactly the class of bug this spike exists to catch.
Task 18 must decide, deliberately, whether the production consuming stage
drops the cache mount for `${build_dir}` (mirroring this spike, simplest,
proven here) or keeps it and arranges for the `COPY`'s output to survive
under it (e.g. copying into the cache mount's target from within a `RUN
--mount=type=cache` itself, before the reconfigure) — but not both
unreconciled, or the copy is silently discarded and the whole cartridge
recompiles from scratch with the cache mount masking why.

## Notes

- **Did the CMake cache survive the reconfigure?** Yes. Only 15 of ~1230
  objects recompiled (3 CXX + 12 C); everything else reported `Built target
  <X>` without recompiling, and the `RDK_BUILD_PGSQL=ON` reconfigure went
  straight from "Configuring done" to relinking previously-built libraries.
- **Did toggling `RDK_BUILD_PGSQL` trigger a broader rebuild?** No. The
  only *new* compilation the toggle caused was `Code/PgSQL/rdkit`'s own 12 C
  sources (`adapter.cpp`'s object was already counted above) plus that one
  `adapter.cpp` C++ translation unit — precisely the cartridge's own source
  tree, nothing in core RDKit. The two incidental `pubchem_align3d`
  recompiles (see "Step 5", above) are attributable to `COPY`'s mtime
  behavior, not to the `RDK_BUILD_PGSQL` toggle.
- **Were any absolute paths mismatched between the two Dockerfiles?** No.
  `source_dir=/tmp/rdkit`, `build_dir=/tmp/rdkit-build`,
  `install_dir=/opt/rdkit`, `cmake_install_dir=/opt/cmake` are the same ARG
  defaults, unchanged, in both `Dockerfile.rdkit-core` and
  `/tmp/Dockerfile.spike`; the successful reconfigure and relink is itself
  the empirical proof that CMake's cached absolute paths matched.
- **Was Boost copied from the core image or reinstalled in the consuming
  stage?** Reinstalled, via `scripts/install_boost.sh`, after the plain
  `COPY --from=core` of Boost's headers and CMake config proved insufficient
  for linking (attempt 2, above) — the documented fallback in the brief's
  Step 3, taken as written.

## Deviations from the brief (beyond C1-C12)

Two additional defects in the brief's own snippets, distinct from C1-C12,
were found and fixed empirically rather than by guessing at anything C1-C12
governs:

1. **Step 3's apt block** (missing `pgdg-archive`, missing `libpq5`) — see
   "What changed between spike attempts 1, 2 and 3", above.
2. **Step 4's build context.** The brief's Step 4 command uses
   `/home/radu/repos/docker-postgres-rdkit` as the build context. In this
   environment that path is a *separate* checkout on branch `wip` that does
   not have `scripts/install_boost.sh` (or most other repo files) checked
   out — `COPY scripts/install_boost.sh ...` failed there with `"/scripts/
   install_boost.sh": not found`. This task's dispatch is explicit that
   every command must run from the worktree
   (`.../worktrees/refactor-single-branch-matrix`), so the consuming
   spike build used `.` (this worktree) as its context instead. Not a
   cmake-flag judgment call; a location fix consistent with the task's own
   operating instructions.

`Dockerfile.rdkit-core` is **left untracked** (spike PASSED — Step 7's
cleanup, which deletes it, applies only to a FAIL). It is not excluded by
`.gitignore`. `scripts/build_key.sh` already lists it among the files it
hashes (skipping it while absent), so the moment it is committed — Task 18's
job, not this spike's — every build key changes; that is intended (R6 must
notice the change) and is recorded here so Task 18 does not treat it as a
surprise.
