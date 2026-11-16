#!/usr/bin/env bash
# Składa APK bez Gradle. Użycie: build-apk.sh <katalog android-build z out/, dl/SDL2-*, sdl-<abi>> <plik apk>
set -euo pipefail
B=$(cd "$1" && pwd) apk=$(realpath -m "$2")
here=$(cd -- "$(dirname -- "$0")" && pwd)
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
bt=$sdk/build-tools/36.0.0 jar=$sdk/platforms/android-34/android.jar
sdl=$(echo "$B"/dl/SDL2-*)
w=$B/apk; rm -rf "$w"; mkdir -p "$w/classes" "$w/lib"
javac -nowarn -source 11 -target 11 -cp "$jar" -d "$w/classes" "$sdl"/android-project/app/src/main/java/org/libsdl/app/*.java 2>&1 | grep -v -E '^(Note|warning)' || true
"$bt/d8" --min-api 24 --lib "$jar" --output "$w" $(find "$w/classes" -name '*.class')
"$bt/aapt2" link -I "$jar" --manifest "$here/AndroidManifest.xml" --min-sdk-version 24 --target-sdk-version 34 -o "$w/base.apk"
for abi in x86_64 arm64-v8a; do
    mkdir -p "$w/lib/$abi"; cp "$B/out/$abi/libmain.so" "$B/sdl-$abi/libSDL2.so" "$w/lib/$abi/"
done
(cd "$w" && cp base.apk unsigned.apk && zip -q -D unsigned.apk classes.dex && zip -q -r -D -0 unsigned.apk lib)
"$bt/zipalign" -f -P 16 4 "$w/unsigned.apk" "$w/aligned.apk"
ks=$B/debug.keystore
[[ -f $ks ]] || keytool -genkeypair -keystore "$ks" -storepass android -keypass android -alias debug -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=debug' >/dev/null 2>&1
"$bt/apksigner" sign --ks "$ks" --ks-pass pass:android --key-pass pass:android --out "$apk" "$w/aligned.apk"
"$bt/apksigner" verify "$apk" && ls -l "$apk"
