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

## Recommended Deployment (Saving $130/mo)
Deploy on **Azure Container Apps (ACA)**:
- Generous free monthly execution tier.
- Built-in automatic free SSL / Let's Encrypt certificates.
- Direct integration with GitHub Actions (`ghcr.io`).
- Costs under $5/mo compared to DreamHost's $130/mo.
