# Overlock 리더보드 서버

재봉 레이싱 게임 **Overlock** 의 기록 저장·조회 API 서버입니다.

개발자 [bnbong](https://github.com/bnbong)의 개인 서버에서 운영되며 트랙별 Top 100 리더보드를 제공합니다.

- 스택: Python 3.11+ · FastAPI · SQLAlchemy 2.0 · SQLite (→ PostgreSQL 여지)
- 기록 등급: 현재는 `unverified` 만 운영합니다. 리플레이 재시뮬레이션 기반 `verified`·`official` 등급은 이후 확장으로 고려중입니다.

---

## 빠른 시작 (로컬)

```bash
cd server

# 1) 가상환경 + 의존성 (pip)
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

#    또는 uv 사용 (pyproject.toml 호환)
#    uv venv && uv pip install -r requirements.txt

# 2) 개발 서버 기동 (자동 리로드)
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

기동하면 서버가 `server/app/tracks/` 스냅샷의 공식 트랙 5종을 DB에 시드합니다.

브라우저에서 `http://127.0.0.1:8000/docs` 를 열어 API 문서를 볼 수 있습니다.

```bash
# 동작 확인
curl http://127.0.0.1:8000/api/health
curl http://127.0.0.1:8000/api/tracks
```

---

## 설정 (환경변수)

모든 설정은 `OVERLOCK_` 접두 환경변수로 덮어씁니다(`server/.env` 파일 운용 가능).

| 변수 | 기본값 | 설명 |
|---|---|---|
| `OVERLOCK_DB_URL` | `sqlite:///<server>/overlock.db` | SQLAlchemy DB URL. PostgreSQL 전환 시 변경할 것. |
| `OVERLOCK_HOST` | `0.0.0.0` | 바인드 호스트 (uvicorn 실행 시 `--host` 로도 지정 가능). |
| `OVERLOCK_PORT` | `8000` | 포트. |
| `OVERLOCK_CORS_ORIGINS` | `*` | 허용 오리진(쉼표 구분). `*` 는 전체 허용. 예) `https://overlock.example.com`. |
| `OVERLOCK_RATE_LIMIT_PER_MINUTE` | `60` | IP당 분당 기록 제출 허용 횟수(인메모리). `0` 이면 제한 해제. |
| `OVERLOCK_TRUST_FORWARDED_FOR` | `false` | 리버스 프록시 뒤라서 `X-Forwarded-For` 의 실제 IP를 써야 하면 `true`. |
| `OVERLOCK_TRACKS_DIR` | `server/app/tracks` | 공식 트랙 스냅샷 디렉토리. |
| `OVERLOCK_MAX_SPEED_PX_S` | `300` | 물리 하한 계산용 최고 속도(px/s). |
| `OVERLOCK_CORS_ALLOW_METHODS` | `GET,POST,DELETE` | CORS 허용 메서드. 공유 허브 삭제가 `DELETE` 를 씁니다. |
| `OVERLOCK_CORS_ALLOW_HEADERS` | `Content-Type,Accept,Authorization` | CORS 허용 요청 헤더. 공유 허브 삭제가 `Authorization` 헤더를 씁니다. |
| `OVERLOCK_MAX_BODY_BYTES` | `16384` | 공유 허브를 제외한 경로의 요청 본문 상한(선언된 Content-Length 기준). |
| `OVERLOCK_COMMUNITY_MAX_BODY_BYTES` | `1048576` | 공유 허브(`/api/community/`) 요청 본문 상한. 실제 수신 바이트를 셉니다. |
| `OVERLOCK_COMMUNITY_POST_PER_MINUTE` | `3` | 공유 허브 게시의 IP당 분당 허용 횟수. `0` 이면 해제합니다. |
| `OVERLOCK_COMMUNITY_POST_PER_DAY` | `30` | 공유 허브 게시의 IP당 24시간 허용 횟수. `0` 이면 해제합니다. |
| `OVERLOCK_COMMUNITY_READ_PER_MINUTE` | `120` | 공유 허브 목록·상세 조회의 IP당 분당 허용 횟수. |
| `OVERLOCK_COMMUNITY_DELETE_PER_MINUTE` | `10` | 공유 허브 삭제 요청의 IP당 분당 허용 횟수(삭제 토큰 추측 방어). |

