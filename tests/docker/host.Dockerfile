# Host: the server that runs the system. Runs sshd, backup scripts, database clients.
# DB_CLIENT: mysql-client or mariadb-client (they cannot be installed together).
FROM ubuntu:24.04

ARG DB_CLIENT=mysql-client
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server zip unzip acl ${DB_CLIENT} postgresql-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash webapp-backup \
    && install -d -o webapp-backup -g webapp-backup -m 700 /home/webapp-backup/.ssh \
    && install -d -o root -g webapp-backup -m 750 /etc/webapp-backup \
    && install -d -m 700 -o webapp-backup -g webapp-backup /var/webapp-backup \
    && install -d -m 777 /exchange \
    && mkdir -p /run/sshd \
    && ssh-keygen -A

COPY host/ /opt/webapp-backup/host/
RUN chmod 755 /opt/webapp-backup/host/*.sh

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
