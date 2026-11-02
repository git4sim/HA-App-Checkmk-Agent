<img src="checkmk_agent/logo.png" alt="Checkmk Agent für Home Assistant" width="250">

# Home Assistant App: Checkmk Agent

Überwacht den Home-Assistant-Host mit Checkmk (Pull, SSH oder TLS/Agent-Controller).

## Installation
1. In Home Assistant: *Einstellungen → Apps → App-Store → ⋮ → Repositories* →
   `https://github.com/git4sim/ha-app-checkmk-agent` hinzufügen.
2. „Checkmk Agent" installieren, Schutzmodus deaktivieren, konfigurieren, starten.

Alternativ lokal: Ordner `checkmk_agent` nach `/addons/` auf dem HA-Host kopieren
(Samba/SSH-App) und im App-Store „Nach Updates suchen" → erscheint unter *Lokale Apps*.

Doku: [checkmk_agent/DOCS.md](checkmk_agent/DOCS.md)

## Lizenz

MIT, siehe [LICENSE](LICENSE). Der Checkmk-Agent selbst stammt von Checkmk GmbH und steht unter GPLv2.

Icon und Logo sind eigene Entwürfe (Quellen in `assets/`), kein offizielles Checkmk-Logo.
