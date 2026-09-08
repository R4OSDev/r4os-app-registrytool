# REG.R4X

`REG.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.7`
- Image target: `/R4OS/SOFTWARE/TERMINAL/REG.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

`REG SET` and `REG DELETE` use the shared value transaction, preserving other
writers and resident deferred changes. Text import uses the shared bounded
hive builder; its explicit whole-file publication remains separate.

R4S migrations use bounded atomic registry batches when supported and retain
the legacy typed single-value fallback. `REG APITEST` covers stable paged
snapshots, explicit generation restarts, validation aborts, and commit
failure atomicity.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


REG-Lesestatus ab 0.78.63
-----------------------
Nur -3 gilt als fehlender Hive. Leere, zu grosse und anderweitig nicht
lesbare Dateien bleiben als vorhandener ungueltiger Bestand erkennbar.
Die sichtbare Leseausgabe unterscheidet diese Fehler. SET/DELETE verwenden
bereits seit0.78.27 die gemeinsame Registry-API; dieser transaktionale
Schreibpfad bleibt unveraendert. Selbsttests folgen gesondert in0.78.64.


Registry-Selbsttests ab 0.78.64
-----------------------------
REG WRITESELFTEST/APITEST/MIGRATESELFTEST und RegEdit /SELFTEST sind nur fuer
ein ausdruecklich privates Testimage vorgesehen. Die Test-Injection liefert
TEMP/REGTEST.R4S mit R4OS_REGISTRY_SELFTEST=PRIVATE_IMAGE; Slim/Full enthalten
diese Testdeklaration nicht. Das ist eine Diagnosekonvention und kein Rechte-
modell. Ohne Deklaration brechen die schreibenden Tests vor Mutationen ab.
REG SELFTEST bleibt ein reiner Speichertest.

Der gemeinsame SDK-Helfer registry_selftest laesst keine bereits vorhandenen
TMP/BAK-, Original-, Restore- oder Displaced-Dateien als eigenen Bestand zu.
Lesefehler werden nicht als Abwesenheit behandelt. Die Originalsicherung wird
vollstaendig mit dem zuvor gelesenen Inhalt verglichen. Zum Rueckbau entsteht
aus ihr eine gepruefte zweite Stagedatei; nur diese wird durch R4SYS atomar
uebernommen. Erst nach erfolgreichem Ersatz, Bytevergleich und Bereinigung
werden REGSYS.SAV beziehungsweise SYSTEM.REB entfernt und OK ausgegeben.
Fehler behalten die Originalkopie; ein erneuter Test ueberschreibt sie nicht.
REGs temporaere Exportdatei wird ebenfalls nur bei vorheriger Abwesenheit
verwendet. Die acht schon zuvor auf16Byte ausgerichteten Scratch-Slices
bleiben bis zur Freigabe ausgerichtet und werden jetzt rueckwaerts freigegeben.

Begleitkorrektur in Kernel0.1.128: Externer atomarer Dateiersatz invalidiert
betroffene Registry-Cacheansichten auch nach einem moeglicherweise partiellen
I/O-Fehler. Der interne Registry-Commit benutzt denselben Dateipfad mit
explizit internem Abschluss, damit sein eigener Kandidat erhalten bleibt.
So stimmen nach einem Restore Dateibytes und gelesene Cachegeneration wieder
ueberein. Kein neuer ABI-Slot und keine neue Kernel-Diagnoseschnittstelle.

Nachweis: vier gebuendelte Hostfaelle fuer fehlgeschlagene Kopie/Publikation,
bestehende Sicherungen, fehlend/leere Hive, beide App-Abschluesse und alle
acht teilweisen Scratchallokationen. Ein lokaler SMP4-Gast verwendet eine
frisch erzeugte private246-Byte-Hive, prueft beide vorhandenen Selbsttests,
Originalbytes, Cachegeneration1 und Bereinigung. Keine regulaere Installation
wird als Testbestand verwendet. Belege unter Temp/roadmap-078-execution/07864.
