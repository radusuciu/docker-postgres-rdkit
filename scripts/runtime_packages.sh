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

# Lines with no resolved path (linux-vdso.so.1, /lib64/ld-linux-x86-64.so.2)
# have no "=> /..." field and are skipped by this filter, not treated as
# unresolved -- they're not owned by any package and load without one.
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

# dpkg -S matches the literal path string recorded in a package's file list at
# packaging time, not the resolved inode. On a merged-usr suite /lib is a
# symlink to /usr/lib, but packages recorded their files under different
# literal prefixes depending on when they were built: some (e.g. libc6,
# zlib1g on bookworm) are indexed under the pre-merge /lib/<triplet> path that
# ldd renders verbatim, while others (e.g. libpng16-16, libbrotli1) are
# indexed only under the canonical /usr/lib/<triplet> path that readlink -f
# produces. Neither the literal ldd path nor its canonicalization matches
# every package on its own, so both are tried and a hit from either counts.
# A miss on both is a hard failure -- the one legitimate miss (/opt) already
# exited at the guard above, so anything still unmapped here is a real gap.
pkgs=""
while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    match=$(dpkg -S "$lib" 2>/dev/null || true)
    if [ -z "$match" ]; then
        canon=$(readlink -f "$lib" 2>/dev/null || true)
        if [ -n "$canon" ] && [ "$canon" != "$lib" ]; then
            match=$(dpkg -S "$canon" 2>/dev/null || true)
        fi
    fi
    if [ -z "$match" ]; then
        echo "ERROR: no installed package owns ${lib} (checked literal and canonicalized path)" >&2
        exit 1
    fi
    pkgs="${pkgs}${match}"$'\n'
done <<LIBS
$libs
LIBS

# dpkg -S prints "pkg:arch: /path" (or "pkg: /path"); take the package name
# and drop any :arch qualifier.
printf '%s' "$pkgs" \
    | cut -d: -f1 \
    | sort -u \
    > "$out"

[ -s "$out" ] || { echo "ERROR: derived an empty runtime package list for ${so}" >&2; exit 1; }

echo "Runtime packages derived from ${so}:" >&2
sed 's/^/  /' "$out" >&2
