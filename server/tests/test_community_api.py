"""공유 허브 API 기본 흐름 테스트 (게시·목록·검색·상세·삭제, 비노출, 정렬, CORS)."""

from __future__ import annotations

import hashlib
import json
import unicodedata

from sqlalchemy import select

from app import community as community_mod
from app.models import CommunityTrack

URL = "/api/community/tracks"
PROD_ORIGIN = "https://overlock.bnbong.com"


def _post(client, payload, **kwargs):
    return client.post(URL, json=payload, **kwargs)


def _publish(client, make_community_payload, **overrides) -> dict:
    resp = _post(client, make_community_payload(**overrides))
    assert resp.status_code == 201, resp.text
    return resp.json()


# ---------------------------------------------------------------------------
# 게시
# ---------------------------------------------------------------------------
def test_publish_returns_id_token_and_normalized_track(client, make_community_payload):
    payload = make_community_payload(title="  Sine   Wave  ", author_name=" bob ", description="첫 줄\r\n둘째  줄")
    payload["track"].update(
        {
            "track_id": "custom_deadbeef",
            "name": "로컬 이름",
            "is_custom": True,
            "editor_version": "0.1.0",
            "checksum": "sha256:" + "0" * 64,
            "length": 99999,
        }
    )
    resp = _post(client, payload)
    assert resp.status_code == 201, resp.text
    assert resp.headers.get("cache-control") == "no-store"
    body = resp.json()

    assert set(body) == {
        "id",
        "title",
        "author_name",
        "description",
        "difficulty",
        "fabric",
        "length",
        "created_at",
        "content_hash",
        "track",
        "delete_token",
    }
    assert len(body["id"]) == 36
    assert len(body["delete_token"]) >= 43
    assert body["title"] == "Sine Wave"
    assert body["author_name"] == "bob"
    assert body["description"] == "첫 줄\n둘째 줄"
    assert body["content_hash"].startswith("sha256:") and len(body["content_hash"]) == 71

    track = body["track"]
    # 클라이언트 로컬 메타는 제거·재계산된다.
    assert set(track) == {
        "name",
        "difficulty",
        "fabric",
        "width",
        "path",
        "items",
        "modifiers",
        "length",
        "editor_version",
    }
    assert track["name"] == "Sine Wave"
    assert track["length"] == body["length"] != 99999
    assert track["path"][0]["type"] == "polyline"
    assert track["modifiers"] == []


def test_detail_matches_publish_without_token(client, make_community_payload):
    created = _publish(client, make_community_payload)
    resp = client.get(f"{URL}/{created['id']}")
    assert resp.status_code == 200
    detail = resp.json()
    assert "delete_token" not in detail
    expected = {k: v for k, v in created.items() if k != "delete_token"}
    assert detail == expected


def test_detail_unknown_id_404(client):
    resp = client.get(f"{URL}/00000000-0000-0000-0000-000000000000")
    assert resp.status_code == 404
    assert isinstance(resp.json()["detail"], str)
    assert client.get(f"{URL}/{'x' * 500}").status_code == 404


# ---------------------------------------------------------------------------
# 목록·검색·페이지네이션
# ---------------------------------------------------------------------------
def test_list_items_only_summary_fields(client, make_community_payload):
    _publish(client, make_community_payload, title="Alpha")
    resp = client.get(URL)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1 and body["limit"] == 20 and body["offset"] == 0 and body["q"] == ""
    assert set(body["items"][0]) == {
        "id",
        "title",
        "author_name",
        "difficulty",
        "fabric",
        "length",
        "created_at",
    }


def test_list_newest_first(client, make_community_payload):
    ids = [_publish(client, make_community_payload, title=f"T{i}")["id"] for i in range(3)]
    items = client.get(URL).json()["items"]
    assert [it["id"] for it in items] == list(reversed(ids))


def test_list_stable_order_on_equal_created_at(client, make_community_payload, monkeypatch):
    monkeypatch.setattr(community_mod, "_now_iso", lambda: "2026-09-30T00:00:00.000000+00:00")
    ids = [_publish(client, make_community_payload, title=f"Same{i}")["id"] for i in range(6)]
    expected = sorted(ids, reverse=True)  # created_at 동률 → id 내림차순
    page1 = client.get(URL, params={"limit": 3}).json()["items"]
    page2 = client.get(URL, params={"limit": 3, "offset": 3}).json()["items"]
    assert [it["id"] for it in page1 + page2] == expected
    # 반복 조회해도 순서가 같다.
    again = client.get(URL, params={"limit": 6}).json()["items"]
    assert [it["id"] for it in again] == expected


