#!/bin/bash
set -e

# Permite o systemd dentro do container
exec /sbin/init
systemctl start stress
systemctl start faulty
