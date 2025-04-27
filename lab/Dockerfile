# lab/Dockerfile
FROM ubuntu:22.04

ENV container docker

RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    dbus \
    less \
    curl \
    vim \
    strace \
    lsof \
    stress \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Copia os services e o script de boot
COPY faulty.service /etc/systemd/system/
COPY stress.service /etc/systemd/system/
COPY setup.sh /setup.sh

VOLUME [ "/sys/fs/cgroup" ]
STOPSIGNAL SIGRTMIN+3

CMD ["/setup.sh"]

