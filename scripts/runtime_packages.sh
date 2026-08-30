#!/usr/bin/env bash
# Derive the Debian packages that must be installed in the runtime image so
# that <shared-object> loads.
#
# The list varies by RDKit release (2024_09 links boost-system, 2025_x does not)
# and by suite (package names carry the Boost SONAME), so it is derived rather
# than hand-maintained. Packages already in the base image are no-ops for
# apt-get install, so the list needs no filtering.
set -euo pipefail

so="${1:?usage: runtime_packages.sh <shared-object> <output-file>}"
out="${2:?usage: runtime_packages.sh <shared-object> <output-file>}"

[ -f "$so" ] || { echo "ERROR: ${so} not found" >&2; exit 1; }

ldd_out=$(ldd "$so" 2>&1 || true)

if printf '%s\n' "$ldd_out" | grep -q 'not found'; then
    {
        echo "ERROR: ${so} has unresolved shared libraries:"
        printf '%s\n' "$ldd_out" | grep 'not found' | sed 's/^/  /'
    } >&2
    exit 1
fi

libs=$(printf '%s\n' "$ldd_out" | awk '/=> \//{print $3}')

# The runtime stage copies only rdkit.so and the extension SQL; anything the
# object pulls from /opt (an in-tree RDKit build, a hand-installed cmake) would
# be missing at LOAD time. Fail here rather than at CREATE EXTENSION.
offenders=$(printf '%s\n' "$libs" | grep '^/opt/' || true)
if [ -n "$offenders" ]; then
    {
        echo "ERROR: ${so} links libraries outside the package system:"
        printf '%s\n' "$offenders" | sed 's/^/  /'
        echo "The runtime stage does not copy these. Check RDK_PGSQL_STATIC=ON."
    } >&2
    exit 1
fi

# dpkg -S prints "pkg:arch: /path" (or "pkg: /path"); take the package name and
# drop any :arch qualifier. dpkg -S exits non-zero for unowned paths, which is
# tolerated -- the /opt guard above already covers the case that matters.
printf '%s\n' "$libs" \
    | xargs -r dpkg -S 2>/dev/null \
    | cut -d: -f1 \
    | tr -d ' ' \
    | sort -u \
    > "$out" || true

[ -s "$out" ] || { echo "ERROR: derived an empty runtime package list for ${so}" >&2; exit 1; }

echo "Runtime packages derived from ${so}:" >&2
sed 's/^/  /' "$out" >&2
