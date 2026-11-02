ARG BUILD_FROM
FROM ${BUILD_FROM}

# Fallback-Agent, falls kein Checkmk-Server angegeben ist.
# Sollte zur Major-Version deines Checkmk-Servers passen.
ARG CHECKMK_BRANCH=2.4.0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash coreutils procps util-linux iproute2 ethtool \
        socat openssh-server curl ca-certificates jq gzip \
        python3 python3-docker \
        lm-sensors smartmontools \
    && rm -rf /var/lib/apt/lists/* \
    && usermod -p "*" root \
    && useradd --system --home-dir /var/lib/cmk-agent --shell /usr/sbin/nologin cmk-agent \
    && mkdir -p /etc/check_mk /usr/lib/check_mk_agent/plugins /opt/checkmk \
    && curl -fsSL -o /opt/checkmk/check_mk_agent.linux \
        "https://raw.githubusercontent.com/Checkmk/checkmk/${CHECKMK_BRANCH}/agents/check_mk_agent.linux" \
    && curl -fsSL -o /opt/checkmk/mk_docker.py \
        "https://raw.githubusercontent.com/Checkmk/checkmk/${CHECKMK_BRANCH}/agents/plugins/mk_docker.py" \
    && chmod 755 /opt/checkmk/check_mk_agent.linux

COPY rootfs /
RUN chmod 755 /usr/local/bin/* /opt/checkmk/local/*

CMD ["/usr/local/bin/run.sh"]
