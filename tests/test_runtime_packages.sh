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
assert_contains "$out" "libc6" "derived list contains libc6"
assert_contains "$out" "zlib1g" "derived list contains zlib1g"
# dpkg -S prints "pkg:arch: /path"; only the bare package name may reach apt-get.
list=$(printf '%s' "$out" | sed -n '/---LIST---/,$p' | tail -n +2)
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
'); rc=$?
assert_eq "1" "$rc" "object linking /opt exits 1"
assert_contains "$out" "/opt/fake/lib/libhelper.so" "error names the offending library"

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
'); rc=$?
assert_eq "1" "$rc" "unresolved library exits 1"
assert_contains "$out" "not found" "error reports the unresolved library"

finish