> `OVERLOCK_TRUST_FORWARDED_FOR=true` 는 신뢰할 수 있는 프록시(nginx 등) 뒤에서만 켜야합니다(클라이언트가 헤더를 위조해 레이트리밋을 우회하는 것 방지).

> **셀프호스팅 시 클라이언트 연결**: 게임 UI 에는 서버 URL 입력이 없습니다(데스크톱 기본=프로덕션, 웹=same-origin). 이 서버를 가리키게 하려면 게임의 `user://settings.json` 에 `base_url` 키를 수동으로 기입. 예) `{"nickname":"me","base_url":"https://api.example.com"}`.

---

## API

- 베이스 경로: `/api` 
- 오류 응답: `{"detail": ...}`
  - 비정상 기록 필터에 걸린 제출은 모두 **HTTP 422**  return

### `GET /api/health`
```json
{ "status": "ok", "version": "0.1.0" }
```

### `GET /api/tracks`
등록된 공식 트랙 목록.
```json
[
  { "id": "cotton_01", "name": "Cotton Warm-up", "difficulty": "normal",
    "checksum": "sha256:8f0116ac...251909" }
]
```

### `GET /api/leaderboard`
쿼리: `track_id`(필수), `difficulty`(선택), `limit`(기본 100, 1~500), `offset`(기본 0).

정렬 우선순위:
1. `final_time_ms` 오름차순
2. `accuracy` 내림차순
3. `cuts` 오름차순
4. `off_seam_ms` 오름차순
5. `created_at` 오름차순

**플레이어(`player_name`)당 최고 기록 1건만** 노출. 

각 항목에는 전역 순위 `rank` 가 붙습니다(`offset` 을 반영한 절대 순위). 등록되지 않은 `track_id` 는 404.

```json
{
  "track_id": "cotton_01", "difficulty": "normal", "limit": 100, "offset": 0,
  "count": 2,
  "entries": [
    { "rank": 1, "run_id": 2, "player_name": "player_B", "final_time_ms": 22000, ... }
  ]
}
```

### `POST /api/runs`
```json
{
  "player_name": "player01", "track_id": "cotton_01", "difficulty": "normal",
  "time_ms": 84231, "penalty_ms": 3000, "final_time_ms": 87231,
  "accuracy": 94.2, "cuts": 1, "off_seam_ms": 840,
  "game_version": "0.1.0",
  "track_checksum": "sha256:...", "replay_hash": "sha256:..."
}
```
성공 시 **201** 과 함께:
```json
{ "run_id": 12, "verification_status": "unverified", "rank": 3 }
```
`rank` 는 저장 후 해당 트랙·난이도 리더보드에서 이 플레이어의 최고 기록 순위입니다.

### `GET /api/runs/{run_id}`
저장된 기록 한 건의 전체 필드. 없으면 404.

---

## 커스텀 트랙 공유 허브 API

플레이어가 만든 커스텀 트랙을 계정 없이 공개하고 내려받는 API입니다. 게시물은 불변이며, 게시자는 게시 응답으로 한 번만 받는 삭제 토큰으로 자기 게시물을 삭제할 수 있습니다. 공식 트랙 기록 체계(`tracks`·`runs` 테이블, `/api/runs` 레이트리밋)와는 테이블과 제한 버킷을 공유하지 않으며, 커스텀 트랙 기록은 서버에 제출하지 않습니다.

오류 본문은 모두 `{"detail": ...}` 형식입니다. 422는 `detail` 이 `[{"loc": [...], "msg": "...", "type": "..."}]` 목록이고, 401·403·404·413·429는 `detail` 이 문자열입니다. 422 목록에는 입력값을 되돌려 싣지 않습니다.

| 메서드·경로 | 동작 | 주요 상태 코드 |
|---|---|---|
| `GET /api/community/tracks?q=&limit=20&offset=0` | 공개 목록(최신순, 제목 부분 일치 검색) | 200, 422, 429 |
| `GET /api/community/tracks/{id}` | 메타데이터, 검증된 트랙 JSON, `content_hash` | 200, 404, 429 |
| `POST /api/community/tracks` | 게시 | 201, 413, 422, 429 |
| `DELETE /api/community/tracks/{id}` | 삭제 토큰을 확인한 뒤 비공개 처리 | 204, 401, 403, 404, 429 |

