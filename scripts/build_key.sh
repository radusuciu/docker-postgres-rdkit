#!/usr/bin/env bash
# Content-addressed build key for rebuild avoidance (SPEC R6).
#
# Because the base image is a moving major tag, "has this already been built?"
# cannot be answered by repository SHA alone. The key hashes everything that
# determines the resulting image:
#   - the content of every file that enters the image
#   - the resolved base image digest for that major
#   - the RDKit version and the Debian suite
#   - the rdkit-core image digest, once R7 lands
#
# versions.json is deliberately NOT an input: adding a pair must not invalidate
# the keys of existing pairs.
set -euo pipefail

rdkit=""
debian=""
base_digest=""
core_digest=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rdkit)       rdkit="${2:-}"; shift 2 ;;
        --debian)      debian="${2:-}"; shift 2 ;;
        --base-digest) base_digest="${2:-}"; shift 2 ;;
        --core-digest) core_digest="${2:-}"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

for name in rdkit debian base_digest; do
    if [ -z "${!name}" ]; then
        echo "usage: build_key.sh --rdkit <v> --debian <suite> --base-digest <sha256:...> [--core-digest <sha256:...>]" >&2
        exit 1
    fi
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Files that enter the image. Missing files are skipped so the key is computable
# before Dockerfile.rdkit-core exists (R7 is gated on a spike).
image_files=(
    Dockerfile
    Dockerfile.rdkit-core
    enable_extension.sql
    scripts/install_boost.sh
    scripts/runtime_packages.sh
    scripts/rdkit_labels.sh
)

manifest=$(
    {
        for rel in "${image_files[@]}"; do
            path="${repo_root}/${rel}"
            if [ -f "$path" ]; then
                printf 'file %s %s\n' "$rel" "$(sha256sum < "$path" | cut -d' ' -f1)"
            fi
        done
        printf 'rdkit %s\n' "$rdkit"
        printf 'debian %s\n' "$debian"
        printf 'base_digest %s\n' "$base_digest"
        printf 'core_digest %s\n' "$core_digest"
    } | LC_ALL=C sort
)

printf '%s\n' "$manifest" | sha256sum | cut -c1-12
