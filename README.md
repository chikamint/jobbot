# jobbot

[![ci](https://github.com/chikamint/jobbot/actions/workflows/ci.yml/badge.svg)](https://github.com/chikamint/jobbot/actions/workflows/ci.yml)

Telegram channel bot that collects **junior/middle DevOps, SRE and Linux vacancies open to
candidates in Georgia and nearby countries** and posts new ones every hour.

Sources (official APIs, RSS feeds, pages allowed by robots.txt; credited in every post):

| Source | Access | Scope |
|---|---|---|
| Himalayas | JSON API | remote jobs open to Georgia |
| Greenhouse, Ashby, Lever | company job board APIs | selected companies |
| Remote OK, Remotive, Jobicy | JSON APIs | global remote boards, location-filtered |
| We Work Remotely | RSS | DevOps & SysAdmin category |
| Habr Career | RSS | remote vacancies |
| hh.ru | official API, application token | remote vacancies |
| jobs.ge | HTML (robots.txt allows, 5 s delay) | local Georgian vacancies |
| Telegram channels | public web preview | excerpt + link to the original post |

Not used on purpose: LinkedIn (scraping forbidden by ToS), sites that disallow their API in robots.txt.

## Architecture

```
            ┌──────────── Kubernetes, namespace jobbot ────────────┐
 job APIs ◄─┤ jobbot (Deployment, 1 replica)                       │
            │   hourly: fetch → filter → upsert → post → mark sent │──► Telegram channel
            │   :8000/metrics                                      │
            │        │ SQL                                         │
            │        ▼                                             │
            │ postgres-0 (StatefulSet + PVC)                       │
            └──────────────────────────────────────────────────────┘
```

Design decisions:
- **Idempotent writes**: vacancy URL is the primary key, `INSERT … ON CONFLICT DO NOTHING`.
- **Commit per message**: each sent Telegram message is marked in the DB right away, so a crash re-posts at most the one in-flight message, not the whole batch.
- **Singleton worker**: 1 replica with `Recreate` strategy, two copies would post duplicates.
- **Failure isolation**: a broken job board or a database outage is logged and counted, the pod keeps running.
- **Hardened pod**: non-root, read-only root filesystem, all capabilities dropped.
- **Observability**: Prometheus metrics, `jobbot_last_success_timestamp_seconds` catches silent failures.

## Local development

Requirements: Linux or WSL2 with Docker.

```bash
make tools      # kubectl, kind, helm, terraform
make cluster    # local kind cluster: 1 control-plane + 2 workers
make test       # unit tests
make deploy     # build image, create secrets, deploy
make logs
make help       # all targets
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | — | PostgreSQL connection (standard libpq variables) |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | empty | without them the bot runs in dry-run mode |
| `HH_TOKEN` | empty | hh.ru application token; without it the hh.ru source is skipped |
| `INTERVAL_MINUTES` | 60 | pause between runs |
| `LOOKBACK_HOURS` | 48 | ignore vacancies older than this |
| `METRICS_PORT` | 8000 | Prometheus metrics endpoint |

Operations: [docs/runbook.md](docs/runbook.md).

## Repository layout

```
app/                     Python service (jobbot.py core, sources.py job boards), tests, Dockerfile
deploy/kind-cluster.yaml local cluster definition
deploy/k8s/base/         manifests shared by all environments
deploy/k8s/overlays/     per-environment settings (local, prod)
scripts/                 tooling install
docs/                    runbook
.github/workflows/       CI pipeline
```

## Roadmap

- [x] Service, PostgreSQL, Kubernetes manifests, local environment
- [x] CI: tests, manifest validation (kubeconform), image build, Trivy scan, push to GHCR
- [ ] GitOps deployment with ArgoCD
- [ ] Production on AWS: Terraform (VPC, EC2), k3s via Ansible, TLS
- [ ] Monitoring: Prometheus, Grafana, alerts to Telegram
- [ ] PostgreSQL backups to S3 with restore test
