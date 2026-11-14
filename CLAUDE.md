# AIMeter (fork di ClaudeUsageBar)

App menu bar macOS, tutto in `app/ClaudeUsageBar.swift`. Storia, decisioni e
dettagli tecnici di ogni build: `ROADMAP.md` (leggerla prima di cambiare qualcosa).

## Verifica
- `cd app && ./build-local.sh --install` (compila, firma, installa, lancia;
  se non riparte: `open -a /Applications/AIMeter.app`).
- Poi: CPU con `top -pid $(pgrep -x AIMeter)` e contenuto di
  `aimeter-snapshot.md` (cartella scelta nei Settings dell'app).
- Contano solo gli errori di `swiftc` (lo script usa l'SDK 26.5): le
  diagnostiche dell'editor su `@State` / `@main` sono rumore.
- Su macOS non esiste `timeout`; per i profili CPU usare `/usr/bin/sample`
  (il `sample` nel PATH è un omonimo Python).

## Repo pubblico
- `origin` è pubblico: mai importi reali, UUID delle org, email o percorsi
  personali in codice, ROADMAP o messaggi di commit.
- Prima di ogni push scansiona il diff per quei dati; pusha solo su
  richiesta esplicita.

## Snapshot
- `aimeter-snapshot.md` è un contratto con chi lo legge: se cambia la forma
  delle righe, alza `Format version` in `exportText()` e dillo all'utente.
