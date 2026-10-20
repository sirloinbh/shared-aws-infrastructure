#!/bin/sh
# First-boot setup of the Lightsail server (#73). Rendered by Terraform templatefile.
# Lightsail prepends its own commands and runs user_data with /bin/sh, so this wrapper
# writes the bash script to a file and runs it with bash (pipefail needs bash).
# Application deploys are done later by scripts/deploy.ps1.
set -eu
cat > /usr/local/sbin/workout-init <<'INIT'
#!/bin/bash
set -euxo pipefail
timedatectl set-timezone Asia/Seoul

# 2 GB swap: the 1 GB plan builds the Docker images on the server.
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

APP=/opt/workout-memo
if [ ! -d "$APP/.git" ]; then git clone ${repo_url} "$APP"; fi
# The database password is generated here and never leaves the server.
if [ ! -f "$APP/.env" ]; then
  PASS=$(openssl rand -hex 24)
  printf 'POSTGRES_DB=workout\nPOSTGRES_USER=workout\nPOSTGRES_PASSWORD=%s\nWEB_BIND=0.0.0.0\nWEB_PORT=80\n' "$PASS" > "$APP/.env"
  chmod 600 "$APP/.env"
fi
chown -R ubuntu:ubuntu "$APP"

# Nightly database dump at 03:30 Seoul, kept ${backup_days} days (also captured by snapshots).
install -d -o ubuntu -g ubuntu -m 700 /var/backups/workout
cat > /usr/local/bin/workout-backup <<'SCRIPT'
#!/bin/bash
set -euo pipefail
cd /opt/workout-memo
file=/var/backups/workout/workout-$(date +%F-%H%M%S).sql.gz
docker compose exec -T db pg_dump -U workout -d workout | gzip > "$file.tmp"
mv "$file.tmp" "$file"
find /var/backups/workout -name 'workout-*.sql.gz' -mtime +${backup_days} -delete
echo "$file"
SCRIPT
chmod 755 /usr/local/bin/workout-backup
touch /var/log/workout-backup.log
chown ubuntu:ubuntu /var/log/workout-backup.log
echo '30 3 * * * ubuntu /usr/local/bin/workout-backup >> /var/log/workout-backup.log 2>&1' > /etc/cron.d/workout-backup
INIT
chmod 700 /usr/local/sbin/workout-init
bash /usr/local/sbin/workout-init
