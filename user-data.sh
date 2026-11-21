#!/bin/sh
# First-boot host baseline of the Lightsail server: time zone, swap, Docker, and Docker log limits.
# Lightsail prepends its own commands and runs user_data with /bin/sh, so this wrapper
# writes the bash script to a file and runs it with bash (pipefail needs bash).
# Apps, the proxy, certificates, the shared .env, and timers are not set up here: the
# Lightsail snapshot is the recovery path for the whole server (#64, docs/operations.md).
set -eu
cat > /usr/local/sbin/server-init <<'INIT'
#!/bin/bash
set -euxo pipefail
timedatectl set-timezone Asia/Seoul

# 2 GB swap: the Docker images are built on the server.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Docker and Compose from the Ubuntu archive (no third-party install script).
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 git curl
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
JSON
systemctl enable docker
systemctl restart docker
usermod -aG docker ubuntu
INIT
chmod 700 /usr/local/sbin/server-init
bash /usr/local/sbin/server-init
