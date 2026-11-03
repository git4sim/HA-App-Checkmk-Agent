# Checkmk Agent

Diese App führt den offiziellen Checkmk-Linux-Agenten auf deinem Home-Assistant-Host aus.
Das Agent-Skript wird beim Start direkt von deinem Checkmk-Server geladen, damit es zur
Server-Version passt. Ohne Server-Angabe wird ein mitgelieferter Agent verwendet.

## Wichtig: Schutzmodus deaktivieren

Für eine vollständige Host-Sicht (alle Prozesse, Docker-Container) musst du auf der
Info-Seite der App den **Schutzmodus** ausschalten. Ohne das laufen CPU, RAM, Netzwerk,
Disk-I/O und Dateisysteme trotzdem, aber Prozesse und Docker siehst du nur eingeschränkt.

## Modi

### `ssh` (empfohlen)
Verschlüsselt, läuft auf jeder Architektur (amd64, aarch64, armv7).

1. Auf dem Checkmk-Server als Site-User einen Key erzeugen:
   ```bash
   su - mysite
   ssh-keygen -t ed25519 -f ~/.ssh/id_homeassistant -N ''
   cat ~/.ssh/id_homeassistant.pub
   ```
2. Den Public Key in `ssh_authorized_keys` eintragen, App starten.
   Der Key wird automatisch mit `restrict,command="check_mk_agent"` eingeschränkt.
3. In Checkmk: *Setup → Agents → Other integrations → Individual program call instead of agent access*,
   Regel für den HA-Host:
   ```
   ssh -p 6522 -i ~/.ssh/id_homeassistant -o StrictHostKeyChecking=accept-new root@$HOSTADDRESS$
   ```

### `tls` (Agent-Controller, wie bei normalen Linux-Hosts)
Lädt `cmk-agent-ctl` vom Server, registriert sich und startet den Controller (TLS-Pull
auf 6556 oder Push, je nach Host-Einstellung in Checkmk).

- Benötigt: `checkmk_server`, `checkmk_site`, `tls_hostname` (muss in Checkmk existieren),
  `tls_username`/`tls_password` (Benutzer mit Recht zur Agent-Registrierung, z. B. Automationsuser).
- `tls_server` entspricht `--server` von `cmk-agent-ctl register`, inkl. Agent-Receiver-Port
  (z. B. `monitoring.example.com:8000`). Leer = Host aus `checkmk_server`, Port per REST-API ermittelt.
- Beim ersten Mal `tls_trust_cert: true` setzen, es gibt keine interaktive Rückfrage.
- Die Registrierung wird in `/data` gespeichert und überlebt Updates/Neustarts.
- **Einschränkung:** Checkmk liefert `cmk-agent-ctl` nur für x86_64. Auf einem Raspberry Pi
  (aarch64/armv7) nutze `ssh` oder lege ein selbst gebautes Binary als
  `/addon_configs/<slug>_checkmk_agent/cmk-agent-ctl` ab.

### `pull` (klassisch, unverschlüsselt)
socat lauscht auf `pull_port` (6556). Nur in vertrauenswürdigen Netzen verwenden und
**unbedingt** `allowed_hosts` setzen. In Checkmk muss für den Host unverschlüsselte
Kommunikation erlaubt sein (Regel *Allowed agent connection modes / TLS erzwingen*).

## Eigene Plugins und Local Checks

Im App-Konfigurationsordner (`/addon_configs/<slug>_checkmk_agent/`, z. B. über die
Samba- oder File-Editor-App erreichbar):

| Pfad | Zweck |
|---|---|
| `plugins/` | Agent-Plugins (auch Unterordner wie `300/` für gecachte Ausführung) |
| `local/` | Local Checks |
| `check_mk_agent.linux` | Ersetzt das Agent-Skript komplett |
| `cmk-agent-ctl` | Eigenes Agent-Controller-Binary (Modus `tls`) |

Änderungen werden beim Neustart der App übernommen.

## Mitgelieferte Home-Assistant-Checks (`ha_local_checks`)

| Service | Inhalt |
|---|---|
| Home Assistant Core / Supervisor / OS | Version, WARN bei verfügbarem Update |
| Home Assistant Apps | Anzahl Apps mit Update (Liste im Langtext) |
| Home Assistant Health | CRIT bei *unhealthy*, WARN bei *unsupported* oder Reparatur-Hinweisen |
| Home Assistant Backup | Alter des letzten Backups (WARN > 2 Tage, CRIT > 7 Tage) |

## Was nicht funktioniert

- systemd-Units, Paket-Updates (`apt`) des Hosts: HA OS hat keinen Paketmanager.
- SMART/Sensoren nur mit Hardware-Zugriff (nicht freigegeben).

### Beispiel: Entsprechung zu `cmk-agent-ctl register`

```
cmk-agent-ctl register --hostname LAB-Home --server monitoring.example.com:8000 \
  --site cmk --user Agent-Registration --password '...'
```

entspricht dieser App-Konfiguration:

```yaml
mode: tls
checkmk_server: https://monitoring.example.com   # Web-URL, für den Download von cmk-agent-ctl
checkmk_site: cmk
tls_server: monitoring.example.com:8000
tls_hostname: LAB-Home
tls_username: Agent-Registration
tls_password: "..."
tls_trust_cert: true
```
