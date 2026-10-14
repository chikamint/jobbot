"""jobbot: collects junior/middle DevOps & Linux vacancies from job boards,
stores them in PostgreSQL and posts new ones to a Telegram channel."""
import logging
import os
import re
import signal
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import psycopg
from prometheus_client import Counter, Gauge, start_http_server

import sources
from sources import Job

log = logging.getLogger("jobbot")

ROLE = re.compile(r"linux|devops|девопс|\bsre\b|reliab|system admin|sysadmin|системн\w* (админ|инженер)|"
                  r"администратор|infra|инфраструктур|platform|support engineer|technical support|"
                  r"инженер\w* (\w+ )?поддержк|cloud|operations eng|\bnoc\b|network eng|сетев\w* инженер", re.I)
BAD = re.compile(r"senior|\bsr\.|head|director|manager|principal|staff|architect|\blead\b|developer|"
                 r"software engineer|quality assurance|\bqa\b|sales|account|recruit|marketing|data eng|"
                 r"machine learning|distinguished|\bcto\b|field|старш|ведущ|руководител|тимлид|"
                 r"разработчик|1с|1c|windows", re.I)
# global boards: keep locations reachable from Georgia
LOCATION = re.compile(r"worldwide|anywhere|global|emea|europe|georgia|tbilisi|armenia|yerevan|cyprus|"
                      r"serbia|belgrade|kazakhstan|almaty|^remote$", re.I)

JOBS_NEW = Counter("jobbot_jobs_new_total", "New vacancies saved", ["source"])
JOBS_POSTED = Counter("jobbot_jobs_posted_total", "Vacancies posted to Telegram")
SOURCE_ERRORS = Counter("jobbot_source_errors_total", "Failed source requests", ["source"])
RUN_FAILURES = Counter("jobbot_run_failures_total", "Collection runs that failed")
LAST_SUCCESS = Gauge("jobbot_last_success_timestamp_seconds", "Unix time of last successful run")

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    url          text PRIMARY KEY,
    source       text NOT NULL,
    company      text NOT NULL,
    title        text NOT NULL,
    location     text NOT NULL,
    published_at timestamptz NOT NULL,
    posted_at    timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
)"""


def suitable(title: str) -> bool:
    return bool(ROLE.search(title)) and not BAD.search(title)


def relevant(job: Job, since: datetime) -> bool:
    return (job.published >= since and suitable(job.title)
            and (job.source in sources.GEO_PREFILTERED or bool(LOCATION.search(job.location))))


def collect(since: datetime) -> list[Job]:
    found = {}
    for source, board in sources.BOARDS:
        try:
            for job in sources.FETCHERS[source](board):
                if relevant(job, since):
                    found[job.url] = job
        except Exception as e:  # one broken board must not stop the others
            SOURCE_ERRORS.labels(source).inc()
            log.warning("%s/%s failed: %s", source, board, e)
    return list(found.values())


def format_message(source: str, company: str, title: str, location: str, url: str) -> str:
    where = " · ".join(x for x in (company, location) if x)
    return f"{title}\n{where}\n{url}\nvia {sources.SOURCE_NAMES.get(source, source)}"


def send_telegram(token: str, chat_id: str, text: str) -> None:
    body = urllib.parse.urlencode({"chat_id": chat_id, "text": text,
                                   "disable_web_page_preview": "true"}).encode()
    urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", body, timeout=15).close()


def run_once(token: str, chat_id: str, lookback_hours: int) -> None:
    jobs = collect(datetime.now(timezone.utc) - timedelta(hours=lookback_hours))
    # empty conninfo: libpq reads PGHOST/PGUSER/PGPASSWORD/PGDATABASE from env
    with psycopg.connect(os.environ.get("DATABASE_URL", "")) as conn:
        conn.execute(SCHEMA)  # shortcut: no migrations tool, add one when the schema changes
        for j in jobs:
            cur = conn.execute(
                "INSERT INTO jobs (url, source, company, title, location, published_at) "
                "VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT (url) DO NOTHING",
                (j.url, j.source, j.company, j.title, j.location, j.published))
            if cur.rowcount:
                JOBS_NEW.labels(j.source).inc()
        conn.commit()

        pending = conn.execute(
            "SELECT url, source, company, title, location FROM jobs WHERE posted_at IS NULL "
            "ORDER BY published_at LIMIT 20").fetchall()
        if not token:
            log.info("dry-run: %d vacancies waiting, TELEGRAM_BOT_TOKEN not set", len(pending))
        for url, source, company, title, location in pending if token else []:
            send_telegram(token, chat_id, format_message(source, company, title, location, url))
            conn.execute("UPDATE jobs SET posted_at = now() WHERE url = %s", (url,))
            conn.commit()  # commit per message: a crash re-posts at most the one in-flight message
            JOBS_POSTED.inc()
            time.sleep(3)  # Telegram allows ~20 messages/min per channel
    LAST_SUCCESS.set_to_current_time()
    log.info("run ok: %d matching vacancies, %d pending", len(jobs), len(pending))


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    # We run as PID 1 in the container: the kernel ignores SIGTERM for PID 1 unless a handler is set,
    # so without this Kubernetes waits 30 s and then SIGKILLs us on every restart/deploy.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
    interval = int(os.environ.get("INTERVAL_MINUTES", "60"))
    lookback = int(os.environ.get("LOOKBACK_HOURS", "48"))
    start_http_server(int(os.environ.get("METRICS_PORT", "8000")))
    while True:
        try:
            run_once(token, chat_id, lookback)
        except Exception:
            RUN_FAILURES.inc()
            log.exception("run failed")
        time.sleep(interval * 60)


if __name__ == "__main__":
    main()
