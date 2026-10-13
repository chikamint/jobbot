from datetime import datetime, timezone

import jobbot
import sources
from sources import Job

NEW = datetime.now(timezone.utc)
OLD = datetime(2020, 1, 1, tzinfo=timezone.utc)
SINCE = datetime(2025, 1, 1, tzinfo=timezone.utc)


def test_suitable_roles():
    assert jobbot.suitable("Junior DevOps Engineer")
    assert jobbot.suitable("Linux System Administrator")
    assert jobbot.suitable("Site Reliability Engineer (SRE)")
    assert jobbot.suitable("Системный администратор Linux")
    assert jobbot.suitable("Инженер технической поддержки")
    assert not jobbot.suitable("Senior DevOps Engineer")
    assert not jobbot.suitable("Ведущий DevOps-инженер")
    assert not jobbot.suitable("Backend Developer")
    assert not jobbot.suitable("Software Engineer - Data Infrastructure")
    assert not jobbot.suitable("Системный администратор Windows")


def test_location_filter_only_for_global_boards():
    assert jobbot.relevant(Job("greenhouse", "a", "DevOps Engineer", "Remote - EMEA", "u", NEW), SINCE)
    assert not jobbot.relevant(Job("greenhouse", "a", "DevOps Engineer", "Bangalore, India", "u", NEW), SINCE)
    assert jobbot.relevant(Job("habr", "a", "DevOps Engineer", "Удалённо", "u", NEW), SINCE)
    assert not jobbot.relevant(Job("habr", "a", "DevOps Engineer", "Удалённо", "u", OLD), SINCE)


def test_collect_survives_broken_source(monkeypatch):
    def good(board):
        yield Job("habr", board, "DevOps Engineer", "", "https://a/1", NEW)

    def broken(board):
        raise TimeoutError("api down")
        yield

    monkeypatch.setattr(sources, "FETCHERS", {"good": good, "broken": broken})
    monkeypatch.setattr(sources, "BOARDS", [("broken", "x"), ("good", "acme")])
    assert [j.url for j in jobbot.collect(SINCE)] == ["https://a/1"]


def test_habr_rss(monkeypatch):
    rss = b"""<?xml version="1.0"?><rss><channel><item>
      <title>\xd0\xa2\xd1\x80\xd0\xb5\xd0\xb1\xd1\x83\xd0\xb5\xd1\x82\xd1\x81\xd1\x8f \xc2\xabDevOps Engineer\xc2\xbb (200 000)</title>
      <author>Acme</author><pubDate>Wed, 07 Oct 2026 10:21:54 +0300</pubDate>
      <link>https://career.habr.com/vacancies/1</link></item></channel></rss>"""
    monkeypatch.setattr(sources, "fetch", lambda url, headers=None: rss)
    [job] = sources.habr("devops")
    assert (job.title, job.company, job.url) == ("DevOps Engineer (200 000)", "Acme", "https://career.habr.com/vacancies/1")
    assert job.published.utcoffset() is not None


def test_telegram_skips_resumes(monkeypatch):
    page = ('<div class="tgme_widget_message_wrap"><div data-post="ch/1"><time datetime="2026-10-10T10:00:00+00:00">'
            '<div class="tgme_widget_message_text">#вакансия DevOps Engineer<br/>remote</div></div>'
            '<div class="tgme_widget_message_wrap"><div data-post="ch/2"><time datetime="2026-10-10T11:00:00+00:00">'
            '<div class="tgme_widget_message_text">#резюме DevOps ищу работу</div></div>')
    monkeypatch.setattr(sources, "fetch", lambda url, headers=None: page.encode())
    jobs = list(sources.telegram("ch"))
    assert [j.url for j in jobs] == ["https://t.me/ch/1"]
    assert jobs[0].title == "DevOps Engineer remote"


def test_hh_disabled_without_token(monkeypatch):
    monkeypatch.delenv("HH_TOKEN", raising=False)
    assert list(sources.hh("devops")) == []


def test_message_credits_source():
    msg = jobbot.format_message("remoteok", "Acme", "DevOps Engineer", "Worldwide", "https://remoteok.com/x")
    assert msg.endswith("via Remote OK")
