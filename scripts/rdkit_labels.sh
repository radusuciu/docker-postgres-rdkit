#!/usr/bin/env bash
# Extract the operationally significant RDKit version stamps from cloned source.
#
# The pickle version is the real client/server compatibility contract: a client
# older than the cartridge depickles a newer format with only a warning
# (MolPickler.cpp), producing corrupt results rather than an error. Stamping it
# onto the image makes the check mechanical (SPEC R9, section 3.2).
set -euo pipefail

source_dir="${1:?usage: rdkit_labels.sh <rdkit-source-dir>}"
pickler="${source_dir}/Code/GraphMol/MolPickler.cpp"
control="${source_dir}/Code/PgSQL/rdkit/rdkit.control"

[ -f "$pickler" ] || { echo "ERROR: ${pickler} not found" >&2; exit 1; }
[ -f "$control" ] || { echo "ERROR: ${control} not found" >&2; exit 1; }

major=$(sed -n 's/.*MolPickler::versionMajor *= *\([0-9]*\).*/\1/p' "$pickler")
minor=$(sed -n 's/.*MolPickler::versionMinor *= *\([0-9]*\).*/\1/p' "$pickler")
patch=$(sed -n 's/.*MolPickler::versionPatch *= *\([0-9]*\).*/\1/p' "$pickler")
cartridge=$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$control")

for name in major minor patch cartridge; do
    if [ -z "${!name}" ]; then
        echo "ERROR: could not extract ${name} from the RDKit source" >&2
        exit 1
    fi
done

echo "rdkit_pickle_version=${major}.${minor}.${patch}"
echo "rdkit_cartridge_version=${cartridge}"
