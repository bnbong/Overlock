# Overlock 리더보드 서버

재봉 레이싱 게임 **Overlock** 의 기록 저장·조회 API다. FastAPI 와 SQLite 로 만들었고,
개인 도메인 클라우드 서버에 그대로 올려 트랙별 Top 100 리더보드를 운영하는 것을
목표로 한다. 설계 근거는 저장소 루트의 `docs/design/game_design.md` §12~§15, §18 이다.

- 스택: Python 3.11+ (3.13 검증) · FastAPI · SQLAlchemy 2.0 · SQLite (→ PostgreSQL 여지)
- 기록 등급: 현재는 `unverified` 만 운영한다. 리플레이 재시뮬레이션 기반 `verified`·`official`
  등급은 이후 확장이다(§14.2).

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

기동하면 서버가 `server/app/tracks/` 스냅샷의 공식 트랙 5종을 DB에 시드한다.
브라우저에서 `http://127.0.0.1:8000/docs` 를 열면 대화형 API 문서를 볼 수 있다.

```bash
# 동작 확인
curl http://127.0.0.1:8000/api/health
curl http://127.0.0.1:8000/api/tracks
```

---

## 설정 (환경변수)

모든 설정은 `OVERLOCK_` 접두 환경변수로 덮어쓴다. `server/.env` 파일에 넣어도 된다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `OVERLOCK_DB_URL` | `sqlite:///<server>/overlock.db` | SQLAlchemy DB URL. PostgreSQL 전환 시 여기만 바꾼다. |
| `OVERLOCK_HOST` | `0.0.0.0` | 바인드 호스트 (uvicorn 실행 시 `--host` 로도 지정 가능). |
| `OVERLOCK_PORT` | `8000` | 포트. |
| `OVERLOCK_CORS_ORIGINS` | `*` | 허용 오리진(쉼표 구분). `*` 는 전체 허용. 예) `https://overlock.example.com`. |
| `OVERLOCK_RATE_LIMIT_PER_MINUTE` | `60` | IP당 분당 기록 제출 허용 횟수(인메모리). `0` 이면 제한 해제. |
| `OVERLOCK_TRUST_FORWARDED_FOR` | `false` | 리버스 프록시 뒤라서 `X-Forwarded-For` 의 실제 IP를 써야 하면 `true`. |
| `OVERLOCK_TRACKS_DIR` | `server/app/tracks` | 공식 트랙 스냅샷 디렉토리. |
| `OVERLOCK_MAX_SPEED_PX_S` | `300` | 물리 하한 계산용 최고 속도(px/s, §7.2 Overlock 단계). |

> `OVERLOCK_TRUST_FORWARDED_FOR=true` 는 신뢰할 수 있는 프록시(nginx 등) 뒤에서만 켜라.
> 그렇지 않으면 클라이언트가 헤더를 위조해 레이트리밋을 우회할 수 있다.

---

## API

베이스 경로는 `/api` 다. 오류 응답은 `{"detail": ...}` 형태이며, 비정상 기록 필터에
걸린 제출은 모두 **HTTP 422** 를 돌려준다.

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

정렬 우선순위는 §14.1 을 그대로 따른다.
1. `final_time_ms` 오름차순
2. `accuracy` 내림차순
3. `cuts` 오름차순
4. `off_seam_ms` 오름차순
5. `created_at` 오름차순

**플레이어(`player_name`)당 최고 기록 1건만** 노출하며, 각 항목에 전역 순위 `rank` 가 붙는다
(`offset` 을 반영한 절대 순위). 등록되지 않은 `track_id` 는 404.

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
바디는 §13.3 스키마 그대로다(`replay_hash` 만 선택).
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
`rank` 는 저장 후 해당 트랙·난이도 리더보드에서 이 플레이어의 최고 기록 순위다.

### `GET /api/runs/{run_id}`
저장된 기록 한 건의 전체 필드. 없으면 404.

---

## 트랙 체크섬 계산 방식 (클라이언트 연동 규약)

> 클라이언트 워커가 반드시 맞춰야 하는 계약이다.

서버는 각 공식 트랙의 체크섬을 **트랙 JSON 파일의 원본 바이트** 에 대한 SHA-256 으로
계산해 저장한다.

```
checksum = "sha256:" + hex( SHA256( 트랙 JSON 파일의 raw bytes ) )
```

- 대상은 파싱한 좌표가 아니라 **파일 바이트 그대로**다. 공백·개행·키 순서가 한 바이트라도
  다르면 값이 달라진다.
