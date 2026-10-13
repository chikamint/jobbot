# Runbook

## Connect Telegram

1. Create a bot with @BotFather, save the token.
2. Create a channel, add the bot as administrator with the "Post messages" right.
3. Store credentials as a Secret (never in git):
   ```bash
   kubectl -n jobbot create secret generic telegram \
     --from-literal=token=<BOT_TOKEN> --from-literal=chat_id=@<channel_username>
   kubectl -n jobbot rollout restart deploy/jobbot
   ```

## Enable hh.ru

hh.ru API rejects anonymous requests (403). Register an application at https://dev.hh.ru
(needs an hh.ru account; the app goes through moderation), get the **application token**, then:
```bash
kubectl -n jobbot create secret generic hh --from-literal=token=<APP_TOKEN>
kubectl -n jobbot rollout restart deploy/jobbot
```

## Add or remove a source

All boards are listed in `BOARDS` at the top of `app/sources.py`.
A new source = one fetcher function yielding `Job(...)` + one entry in `FETCHERS` + a test with a saved sample response.
Before adding a site check its robots.txt and terms: public channel posts must not violate them.

## Production

```bash
make prod-status                 # node + pods on AWS
make prod-logs
ssh ubuntu@$(terraform -chdir=infra/terraform/prod output -raw public_ip)
```

**Release a new version**: take the `sha-xxxxxxx` tag from the green CI run, put it into
`deploy/k8s/overlays/prod/kustomization.yaml` (`newTag`), commit, `make prod-deploy`.
Rollback = previous tag + `make prod-deploy`.

**SSH / kubectl stopped working** — your home IP changed: `make infra-apply` updates the security group.

**Upgrade k3s** — change `k3s_version` in `infra/ansible/roles/k3s/defaults/main.yml`, `make provision`.

## Health checks

```bash
make status                                   # pods, PVC
make logs                                     # expect "run ok: N matching vacancies"
kubectl -n jobbot port-forward svc/jobbot 8000:8000
curl -s localhost:8000/metrics | grep ^jobbot_
```

| Metric | Meaning | Alert when |
|---|---|---|
| `jobbot_last_success_timestamp_seconds` | last fully successful run | older than 2 × interval |
| `jobbot_run_failures_total` | runs that failed (DB down, bug) | increases |
| `jobbot_source_errors_total{source}` | failed job board requests | grows for one source for hours |
| `jobbot_jobs_posted_total` | messages sent | flat for a day while jobs are found |

## Troubleshooting

**Bot is Running but posts nothing**
1. `make logs`: `dry-run` means the `telegram` Secret is missing; `run failed` shows the exception.
2. `make psql` → `select count(*), count(posted_at) from jobs;` — are vacancies found but not posted?
3. Telegram `403 Forbidden` in logs: the bot is not an admin of the channel.

**`run failed` with connection errors**
Check `kubectl -n jobbot get pods` — `postgres-0` must be `1/1 Running`, then `kubectl -n jobbot describe pod postgres-0`.

**One source keeps failing (`<source>/<board> failed: HTTP Error 404`)**
The company moved or closed its job board: remove it from `BOARDS` in `app/sources.py`.

## Database

```bash
make psql
```
```sql
select source, count(*) from jobs group by source;
select title, company, published_at from jobs order by published_at desc limit 20;
```
