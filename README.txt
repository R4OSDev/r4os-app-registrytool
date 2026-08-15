REG.R4X
=======

REG.R4X ist das Terminal-Werkzeug fuer Registry-Operationen und Registry-
Abnahmen.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\RegistryTool
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\RegistryTool\zig-out\REG.R4X

Contract:
- R4XStart-Entry: `reg_main`
- App-Klasse: `console`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\REG.R4X`

