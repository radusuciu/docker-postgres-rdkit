#!/usr/bin/env bash
# Install the Debian Boost -dev family that satisfies RDKit's declared floor.
#
# RDKit declares its minimum Boost in RDK_BOOST_VERSION in its CMakeLists.txt,
# and that floor has moved inside a patch series before (2025_03_1 -> 2025_03_6),
# so it is read from the cloned source rather than tabulated.
#
# Debian ships several Boost families side by side. We pick the LOWEST family
# that satisfies the floor: that is closest to what RDKit was tested against,
# and the newest family in a suite is the one most likely to have removed an
# API RDKit still uses.
#
# Prints the installed dotted Boost version (e.g. 1.81.0) on stdout.
# Progress and errors go to stderr.
set -euo pipefail

source_dir="${1:?usage: install_boost.sh <rdkit-source-dir>}"
cmakelists="${source_dir}/CMakeLists.txt"

[ -f "$cmakelists" ] || {
    echo "ERROR: ${cmakelists} not found" >&2
    exit 1
}

floor=$(sed -n 's/^set(RDK_BOOST_VERSION *"\([0-9.]*\)").*/\1/p' "$cmakelists")
[ -n "$floor" ] || {
    echo "ERROR: could not read RDK_BOOST_VERSION from ${cmakelists}" >&2
    exit 1
}
echo "RDKit declares Boost floor ${floor}" >&2

available=$(apt-cache search --names-only '^libboost[0-9.]+-dev$' || true)
families=$(printf '%s\n' "$available" \
    | sed -n 's/^libboost\([0-9.]*\)-dev.*/\1/p' \
    | sort -V)

family=""
for f in $families; do
    # Debian family numbers are two components (1.81); the floor is three
    # (1.81.0). Compare on the family's .0 patch release.
    if dpkg --compare-versions "${f}.0" ge "$floor"; then
        family="$f"
        break
    fi
done

if [ -z "$family" ]; then
    {
        echo "ERROR: RDKit requires Boost >= ${floor}; this Debian suite offers only:"
        if [ -n "$available" ]; then
            printf '%s\n' "$available" | awk '{print "  " $1}'
        else
            echo "  (no libboost<X>-dev packages found; is the apt cache populated?)"
        fi
        echo "Fix: raise 'debian' in versions.json to a newer suite (trixie ships 1.83 and 1.88)."
    } >&2
    exit 1
fi

echo "Selected Boost family ${family} (floor ${floor})" >&2

# The versioned families Conflicts: one another, so exactly one is installed and
# its headers land in /usr/include/boost with its CMake config in
# /usr/lib/<triplet>/cmake/Boost-<X>/. No BOOST_ROOT or Boost_DIR hint needed.
#
# 'system' is header-only since 1.69 but RDKit 2024_09 still lists it as a
# find_package component.
apt-get install -y --no-install-recommends \
    "libboost${family}-dev" \
    "libboost-serialization${family}-dev" \
    "libboost-iostreams${family}-dev" \
    "libboost-system${family}-dev" >&2

# Report the exact installed version for the org.boost.version label (R9).
boost_int=$(sed -n 's/^#define BOOST_VERSION \([0-9]*\)$/\1/p' /usr/include/boost/version.hpp)
[ -n "$boost_int" ] || {
    echo "ERROR: could not read BOOST_VERSION from /usr/include/boost/version.hpp" >&2
    exit 1
}
printf '%d.%d.%d\n' \
    "$((boost_int / 100000))" \
    "$((boost_int / 100 % 1000))" \
    "$((boost_int % 100))"
