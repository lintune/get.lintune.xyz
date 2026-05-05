#!/bin/sh
set -e

#
# Lintune Installer
# Usage: curl -fsSL https://get.lintune.xyz | bash
#

INSTALL_DIR=/opt/lintune
ADMIN_IMAGE=git.nexed.tech/stephan/lintune-admin:latest
DASH_IMAGE=git.nexed.tech/stephan/lintune-dash:latest

# ── Output helpers ────────────────────────────────────────────────────────────

bold()    { printf "\033[1m%s\033[0m\n" "$*"; }
info()    { printf "\033[1;34m  →\033[0m %s\n" "$*"; }
ok()      { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
warn()    { printf "\033[1;33m  !\033[0m %s\n" "$*"; }
die()     { printf "\033[1;31mError:\033[0m %s\n" "$*" >&2; exit 1; }

# When piped through bash, stdin is the script — use /dev/tty for prompts
ask() {
    printf "\033[1;36m  ?\033[0m %s " "$1" >/dev/tty
    read -r REPLY </dev/tty
    printf '%s' "$REPLY"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

printf "\n"
bold "╔══════════════════════════════════╗"
bold "║       Lintune Installer          ║"
bold "╚══════════════════════════════════╝"
printf "\n"

[ "$(id -u)" -eq 0 ] || die "Run as root or with sudo."

command -v curl    >/dev/null 2>&1 || die "curl is required but not installed."
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed."

if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    warn "Lintune is already installed at $INSTALL_DIR."
    CONFIRM=$(ask "Reinstall? This will recreate config files but keep data volumes. [y/N]")
    case "$CONFIRM" in
        [yY]*) info "Continuing with reinstall..." ;;
        *) die "Aborted." ;;
    esac
fi

# ── Install Docker ────────────────────────────────────────────────────────────

if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
    info "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed."
fi

# Ensure docker compose (v2 plugin) is available
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found. Install docker-compose-plugin and retry."

# ── Gather config ─────────────────────────────────────────────────────────────

printf "\n"
bold "Configuration"
printf "\n"

# ── Base domain ────────────────────────────────────────────────────────────────

BASE_DOMAIN=$(ask "Base domain (e.g. lintune.company.com):")
[ -n "$BASE_DOMAIN" ] || die "Base domain is required."

ADMIN_DOMAIN="admin.${BASE_DOMAIN}"
DASH_DOMAIN="dash.${BASE_DOMAIN}"
KUMA_DOMAIN="isitup.${BASE_DOMAIN}"

ADMIN_URL="https://${ADMIN_DOMAIN}"
DASH_URL="https://${DASH_DOMAIN}"
SESSION_SECURE=true

printf "\n"
info "Service subdomains (point all to this server's IP):"
info "  Admin panel  ->  ${ADMIN_DOMAIN}"
info "  Tenant dash  ->  ${DASH_DOMAIN}"
info "  Keycloak     ->  auth.${BASE_DOMAIN}"
info "  Mailcow      ->  mail.${BASE_DOMAIN}"
info "  Nextcloud    ->  cloud.${BASE_DOMAIN}"
info "  Vaultwarden  ->  vault.${BASE_DOMAIN}"
info "  Status       ->  ${KUMA_DOMAIN}"
printf "\n"

# ── Reverse proxy choice ───────────────────────────────────────────────────────

USE_CADDY_REPLY=$(ask "Use Caddy as automatic reverse proxy with SSL for admin + dash? [Y/n]")
case "$USE_CADDY_REPLY" in
    [nN]*) USE_CADDY=false ;;
    *)     USE_CADDY=true  ;;
esac

if $USE_CADDY; then
    info "Caddy will obtain SSL certificates for ${ADMIN_DOMAIN} and ${DASH_DOMAIN} automatically."
    info "Keycloak, Mailcow, and Nextcloud manage their own SSL or sit behind your external proxy."
else
    printf "\n"
    info "Admin will be exposed on port 8889, tenant dashboard on port 8888."
    info "Point your reverse proxy to these ports for ${ADMIN_DOMAIN} and ${DASH_DOMAIN}."
fi
printf "\n"

# ── Generate secrets ──────────────────────────────────────────────────────────

info "Generating secrets..."
APP_KEY="base64:$(openssl rand -base64 32)"
DB_ROOT_PASSWORD=$(openssl rand -hex 20)
DB_PASSWORD=$(openssl rand -hex 20)
DB_DATABASE=lintune
DB_USERNAME=lintune
KUMA_DB_NAME=kuma

