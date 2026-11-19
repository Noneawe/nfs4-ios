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

Zmienne środowiskowe (`NFS4_FPS`, `NFS4_WIDE`, `NFS4_BENCH`...) ustawia plik `files/env.txt` (linie `KLUCZ=WARTOŚĆ`, `#` komentarz).

## Sterowanie

- **Menu:** przesuwanie palcem porusza kursorem gry jak touchpad (kursor nie skacze pod palec), krótkie stuknięcie klika.
- **Wyścig:** bez nakładki dotykowej, sterowanie padem (Bluetooth/USB, SDL GameController) lub klawiaturą.
  Pad: RT gaz, LT hamulec, lewa gałka kierownica, A hamulec ręczny, Y kamera, LB/RB biegi, Start pauza. Przycisk Wstecz Androida działa jak Esc.
- **Licznik klatek:** `NFS4_SHOW_FPS=1` w `env.txt`, w grze L3+R3 na padzie.

Stan: menu, wejście z pada/klawiatury i dotyk w menu sprawdzone w emulatorze x86_64; aplikacja uruchomiona na telefonie ARM64
(Adreno 810, menu 30 FPS w GLES). Pełny wyścig z padem na telefonie czeka na test ręczny.