def test_pagination_total(client, make_community_payload):
    for i in range(5):
        _publish(client, make_community_payload, title=f"P{i}")
    r = client.get(URL, params={"limit": 2, "offset": 0}).json()
    assert r["total"] == 5 and len(r["items"]) == 2
    r = client.get(URL, params={"limit": 2, "offset": 4}).json()
    assert r["total"] == 5 and len(r["items"]) == 1
    r = client.get(URL, params={"limit": 2, "offset": 10}).json()
    assert r["total"] == 5 and r["items"] == []


def test_list_limit_bounds(client):
    assert client.get(URL, params={"limit": 50}).status_code == 200
    assert client.get(URL, params={"limit": 51}).status_code == 422
    assert client.get(URL, params={"limit": 0}).status_code == 422
    assert client.get(URL, params={"offset": -1}).status_code == 422


def test_search_empty_result(client, make_community_payload):
    _publish(client, make_community_payload, title="Heart")
    r = client.get(URL, params={"q": "zzz-not-there"}).json()
    assert r == {"total": 0, "limit": 20, "offset": 0, "q": "zzz-not-there", "items": []}


def test_search_special_characters(client, make_community_payload):
    titles = ["100% 면", "a_b", "axb", "back\\slash", "O'Brien", "하트 트랙", "Plain"]
    for t in titles:
        _publish(client, make_community_payload, title=t)

    def titles_for(q: str) -> list[str]:
        resp = client.get(URL, params={"q": q})
        assert resp.status_code == 200, resp.text
        return sorted(it["title"] for it in resp.json()["items"])

    assert titles_for("%") == ["100% 면"]  # % 는 와일드카드가 아니라 리터럴
    assert titles_for("_") == ["a_b"]  # _ 가 'axb' 와 매칭되면 안 된다
    assert titles_for("\\") == ["back\\slash"]
    assert titles_for("'") == ["O'Brien"]
    assert titles_for("o'b") == ["O'Brien"]  # ASCII 대소문자 무시
    assert titles_for("하트") == ["하트 트랙"]
    assert titles_for(unicodedata.normalize("NFD", "하트")) == ["하트 트랙"]  # NFC 정규화
    assert titles_for("  하트   트랙 ") == ["하트 트랙"]  # 공백 정리
    assert titles_for("'; DROP TABLE community_tracks; --") == []
    assert client.get(URL).json()["total"] == len(titles)


def test_search_query_length_limit(client):
    assert client.get(URL, params={"q": "가" * 80}).status_code == 200
    resp = client.get(URL, params={"q": "가" * 81})
    assert resp.status_code == 422
    assert isinstance(resp.json()["detail"], list)


# ---------------------------------------------------------------------------
# 삭제
# ---------------------------------------------------------------------------
def test_delete_flow(client, make_community_payload):
    created = _publish(client, make_community_payload, title="ToDelete")
    keep = _publish(client, make_community_payload, title="Keep")
    url = f"{URL}/{created['id']}"

    # 토큰 없음 / 형식 오류 → 401
    r = client.delete(url)
    assert r.status_code == 401
    assert r.headers.get("www-authenticate") == "Bearer"
    assert client.delete(url, headers={"Authorization": "Basic abc"}).status_code == 401
    assert client.delete(url, headers={"Authorization": "Bearer "}).status_code == 401
    assert client.delete(url, headers={"Authorization": "Bearer " + "a" * 300}).status_code == 401

    # 틀린 토큰 / 다른 게시물의 토큰 → 403
    assert client.delete(url, headers={"Authorization": "Bearer wrong"}).status_code == 403
    r = client.delete(url, headers={"Authorization": f"Bearer {keep['delete_token']}"})
    assert r.status_code == 403

    # 올바른 토큰 → 204, 이후 조회·목록에서 사라진다.
    r = client.delete(url, headers={"Authorization": f"Bearer {created['delete_token']}"})
    assert r.status_code == 204
    assert r.content == b""
    assert client.get(url).status_code == 404
    listing = client.get(URL).json()
    assert listing["total"] == 1
    assert [it["id"] for it in listing["items"]] == [keep["id"]]
    assert client.get(URL, params={"q": "ToDelete"}).json()["total"] == 0

    # 이미 삭제됨 → 404(토큰이 맞아도)
    r = client.delete(url, headers={"Authorization": f"Bearer {created['delete_token']}"})
    assert r.status_code == 404


def test_delete_unknown_id_404(client):
    r = client.delete(
        f"{URL}/00000000-0000-0000-0000-000000000000",
        headers={"Authorization": "Bearer something"},
    )
    assert r.status_code == 404


def test_bearer_scheme_case_insensitive(client, make_community_payload):
    created = _publish(client, make_community_payload)
    r = client.delete(
        f"{URL}/{created['id']}", headers={"Authorization": f"bearer {created['delete_token']}"}
    )
    assert r.status_code == 204


