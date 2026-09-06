#!/usr/bin/env bash
# Extract the operationally significant RDKit version stamps from cloned source.
#
# The pickle version is the real client/server compatibility contract: a client
# older than the cartridge depickles a newer format with only a warning
# (MolPickler.cpp), producing corrupt results rather than an error. Stamping it
# onto the image makes the check mechanical.
set -euo pipefail

source_dir="${1:?usage: rdkit_labels.sh <rdkit-source-dir>}"
pickler="${source_dir}/Code/GraphMol/MolPickler.cpp"
control="${source_dir}/Code/PgSQL/rdkit/rdkit.control"

[ -d "$source_dir" ] || { echo "ERROR: source directory not found: ${source_dir}" >&2; exit 1; }
[ -f "$pickler" ] || { echo "ERROR: ${pickler} not found" >&2; exit 1; }
[ -f "$control" ] || { echo "ERROR: ${control} not found" >&2; exit 1; }

# Extract version components with validation: exactly one match per constant
# Count lines for major version
major_count=$(sed -n 's/^const int32_t MolPickler::versionMajor *= *\([0-9]*\).*/\1/p' "$pickler" | wc -l)
if [ "$major_count" -eq 0 ]; then
    echo "ERROR: could not extract versionMajor from the RDKit source" >&2
    exit 1
elif [ "$major_count" -gt 1 ]; then
    echo "ERROR: found multiple versionMajor definitions in the RDKit source" >&2
    exit 1
fi
major=$(sed -n 's/^const int32_t MolPickler::versionMajor *= *\([0-9]*\).*/\1/p' "$pickler")

# Count lines for minor version
minor_count=$(sed -n 's/^const int32_t MolPickler::versionMinor *= *\([0-9]*\).*/\1/p' "$pickler" | wc -l)
if [ "$minor_count" -eq 0 ]; then
    echo "ERROR: could not extract versionMinor from the RDKit source" >&2
    exit 1
elif [ "$minor_count" -gt 1 ]; then
    echo "ERROR: found multiple versionMinor definitions in the RDKit source" >&2
    exit 1
fi
minor=$(sed -n 's/^const int32_t MolPickler::versionMinor *= *\([0-9]*\).*/\1/p' "$pickler")

# Count lines for patch version
patch_count=$(sed -n 's/^const int32_t MolPickler::versionPatch *= *\([0-9]*\).*/\1/p' "$pickler" | wc -l)
if [ "$patch_count" -eq 0 ]; then
    echo "ERROR: could not extract versionPatch from the RDKit source" >&2
    exit 1
elif [ "$patch_count" -gt 1 ]; then
    echo "ERROR: found multiple versionPatch definitions in the RDKit source" >&2
    exit 1
fi
patch=$(sed -n 's/^const int32_t MolPickler::versionPatch *= *\([0-9]*\).*/\1/p' "$pickler")

# Count lines for cartridge version
cartridge_count=$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$control" | wc -l)
if [ "$cartridge_count" -eq 0 ]; then
    echo "ERROR: could not extract cartridge version from the RDKit source" >&2
    exit 1
elif [ "$cartridge_count" -gt 1 ]; then
    echo "ERROR: found multiple default_version definitions in the RDKit source" >&2
    exit 1
fi
cartridge=$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$control")

echo "rdkit_pickle_version=${major}.${minor}.${patch}"
echo "rdkit_cartridge_version=${cartridge}"

