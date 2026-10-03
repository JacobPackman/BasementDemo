# Wet Basement Services — Modernized Prototype

A lightweight, modern, and cost-effective redesign of **Wet Basement Services**
built for high speed, low maintenance, and easy administrative editing for Dad.

> ## ⚠️ Demo status: Azure deployment TORN DOWN
>
> The live demo has been decommissioned. The resource group
> `rg-wetbasement-demo` and the Entra app registration `wbs-github-oidc`
> were deleted, and the demo hostname no longer resolves.
>
> **The repo is an intact, working template.** Running `infra/setup-oidc.sh`
> stands the whole thing back up from scratch (see DEPLOYMENT.md).
>
> **The GitHub Actions repository variables are now stale** — they still
> point at the deleted subscription/registry/app-registration IDs, so a push
> to `main` will fail at the `azure/login` step with `AADSTS700213` until
> the bootstrap is re-run. Nothing is broken; it just has no Azure to talk to.

## Architecture

- **Framework:** FastAPI (Python 3.11, async) + Uvicorn
- **Frontend:** Tailwind CSS + FontAwesome + HTMX for no-reload quote form submits
- **Admin CMS:** [SQLAdmin](https://github.com/aminalaee/sqladmin) 0.32 mounted
  in-process at `/admin` — a model-driven CRUD admin, not a standalone CMS.
  Dad can edit:
  - Phone numbers, 24/7 emergency hotline, email, service areas
  - Homepage headline and hero copy
  - Services, icons, badges, descriptions, ordering, active/inactive
  - Testimonials and star ratings
  - Customer quote leads, including emergency-flagged ones
- **Database:** SQLite via `aiosqlite` + SQLAlchemy 2.0 asyncio, on the
  container's **local disk**. See "Known constraints" — this is deliberate.
- **Containerization:** multi-stage `Dockerfile` + `docker-compose.yml`
- **CI/CD:** GitHub Actions → Azure Container Registry → Azure Container Apps,
  authenticated with **OIDC** (no stored credentials anywhere)

## Running locally

```bash
docker compose up --build
```

Or with Python:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

- Public site: `http://localhost:8000/`
- Admin CMS: `http://localhost:8000/admin`
  (defaults to `admin` / `seattlewet123` if `ADMIN_USER`/`ADMIN_PASS` are unset)

## Deployment

See **[DEPLOYMENT.md](DEPLOYMENT.md)** for the full architecture and bring-up.

Pushing to `main` builds, deploys a new revision at **0% traffic**, smoke tests
it on its own FQDN, and **stops**. Nothing reaches customers until someone runs
the **Promote** workflow. **Rollback** is a one-command traffic shift — seconds,
no rebuild.

Target platform is **Azure Container Apps**, not ACI:

- Free automated managed TLS on custom domains
- Scale-to-zero, so compute is ~$0 at low traffic
- Multiple revisions, which is what makes staged deploys and instant rollback possible
- Images pulled by **managed identity** — no registry credential exists anywhere

## Known constraints

- **SQLite cannot run on Azure Files (SMB).** It appears to work, then wedges
  permanently with `database is locked` on `CREATE TABLE`, and the container
  crash-loops. ACA offers only Azure Files for volumes, so there is no
  reliable persistent volume for SQLite here. The app therefore uses
  container-local disk, which means **the database is ephemeral — it resets on
  every new revision, losing leads and CMS edits.** For real persistence,
  move to PostgreSQL Flexible Server. Full write-up in DEPLOYMENT.md.
- **`maxReplicas` is pinned to 1** — a single-writer database must never have
  two containers writing to it.
- **The `/quote` endpoint is open and unauthenticated.** Fine locally; needs
  rate limiting and a bot check (e.g. Cloudflare Turnstile) before going live.
- **The admin password is compared in plaintext** and `/admin/login` has no
  rate limiting or lockout. Fine for a demo; hash it and add throttling for real.
