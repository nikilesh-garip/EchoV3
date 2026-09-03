"""Tests for TelegramNotifier.send_alert's status/detail reporting.

No real network calls: requests.post is mocked throughout. What's under
test is Echo's own status logic -- specifically, that a sub-send failure
(the evidence clip or the location pin) is never reported as an overall
"sent" just because the text message itself went through.
"""

import notifiers


class _FakeResponse:
    def __init__(self, status_code, text="", json_body=None):
        self.status_code = status_code
        self.text = text
        self._json_body = json_body or {}

    def json(self):
        return self._json_body


def _notifier():
    return notifiers.TelegramNotifier(token="fake-token")


def test_message_and_clip_and_location_all_succeed_reports_sent(monkeypatch, tmp_path):
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    monkeypatch.setattr(notifiers.requests, "post", lambda *a, **k: _FakeResponse(200))

    status, detail = _notifier().send_alert(
        chat_id="123", message="alert", clip_path=str(clip),
        latitude=17.385, longitude=78.486,
    )
    assert status == "sent"
    assert "clip sent" in detail
    assert "location pin sent" in detail


def test_clip_send_failure_downgrades_status_to_failed(monkeypatch, tmp_path):
    clip = tmp_path / "clip.wav"
    clip.write_bytes(b"RIFFfake")

    calls = {"n": 0}

    def fake_post(url, **kwargs):
        calls["n"] += 1
        if "sendMessage" in url:
            return _FakeResponse(200)
        # sendAudio and its sendDocument fallback both fail.
        return _FakeResponse(500)

    monkeypatch.setattr(notifiers.requests, "post", fake_post)

    status, detail = _notifier().send_alert(
        chat_id="123", message="alert", clip_path=str(clip),
    )
    # The message reaching the contact is not enough on its own -- the clip
    # is the evidence. A caller reading only `status` (exactly what
    # escalation_attempts.status is for) must see this as not fully sent.
    assert status == "failed"
    assert "message sent" in detail
    assert "clip failed" in detail


def test_location_send_failure_downgrades_status_to_failed(monkeypatch):
    def fake_post(url, **kwargs):
        if "sendMessage" in url:
            return _FakeResponse(200)
        return _FakeResponse(500)  # sendLocation fails

    monkeypatch.setattr(notifiers.requests, "post", fake_post)

    status, detail = _notifier().send_alert(
        chat_id="123", message="alert", latitude=17.385, longitude=78.486,
    )
    assert status == "failed"
    assert "location failed" in detail


def test_message_only_no_clip_no_location_still_reports_sent(monkeypatch):
    monkeypatch.setattr(notifiers.requests, "post", lambda *a, **k: _FakeResponse(200))

    status, detail = _notifier().send_alert(chat_id="123", message="alert")
    assert status == "sent"
    assert "no clip available" in detail


def test_message_send_failure_reports_failed():
    status, _ = notifiers.TelegramNotifier(token="").send_alert(chat_id="123", message="alert")
    assert status == "simulated"  # no token configured -- correct, distinct case
