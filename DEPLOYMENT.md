# Deployment Architecture

Target: replace ~$130/mo DreamHost WordPress with a pipeline that costs
**$5–35/mo** depending on one setting, and can roll back in seconds.

## Diagram

```
  git push main
        │
        ▼
┌───────────────────────┐
│ GitHub-hosted runner  │  free tier: 2,000 Linux min/mo (private repo)
│ ubuntu-latest         │  ~2-3 min per build → ~700 deploys/mo free
└───────────┬───────────┘
            │ OIDC (short-lived federated token — no stored secret)
            ▼
┌───────────────────────┐
│ Entra ID federated    │  subject scoped to repo + GitHub Environment
│ credential            │  RBAC scoped to the resource group
└───────────┬───────────┘
            │
            ▼
┌───────────────────────┐        push via AAD token (AcrPush)
│ Azure Container       │ ◄──────────────────────────────┐
│ Registry (Basic)      │                                │
│ ~$5/mo                │        pull via managed identity (no creds!)
└───────────┬───────────┘                                │
            │                                            │
            ▼                                            │
┌───────────────────────────────────────────────────────┴───────┐
│ Azure Container Apps  (activeRevisionsMode: Multiple)         │
│                                                               │
│   rev-abc123  0%  ← staged, smoke tested on its own FQDN      │
│   rev-def456  100% ← live                                     │
│                                                               │
│   promote  = az containerapp ingress traffic set              │
│   rollback = same command, previous revision  (seconds)       │
└───────────────────────────────────────────────────────────────┘
```

## The four decisions that matter

### 1. GitHub-hosted runners, never self-hosted
Self-hosted is no longer free — GitHub bills a $0.002/min platform charge for
self-hosted runners on private repos as of March 1, 2026. More importantly, a
self-hosted runner is an RCE foothold inside your subscription that runs
whatever anyone pushes. The free 2,000 Linux min/month covers roughly 700
builds of this app.

### 2. ACR, not GHCR
Container Apps can pull from ACR using a **managed identity**, so no registry
credential exists anywhere. Private GHCR images instead require a GitHub PAT
stored in the Container App config:

```bash
# This is what you're avoiding:
az containerapp registry set --server ghcr.io \
  --username <user> --password <GHCR_PAT>
```

A long-lived secret readable by anyone with Reader on the resource group, and
a silent deploy-breaker when someone rotates it. $5/mo is the cheaper option.

*Free alternative:* make the repo public so the GHCR package is public and
needs no credentials. Publishes the source. Fine for a brochure site,
your call.

### 3. OIDC federated credentials, no stored secrets
`azure/login@v2` + `permissions: id-token: write`. GitHub mints a short-lived
token; Azure validates the federation. **No `AZURE_CREDENTIALS` JSON blob.**
The federated credential is scoped to `repo:ORG/REPO:environment:prod`, so a
compromised workflow cannot authenticate for a prod deploy.

### 4. Multiple revisions = staged deploys + instant rollback
`activeRevisionsMode: Multiple`. New revisions land at **0% traffic** and get
smoke tested at `<app>--<revision>.<env-domain>` before customers ever see
them. Rollback is a traffic shift, not a rebuild — the old image is still in
ACR. This is the real capability ACI cannot provide.

## Cost model

**At under 100 visits/month the compute bill is literally $0.00** — not "about
zero." Run the arithmetic:

- ~100 visits × ~10 requests = **~1,000 requests/month**
- Free grant: **2,000,000 requests** → 0.05% used
- ~1,000 requests × 0.5 vCPU × 0.2s = **~100 vCPU-seconds**
- Free grant: **180,000 vCPU-seconds** → 0.06% used

So `minReplicas: 0` isn't a cost optimization at this traffic — the free grant
isn't even visible on the horizon. **The compute line is $0 regardless of what
you choose here.**

### What that means for the decisions

Because compute is free either way, `minReplicas` no longer trades cost against
latency. It only controls **cold starts**. And if Cloudflare's free proxy is
caching the HTML, visitors get served from the edge and never touch the
container at all — it wakes a handful of times a month, for form POSTs and
`/admin`.

**Conclusion: leave `minReplicas: 0`. The cold start is invisible. There is
nothing to buy by going warm.**

### The actual bill

With compute at $0, the registry becomes the *entire* bill:

| Component | Cost |
|---|---|
| Container App compute (`minReplicas: 0`) | **$0.00** |
| Log Analytics (under the 5 GB/mo free ingestion) | $0.00 |
| Azure Files (Standard LRS, a few MB) | <$0.10/mo |
| GitHub Actions (private repo) | $0 (well under 2,000 min) |
| **ACR Basic** | **~$5/mo** |
| **Total** | **~$5/mo** |

### Zeroing out the last $5

