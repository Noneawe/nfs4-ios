# NFS4 — lokalny port ARM64 / R36S

Ta wersja jest przygotowana do testów na fizycznym R36S. Nie została jeszcze
zweryfikowana na konsoli. Dzięki avoseed za rekompilator i wspólny runtime
[nfs4-ios](https://github.com/avoseed/nfs4-ios), na których oparto port.

## Budowa

Na komputerze x86-64 z działającym Dockerem:

```bash
./build-arm64.sh
```

Skrypt buduje obraz Ubuntu 20.04 z kompilatorem krzyżowym ARM64 i bibliotekami
SDL2/GLES/EGL dla ARM64, a następnie kompiluje kod z optymalizacją `-O2`. Nie używa
`fast-math`. Sprawdza nagłówek ELF, uruchamia test hosta i profilu przez QEMU
oraz tworzy `work/nfs4-r36s-test.zip`. Budowa wymaga internetu do pobrania
obrazu i pakietów. Późniejsze kompilacje w kontenerze nie używają sieci.

Można też użyć zainstalowanego `aarch64-linux-gnu-gcc` z odpowiednim sysrootem
SDL2/GLES. `PKG_CONFIG_LIBDIR` musi wskazywać biblioteki docelowe, a nie x86-64.
`AARCH64_CC`, `PKG_CONFIG`, `SDL_CFLAGS`, `SDL_LIBS`, `GLES_CFLAGS` i `GLES_LIBS`
pozwalają wskazać własny toolchain. Obiekty różnych architektur są rozdzielone.

Domyślny kontener używa glibc 2.31. Na urządzeniu sprawdź `ldd --version`.
Starszy firmware wymaga starszego zgodnego sysroota; samo ARM64 nie zapewnia
zgodności bibliotek. Zasady: [środowiska PortMaster](https://portmaster.games/contribute/porting/build-environments/).

## Instalacja

1. Rozpakuj `work/nfs4-r36s-test.zip` do katalogu `ports` na karcie konsoli.
2. Skopiuj **zawartość** przygotowanego na PC `work/game/` do `ports/nfs4/game/`.
   Ścieżka końcowa to `ports/nfs4/game/data/text/mam.dat`. Użyj przygotowanej
   kopii z małymi literami i łatką VEG, nie surowego katalogu `DATA`.
3. Uruchom `Need for Speed 4` w menu Ports.

Paczka nie kopiuje zapisów z PC. Zapisy konsoli trafiają do `nfs4/save/`,
a log do `nfs4/log.txt`. Katalog `game/` zawiera oddzielną kopię danych.

## Profil R36S

`nfs4/profile.sh` wybiera 640×480, pełny ekran, limit 30 FPS i oryginalne
tekstury. Rozdzielczość jest wybierana przez konfigurację silnika, a nie przez
obcięcie obrazu. Odczyt konfiguracji nie zmienia źródłowych plików PC.
`NFS4_ORIGINAL_TEXTURES=1` wyłącza również kosztowne powiększanie tekstur aut.

Możesz zmienić `NFS4_FPS` (0–120; 0 oznacza brak limitu) i `NFS4_DEADZONE`
(0–30000; domyślnie 8000). Nie ma jeszcze pomiaru wydajności na R36S.
Na R36S (Mali-G31) obraz idzie prosto z GLES do okna SDL/KMS (`NFS4_DIRECT=1`, domyślnie
w profilu), bez odczytu klatki do RAM. Zamiana buforów dla klatki N odbywa się na początku
klatki N+1, więc GPU liczy równolegle z logiką gry (opóźnienie jednej klatki). W wyścigu daje to
ok. 20 FPS zamiast ok. 15 FPS przy odczycie przez PBO (`NFS4_DIRECT=0`). Odczyt PBO jest nadal
używany na pozostałych platformach.

W trybie `NFS4_DIRECT=0` GLES używa osobnego kontekstu EGL z powierzchnią pbuffer. Okno SDL pozostaje
przeznaczone do prezentacji, bez jednoczesnego wiązania jego powierzchni przez
wątek gry. Rzeczywista obsługa KMS/DRM i sterownika Mali wymaga testu na R36S.

## Sterowanie

Mapowanie SDL pobierane jest przez `get_controls` z PortMaster.

| Kontrolka | Menu | Wyścig — wysyłany klawisz |
|---|---|---|
| D-pad / lewy analog | Strzałki | Lewo/prawo; D-pad również góra/dół |
| A | Enter | Góra — gaz przy domyślnej konfiguracji |
| B | Escape | Dół — hamulec przy domyślnej konfiguracji |
| X | Kliknięcie myszy | Spacja |
| Y | — | C |
| L1 / R1 | — | A / Z |
| L2 / R2 | — | Dół / góra |
| Prawy analog | Ruch kursora | — |
| Start | Enter | Escape — pauza |
| Select | Escape | Tab |
| Select + Start | Wyjście z procesu | Wyjście z procesu |

Domyślnie pad emuluje klawiaturę, więc nie wymaga ustawiania kierownicy w grze.
Równolegle dostępne są analogowe osie i osiem przycisków urządzenia DirectInput
`Touch Wheel`. Aby używać analogowego kierowania, ustaw to urządzenie w grze
i dodaj `export NFS4_ANALOG_STEERING=1` do profilu. D-pad nadal działa cyfrowo.

## Test na konsoli

Sprawdź w logu nazwę renderera GLES: powinien to być sterownik Mali/Panfrost,
a nie `llvmpipe` ani `softpipe`. Potem sprawdź menu, auto i trasę, pełny wyścig,
światła nocą, dźwięk, zapis i powrót do menu. Zanotuj FPS z logu.

Przez SSH można wywołać skrypt startowy z `--gpu-self-test` lub `--self-test`.
`--controller-self-test` sprawdza wirtualny kontroler na SDL >= 2.0.14; na
starszym SDL zwraca 77, co oznacza pominięcie testu, nie awarię pada.

## Status

Przed testem sprzętowym jest to paczka deweloperska do lokalnej instalacji.
Nie została zgłoszona ani opublikowana w katalogu PortMaster.