### `GET /api/community/tracks`

- `q`: 제목 부분 일치 검색어입니다. 서버는 NFC 정규화와 공백 정리를 거친 뒤 최대 80자까지 받으며, `%`·`_`·`\` 는 와일드카드가 아닌 일반 문자로 취급합니다. ASCII 대소문자는 구분하지 않습니다.
- `limit`: 기본 20, 최대 50입니다. `offset` 은 0 이상입니다.
- 정렬은 `created_at` 내림차순이며, 등록 시각이 같으면 `id` 내림차순으로 고정합니다.
- 항목에는 목록 표시용 필드만 담습니다. 트랙 전체 JSON, 삭제 토큰, 해시는 넣지 않습니다.

```json
{"total":1,"limit":20,"offset":0,"q":"","items":[{"id":"5507e774-fec6-4db4-8fc8-504d2913bbfe","title":"사인 곡선 100%","author_name":"bnbong","difficulty":"normal","fabric":"silk","length":2695,"created_at":"2026-09-30T09:36:36.772183+00:00"}]}
```

### `GET /api/community/tracks/{id}`

없는 게시물과 삭제된 게시물은 모두 404입니다. `track` 은 서버가 정규화한 트랙 JSON이며, 게임의 JSON 가져오기(`TrackLoader._prepare_import`)에 그대로 넣을 수 있는 형태입니다.

```json
{"id":"5507e774-...","title":"사인 곡선 100%","author_name":"bnbong","description":"완만한 S 곡선입니다.\n처음 해 보기 좋아요.","difficulty":"normal","fabric":"silk","length":2695,"created_at":"2026-09-30T09:36:36.772183+00:00","content_hash":"sha256:b46e...1aa3","track":{"name":"사인 곡선 100%","difficulty":"normal","fabric":"silk","width":{"perfect":18.0,"safe":42.0,"fail":90.0},"path":[{"type":"polyline","points":[[0.0,0.0],[40.0,30.0],"..."],"closed":false}],"items":[{"s":1200.0,"type":"thimble","lat":0.0}],"modifiers":[],"length":2695,"editor_version":"0.1.0"}}
```

### `POST /api/community/tracks`

본문은 게시 메타데이터와, 게임이 `user://tracks/custom/` 에 저장한 커스텀 트랙 JSON을 담은 `track` 으로 구성합니다.

```json
{
  "title": "사인 곡선",
  "author_name": "bnbong",
  "description": "완만한 S 곡선입니다.",
  "track": {
    "difficulty": "normal", "fabric": "silk",
    "width": {"perfect": 18, "safe": 42, "fail": 90},
    "path": [{"type": "polyline", "points": [[0, 0], [40, 30]], "closed": false}],
    "items": [{"s": 1200, "type": "thimble", "lat": 0}],
    "modifiers": [], "editor_version": "0.1.0",
    "track_id": "custom_1a2b3c4d", "name": "로컬 이름", "is_custom": true,
    "checksum": "sha256:...", "length": 2695
  }
}
```

성공하면 201과 함께 상세 응답과 같은 필드에 `delete_token` 을 더해 돌려줍니다. 삭제 토큰은 이 응답에만 들어 있고 서버에는 SHA-256 값만 남으므로, 클라이언트가 분실하면 다시 받을 방법이 없습니다. 응답에는 `Cache-Control: no-store` 를 붙입니다.

업로드 검증 규칙은 다음과 같습니다. 서버는 클라이언트 검증 결과를 신뢰하지 않고 모든 규칙을 다시 적용합니다.