ACR Basic exists for exactly one reason: pulling a **private** image with a
managed identity. Because the compute is free, that $5 *is* the bill — so it's
worth asking whether a private registry is worth 100% of your cost.

It isn't, if you're willing to make the repo **public**:

```bash
# Public GHCR image: no username, no password, no credential at all.
az containerapp registry set \
  --name wbs-web --resource-group rg-wetbasement-prod --server ghcr.io
```

Public repo → public GHCR package → ACA pulls it with **no credentials**, same
as the managed-identity path. Total: **$0/month.** The only cost is that the
source is visible — for a brochure site with no secrets in it, that's a fair
trade, and it's arguably good practice for a local business.

**Caveat that must hold:** with a public repo, no secret may ever be committed.
The admin password lives in ACA secrets and the Bicep takes it as a `@secure()`
parameter, so the current design is already clean. Keep it that way — and note
that a public repo means a fork/PR can't reach your Azure credentials, since the
OIDC federated credential is scoped to `environment:prod` on *your* repo only.

Pick one:

| Path | Cost | Trade-off |
|---|---|---|
| Private repo + ACR Basic | **$5/mo** | Source private; managed-identity pull |
| Public repo + GHCR | **$0/mo** | Source public; no credential needed either |

### If you'd rather never think about cold starts

**Azure App Service B1, Linux** is ~$13/mo, always warm, no container runtime
concepts, built-in SSL, and deploys from a zip. That's ~$18/mo total if you keep
ACR. It's the simpler platform — but at 100 visits/month it's strictly more
expensive than ACA's $0 compute, and you lose revision-based rollback. I'd still
take ACA.

## What NOT to cut: staged deploys

It's tempting to drop `activeRevisionsMode: Multiple` and the approval gate as
overkill for a site this small. Don't. **None of that machinery is about
capacity — it's about not taking Dad's phone number down at 2 AM.** Cost of the
feature: $0. Cost of a bad deploy on an emergency flood-response site during a
storm: however many leads call a competitor instead.

The traffic argument says "you don't need replicas." It does not say "you don't
need a rollback." Those are different questions.

## Known constraints

**SQLite over Azure Files (SMB) is single-writer and file locking over SMB is
unreliable.** The Bicep now defaults `maxReplicas: 1` precisely because of this
— at under 100 visits/month you will never need more than one replica, so the
risk is removed for free. **Do not raise `maxReplicas` above 1 until the
database is migrated to Postgres**, or concurrent writers can corrupt the file.

Migrate to **Azure Database for PostgreSQL Flexible Server, Burstable B1ms**
(~$13/mo) before adding anything stateful (booking, accounts, uploads). Note
this quadruples the bill at current traffic — so migrate when a feature actually
needs it, not preemptively.

**Cold starts.** Scale-to-zero means the first request after idle pays a
platform cold-start (~2–5s). FastAPI itself boots in well under a second; the
delay is provisioning, so there's nothing to optimize in the app.

## Repo layout

```
main.py, models.py, admin.py      FastAPI app + SQLAdmin CMS
templates/                        Jinja2 templates (Tailwind + HTMX)
Dockerfile, docker-compose.yml    local + container build
infra/main.bicep                  all Azure resources, declarative
infra/setup-oidc.sh               one-time Entra + OIDC + RBAC bootstrap
.github/workflows/deploy.yml      build → stage → smoke → promote
.github/workflows/rollback.yml    one-click traffic shift to a prior revision
```

Delete `.github/workflows/docker-build.yml` (the original GHCR push) — `deploy.yml`
supersedes it with the ACR + ACA path.

## Bring-up order

1. `az login && az account set --subscription <id>`
2. Edit `GITHUB_ORG` / `GITHUB_REPO` at the top of `infra/setup-oidc.sh`
3. `chmod +x infra/setup-oidc.sh && ./infra/setup-oidc.sh`
4. Paste the three printed values into GitHub → Settings → Secrets and
   variables → Actions → **Variables**
5. Create GitHub Environments `dev` and `prod`; add required reviewers on `prod`
6. Push to `main`
7. Point `wetbasementservices.com` at the Container App FQDN behind Cloudflare

## Before going live

- [ ] Admin password is in ACA secrets (`secretref`), not a plain env var —
      already wired in the Bicep, but the defaults in `main.py` must be removed
- [ ] Move `ADMIN_PASS` / `SECRET_KEY` to **Azure Key Vault** references
- [ ] Add CSRF protection to the public `/quote` form (it's currently open and
      unauthenticated — fine locally, needs rate limiting and a bot check in prod)
- [ ] Add Cloudflare Turnstile to the quote form
- [ ] Confirm the real phone numbers and copy replace the seeded placeholder text
- [ ] Set a budget alert on the subscription