# ---------------------------------------------------------------------------
# 토큰·해시·IP 비노출
# ---------------------------------------------------------------------------
def test_token_hash_and_ip_never_exposed(make_client, make_community_payload):
    client = make_client(trust_forwarded_for=True, trusted_proxy_hops=1)
    ip = "203.0.113.77"
    headers = {"X-Forwarded-For": ip}
    created = client.post(URL, json=make_community_payload(), headers=headers).json()
    token = created["delete_token"]
    token_hash = hashlib.sha256(token.encode()).hexdigest()

    texts = [
        client.get(URL, headers=headers).text,
        client.get(URL, params={"q": "My"}, headers=headers).text,
        client.get(f"{URL}/{created['id']}", headers=headers).text,
    ]
    for text in texts:
        assert token not in text
        assert token_hash not in text
        assert "delete_token" not in text
        assert ip not in text
        assert "testclient" not in text
    created_text = json.dumps(created)
    assert token_hash not in created_text and ip not in created_text

    # DB 에는 원문 토큰이 아니라 SHA-256 만 저장된다.
    with client.app.state.sessionmaker() as session:
        row = session.scalars(select(CommunityTrack)).one()
        assert row.delete_token_hash == token_hash
        for value in vars(row).values():
            if isinstance(value, str):
                assert token not in value
                assert ip not in value


# ---------------------------------------------------------------------------
# content_hash
# ---------------------------------------------------------------------------
def test_content_hash_covers_play_data_only(client, make_community_payload):
    base = _publish(client, make_community_payload, title="A", author_name="x")
    other_meta = _publish(client, make_community_payload, title="B", author_name="y", description="d")
    assert base["content_hash"] == other_meta["content_hash"]

    p = make_community_payload()
    p["track"]["width"] = {"perfect": 18.0, "safe": 42.0, "fail": 90.0}  # int ↔ float 동일
    assert _post(client, p).json()["content_hash"] == base["content_hash"]

    p = make_community_payload()
    p["track"]["width"] = {"perfect": 18, "safe": 42, "fail": 91}
    assert _post(client, p).json()["content_hash"] != base["content_hash"]

    p = make_community_payload()
    p["track"]["fabric"] = "denim"
    assert _post(client, p).json()["content_hash"] != base["content_hash"]

    p = make_community_payload()
    p["track"]["difficulty"] = "expert"
    assert _post(client, p).json()["content_hash"] != base["content_hash"]

    items = [
        {"s": 500, "type": "thimble", "lat": 0},
        {"s": 100, "type": "autopilot", "lat": 5},
    ]
    p1 = make_community_payload()
    p1["track"]["items"] = items
    p2 = make_community_payload()
    p2["track"]["items"] = list(reversed(items))
    h1 = _post(client, p1).json()
    h2 = _post(client, p2).json()
    assert h1["content_hash"] == h2["content_hash"] != base["content_hash"]
    assert [it["s"] for it in h1["track"]["items"]] == [100.0, 500.0]


def test_duplicate_content_gets_new_post(client, make_community_payload):
    a = _publish(client, make_community_payload)
    b = _publish(client, make_community_payload)
    assert a["id"] != b["id"] and a["delete_token"] != b["delete_token"]
    assert a["content_hash"] == b["content_hash"]


# ---------------------------------------------------------------------------
# CORS (웹 export 에서 DELETE + Authorization 사용)
# ---------------------------------------------------------------------------
def test_cors_preflight_allows_delete_with_authorization(make_client):
    client = make_client(cors_origins=PROD_ORIGIN)
    resp = client.options(
        f"{URL}/some-id",
        headers={
            "Origin": PROD_ORIGIN,
            "Access-Control-Request-Method": "DELETE",
            "Access-Control-Request-Headers": "authorization",
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.headers.get("access-control-allow-origin") == PROD_ORIGIN
    assert "DELETE" in resp.headers.get("access-control-allow-methods", "")
    assert "authorization" in resp.headers.get("access-control-allow-headers", "").lower()


def test_cors_preflight_post_json_from_itch(make_client):
    client = make_client(cors_origins=PROD_ORIGIN)
    origin = "https://html-classic.itch.zone"
    resp = client.options(
        URL,
        headers={
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )
    assert resp.status_code == 200
    assert resp.headers.get("access-control-allow-origin") == origin


def test_cors_default_settings_values():
    from app.config import Settings

    s = Settings()
    assert s.cors_method_list() == ["GET", "POST", "DELETE"]
    assert s.cors_header_list() == ["Content-Type", "Accept", "Authorization"]
