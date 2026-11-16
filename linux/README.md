# Need for Speed 4 na Linuksie

Paczka buduje natywny host ELF dla pecetowego NFS 4 High Stakes / Road Challenge. Używa rekompilacji i warstwy Glide z projektu [nfs4-ios](https://github.com/avoseed/nfs4-ios), backendu OpenGL ES 3.0/EGL oraz SDL2. Okno startowe ma 640×480, a limit to 30 FPS. Obsługuje kontrolery SDL2. Wersja x86‑64 przeszła test wyścigu użytkownika; wersja ARM64/R36S wymaga jeszcze kompilacji i testu sprzętowego.

## Przygotowanie

Na Debianie lub Ubuntu zainstaluj pakiety. Na wydaniach z nazwą `7zip` możesz jej użyć zamiast `p7zip-full`.

```bash
sudo apt install build-essential pkg-config libsdl2-dev libgles2-mesa-dev libegl1-mesa-dev python3-venv curl p7zip-full
```

Skopiuj katalog `DATA` z pecetowej gry do dowolnego katalogu. Skopiuj też `SAVEDATA`, jeśli jest dostępny. Następnie rozpakuj tę paczkę i uruchom poniższe polecenia z jej katalogu.

```bash
./setup.sh "/ścieżka/do/NFS4"
./run.sh
```

`setup.sh` pobiera sprawdzoną wersję łatki VEG i kod źródłowy z przypiętej rewizji. Weryfikuje SHA‑256, nakłada łatkę na kopię danych w `work/game/`, generuje C i buduje plik `work/nfs4host`. Pierwsza kompilacja może potrwać kilka minut. Jeśli masz już archiwum VEG, wskaż je jako drugi argument.

```bash
./setup.sh "/ścieżka/do/NFS4" "/ścieżka/do/nfs4_modern_patch.7z"
```

Kopie danych i kompilacja powstają lokalnie. Paczka zawiera skrypty oraz źródło warstwy linuksowej. Zapisy trafiają do `work/save/`, a komunikaty z gry do `work/nfs4host.log`. Do pierwszej próby użyj klawiatury. Jeśli menu się otworzy, spróbuj uruchomić pojedynczy wyścig i sprawdź obraz, sterowanie oraz dźwięk.

## Test samego hosta

```bash
./setup.sh --build-only
./run.sh --self-test
./run.sh --controller-self-test
./run.sh --profile-self-test
```

Self-test sprawdza inicjalizację SDL2 i wyświetlenie testowej klatki na wirtualnym ekranie.

## Akceleracja 3D

`./run.sh` domyślnie używa backendu GLES. Gdy nie można utworzyć kontekstu lub skompilować shaderów, gra wraca do renderera programowego. W `work/nfs4host.log` sprawdź `GLES vendor`, `renderer`, `version` oraz `glide: window ... GPU renderer`. Nazwy `llvmpipe` i `softpipe` oznaczają renderowanie przez CPU, nawet gdy aktywna jest ścieżka GLES.

```bash
./run.sh --gpu-self-test
NFS4_SOFTWARE=1 ./run.sh
```

Test GLES sprawdza rzeczywiste shadery, tekstury, orientację obrazu, głębię, scissor, odrzucanie alfa i zmianę rozdzielczości. W środowisku bez ekranu można użyć `SDL_VIDEODRIVER=offscreen ./run.sh --gpu-self-test`. Nie zastępuje to sprawdzenia sterownika GPU na pulpicie i ukończenia wyścigu.

Bufor głębi ma 16 bitów, zgodnie z możliwościami deklarowanymi przez Glide. Shader zachowuje współrzędne ekranu i głębię z gry; perspektywę tekstur oblicza osobno. Eliminuje to zbędne przeliczanie głębi przez `w`, które wraz z wcześniejszym buforem 24-bitowym powodowało czarne paski pod światłami `projected`. Test GLES obejmuje nakładanie powierzchni o głębiach różniących się o mniej niż krok Glide oraz perspektywę tekstur.

Projekcja tekstur zachowuje znak `q` i odrzuca próbki za płaszczyzną projektora. Maski z pojedynczym poziomem szczegółowości nie otrzymują automatycznych mipmap. `patch-runtime.py`, uruchamiany przez `build-native.sh`, poprawia obsługę takich tekstur i ich kluczy pamięci podręcznej w przypiętej warstwie Glide. Sprawdza oczekiwany kod przed zmianą i można go uruchamiać wielokrotnie. Test GLES sprawdza również przejście projekcji przez `q=0` i ciemne krawędzie maski przy pomniejszeniu.

Na platformach EGL renderer tworzy kontekst z osobną powierzchnią pbuffer na wyświetlaczu SDL. Wątek gry nie zajmuje powierzchni okna prezentowanego przez SDL. To pozwala uniknąć drugiego okna na urządzeniach KMS/DRM. Na pulpicie bez bieżącego wyświetlacza EGL pozostaje zapasowa ścieżka z ukrytym oknem SDL. Test GLES wykonuje rysowanie na osobnym wątku.

Pierwsza wersja backendu odczytuje gotowe klatki z GPU do SDL2. To może ograniczyć wydajność przy wysokich rozdzielczościach, szczególnie na R36S. Jeśli pomiary wykażą takie ograniczenie, kolejnym krokiem będzie prezentacja przez współdzielone tekstury bez odczytu do RAM.

Poprzedni build zachowano w `work/nfs4host-software`, a jego log w `work/nfs4host-software.log`. Przebudowa przez `./setup.sh --build-only` zachowuje istniejące dane gry i zapisy.

## ARM64 / R36S / PortMaster

Działający punkt odniesienia x86‑64, źródła oraz sumy SHA‑256 są w `work/x86-reference/`.
Szczegóły budowy, zgodności glibc, instalacji, sterowania i testów sprzętowych:
[portmaster/README.md](portmaster/README.md).

```bash
./build-arm64.sh
```

Wymaga kompilatora ARM64 z bibliotekami SDL2/GLES/EGL albo działającego Dockera.
Po kompilacji i testach QEMU tworzy `work/nfs4-r36s-test.zip`, sprawdzając, że
pakowana binarka jest wykonywalnym ELF ARM64. Nie pakuje danych gry ani zapisów.

Do przeniesienia projektu na komputer z Dockerem można przygotować zestaw
źródeł z wygenerowanym C:

```bash
python3 package-portmaster.py --source-kit
tar -xzf work/nfs4-r36s-build-kit.tar.gz
cd nfs4-r36s
./build-arm64.sh
```

`NFS4_SOURCE_ONLY=1 ./setup.sh --build-only` przygotowuje `work/source` od zera,
jeśli katalog jeszcze nie istnieje. Obiekty różnych architektur są rozdzielone;
ARM64 domyślnie używa `-O2`, a x86‑64 zachowuje `-O0` dla wygenerowanego kodu.
Test pakowania: `python3 test_portmaster.py`.

Pad obsługiwany jest bez gptokeyb. Domyślnie emuluje klawiaturę; analogowe osie
są też dostępne jako `Touch Wheel` w ustawieniach gry. Martwą strefę ustawia
`NFS4_DEADZONE` (domyślnie 8000), limit klatek `NFS4_FPS` (domyślnie 30).
Mapowanie przycisków i tryb analogowego kierowania opisano w instrukcji PortMaster.
