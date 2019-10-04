FROM haproxy:2.0

RUN apt-get update && apt-get install -y gnupg ca-certificates curl wget python-pip && pip install j2cli
RUN curl -slL https://apt.signalsciences.net/release/gpgkey | apt-key add - && \
    echo "deb https://apt.signalsciences.net/release/ubuntu/ bionic main" | tee /etc/apt/sources.list.d/sigsci-release.list && \
    apt-get update && apt-get install -y sigsci-agent && \
    wget https://github.com/square/certstrap/releases/download/v1.1.1/certstrap-v1.1.1-linux-amd64 -O /usr/local/bin/certstrap && \
    chmod +x /usr/local/bin/certstrap && \
    mkdir /etc/certs && \
    chmod 0755 /etc/certs && \
    mkdir /etc/certs/ca && \
    chmod 0700 /etc/certs/ca

COPY generate-certs.sh /usr/local/sbin/generate-certs

RUN chmod +x /usr/local/sbin/generate-certs && \
    generate-certs service proxy 15552000
RUN apt-get purge -y --auto-remove && rm -rf /var/lib/apt/lists/*

COPY haproxy.cfg.j2 /tmp/
COPY error-pages/* /usr/local/etc/haproxy/errors/
COPY SignalSciences.lua /usr/local/etc/haproxy/
COPY fourosix.lua /usr/local/etc/haproxy/
COPY MessagePack.lua /usr/local/share/lua/5.3/sigsci/
COPY pprint.lua /usr/local/share/lua/5.3/sigsci/
COPY entrypoint.sh .

ENV SIGSCI_RPCADDRESS="unix:/var/run/sigsci.sock"

EXPOSE 8443
EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
