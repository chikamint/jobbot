"""Job sources. Each fetcher takes one board/query and yields Job objects.

Only official APIs, RSS feeds and pages allowed by robots.txt are used.
Sources that require attribution are credited in the Telegram message (SOURCE_NAMES)."""
import html
import json
import os
import re
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime


@dataclass
class Job:
    source: str
    company: str
    title: str
    location: str
    url: str
    published: datetime


SOURCE_NAMES = {
    "himalayas": "Himalayas", "greenhouse": "Greenhouse", "ashby": "Ashby", "lever": "Lever",
    "remoteok": "Remote OK", "remotive": "Remotive", "jobicy": "Jobicy", "wwr": "We Work Remotely",
    "habr": "Хабр Карьера", "hh": "hh.ru", "jobsge": "jobs.ge", "telegram": "Telegram",
}

# What to query. Edit these lists to tune the channel.
BOARDS = (
    [("himalayas", q) for q in ["devops", "linux", "sre", "system administrator", "support engineer", "noc"]]
    + [("greenhouse", c) for c in ["canonical", "gitlab", "nebius", "wheely", "jetbrains"]]
    + [("ashby", c) for c in ["constructor", "GR8-TECH"]]
    + [("lever", c) for c in ["xsolla"]]
    + [("remoteok", t) for t in ["devops", "sysadmin"]]
    + [("remotive", "devops")]
    + [("jobicy", t) for t in ["devops", "linux", "sre"]]
    + [("wwr", "remote-devops-sysadmin-jobs")]
    + [("habr", q) for q in ["devops", "linux", "sre", "системный администратор"]]
    + [("hh", q) for q in ["devops", "linux", "sre", "системный администратор"]]
    + [("jobsge", q) for q in ["devops", "linux", "system administrator", "sre"]]
    + [("telegram", ch) for ch in ["devops_jobs_feed", "Job_DevOps", "sysadmin_jobs", "remote_it_jobs",
                                   "opento_igaming", "iGaming_work", "iGamingoffice"]]
)

# Sources whose results are already limited to Georgia / remote-from-anywhere / RU-speaking market.
# Global boards are additionally filtered by location in jobbot.collect().
GEO_PREFILTERED = {"himalayas", "hh", "habr", "jobsge", "telegram"}

UA = "jobbot/1.0 (+https://github.com/chikamint/jobbot)"
MONTHS = {m: i for i, m in enumerate(["january", "february", "march", "april", "may", "june", "july", "august",
                                      "september", "october", "november", "december"], 1)}


