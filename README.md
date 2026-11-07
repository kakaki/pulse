# Pulse

Monitor systemu w pasku menu macOS (CPU, GPU, pamięć, dysk, sieć, temperatury, bateria) w stylu Liquid Glass.

- Wymagania: macOS 26, Mac z Apple Silicon
- Pobierz: najnowszy DMG z folderu [`updates/`](updates/) – aplikacja aktualizuje się sama (Sparkle)

## Budowanie

```bash
./build.sh --install     # lokalna kompilacja → /Applications
./release.sh             # podpis Developer ID, notaryzacja, DMG, appcast w updates/
```

Nowa wersja: podnieś `CFBundleShortVersionString` i `CFBundleVersion` w `Info.plist`, uruchom `./release.sh`, potem commit i push folderu `updates/`.
