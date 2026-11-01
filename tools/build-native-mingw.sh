#!/bin/sh
# Builds native/ into native/build from a Linux box: the same two files tools/build-native.ps1 makes with Visual Studio
# (main.dll, the relay that ships, and relay_cli.exe, for the tests only), with mingw-w64's cross compiler instead.
# Same sources, same warning level; the runtime is static, so players still need no Visual C++ redistributable.
#
# This is for whoever has no Windows at hand (a CI runner, a test build from a laptop): a zip built this way is a
# test build. Debian/Ubuntu: apt-get install g++-mingw-w64-x86-64-posix.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$root/native"
out="$src/build"
cxx=${CXX:-x86_64-w64-mingw32-g++}
mkdir -p "$out"

# -municode: relay_cli's entry point is wmain. /MT's equivalent here is -static -static-libgcc -static-libstdc++.
flags="-std=c++20 -O2 -Wall -D_WINSOCK_DEPRECATED_NO_WARNINGS"
libs="-lws2_32 -lbcrypt -lwinmm"
# shellcheck disable=SC2086
"$cxx" $flags -shared -static -static-libgcc -static-libstdc++ "$src/main_dll.cpp" "$src/steam.cpp" \
    -o "$out/main.dll" $libs
# shellcheck disable=SC2086
"$cxx" $flags -municode -static -static-libgcc -static-libstdc++ "$src/relay_cli.cpp" -o "$out/relay_cli.exe" $libs
ls -l "$out/main.dll" "$out/relay_cli.exe"