def fetch(url: str, headers: dict | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.read()


def fetch_json(url: str, headers: dict | None = None):
    return json.loads(fetch(url, headers))


def iso(value: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def clean(text: str) -> str:
    text = re.sub(r"<br\s*/?>", " ", text)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", text))).strip()


def q(value: str) -> str:
    return urllib.parse.quote(value)


# --- company boards and global remote boards (JSON APIs) ---

def himalayas(query):
    data = fetch_json(f"https://himalayas.app/jobs/api/search?country=Georgia&sort=recent&q={q(query)}")
    for j in data.get("jobs", []):
        if re.search("senior|manager|director|executive", ",".join(j.get("seniority") or []), re.I):
            continue
        yield Job("himalayas", j["companyName"], j["title"], "Remote (Georgia OK)",
                  j["applicationLink"], datetime.fromtimestamp(j["pubDate"], timezone.utc))


def greenhouse(company):
    for j in fetch_json(f"https://boards-api.greenhouse.io/v1/boards/{company}/jobs")["jobs"]:
        yield Job("greenhouse", company, j["title"], j["location"]["name"], j["absolute_url"], iso(j["updated_at"]))


def ashby(company):
    for j in fetch_json(f"https://api.ashbyhq.com/posting-api/job-board/{company}")["jobs"]:
        yield Job("ashby", company, j["title"], j.get("location") or "", j["jobUrl"], iso(j["publishedAt"]))


def lever(company):
    for j in fetch_json(f"https://api.lever.co/v0/postings/{company}?mode=json"):
        yield Job("lever", company, j["text"], j["categories"].get("location") or "", j["hostedUrl"],
                  datetime.fromtimestamp(j["createdAt"] / 1000, timezone.utc))


def remoteok(tag):
    for j in fetch_json(f"https://remoteok.com/api?tag={q(tag)}")[1:]:  # [0] is the legal notice
        # ToS: link to the Remote OK page (url), not directly to apply_url
        yield Job("remoteok", j["company"], j["position"], j.get("location") or "", j["url"], iso(j["date"]))


def remotive(category):
    for j in fetch_json(f"https://remotive.com/api/remote-jobs?category={q(category)}")["jobs"]:
        yield Job("remotive", j["company_name"], j["title"], j.get("candidate_required_location") or "",
                  j["url"], iso(j["publication_date"]))


def jobicy(tag):
    for j in fetch_json(f"https://jobicy.com/api/v2/remote-jobs?count=50&tag={q(tag)}").get("jobs", []):
        yield Job("jobicy", j["companyName"], j["jobTitle"], j.get("jobGeo") or "", j["url"],
                  iso(j["pubDate"].replace(" ", "T")))


# --- RSS feeds ---

def wwr(category):
    root = ET.fromstring(fetch(f"https://weworkremotely.com/categories/{category}.rss"))
    for item in root.iter("item"):
        company, _, title = (item.findtext("title") or "").partition(": ")
        yield Job("wwr", company, title or company, item.findtext("region") or "", item.findtext("link"),
                  parsedate_to_datetime(item.findtext("pubDate")))


def habr(query):
    root = ET.fromstring(fetch(f"https://career.habr.com/vacancies/rss?type=all&remote=true&q={q(query)}"))
    for item in root.iter("item"):
        # "Требуется «DevOps» (от 240 000 ₽)" -> "DevOps (от 240 000 ₽)"
        title = re.sub(r"^Требуется «(.*?)»", r"\1", item.findtext("title") or "")
        yield Job("habr", item.findtext("author") or "", title, "Удалённо", item.findtext("link"),
                  parsedate_to_datetime(item.findtext("pubDate")))


# --- hh.ru: official API, needs an application token from dev.hh.ru ---

def hh(query):
    token = os.environ.get("HH_TOKEN", "")
    if not token:
        return  # source disabled until the token is configured
    params = urllib.parse.urlencode({"text": query, "search_field": "name", "work_format": "REMOTE",
                                     "period": 2, "per_page": 50, "order_by": "publication_time"})
    data = fetch_json(f"https://api.hh.ru/vacancies?{params}",
                      {"Authorization": f"Bearer {token}", "HH-User-Agent": UA})
    for j in data["items"]:
        yield Job("hh", (j.get("employer") or {}).get("name") or "", j["name"], "Удалённо",
                  j["alternate_url"], iso(j["published_at"]))


# --- HTML pages (allowed by robots.txt) ---

def jobsge(query):
    page = fetch(f"https://jobs.ge/en/?q={q(query)}").decode("utf-8", "replace")
    now = datetime.now(timezone.utc)
    for row in re.findall(r"<tr>(.*?)</tr>", page, re.S):
        link = re.search(r'href="(/en/\?view=jobs&id=\d+)"[^>]*>([^<]+)</a>', row)
        cells = re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)
        if not link or len(cells) < 5:
            continue
        day, month = (clean(cells[4]).split() + ["", ""])[:2]
        if month.lower() not in MONTHS:
            continue
        published = datetime(now.year, MONTHS[month.lower()], int(day), tzinfo=timezone.utc)
        if published > now:  # "22 December" seen in January belongs to last year
            published = published.replace(year=now.year - 1)
        yield Job("jobsge", clean(cells[3]), clean(link.group(2)), "Georgia",
                  "https://jobs.ge" + html.unescape(link.group(1)), published)
    time.sleep(5)  # robots.txt: Crawl-delay 5


def telegram(channel):
    page = fetch(f"https://t.me/s/{channel}").decode("utf-8", "replace")
    for post in page.split("tgme_widget_message_wrap")[1:]:
        post_id = re.search(r'data-post="([^"]+)"', post)
        date = re.search(r'datetime="([^"]+)"', post)
        text = re.search(r'tgme_widget_message_text[^>]*>(.*?)</div>', post, re.S)
        if not (post_id and date and text):
            continue
        body = clean(text.group(1))
        if re.search(r"#резюме|#cv\b|ищу работу", body, re.I):
            continue
        # drop channel boilerplate and hashtags, keep the vacancy text
        body = re.sub(r"Публикатор:.*?Обсуждение:\s*@\w+|#\w+", " ", body)
        body = re.sub(r"\s+", " ", body).strip(" |·-")
        # we publish only a short excerpt and a link to the original post
        yield Job("telegram", f"@{channel}", body[:150], "", f"https://t.me/{post_id.group(1)}", iso(date.group(1)))


FETCHERS = {"himalayas": himalayas, "greenhouse": greenhouse, "ashby": ashby, "lever": lever,
            "remoteok": remoteok, "remotive": remotive, "jobicy": jobicy, "wwr": wwr,
            "habr": habr, "hh": hh, "jobsge": jobsge, "telegram": telegram}
