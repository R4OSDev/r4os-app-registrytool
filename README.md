# REG.R4X

`REG.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.6`
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