ok "Secrets generated."

# ── Create install directory ──────────────────────────────────────────────────

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/logs"
chmod 700 "$INSTALL_DIR"
chmod 777 "$INSTALL_DIR/logs"

# ── Write Caddyfile (only when using Caddy) ───────────────────────────────────

if $USE_CADDY; then
    cat > "$INSTALL_DIR/Caddyfile" << EOF
${ADMIN_DOMAIN} {
    reverse_proxy lintune-admin:80
}

${DASH_DOMAIN} {
    reverse_proxy lintune-dash:80
}

${KUMA_DOMAIN} {
    reverse_proxy uptime-kuma:3001
}
EOF
    ok "Caddyfile written."
fi

# ── Write admin.env ───────────────────────────────────────────────────────────

cat > "$INSTALL_DIR/admin.env" << EOF
APP_NAME="Lintune Admin"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=${ADMIN_URL}
LOG_CHANNEL=stack
LOG_LEVEL=error
DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
SESSION_DRIVER=database
SESSION_LIFETIME=120
SESSION_SECURE_COOKIE=${SESSION_SECURE}
DASH_URL=${DASH_URL}
BASE_DOMAIN=${BASE_DOMAIN}
KUMA_URL=https://${KUMA_DOMAIN}
KUMA_INTERNAL_URL=http://uptime-kuma:3001
KUMA_DB_HOST=db
KUMA_DB_PORT=3306
KUMA_DB_NAME=${KUMA_DB_NAME}
KUMA_DB_USERNAME=${DB_USERNAME}
KUMA_DB_PASSWORD=${DB_PASSWORD}
EOF

# 666 inside a 700 directory: host-protected but writable by the container's www-data.
# The install wizard writes Keycloak credentials and SETUP_COMPLETE back to this file.
chmod 666 "$INSTALL_DIR/admin.env"
ok "admin.env written."

# ── Write dash.env ────────────────────────────────────────────────────────────

cat > "$INSTALL_DIR/dash.env" << EOF
APP_NAME=Lintune
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=${DASH_URL}
LOG_CHANNEL=stack
LOG_LEVEL=error
DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
SESSION_DRIVER=database
SESSION_LIFETIME=120
SESSION_SECURE_COOKIE=${SESSION_SECURE}
BASE_DOMAIN=${BASE_DOMAIN}
KEYCLOAK_BASE_URL=
KEYCLOAK_CLIENT_ID=lintune-frontend
KEYCLOAK_ALLOWED_GROUPS=realm-admin
KEYCLOAK_ADMIN_CLI_CLIENT=admin-cli
KUMA_DB_HOST=db
KUMA_DB_PORT=3306
KUMA_DB_NAME=${KUMA_DB_NAME}
KUMA_DB_USERNAME=${DB_USERNAME}
KUMA_DB_PASSWORD=${DB_PASSWORD}
EOF

chmod 600 "$INSTALL_DIR/dash.env"
ok "dash.env written."

# ── Write secrets reference ───────────────────────────────────────────────────

cat > "$INSTALL_DIR/.env" << EOF
# Lintune — generated by installer on $(date -u '+%Y-%m-%d %H:%M UTC')
# Keep this file safe. Do not share it.
# Application env files: admin.env  dash.env

ADMIN_URL=${ADMIN_URL}
DASH_URL=${DASH_URL}

APP_KEY=${APP_KEY}

DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
EOF

chmod 600 "$INSTALL_DIR/.env"
ok "Secrets reference (.env) written."

# ── Write MariaDB init script ─────────────────────────────────────────────────

