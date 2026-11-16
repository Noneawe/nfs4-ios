#!/usr/bin/env bash
# Pełny build APK: SDL2 (CMake/NDK) -> libmain.so (x86_64 + arm64-v8a) -> APK. Wymaga Android SDK + NDK 28, cmake, ninja, JDK.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
B=${1:-$here/../../android-build}; mkdir -p "$B/dl"; B=$(cd "$B" && pwd)
NDK=${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/28.2.13676358}
CM=${CMAKE:-$HOME/Android/Sdk/cmake/3.22.1/bin/cmake}
[[ -d $B/dl/SDL2-2.30.12 ]] || { curl -sL https://github.com/libsdl-org/SDL/releases/download/release-2.30.12/SDL2-2.30.12.tar.gz | tar -xz -C "$B/dl"; }
for abi in x86_64 arm64-v8a; do
    [[ -f $B/sdl-$abi/libSDL2.so ]] || { "$CM" -S "$B/dl/SDL2-2.30.12" -B "$B/sdl-$abi" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=$abi -DANDROID_PLATFORM=android-24 \
        -DCMAKE_BUILD_TYPE=Release -DSDL_STATIC=OFF -DSDL_TEST=OFF >/dev/null; "$CM" --build "$B/sdl-$abi" >/dev/null; }
    "$here/build-lib.sh" $abi "$B/dl/SDL2-2.30.12" "$B/sdl-$abi" "$B/out/$abi/libmain.so"
done
"$here/build-apk.sh" "$B" "$B/nfs4.apk"
