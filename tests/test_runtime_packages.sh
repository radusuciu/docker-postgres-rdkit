#!/usr/bin/env bash
# Exercises scripts/runtime_packages.sh inside throwaway Debian containers.
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

run_case() {
    docker run --rm \
        -v "${REPO_ROOT}/scripts:/scripts:ro" \
        debian:bookworm-slim \
        bash -c "$1" 2>&1
}

echo "--- happy path: a packaged .so resolves to packaged dependencies ---"
out=$(run_case '
    set -e
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends libfreetype6 >/dev/null 2>&1
    /scripts/runtime_packages.sh /usr/lib/x86_64-linux-gnu/libfreetype.so.6 /tmp/pkgs.txt
    echo "---LIST---"
    cat /tmp/pkgs.txt
'); rc=$?
assert_eq "0" "$rc" "packaged .so exits 0"
list=$(printf '%s' "$out" | sed -n '/---LIST---/,$p' | tail -n +2)
# libfreetype.so.6 on debian:bookworm-slim links libz.so.1, libpng16.so.16,
# libbrotlidec.so.1, libc.so.6, libm.so.6 and libbrotlicommon.so.1 (per ldd,
# confirmed live). ldd resolves libpng16.so.16/libbrotlidec.so.1/
# libbrotlicommon.so.1 only via a merged-usr canonical path that dpkg's own
# database does not index them under literally, while libc.so.6/libm.so.6/
# libz.so.1 are indexed only under the literal (non-canonicalized) path --
# a membership-only assertion here previously let a version of the script
# that silently dropped libpng16-16 and libbrotli1 pass. Assert the complete
# set instead. Each name below was independently confirmed installable by
# that exact name (apt-cache show + apt-get install) outside this test.
expected=$'libbrotli1\nlibc6\nlibpng16-16\nzlib1g'
assert_eq "$expected" "$(printf '%s' "$list" | sort)" "derived list is exactly the complete package set"
# dpkg -S prints "pkg:arch: /path"; only the bare package name may reach apt-get.
assert_eq "" "$(printf '%s' "$list" | grep ':' || true)" "no arch qualifiers or colons in the list"
assert_eq "" "$(printf '%s' "$list" | grep '/' || true)" "no file paths in the list"

echo "--- guard: an object linking /opt must fail ---"
out=$(run_case '
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends gcc libc6-dev >/dev/null 2>&1
    mkdir -p /opt/fake/lib
    echo "int helper(void){return 1;}" > /tmp/h.c
    gcc -shared -fPIC -o /opt/fake/lib/libhelper.so /tmp/h.c
    echo "int helper(void); int f(void){return helper();}" > /tmp/m.c
    gcc -shared -fPIC -o /tmp/mod.so /tmp/m.c -L/opt/fake/lib -lhelper -Wl,-rpath,/opt/fake/lib
    /scripts/runtime_packages.sh /tmp/mod.so /tmp/pkgs.txt
    script_rc=$?
    if [ -e /tmp/pkgs.txt ]; then echo "OUTPUT_FILE: present"; else echo "OUTPUT_FILE: absent"; fi
    exit "$script_rc"
'); rc=$?
assert_eq "1" "$rc" "object linking /opt exits 1"
assert_contains "$out" "/opt/fake/lib/libhelper.so" "error names the offending library"
assert_contains "$out" "OUTPUT_FILE: absent" "output file was never created"

echo "--- guard: an unresolved library must fail ---"
out=$(run_case '
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends gcc libc6-dev >/dev/null 2>&1
    mkdir -p /tmp/gone
    echo "int helper(void){return 1;}" > /tmp/h.c
    gcc -shared -fPIC -o /tmp/gone/libhelper.so /tmp/h.c
    echo "int helper(void); int f(void){return helper();}" > /tmp/m.c
    gcc -shared -fPIC -o /tmp/mod.so /tmp/m.c -L/tmp/gone -lhelper
    rm -rf /tmp/gone
    /scripts/runtime_packages.sh /tmp/mod.so /tmp/pkgs.txt
    script_rc=$?
    if [ -e /tmp/pkgs.txt ]; then echo "OUTPUT_FILE: present"; else echo "OUTPUT_FILE: absent"; fi
    exit "$script_rc"
'); rc=$?
assert_eq "1" "$rc" "unresolved library exits 1"
assert_contains "$out" "not found" "error reports the unresolved library"
assert_contains "$out" "OUTPUT_FILE: absent" "output file was never created"

finish
