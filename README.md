# get.lintune.xyz

Bootstrap install script for Lintune. Fetched and executed with:

```bash
curl -fsSL https://get.lintune.xyz | bash
```

## What it does

1. Installs Docker if not already present
2. Prompts for public domain names and proxy preference (Caddy with auto-SSL, or bring your own)
3. Generates secrets and writes `admin.env`, `dash.env`, and `docker-compose.yml` to `/opt/lintune/`
4. Pulls images and starts the stack: lintune-admin, lintune-dash, MariaDB, Uptime Kuma, and optionally Caddy
5. Outputs the admin URL

Once the script completes, open the admin URL in a browser to run the setup wizard.

## Requirements

- Fresh Linux server with root access
- Public domain pointed at the server (required for Caddy auto-SSL)
- Ports 80 and 443 open if using Caddy; or configure your own reverse proxy
