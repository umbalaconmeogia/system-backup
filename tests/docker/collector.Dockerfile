# Collector: the backup server.
FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-client curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 700 /root/.ssh

COPY collector/ /opt/webapp-backup/collector/
RUN chmod 755 /opt/webapp-backup/collector/*.sh

CMD ["sleep", "infinity"]
