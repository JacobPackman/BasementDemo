# Wet Basement Services - Modernized Prototype

A lightweight, modern, and cost-effective redesign of **Wet Basement Services** built for high speed, low maintenance, and easy administrative editing for Dad.

## Architecture
- **Framework:** FastAPI (Python 3.11 asynchronous)
- **Frontend:** Responsive Tailwind CSS + FontAwesome + HTMX for smooth, reactive quote form submissions.
- **Admin CMS:** Integrated [SQLAdmin](https://github.com/aminalaee/sqladmin) at `/admin`. Dad can edit:
  - Phone numbers, emergency flood hotline, email, service areas
  - Homepage headlines and announcement copy
  - Services, icons, badges, descriptions
  - Testimonials and reviews
  - Real-time customer quote leads & emergency dispatch requests
- **Database:** SQLite via `aiosqlite` and `SQLAlchemy 2.0` (persisted to volume `/data/wetbasement.db`). Zero cloud DB bills required.
- **Containerization:** Clean multi-stage `Dockerfile` and `docker-compose.yml`.
- **CI/CD:** GitHub Actions pipeline configured in `.github/workflows/docker-build.yml` targeting GitHub Container Registry (`ghcr.io`).

## Running Locally

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

- Public Site: `http://localhost:8000/`
- Dad's CMS: `http://localhost:8000/admin` (Default: `admin` / `seattlewet123`)

## Deployment

See **[DEPLOYMENT.md](DEPLOYMENT.md)** for the full architecture.

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

- **SQLite on Azure Files is single-writer.** `maxReplicas` is pinned to 1 for
  this reason. Migrate to Postgres before adding anything stateful.
- **The `/quote` endpoint is open and unauthenticated.** Fine locally; needs
  rate limiting and a bot check before going live.