- 형식: 최상위와 `track`, 세그먼트, 아이템에는 정해진 필드만 허용하며 알 수 없는 필드가 있으면 422로 거부합니다. 숫자 자리에 bool이나 문자열을 넣으면 변환하지 않고 거부합니다. `NaN`·`Infinity`·범위를 넘는 실수와 중첩 깊이 8을 넘는 JSON도 거부합니다.
- 메타데이터: `title` 은 1~80자, `author_name` 은 1~32자, `description` 은 0~1000자입니다. 길이는 NFC 정규화와 공백 정리(연속 공백 축약, 앞뒤 공백 제거) 뒤에 잽니다. 제어 문자와 서식 문자(유니코드 C 범주)는 거부하되, `description` 의 줄바꿈은 허용합니다. `title` 과 `author_name` 이 공백과 화면에 보이지 않는 문자(한글 채움 문자 U+3164·U+115F·U+1160·U+FFA0, 점자 공백 U+2800 등)로만 이루어져 있으면 빈 값으로 보고 거부합니다. HTML이나 BBCode는 해석하지 않고 문자열 그대로 보관하므로, 클라이언트는 이 값을 일반 텍스트로 그려야 합니다.
- 경로: `path` 는 `type: "polyline"` 세그먼트 1~64개만 받고 bezier 등 다른 세그먼트는 거부합니다. 점은 모든 세그먼트를 합쳐 최대 4096개이고, 좌표는 유한한 수이며 절댓값이 16384 이하여야 합니다. 이 상한은 에디터의 좌표 클램프(4000)와 공식 트랙의 최대 좌표(1546)보다 충분히 크면서, float32 좌표 오차를 0.001px 이하로 묶기 위해 정했습니다. 서버는 좌표를 0.1 격자로 반올림한 뒤 게임과 같은 규칙(6px 이하 세분)으로 베이크하고, `TrackValidator` 의 하드 거부 기준(베이크 후 점 8개 이상, 길이 1500~8000px, 최소 곡률반경 28px, 자기근접)을 적용합니다. 베이크한 점과 누적 호길이는 게임과 같은 float32 연산으로 계산합니다. 플랫폼마다 마지막 비트가 달라질 수 있으므로 하드 기준에는 서버 쪽이 더 엄격한 여유 폭(길이 0.5px, 곡률반경 0.1px, 자기근접 거리 0.01px와 호길이 창 0.05px)을 둡니다. 따라서 서버가 받은 트랙은 게임의 가져오기 검증도 통과하며, 기준값에 아주 가까운 트랙만 서버에서 거부될 수 있습니다. 소프트 경고는 거부 사유가 아닙니다.
- 폭: `perfect < safe < fail` 이어야 하고, 세 값 모두 0보다 크고 1000 이하인 유한한 수여야 합니다.
- 난이도·재질: `difficulty` 는 `beginner`·`normal`·`expert`·`master`, `fabric` 은 `cotton`·`denim`·`silk`·`knit`·`wool`·`felt`·`satin`·`leather` 만 받습니다.
- 아이템: 최대 128개이고 `type` 은 `thimble`·`autopilot` 만 받습니다. `s` 는 0 이상이고 베이크한 경로 길이에서 0.5px를 뺀 값 이하여야 하며, `lat` 은 절댓값이 `fail` 이하여야 합니다. `lat` 을 생략하면 0으로 채웁니다.
- 기타: `modifiers` 는 빈 배열만 받습니다. `editor_version` 을 보낸다면 `0.1.0` 이어야 합니다. `track_id`·`name`·`is_custom`·`checksum`·`length` 는 형식만 확인한 뒤 버리고, 저장본의 `name` 은 게시 제목으로, `length` 는 서버가 다시 계산한 값으로 채웁니다.

`content_hash` 는 정규화한 트랙의 플레이 데이터(`difficulty`·`fabric`·`width`·`path`·`items`)를 키 정렬, 공백 없는 구분자, UTF-8로 직렬화한 JSON의 SHA-256이며 `sha256:<소문자 hex 64자>` 형식입니다. 정규화 단계에서 수치는 모두 실수로 바꾸고 `-0.0` 은 `0.0` 으로 통일하며, 아이템은 `(s, lat, type)` 순으로 정렬하므로, 제목이나 설명만 다른 게시물은 같은 해시를 갖습니다. 세그먼트의 `closed` 는 게임이 읽지 않으므로 해시 대상에서 빼지만, 저장본과 응답에는 그대로 남깁니다. 같은 점 열이라도 세그먼트를 나눈 방식이 다르면 해시가 달라집니다. 클라이언트는 이 값을 다시 계산하지 말고 게시물 내용을 구분하는 식별자로만 비교해야 합니다.

