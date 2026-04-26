# Lintune Architecture Overview

## Repository Structure

| Repo | Purpose |
|---|---|
| `lintune-admin` | Core Laravel app — super admin portal, orchestration logic |
| `lintune-dash` | Core Laravel app — tenant admin portal |
| `docker-lintune-admin` | Docker build only — pulls lintune-admin from git, pins versions, environment scaffolding |
| `docker-lintune-dash` | Docker build only — pulls lintune-dash from git, pins versions, environment scaffolding |
| `get.lintune.xyz` | Installer script — installs Docker, creates compose file, starts the stack |

Each repo has a single responsibility. No Docker configuration lives in the application repos. No application logic lives in the Docker repos.

---

## Deployment Paths

### Recommended — Docker (via installer)

The recommended path for new installations. One command on a fresh VPS:

```bash
curl -fsSL https://get.lintune.xyz | bash
```

The installer script:
1. Calls `get.docker.com` to install Docker
2. Creates `/opt/lintune` with a generated `docker-compose.yml` and `.env`
3. Pulls `docker-lintune-admin` and `docker-lintune-dash` images
4. Starts the stack
5. Outputs the admin URL

The Docker images pull the latest pinned release of `lintune-admin` and `lintune-dash` from git during build, ensuring reproducible deployments.

### Advanced — Bare Metal

For users who prefer a traditional stack (DirectAdmin, ISPConfig, LAMP/LEMP etc.) or already have an existing server environment. Clone `lintune-admin` and `lintune-dash` directly and follow the manual install guides.

No Docker configuration is included in the application repos — they stay clean and portable.

---

## Service Layer

Regardless of how lintune-admin is installed, all external services (Keycloak, Mailcow, Nextcloud, Vaultwarden, ISPConfig, DNS) are connected through the web UI. The bootstrap method has no bearing on which services you can use.

### Option A — Provisioned by Lintune

Lintune SSHes into a target server and provisions the service automatically via the guided wizard. Caddy is set up as the reverse proxy with automatic HTTPS. Keycloak is configured via `kcadm.sh`.

### Option B — Existing infrastructure (API connect)

For tech-savvy users or those who already run their own services. During setup, instead of provisioning, simply provide the API URL and key. The setup wizard shows exactly what permissions the API key needs and how to generate it in each service.

This is the natural path for bare-metal installs where services may already be running.

---

## Design Principles

- **Modular repos** — each repo has one job, no overlap
- **Docker is the default** — recommended for simplicity and reproducibility
- **Bare metal is supported** — for advanced users and existing infrastructure
- **API-only is possible** — skip provisioning entirely by providing credentials directly
- **Service orchestration is always web-driven** — no CLI required after initial install
- **The only manual step is the bootstrap** — everything else is managed through the UI

---

## The Goal

An MSP should be able to onboard a new customer — identity, email, file storage, password manager, web hosting, DNS — with a single form submission, on a fully self-hosted open source stack. The only time you touch a terminal is to run the bootstrap script on the Lintune server itself.
