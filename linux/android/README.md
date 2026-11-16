# NFS 4 na Androida (APK)

APK składany bez Gradle: SDL2 2.30.12 (`SDLActivity`) + ta sama warstwa SDL2/GLES co na Linuksie
(`plat_linux.c`, `gpu_gles.c`, `input_sdl.c`), biblioteka `libmain.so` dla `arm64-v8a` i `x86_64`.

```bash
android/build.sh                      # tworzy ../android-build/nfs4.apk (debug-podpisany)
adb install -r ../android-build/nfs4.apk
P=/sdcard/Android/data/io.github.noneawe.nfs4/files
adb shell mkdir -p $P && adb push work/game $P/
adb shell chmod -R a+rwX $P/game      # pliki wgrane przez adb są własnością `shell`
adb shell am start -n io.github.noneawe.nfs4/org.libsdl.app.SDLActivity
```

Ikona aplikacji jest wyciągana z zasobów `work/game/nfs4.exe` (`android/extract_ico.py`, jak ikona w Windows) podczas budowania;
bez tego pliku APK dostaje domyślną ikonę Androida. Ikony nie ma w repozytorium, bo to zasób gry (`NFS4_EXE=` wskazuje inny `nfs4.exe`).

Dane gry czytane są z `/sdcard/Android/data/io.github.noneawe.nfs4/files/game`, zapisy trafiają do `.../files/save`.
Aplikacja nie wymaga uprawnień. Dane PC (`DATA`) przygotuj tak samo jak dla Linuksa (`./setup.sh`, katalog `work/game`).
Widescreen: na Androidzie włączony automatycznie (proporcje ekranu, do 16:9); menu zostaje w 4:3 z czarnymi pasami.

## Sterowanie dotykowe

- **Menu:** przesuwanie palcem porusza kursorem gry jak touchpad (kursor nie skacze pod palec), krótkie stuknięcie klika.
- **Wyścig:** przyciski na ekranie, wielodotyk: skręt w lewo/prawo (lewy dolny róg), gaz i hamulec (prawy dolny róg),
  `HR` hamulec ręczny, `C` kamera, `II` pauza. Przycisk Wstecz Androida działa jak Esc.
- Pad Bluetooth/USB i klawiatura działają jak na Linuksie (SDL GameController).

Stan: menu, wejście z pada/klawiatury i dotyk w menu sprawdzone w emulatorze x86_64; aplikacja uruchomiona na telefonie ARM64
(Adreno 810, menu 30 FPS w GLES). Przyciski w wyścigu i pełny wyścig na telefonie czekają na test ręczny.
Układ przycisków jest stałą tablicą `buttons[]` w `input_touch.c`.