### `DELETE /api/community/tracks/{id}`

`Authorization: Bearer <delete_token>` 헤더가 필요합니다. 서버는 다음 순서로 판정합니다.

1. 헤더가 없거나 `Bearer` 형식이 아니면 401을 돌려주고 `WWW-Authenticate: Bearer` 를 붙입니다.
2. 게시물이 없거나 이미 삭제(비공개)된 상태이면 404를 돌려줍니다.
3. 토큰의 SHA-256이 저장된 값과 다르면 403을 돌려줍니다. 비교에는 `hmac.compare_digest` 를 씁니다.
4. 일치하면 `deleted_at` 을 기록해 소프트 삭제하고 204를 돌려줍니다. 기록은 아직 삭제되지 않은 행만 바꾸는 원자적 갱신으로 수행하므로, 같은 게시물에 대한 삭제 요청이 동시에 들어오면 먼저 처리된 요청만 204를 받고 나머지는 404를 받습니다. 행은 DB에 남지만 목록과 상세에서는 제외됩니다.

### 제한값

| 항목 | 기본값 | 비고 |
|---|---|---|
| 요청 본문 | 1MiB | 게시(POST)는 Content-Length 누락·거짓·chunked 전송이어도 실제 수신 바이트가 상한을 넘기 직전에 413으로 끊습니다. 조회와 삭제는 본문을 읽지 않으므로 선언된 Content-Length 만 검사합니다. 다른 경로는 기존 16KB 상한을 그대로 씁니다. |
| 422 오류 항목 | 20건 | 오류가 더 많으면 앞의 19건과 생략 안내 1건만 `detail` 에 담습니다. 오류 메시지는 입력값을 되돌려 보여 주지 않고 허용 목록만 안내합니다. |
| 게시 | IP당 분당 3회, 24시간 30회 | 검증에 실패한 요청도 횟수에 포함합니다. |
| 조회 | IP당 분당 120회 | 목록과 상세가 같은 버킷을 씁니다. |
| 삭제 | IP당 분당 10회 | 토큰이 틀린 요청도 횟수에 포함합니다. |

레이트리밋은 `OVERLOCK_TRUST_FORWARDED_FOR` 와 `trusted_proxy_hops` 규칙으로 얻은 클라이언트 IP를 키로 쓰며, `/api/runs` 버킷과는 독립적으로 셉니다. 제한 상태는 프로세스 메모리에 있으므로 아래 "레이트리밋과 워커 수" 절의 한계가 똑같이 적용됩니다.

---

## 트랙 체크섬 계산 방식 (클라이언트 연동 규약)

> 클라이언트 워커가 반드시 맞춰야 하는 계약.

서버는 각 공식 트랙의 체크섬을 **트랙 JSON 파일의 원본 바이트**의 SHA-256 으로 계산해 저장합니다.

```
checksum = "sha256:" + hex( SHA256( 트랙 JSON 파일의 raw bytes ) )
```

- 대상은 **파일 바이트 원본**입니다. 공백·개행·키 순서가 한 바이트라도 다르면 값이 달라지니 주의.
- hex 는 소문자 64자, 접두는 `sha256:` (기획서 §13.3 예시 형식과 동일).
- 서버의 `server/app/tracks/` 스냅샷은 `game/tracks/official/` 의 바이트를 그대로 복사했습니다. 따라서 **클라이언트가 자기 번들의 동일 트랙 파일 바이트에 같은 계산을 적용하면** 서버 값과 일치하게 됩니다.
- `POST /api/runs` 는 제출된 `track_checksum` 이 서버에 등록된 값과 다르면 422 로 거부.

예시:
```
cotton_01.json → sha256:8f0116ac7d4fdb0a940e431ec11ba9e2b561ac9392631d5ed1f18dcddc251909
```
클라이언트 GDScript 예:
```gdscript
var bytes := FileAccess.get_file_as_bytes("res://tracks/official/cotton_01.json")
var checksum := "sha256:" + bytes.sha256_text()  # 또는 HashingContext(SHA_256)
```

