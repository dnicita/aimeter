# AIMeter — fork personale di Daniele (ex ClaudeUsageBar)

Fork di https://github.com/Artzainnn/ClaudeUsageBar (licenza MIT), **rinominato AIMeter**.
Codice: `app/ClaudeUsageBar.swift` (nome file invariato). Upstream di riferimento in `upstream/`.
App: **AIMeter** · bundle id `com.danielenicita.aimeter` · Keychain service idem · LaunchAgent `com.danielenicita.aimeter`. Icona: `AIMeter.icns` (generata da `make_aimeter_icon.swift` → `aimeter-1024.png`).

## Build & install
- `cd app && ./build-local.sh --install` → compila universale, firma con cert stabile, installa in /Applications, lancia.
- Firma stabile: `app/create_signing_cert.sh` (già eseguito una volta; identità keychain "ClaudeUsageBar Local").
- Versioning: `CFBundleVersion` (build number) auto-incrementa ad ogni build; `CFBundleShortVersionString` = `1.3.0-fork` (semver, bump a mano per release). Versione visibile nel footer del popover.

## ✅ Fatto (build 13)
- **Login al boot reale**: era un toggle finto (scriveva solo un bool). Ora LaunchAgent in `~/Library/LaunchAgents/com.claude.usagebar.plist` (SMAppService era inaffidabile con firma ad-hoc).
- **Firma stabile** (cert self-signed): niente più ri-prompt Keychain/Accessibilità ad ogni build.
- **Cookie nel Keychain** (device-only) con migrazione dal plaintext UserDefaults.
- **Rilevamento cookie scaduto** (401/403 → banner rosso + notifica una-tantum).
- **Refresh configurabile** (1/5/10/15/30 min) + "Refresh now".
- **Controlli extra**: banner dati "stale" (>15min), stato reale login item, notifica reset sessione (imminente <10min e avvenuto).
- **Grafica**: icona menu bar = anello di progresso; icona app ritintata teal (vs arancione originale).
- **Rimosso** il link donazioni "Buy Dev a Coffee".
- **BUG popover risolto**: NSPopover, quando il contenuto SwiftUI cresceva dopo l'apertura, espandeva la finestra verso l'alto fuori schermo. Fix: `hosting.sizingOptions = []` + pilotare `popover.contentSize` da AppDelegate (`setPopoverHeight`/`reportPopoverHeight`).
- **Icona dinamica + colori (build 17)**: anello Sessione verde `#30D158` (= colore %), con **4 taglietti** a ore 12/3/6/9, si riempie con l'uso, vira a rosso >75% e **lampeggia** (accelerando) sotto il 25% rimasto. **Punto centrale intermittente** (ritmo diverso) per disservizi: 🟡 minore / 🔴 grave. Palette identità: Sessione=verde, Weekly=azzurro `#5AC8FA`, Sonnet=arancione `#FF9F0A`. Vedi `Palette` enum + `sessionRingColor`/`createRingIcon`/`menuBarTitle`/`reconfigureBlink` in AppDelegate.
- **Countdown reset (#8 DONE)**: "in 1h59m / 2d17h" accanto ai reset nel popover e opzionali in barra. `UsageManager.countdown(to:)`.
- **Valori extra in barra** (Settings → "Show in menu bar"): toggle indipendenti per timer sessione, % e timer weekly, % sonnet + toggle "disabilita blink". Default: solo % sessione.
- **Rebrand AIMeter (build 18, FATTO)**: nome + bundle id + icona "meter". Migrazione automatica del cookie dal vecchio Keychain (`com.claude.usagebar`) e del LaunchAgent; vecchia app + agent rimossi. Vedi `KeychainHelper.legacyService`, `LoginItemManager.migrateFromLegacy()`. Check aggiornamenti disabilitato.
- Backup build 13 in `backups/v1.3.0-fork-build13-20260623/`.
- Nota minore: l'header del popover dice ancora "Claude Usage" (descrittivo, uso nominativo — lasciato apposta).

## ❌ Abbandonato — Monitorare credito API in dollari
Tentato (build 19) con WKWebView embedded + intercettazione XHR della pagina Billing del Console (per evitare di indovinare l'endpoint). **Bloccato**: l'account usa **login Google**, e Google **rifiuta l'OAuth nei browser embedded** ("Si è verificato un errore durante l'accesso"). Niente workaround affidabile (Safari protegge i cookie; spoof UA non basta). Anche il cookie di claude.ai NON autentica il Console (302→login) e claude.ai blocca curl (Cloudflare; l'app però passa). Unica via residua: cattura manuale cookie+endpoint del Console dal browser normale (manuale + da rifare a scadenza). Vista l'utenza quasi solo Max (crediti API ~fermi), **non vale la pena**. Codice rimosso in build 20.

## 📋 Da fare (prossima sessione)

### #10 — Verificare fork "legale"
Codice MIT → fork/modifica/ridistribuzione OK mantenendo LICENSE + copyright. Caveat: marchio/logo "Claude" (Anthropic) non coperto da MIT; uso API interna + cookie è zona grigia ToS. Per uso personale: nessun problema. Per distribuzione pubblica: rinominare/rebrand + disclaimer "non affiliato". Se si pubblica: preparare README di fork con attribuzioni MIT.
