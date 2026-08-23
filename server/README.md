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

---

## DB 백업

SQLite 는 파일 하나로 운영되어 백업이 간단하기 때문에 온라인 백업으로 수행:
```bash
sqlite3 /var/lib/overlock/overlock.db ".backup '/var/backups/overlock-$(date +%F).db'"
```

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
