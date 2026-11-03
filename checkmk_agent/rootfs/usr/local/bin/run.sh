#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
# Startskript der Checkmk-Agent-App für Home Assistant.
set -o pipefail

CFG=/config          # = /addon_configs/<slug> auf dem Host (Plugins, Local Checks, Overrides)
DATA=/data           # persistenter App-Speicher
RUN=/run/cmk
LIBDIR=/usr/lib/check_mk_agent

MODE=$(bashio::config 'mode')
SERVER=$(bashio::config 'checkmk_server' '')
SERVER="${SERVER%/}"
SITE=$(bashio::config 'checkmk_site' '')

CURL=(curl -fsSL --max-time 60)
bashio::config.false 'verify_ssl' && CURL+=(-k)

mkdir -p "$RUN" "$DATA/check_mk_agent" "$DATA/cache" "$CFG/plugins" "$CFG/local"
chmod 755 "$RUN"

server_url() { # $1 = Pfad unterhalb von /<site>/check_mk/agents/
    [[ -n $SERVER && -n $SITE ]] || return 1
    echo "${SERVER}/${SITE}/check_mk/agents/$1"
}

# -----------------------------------------------------------------------------
# 1. Agent-Skript auswählen: Override > Checkmk-Server > Cache > mitgeliefert
# -----------------------------------------------------------------------------
agent_target="$RUN/check_mk_agent.linux"
if [[ -f $CFG/check_mk_agent.linux ]]; then
    bashio::log.info "Nutze eigenen Agenten aus ${CFG}/check_mk_agent.linux"
    cp "$CFG/check_mk_agent.linux" "$agent_target"
elif url=$(server_url check_mk_agent.linux); then
    bashio::log.info "Lade Agent von ${url}"
    if "${CURL[@]}" -o "$DATA/cache/agent.new" "$url" && head -n1 "$DATA/cache/agent.new" | grep -q '^#!.*bash'; then
        mv "$DATA/cache/agent.new" "$DATA/cache/check_mk_agent.linux"
    else
        rm -f "$DATA/cache/agent.new"
        bashio::log.warning "Download fehlgeschlagen (Server/Site/SSL prüfen)."
    fi
    if [[ -f $DATA/cache/check_mk_agent.linux ]]; then
        cp "$DATA/cache/check_mk_agent.linux" "$agent_target"
    else
        bashio::log.warning "Kein Agent im Cache - nutze mitgelieferten Agenten."
        cp /opt/checkmk/check_mk_agent.linux "$agent_target"
    fi
else
    bashio::log.info "Kein Checkmk-Server konfiguriert - nutze mitgelieferten Agenten."
    cp /opt/checkmk/check_mk_agent.linux "$agent_target"
fi
chmod 755 "$agent_target"
bashio::log.info "Agent: $(grep -m1 -E '^CMK_VERSION=' "$agent_target" || echo 'Version unbekannt')"

# -----------------------------------------------------------------------------
# 2. Plugins & Local Checks zusammenstellen
# -----------------------------------------------------------------------------
rm -rf "${LIBDIR:?}/plugins" "${LIBDIR:?}/local"
mkdir -p "$LIBDIR/plugins" "$LIBDIR/local"