- hex 는 소문자 64자, 접두는 `sha256:` (기획서 §13.3 예시 형식과 동일).
- 서버의 `server/app/tracks/` 스냅샷은 `game/tracks/official/` 의 바이트를 그대로 복사한
  것이다. 따라서 **클라이언트가 자기 번들의 동일 트랙 파일 바이트에 같은 계산을 적용하면**
  서버 값과 일치한다.
- `POST /api/runs` 는 제출된 `track_checksum` 이 서버에 등록된 값과 다르면 422 로 거부한다.

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
> 기반이라 계산 방식이 다르다. 공식 트랙 리더보드 제출에는 위의 **파일 바이트 SHA-256** 을
> 써야 한다.

---

## 비정상 기록 필터 (§18)

객관적으로 판정 가능한 규칙만 적용한다. 모두 위반 시 422.

- **트랙 미등록 / 체크섬 불일치**: 등록되지 않은 `track_id`, 혹은 등록 체크섬과 다른
  `track_checksum`.
- **물리 하한**: `final_time_ms < (트랙 길이 px ÷ 최고속도 300px/s) × 1000`. 최고속도로도
  불가능한 기록을 거부한다. 트랙별 하한은 시드 시 계산해 저장한다.
- **범위·형식 검증**: `accuracy` 0~100, `cuts` ≥ 0 정수, `final_time_ms == time_ms + penalty_ms`,
  `player_name` 1~16자(제어 문자·공백만 금지, 유니코드 허용), `game_version` 은 semver 유사
  형식(`\d+.\d+.\d+`).
- **레이트리밋**: IP당 분당 `OVERLOCK_RATE_LIMIT_PER_MINUTE` 회 초과 시 429(인메모리,
  단일 프로세스 기준).

---

## 테스트

```bash
cd server
pip install -r requirements.txt -r requirements-dev.txt
pytest
```

정상 제출/조회, 정렬, 플레이어당 1건, 각 필터 거부, 레이트리밋을 FastAPI `TestClient` 로
검증한다.

---

## 배포 (개인 클라우드 서버)

### 1) systemd 유닛

`/etc/systemd/system/overlock.service`:
```ini
[Unit]
Description=Overlock Leaderboard API
After=network.target

[Service]
Type=simple
User=overlock
WorkingDirectory=/opt/overlock/server
Environment=OVERLOCK_DB_URL=sqlite:////var/lib/overlock/overlock.db
Environment=OVERLOCK_CORS_ORIGINS=https://overlock.example.com
Environment=OVERLOCK_TRUST_FORWARDED_FOR=true
ExecStart=/opt/overlock/server/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
```bash
sudo mkdir -p /var/lib/overlock
sudo systemctl daemon-reload
sudo systemctl enable --now overlock
```

### 2) 리버스 프록시 (nginx)

앱은 `127.0.0.1:8000` 에만 바인드하고, 앞단 nginx 가 TLS 종료와 실제 IP 전달을 맡는다.
`OVERLOCK_TRUST_FORWARDED_FOR=true` 를 켜면 레이트리밋이 프록시가 넘긴 실제 IP를 쓴다.

```nginx
server {
    listen 443 ssl;
    server_name overlock.example.com;
    # ssl_certificate / ssl_certificate_key ...

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 3) Docker (선택)

`server/` 안에서:
```dockerfile
# Dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
ENV OVERLOCK_DB_URL=sqlite:////data/overlock.db
VOLUME /data
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```
```bash
docker build -t overlock-server ./server
docker run -d -p 8000:8000 -v overlock-data:/data overlock-server
```

---

## DB 백업

SQLite 는 파일 하나다. 온라인 백업이 안전하다.
```bash
sqlite3 /var/lib/overlock/overlock.db ".backup '/var/backups/overlock-$(date +%F).db'"
```

---

## PostgreSQL 전환 여지

코드는 SQLAlchemy 2.0 위에 있어 DB 를 바꾸는 데 소스 수정이 필요 없다. 드라이버를 깔고
URL 만 바꾸면 된다(§12).

```bash
pip install "psycopg[binary]"
export OVERLOCK_DB_URL="postgresql+psycopg://user:password@localhost:5432/overlock"
```

스키마는 기동 시 자동 생성된다. 기존 SQLite 데이터를 옮기려면 별도 마이그레이션 스크립트로
`tracks`·`runs` 를 복사하면 된다(트랙은 재시드로도 채워진다).
