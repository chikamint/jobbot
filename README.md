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

## Production infrastructure (AWS, Terraform)

```
eu-north-1
 └─ VPC 10.0.0.0/16 ── Internet Gateway
     └─ public subnet 10.0.1.0/24
         └─ EC2 t4g.small (ARM, 2 GiB, Ubuntu 24.04, gp3 encrypted, IMDSv2) + Elastic IP
             security group: 22, 6443 from admin IP only; 80/443 public
```

- State in S3 (`infra/terraform/bootstrap`): versioned, encrypted, private, native S3 locking.
- No NAT gateway and a single public subnet: deliberate cost trade-off for a one-node setup (~$18/month).
- Images are multi-arch (amd64 + arm64): the same tag runs on local kind and on the ARM node.

```bash
make infra-bootstrap   # once: state bucket
make infra-plan        # preview changes
make infra-apply       # create / update (admin IP is detected automatically)
make provision         # Ansible: OS baseline (updates, swap, SSH hardening) + k3s, fetches kubeconfig
make prod-deploy       # deploy the image tag pinned in deploy/k8s/overlays/prod
make prod-status
make prod-monitoring-secrets && make prod-monitoring   # Prometheus + Alertmanager
make prod-prometheus   # Prometheus UI on http://localhost:9090
```

Node configuration (`infra/ansible`, roles `base` and `k3s`): unattended security upgrades, 2 GiB swap,
key-only SSH without root, k3s pinned to a stable version with Secrets encryption at rest.

## Repository layout

```
infra/terraform/         AWS infrastructure (bootstrap: state bucket, prod: network + node)
infra/ansible/           node configuration: OS baseline + k3s
app/                     Python service (jobbot.py core, sources.py job boards), tests, Dockerfile
deploy/kind-cluster.yaml local cluster definition
deploy/k8s/base/         manifests shared by all environments
deploy/k8s/overlays/     per-environment settings (local, prod)
deploy/k8s/components/   optional pieces (monitoring: ServiceMonitor, alerts + tests, dashboard)
deploy/monitoring/       kube-prometheus-stack values
scripts/                 tooling install
docs/                    runbook
.github/workflows/       CI pipeline
```

## Roadmap

- [x] Service, PostgreSQL, Kubernetes manifests, local environment
- [x] CI: tests, manifest validation (kubeconform), image build, Trivy scan, push to GHCR
- [ ] GitOps deployment with ArgoCD
- [x] Production on AWS: Terraform (VPC, EC2, S3 state), k3s via Ansible
- [ ] TLS and public endpoint via Gateway API
- [x] Monitoring: kube-prometheus-stack trimmed to fit 2 GiB (Prometheus, Alertmanager, exporters; Grafana dropped after it caused swap thrashing), symptom-based alerts unit-tested with promtool, alerts to Telegram
- [ ] Grafana dashboards via Grafana Cloud (dashboard JSON already in `deploy/k8s/components/monitoring`)
- [x] PostgreSQL backups: daily CronJob → S3 (14-day lifecycle, IAM instance role, no static keys), freshness alert, restore tested