cat > "$INSTALL_DIR/init-kuma.sql" << EOF
CREATE DATABASE IF NOT EXISTS \`${KUMA_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${KUMA_DB_NAME}\`.* TO '${DB_USERNAME}'@'%';
FLUSH PRIVILEGES;
EOF

chmod 644 "$INSTALL_DIR/init-kuma.sql"
ok "MariaDB init script written."

# ── Write docker-compose.yml ──────────────────────────────────────────────────

if $USE_CADDY; then

cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:

  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${DB_DATABASE}
      MARIADB_USER: ${DB_USERNAME}
      MARIADB_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
      - ./init-kuma.sql:/docker-entrypoint-initdb.d/init-kuma.sql:ro
    networks:
      - internal
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 5s
      retries: 10

  lintune-admin:
    image: ${ADMIN_IMAGE}
    restart: unless-stopped
    env_file: admin.env
    volumes:
      - ./admin.env:/var/www/html/lintune-admin/.env
      - ./logs:/var/www/html/lintune-admin/storage/logs/install
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  lintune-dash:
    image: ${DASH_IMAGE}
    restart: unless-stopped
    env_file: dash.env
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - internal

  uptime-kuma:
    image: louislam/uptime-kuma:2
    restart: unless-stopped
    environment:
      - UPTIME_KUMA_DB_TYPE=mariadb
      - UPTIME_KUMA_DB_HOSTNAME=db
      - UPTIME_KUMA_DB_PORT=3306
      - UPTIME_KUMA_DB_NAME=${KUMA_DB_NAME}
      - UPTIME_KUMA_DB_USERNAME=${DB_USERNAME}
      - UPTIME_KUMA_DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

volumes:
  db_data:
  caddy_data:
  caddy_config:

networks:
  internal:
    driver: bridge
EOF

else

cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:

  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${DB_DATABASE}
      MARIADB_USER: ${DB_USERNAME}
      MARIADB_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
      - ./init-kuma.sql:/docker-entrypoint-initdb.d/init-kuma.sql:ro
    networks:
      - internal
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 5s
      retries: 10

  lintune-admin:
    image: ${ADMIN_IMAGE}
    restart: unless-stopped
    ports:
      - "8889:80"
    env_file: admin.env
    volumes:
      - ./admin.env:/var/www/html/lintune-admin/.env
      - ./logs:/var/www/html/lintune-admin/storage/logs/install
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  lintune-dash:
    image: ${DASH_IMAGE}
    restart: unless-stopped
    ports:
      - "8888:80"
    env_file: dash.env
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  uptime-kuma:
    image: louislam/uptime-kuma:2
    restart: unless-stopped
    environment:
      - UPTIME_KUMA_DB_TYPE=mariadb
      - UPTIME_KUMA_DB_HOSTNAME=db
      - UPTIME_KUMA_DB_PORT=3306
      - UPTIME_KUMA_DB_NAME=${KUMA_DB_NAME}
      - UPTIME_KUMA_DB_USERNAME=${DB_USERNAME}
      - UPTIME_KUMA_DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "3001:3001"
    networks:
      - internal

volumes:
  db_data:

networks:
  internal:
    driver: bridge
EOF

fi

ok "docker-compose.yml written."

# ── Pull images and start ─────────────────────────────────────────────────────

printf "\n"
bold "Starting Lintune..."
printf "\n"

cd "$INSTALL_DIR"

info "Pulling images..."
docker compose pull

info "Starting services..."
docker compose up -d

# ── Wait for admin to be reachable ────────────────────────────────────────────

info "Waiting for lintune-admin to be ready..."
TRIES=0
until docker compose exec -T lintune-admin php artisan --version >/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    [ "$TRIES" -ge 30 ] && die "lintune-admin did not start within 60 seconds. Check logs: docker compose -f $INSTALL_DIR/docker-compose.yml logs lintune-admin"
    sleep 2
done

ok "lintune-admin is up."

# ── Done ──────────────────────────────────────────────────────────────────────

printf "\n"
bold "╔══════════════════════════════════════════════════════════╗"
bold "║  Lintune is running!                                     ║"
bold "╚══════════════════════════════════════════════════════════╝"
printf "\n"
ok "Admin panel : ${ADMIN_URL}"
ok "Tenant dash : ${DASH_URL}"

if ! $USE_CADDY; then
    printf "\n"
    info "Ports exposed on this host:"
    info "  Admin : 8889  ->  point your proxy to http://$(hostname -I | awk '{print $1}'):8889"
    info "  Dash  : 8888  ->  point your proxy to http://$(hostname -I | awk '{print $1}'):8888"
fi

printf "\n"
warn "Secrets saved to: ${INSTALL_DIR}/.env  (root-readable only)"
warn "App env files  : ${INSTALL_DIR}/admin.env and ${INSTALL_DIR}/dash.env"
printf "\n"
info "Open ${ADMIN_URL} in your browser to complete the setup wizard."
info "The wizard will pre-fill service domains from base domain: ${BASE_DOMAIN}"
printf "\n"
info "  Keycloak  ->  https://auth.${BASE_DOMAIN}"
info "  Mailcow   ->  https://mail.${BASE_DOMAIN}"
info "  Nextcloud ->  https://cloud.${BASE_DOMAIN}"
printf "\n"
info "To view logs:    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
info "To stop:         docker compose -f ${INSTALL_DIR}/docker-compose.yml down"
printf "\n"