shopt -s nullglob
for f in "$CFG"/plugins/*; do ln -s "$f" "$LIBDIR/plugins/"; done
for f in "$CFG"/local/*;   do ln -s "$f" "$LIBDIR/local/";   done
shopt -u nullglob

if bashio::config.true 'docker_plugin'; then
    if [[ -S /run/docker.sock ]]; then
        if url=$(server_url plugins/mk_docker.py) && "${CURL[@]}" -o "$DATA/cache/mk_docker.py.new" "$url" \
            && head -n1 "$DATA/cache/mk_docker.py.new" | grep -q python; then
            mv "$DATA/cache/mk_docker.py.new" "$DATA/cache/mk_docker.py"
        fi
        rm -f "$DATA/cache/mk_docker.py.new"
        src=/opt/checkmk/mk_docker.py
        [[ -f $DATA/cache/mk_docker.py ]] && src="$DATA/cache/mk_docker.py"
        install -m 755 "$src" "$LIBDIR/plugins/mk_docker.py"
        bashio::log.info "Docker-Plugin aktiv."
    else
        bashio::log.warning "Docker-Plugin aktiviert, aber kein Docker-Socket vorhanden. Schutzmodus der App deaktivieren!"
    fi
fi

if bashio::config.true 'ha_local_checks'; then
    install -m 600 /dev/null "$RUN/supervisor_token"
    printf '%s' "${SUPERVISOR_TOKEN}" >"$RUN/supervisor_token"
    ln -s /opt/checkmk/local/homeassistant "$LIBDIR/local/homeassistant"
fi

# Hinweis bei aktivem Schutzmodus: ohne Host-PID-Namespace sieht der Agent nur den Container.
if [[ "$(cat /proc/1/comm 2>/dev/null)" != "systemd" ]]; then
    bashio::log.warning "Kein Host-PID-Namespace: Prozess-Checks zeigen nur den Container. Schutzmodus der App deaktivieren!"
fi

if [[ "$(bashio::config 'log_level')" =~ ^(debug|trace)$ ]]; then
    bashio::log.info "Test-Lauf des Agenten (erste 20 Zeilen):"
    /usr/local/bin/check_mk_agent 2>&1 | head -n 20
fi

# -----------------------------------------------------------------------------
# 3. Auslieferung je nach Modus
# -----------------------------------------------------------------------------
case "$MODE" in
pull)
    PORT=$(bashio::config 'pull_port')
    : >"$RUN/allowed_hosts"
    for h in $(bashio::config 'allowed_hosts'); do echo "$h" >>"$RUN/allowed_hosts"; done
    if [[ -s $RUN/allowed_hosts ]]; then
        bashio::log.info "Erlaubte Quellen: $(tr '\n' ' ' <"$RUN/allowed_hosts")"
    else
        bashio::log.warning "allowed_hosts ist leer - JEDER im Netz kann die Agent-Ausgabe abrufen (unverschlüsselt)!"
    fi
    listen="TCP4-LISTEN:${PORT}"
    [[ -f /proc/net/if_inet6 ]] && listen="TCP6-LISTEN:${PORT},ipv6only=0"
    bashio::log.info "Pull-Modus (unverschlüsselt) auf Port ${PORT}"
    exec socat -d "${listen},reuseaddr,fork,max-children=10" EXEC:/usr/local/bin/cmk-pull-gate
    ;;

ssh)
    PORT=$(bashio::config 'ssh_port')
    mkdir -p "$DATA/ssh" /run/sshd
    chmod 700 "$DATA/ssh"
    for t in ed25519 rsa; do
        [[ -f $DATA/ssh/ssh_host_${t}_key ]] || ssh-keygen -q -t "$t" -N '' -f "$DATA/ssh/ssh_host_${t}_key"
    done
    : >"$RUN/authorized_keys"
    while read -r key; do
        [[ -z $key ]] && continue
        echo "restrict,command=\"/usr/local/bin/check_mk_agent\" ${key}" >>"$RUN/authorized_keys"
    done < <(bashio::config 'ssh_authorized_keys')
    chmod 600 "$RUN/authorized_keys"
    [[ -s $RUN/authorized_keys ]] || bashio::exit.nok "Modus ssh: mindestens ein Key in ssh_authorized_keys nötig."

    cat >"$RUN/sshd_config" <<CONF
Port ${PORT}
HostKey ${DATA}/ssh/ssh_host_ed25519_key
HostKey ${DATA}/ssh/ssh_host_rsa_key
AuthorizedKeysFile ${RUN}/authorized_keys
PermitRootLogin forced-commands-only
AllowUsers root
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitTTY no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
PidFile /run/sshd.pid
LogLevel INFO
CONF
    bashio::log.info "SSH-Modus auf Port ${PORT}. Host-Key-Fingerprints:"
    for t in ed25519 rsa; do ssh-keygen -lf "$DATA/ssh/ssh_host_${t}_key.pub"; done
    exec /usr/sbin/sshd -D -e -f "$RUN/sshd_config"
    ;;

tls)
    # --- Agent-Controller beschaffen ---
    ctl="$DATA/cache/cmk-agent-ctl"
    if [[ -f $CFG/cmk-agent-ctl ]]; then
        bashio::log.info "Nutze eigenen cmk-agent-ctl aus ${CFG}"
        cp "$CFG/cmk-agent-ctl" "$ctl"
    elif url=$(server_url linux/cmk-agent-ctl.gz); then
        bashio::log.info "Lade cmk-agent-ctl von ${url}"
        if "${CURL[@]}" "$url" | gunzip >"$ctl.new" 2>/dev/null && [[ -s $ctl.new ]]; then
            mv "$ctl.new" "$ctl"
        else
            rm -f "$ctl.new"
            bashio::log.warning "Download von cmk-agent-ctl fehlgeschlagen."
        fi
    fi
    [[ -f $ctl ]] || bashio::exit.nok "Kein cmk-agent-ctl verfügbar. checkmk_server/checkmk_site setzen oder Binary nach ${CFG}/cmk-agent-ctl legen."
    install -m 755 "$ctl" /usr/bin/cmk-agent-ctl
    if ! ver=$(cmk-agent-ctl --version 2>&1); then
        bashio::exit.nok "cmk-agent-ctl läuft auf dieser Architektur ($(uname -m)) nicht: ${ver}. Nutze den Modus 'ssh' oder lege ein passendes Binary nach ${CFG}/cmk-agent-ctl."
    fi
    bashio::log.info "Agent-Controller: ${ver}"

    # --- Persistenter Zustand (Registrierung, Zertifikate) ---
    mkdir -p "$DATA/cmk-agent"
    rm -rf /var/lib/cmk-agent
    ln -sfn "$DATA/cmk-agent" /var/lib/cmk-agent
    chown -R cmk-agent:cmk-agent "$DATA/cmk-agent"

    # --- Agent-Socket (ersetzt check-mk-agent.socket von systemd) ---
    socat "UNIX-LISTEN:/run/check-mk-agent.socket,fork,unlink-early,mode=0660,user=root,group=cmk-agent" \
        EXEC:/usr/local/bin/check_mk_agent &
    SOCAT_PID=$!

    # --- Registrierung ---
    marker="$DATA/cmk-agent/.ha_registered"
    # --server für die Registrierung: tls_server (z. B. "host:8000") oder Host aus checkmk_server
    srvhost=$(bashio::config 'tls_server' '')
    if [[ -z $srvhost ]]; then
        srvhost="${SERVER#*://}"; srvhost="${srvhost%%/*}"; srvhost="${srvhost%%:*}"
    fi
    want="${srvhost}|${SITE}|$(bashio::config 'tls_hostname' '')"
    if bashio::config.true 'tls_force_register' || [[ ! -f $marker || "$(cat "$marker")" != "$want" ]]; then
        for opt in checkmk_site tls_hostname tls_username tls_password; do
            bashio::config.has_value "$opt" || bashio::exit.nok "Modus tls: Option '${opt}' fehlt."
        done
        [[ -n $srvhost ]] || bashio::exit.nok "Modus tls: tls_server oder checkmk_server setzen."
        args=(register --hostname "$(bashio::config 'tls_hostname')" --server "$srvhost" --site "$SITE"
              --user "$(bashio::config 'tls_username')" --password "$(bashio::config 'tls_password')")
        bashio::config.true 'tls_trust_cert' && args+=(--trust-cert)
        bashio::log.info "Registriere bei ${srvhost}/${SITE} als '$(bashio::config 'tls_hostname')' ..."
        if cmk-agent-ctl "${args[@]}" </dev/null; then
            echo "$want" >"$marker"
            chown -R cmk-agent:cmk-agent "$DATA/cmk-agent"
            bashio::log.info "Registrierung erfolgreich. Du kannst tls_force_register wieder ausschalten."
        else
            bashio::log.error "Registrierung fehlgeschlagen. Beim ersten Mal tls_trust_cert aktivieren (keine interaktive Bestätigung möglich)."
            kill "$SOCAT_PID"
            exit 1
        fi
    else
        bashio::log.info "Bereits registriert - überspringe Registrierung."
    fi

    bashio::log.info "Starte Agent-Controller (TLS-Pull bzw. Push)."
    runuser -u cmk-agent -- cmk-agent-ctl daemon &
    CTL_PID=$!
    trap 'kill $CTL_PID $SOCAT_PID 2>/dev/null' TERM INT
    wait -n "$CTL_PID" "$SOCAT_PID"
    rc=$?
    bashio::log.error "Ein Dienst wurde beendet (rc=${rc}) - App stoppt."
    kill "$CTL_PID" "$SOCAT_PID" 2>/dev/null
    exit "$rc"
    ;;
esac