> 참고: 클라이언트의 커스텀 트랙 체크섬(`TrackLoader.compute_checksum`)은 좌표 폴리라인
> 기반이라 계산 방식이 다릅니다. 공식 트랙 리더보드 제출에는 위의 **파일 바이트 SHA-256** 을
> 써야 합니다.

---

## 비정상 기록 필터

하단 규칙 모두 위반 시 422.

- **트랙 미등록 / 체크섬 불일치**: 등록되지 않은 `track_id`, 혹은 등록 체크섬과 다른 `track_checksum`.
- **물리 하한**: `final_time_ms < (트랙 길이 px ÷ 최고속도 300px/s) × 1000`. 최고속도로도 불가능한 기록을 거부. 트랙별 하한은 시드 시 계산해 저장.
- **범위·형식 검증**: `accuracy` 0~100, `cuts` ≥ 0 정수, `final_time_ms == time_ms + penalty_ms`, `player_name` 1~16자(제어 문자·공백만 금지, 유니코드 허용), `game_version` 은 semver 유사 형식(`\d+.\d+.\d+`).
- **레이트리밋**: IP당 분당 `OVERLOCK_RATE_LIMIT_PER_MINUTE` 회 초과 시 429(인메모리, 단일 프로세스 기준).

---

## 테스트

```bash
cd server
pip install -r requirements.txt -r requirements-dev.txt
pytest
```

FastAPI `TestClient` 로 검증.

---

## 배포

### 1) 리버스 프록시 (Nginx Proxy Manager)

`OVERLOCK_TRUST_FORWARDED_FOR=true` 를 켜면 레이트리밋이 프록시가 넘긴 실제 IP를 씁니다.

```nginx
server {
    listen 443 ssl;
    server_name overlock.example.com;
    # ssl_certificate / ssl_certificate_key ...

    location /api/ {
        proxy_pass <컨테이너 혹은 인스턴스 호스트 + 포트>;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 2) Docker

이미지 정의는 `server/Dockerfile` 에 있습니다(`python:3.13-slim` · 비루트 실행 · `/api/health` HEALTHCHECK 포함). 

DB 는 `/data` 볼륨의 SQLite 파일에 저장합니다(`ENV OVERLOCK_DB_URL=sqlite:////data/overlock.db`). 빌드 컨텍스트는 `server/.dockerignore` 로 `.venv`·`__pycache__`·`*.db`·`tests` 등을 제외합니다.

```bash
docker build -t overlock-server ./server
docker run -d -p 8000:8000 -v overlock-data:/data overlock-server
curl http://127.0.0.1:8000/api/health   # {"status":"ok","version":"..."}
```

컨테이너 내부 포트는 `8000` 고정입니다. 다른 호스트 포트로 노출하려면 매핑만 바꿉니다(예: `-p 8010:8000`). 오리진 제한·프록시 뒤 실제 IP 사용 등은 환경변수로 켭니다.

```bash
docker run -d -p 8010:8000 -v overlock-data:/data \
  -e OVERLOCK_TRUST_FORWARDED_FOR=true \
  -e OVERLOCK_CORS_ORIGINS=https://overlock.example.com \
  overlock-server
```

### 3) 레이트리밋과 워커 수

기록 제출과 공유 허브의 레이트리밋은 모두 프로세스 메모리에 카운터를 둡니다. 따라서 제한값은 uvicorn 워커 하나를 기준으로 정확하게 동작합니다. 현재 `Dockerfile` 과 배포 워크플로는 워커 하나로 실행합니다. `--workers` 로 워커를 늘리거나 인스턴스를 여러 대 띄우면 카운터가 워커마다 따로 존재하므로 실제 허용량이 워커 수만큼 늘어나고, 재시작하면 카운터가 초기화됩니다. 다중 워커로 공개 운영해야 한다면 앞단 리버스 프록시에서 경로별 공통 제한(nginx `limit_req` 등)을 함께 설정하는 방식을 권장합니다. 이 서버는 Redis 같은 외부 저장소를 쓰지 않습니다.

공유 허브 게시 본문은 최대 1MiB입니다. 리버스 프록시의 본문 상한이 이보다 작으면 프록시가 먼저 거부하므로, `/api/community/` 경로에는 1MiB 이상을 허용해야 합니다(nginx 기본값 `client_max_body_size 1m` 이면 경계에 걸린 요청을 프록시가 거부할 수 있습니다). 그 밖의 경로는 앱이 선언된 Content-Length 만 검사하므로 기존처럼 프록시 상한을 함께 두어야 합니다.

---

## DB 백업

SQLite 는 파일 하나로 운영되어 백업이 간단하기 때문에 온라인 백업으로 수행:
```bash
sqlite3 /var/lib/overlock/overlock.db ".backup '/var/backups/overlock-$(date +%F).db'"
```

공유 허브 게시물(`community_tracks` 테이블)도 같은 DB 파일에 저장되므로 위 백업에 함께 포함됩니다. 이 테이블은 기존 DB에 서버를 다시 띄우면 `create_all` 이 새로 만들며, 기존 `tracks`·`runs` 테이블과 행은 바꾸지 않습니다. 그래도 공유 허브를 처음 배포하기 전과 운영자 비공개 처리처럼 데이터를 바꾸는 작업 전에는 백업을 먼저 받아 두는 것이 안전합니다. Docker 볼륨을 쓰는 경우에는 다음처럼 컨테이너 안에서 백업한 뒤 호스트로 복사할 수 있습니다(컨테이너 이미지에 `sqlite3` 명령이 없으므로 파이썬 표준 라이브러리를 씁니다).

```bash
docker exec <컨테이너> python -c "import sqlite3; s=sqlite3.connect('/data/overlock.db'); d=sqlite3.connect('/data/backup.db'); s.backup(d); d.close()"
docker cp <컨테이너>:/data/backup.db ./overlock-$(date +%F).db
```

---

## 공유 허브 운영자 비공개 처리

공개 관리자 API는 없습니다. 운영자는 서버 셸에서 `app.community_admin` 명령으로 게시물을 비공개 처리합니다. 명령은 서버와 같은 환경변수(`OVERLOCK_DB_URL` 등)로 DB를 열고, 공식 트랙 시드나 레이트리밋 상태에는 영향을 주지 않습니다.

```bash
cd server                                        # Docker 는 docker exec <컨테이너> 뒤에 붙여 실행
python -m app.community_admin list               # 공개 게시물 최신순 50건
python -m app.community_admin list --all -n 200  # 비공개 게시물 포함
python -m app.community_admin list -q 하트        # 제목 부분 일치
python -m app.community_admin show <id>          # 한 건의 메타데이터
python -m app.community_admin hide <id>          # 비공개 처리
python -m app.community_admin unhide <id>        # 비공개 해제(실수 복구)
```

절차는 다음과 같습니다.

1. 신고받은 게시물의 `id` 를 확인합니다. 게임이나 `GET /api/community/tracks?q=` 로 찾거나 `list -q` 로 검색합니다.
2. DB 백업을 받습니다.
3. `hide <id>` 를 실행합니다. 게시자 삭제와 같은 소프트 삭제이므로 이후 목록·상세·삭제 요청은 404를 받습니다.
4. `list --all` 에서 해당 행이 `hidden` 으로 표시되는지 확인합니다.

행은 DB에 남습니다. 영구 삭제가 필요하면 백업을 받은 뒤 DB에서 해당 행을 직접 지웁니다. 출력에는 삭제 토큰 해시를 표시하지 않으며, 삭제 토큰 원문은 서버 어디에도 저장하지 않습니다.

---

## PostgreSQL 전환 여지

코드는 SQLAlchemy 2.0 위에 있어 DB 를 바꿔도 소스 수정이 필요 없습니다.

DB 인스턴스에 마이그레이션 후 드라이버를 깔고 URL 만 바꾸면 됩니다.

```bash
pip install "psycopg[binary]"
export OVERLOCK_DB_URL="postgresql+psycopg://user:password@localhost:5432/overlock"
```

스키마는 기동 시 자동 생성됩니다. 

기존 SQLite 데이터를 옮기려면 별도 마이그레이션 스크립트로 `tracks`·`runs` 를 복사(트랙은 재시드로도 채워짐).
