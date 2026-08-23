# Overlock 웹(HTML5) 배포 가이드

Overlock 클라이언트를 정적 웹 빌드로 내보내 개인 도메인에 호스팅.

- 산출물 `build/web/` — 모든 정적 호스팅에 그대로 업로드.
- 리더보드 사용 시 `server/`(FastAPI) 별도 기동 + 클라이언트에서 주소 지정(§5).
- 대상 엔진: **Godot 4.6.1.stable** (`4.6.1.stable.official.14d19694e` 검증).
- 렌더러: **GL Compatibility**(WebGL 2.0). 프로젝트에 웹용으로 미리 설정됨.
- 스레드: **OFF**(단일 스레드). 근거 §2 "스레드 OFF 결정".

---

## 1. 사전 준비: 웹 export 템플릿

설치된 Godot 버전과 **정확히 같은 버전**의 웹 export 템플릿 필수. 버전 불일치 시 export 거부.

설치 위치(운영체제별):

| OS | 경로 |
|---|---|
| macOS | `~/Library/Application Support/Godot/export_templates/4.6.1.stable/` |
| Linux | `~/.local/share/godot/export_templates/4.6.1.stable/` |
| Windows | `%APPDATA%\Godot\export_templates\4.6.1.stable\` |

- 최소 `web_nothreads_release.zip`(스레드 OFF 릴리스 템플릿) 존재 시 충분.
- 현 작업 환경: 8종 웹 템플릿 전부 + `version.txt` 설치됨.

### 방법 A — 에디터에서 설치 (권장)

네트워크만 되면 버전 자동 정합.

1. Godot 에디터 → **Editor → Manage Export Templates…**
2. **Download and Install** — 현재 에디터 버전(4.6.1.stable) 맞는 템플릿 자동 내려받아 위 경로에 설치.

### 방법 B — 릴리스에서 직접 내려받아 설치 (CLI)

에디터 불가·CI 자동화용. `.tpz`는 실은 zip → `unzip`으로 해제.

```bash
VER=4.6.1
DEST="$HOME/Library/Application Support/Godot/export_templates/${VER}.stable"   # macOS 기준

curl -L -o /tmp/templates.tpz \
  "https://github.com/godotengine/godot/releases/download/${VER}-stable/Godot_v${VER}-stable_export_templates.tpz"

mkdir -p "$DEST"
# 웹 템플릿만 추출(전체 설치가 필요하면 web_* 패턴 대신 templates/* 를 푼다)
unzip -o -j /tmp/templates.tpz "templates/web_*.zip" "templates/version.txt" -d "$DEST"

cat "$DEST/version.txt"   # -> 4.6.1.stable 이어야 한다
```

> `.tpz` 전체 >1GB — 느린 회선은 방법 A 권장.

---

## 2. 웹 빌드하기

- 빌드 설정: `game/export_presets.cfg`의 **"Web"** 프리셋.
- 저장소 루트에서 실행. 경로 인자는 `game/` 기준 상대경로 → `../build/web/…`가 루트 `build/web/`에 출력.

```bash
GODOT=/path/to/Godot            # 예: /Users/you/Downloads/Godot.app/Contents/MacOS/Godot

mkdir -p build/web

# 리소스가 바뀐 뒤 첫 빌드라면 임포트를 먼저 한 번(선택)
"$GODOT" --headless --path game --import

# 릴리스 export
"$GODOT" --headless --path game --export-release "Web" ../build/web/index.html
```

exit code 0 = 성공. `build/web/` 산출물:

| 파일 | 크기(대략) | 설명 |
|---|---|---|
| `index.html` | 5 KB | 로더 셸. 진입점. |
| `index.js` | 308 KB | 엔진 로더/글루 코드. |
| `index.wasm` | **36 MB** | 엔진 바이너리. 첫 로드 대부분. |
| `index.pck` | 3.9 MB | 게임 리소스 팩(씬·스크립트·오디오·트랙). |
| `index.audio.worklet.js` / `index.audio.position.worklet.js` | 각 3~7 KB | 오디오 워클릿. |
| `index.icon.png` / `index.apple-touch-icon.png` / `index.png` | 5~21 KB | 아이콘·스플래시. |

- 첫 방문 전송량 ~**40 MB**. gzip/brotli 압축 시 `.wasm`·`.pck` 전송량 대폭 감소(§4-2). 재방문은 브라우저 캐시로 가벼움.
- `build/`는 루트 `.gitignore` 등록 — 커밋 안 됨.

### 스레드 OFF 결정 (성능 트레이드오프)

프리셋 `variant/thread_support=false` — 멀티스레드 OFF. 근거:

- 스레드 ON → 브라우저가 `SharedArrayBuffer` 요구 → 페이지 **교차 출처 격리(cross-origin isolation)** 필요 → 서버가 모든 응답에 `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` 헤더 부착 필수. GitHub Pages·S3 등 흔한 정적 호스팅은 이 헤더 지정이 어렵거나 불가.
- 스레드 OFF → 그 요구 소멸 → **아무 정적 호스팅에서나 부팅**. 호환성 최우선으로 채택.
- 트레이드오프: 물리·리소스 로딩이 메인 스레드에서만 실행. Overlock은 2D GL Compatibility 경량 게임이라 체감 영향 작음. 대형/무거운 씬 계획 시 스레드 ON + 격리 헤더 지원 호스팅으로 전환 검토.

확인: 부팅 로그 `Build configuration: … single-threaded, no GDExtension support`.

### 웹에서 달라지는 동작 (웹 가드)

브라우저에 앱 종료·로컬 파일시스템 접근 없음 → 아래만 웹 전용 대체. 그 외 그리기·검증·저장·플레이는 웹에서도 동일 동작.

- **메인 메뉴 Quit 버튼**: 웹에서 숨김(탭이 곧 앱 수명).
- **트랙 파일 불러오기·내보내기**: 데스크톱 `FileDialog`/드래그드롭 ↔ 웹 **JavaScriptBridge**(Phase 2). 웹 불러오기 = 브라우저 `<input type=file>`로 JSON 업로드, 내보내기 = 커스텀 트랙 JSON Blob 다운로드. 데스크톱·웹 동일 임포트 파이프라인(`TrackLoader.import_custom_from_text`)으로 수렴.
- **커스텀 트랙 저장·로컬 기록**: `user://`에 기록, 웹은 브라우저 **IndexedDB**로 영속. 웹에서도 저장·재개 유지.

---

## 3. 로컬에서 확인하기

`file://` 직접 열기 금지(브라우저가 `.wasm` 로드 실패). HTTP 서빙 필수. 저장소 로컬 서버 스크립트 사용(표준 라이브러리만, `.wasm` MIME 정확 지정).

```bash
python3 tools/web_serve.py                 # http://127.0.0.1:8060/ 로 build/web 서빙
python3 tools/web_serve.py --port 9000     # 포트 변경
python3 tools/web_serve.py --coi           # COOP/COEP/CORP 헤더 부착(스레드 ON 실험용, 평소엔 불필요)
```

### 브라우저 확인 체크리스트

1. **부팅** — 주소 열면 로딩 후 메인 메뉴. 콘솔(F12) 빨간 에러 0. **Quit 버튼 없음**이 정상(웹 가드).
2. **오디오(사용자 제스처)** — 브라우저는 클릭 전 무음. **Start 버튼 후** BGM·재봉틀 틱·효과음 확인.
3. **키 입력** — 메뉴 ←/→(A/D)로 트랙 전환, 플레이 중 조작 키 반응 확인.
4. **기록 영속(IndexedDB)** — 완주 기록 후 **새로고침**해도 메인 Best 유지. 에디터 커스텀 트랙 저장 후 새로고침에도 목록 유지 = `user://` 영속 정상.
5. **트랙 가져오기/내보내기(웹)** — TrackSelect **불러오기** → 파일 선택창 → 유효 JSON 고르면 "…트랙을 가져왔습니다" 토스트 + 목록 즉시 반영(검증 실패 JSON은 사유 토스트로 거부). 커스텀 선택 시 **내보내기** 버튼 노출 → `<이름>_<id>.json` 다운로드(공식 트랙은 버튼 없음).
6. **한글 렌더(웹 폰트)** — 닉네임 태그·오프라인 토스트, 맵 선택 "트랙 만들기"·"불러오기"·"뒤로", 한글 닉네임·커스텀 트랙명이 □(tofu) 없이 표시. 웹은 OS 폰트 폴백 없음 → 번들 서브셋 폰트(`assets/fonts/Pretendard-Regular.woff2`, `project.godot`의 `gui/theme/custom_font`)로 커버(근거: 해당 폴더 `README.md`).

> 자동 점검(헤드리스 크로미움): 콘솔 에러 0, 페이지 에러 0, 캔버스 1280×720, 엔진 배너 `v4.6.1.stable … single-threaded`, WebGL 2.0 Compatibility 정상.

---

## 4. 정적 호스팅에 올리기

`build/web/` 내부 파일을 호스팅 루트(또는 하위 경로)에 업로드. 스레드 OFF → 격리 헤더 없이 부팅.

### 4-1. 업로드

- **정적 호스팅(Nginx/Apache/S3+CloudFront/Netlify/개인 서버 등)**: `build/web/` 내용 업로드, 진입 URL이 `…/index.html` 가리키게.
- 하위 경로(예: `https://example.com/overlock/`)도 가능. 산출물은 상대경로로 옆의 `index.js`·`index.wasm`·`index.pck` 참조 → 경로 이동에 강함.

### 4-2. MIME 타입 주의 — `.wasm` 이 핵심

**`.wasm`은 반드시 `application/wasm`으로 서빙.** 스트리밍 컴파일 조건. `application/octet-stream` 등이면 부팅 지연·실패. 최신 웹서버는 기본 정합, 예전 설정은 명시 필요.

Nginx 예시(압축 포함):

```nginx
types { application/wasm wasm; }        # 기본 mime.types 에 없으면 추가

location / {
    root /var/www/overlock;             # build/web 내용을 여기에 업로드
    # 브로틀리/지gzip 로 .wasm·.pck 전송량 축소(모듈 유무에 따라 택1)
    gzip on;
    gzip_types application/wasm application/javascript application/octet-stream;
}
```

- `.pck` → `application/octet-stream`.
- `.js` → `text/javascript`(또는 `application/javascript`).
- 압축 시 36 MB `.wasm` 전송량 대폭 감소. `*.wasm.br`/`*.wasm.gz` precompressed 방식이면 서버 CPU 절감.

---

## 5. 리더보드 서버(server/) 연계

웹 클라이언트는 서버 없이 완전 동작(로컬 기록만). 온라인 리더보드 사용 시 `server/` 기동 + 클라이언트에서 주소 지정.

### 5-1. 클라이언트에서 API 주소 지정

**서버 URL은 유저 UI에 미노출.** 기본값: 데스크톱 릴리스 = 프로덕션(`https://overlock.bnbong.com`), 디버그 데스크톱 = `http://localhost:8000`, 웹 = 현재 사이트(same-origin) 자동. **Settings**·메인 닉네임 태그는 **닉네임**만 관리, 저장은 `user://settings.json`(웹=IndexedDB).

- **셀프호스팅/개발**: `user://settings.json`에 `base_url` 키 **수동** 기입(예: `{"nickname":"me","base_url":"https://api.example.com"}`). 데스크톱 기본값보다 우선. 과거 프리필 기본값(localhost/프로덕션)·빈 값은 무시하고 코드 기본값 사용.
- 온라인 점검: 메인 진입 시 `GET /api/health` 자동 호출 → 상태 점 표시, 미연결 시 세션당 1회 안내 토스트.
- 기록 제출/리더보드 조회 실패해도 게임 미차단(조용히 실패, 오프라인이면 제출 버튼 숨김).

### 5-2. 서버 CORS

`server/` 기본 = **모든 오리진 허용**(`OVERLOCK_CORS_ORIGINS=*`) → 타 도메인 API 호출도 CORS 미차단. 배포 시 오리진 축소하려면 게임 서비스 도메인 지정.

```bash
OVERLOCK_CORS_ORIGINS=https://overlock.example.com
```

서버 설정·배포(systemd·리버스 프록시·Docker) 상세: **`server/README.md`**.

### 5-3. Mixed content 주의 — HTTPS 페이지에서 HTTP API 호출 금지

- 게임 페이지 **HTTPS** + 서버 URL **HTTP**(`http://…:8000`) → 브라우저가 **mixed content 차단** → 리더보드 조용히 실패(오프라인처럼 보임).
- 해결: **서버도 HTTPS로 노출.** 앱은 `127.0.0.1:8000` 바인드 + 앞단 TLS 리버스 프록시(Nginx 등)로 `https://api.example.com` 노출 → 클라이언트 Settings에 그 **HTTPS 주소** 기입. 프록시 구성(TLS 종료·`X-Forwarded-For` 전달): `server/README.md` "리버스 프록시(nginx)" 절.

> **게임 HTTPS ↔ API HTTPS** 정합. 한쪽만 HTTP면 mixed content 차단.

---

## 6. 문제 해결

| 증상 | 원인/해결 |
|---|---|
| 빈 화면 + 콘솔에 wasm 관련 에러 | `.wasm` MIME 가 `application/wasm` 인지 확인(4-2). |
| `file://` 로 열었더니 아무것도 안 뜸 | 정적 서버로 HTTP 서빙 필요(3장). |
| export 가 "template not found" 로 실패 | 설치된 엔진과 **같은 버전**의 웹 템플릿이 있는지 확인(1장). |
| 리더보드가 계속 오프라인 | 서버 URL 오타/미기동, 또는 HTTPS↔HTTP mixed content 차단(5-3). |
| 소리가 안 남 | 브라우저 정책상 Start(사용자 클릭) 이후에 재생됨. 정상. |

---

## 7. GitHub Actions CI/CD

§1~6 수동 절차를 GitHub Actions로 자동화. 인프라 식별값(호스트·경로·포트·컨테이너명)은 전부 **저장소 Secrets** 주입 → 워크플로 파일에 미포함. Secrets만 채우면 동작. 워크플로 3개.

### 7-1. 워크플로 개요

| 파일 | 트리거 | 하는 일 |
|---|---|---|
| `.github/workflows/ci.yml` | push(main)·PR | 서버 pytest / GDScript gdparse·gdlint / 공식 트랙 정합성 검증(병렬 3 잡) |
| `.github/workflows/deploy-server.yml` | 수동(+선택: `server/**` push) | GHCR 이미지 빌드·푸시(멀티아치 amd64+arm64) → API 호스트 컨테이너 교체 → 헬스 확인 |
| `.github/workflows/deploy-web.yml` | 수동(+선택: `game/**` push) | Godot 웹 export → 웹 호스트 rsync·nginx reload → Cloudflare 캐시 purge |

- **ci.yml**: 배포 안 함, 코드 무결성만 검사.
  - `server`: Python 3.13, `pip install -r requirements.txt -r requirements-dev.txt` 후 `pytest`(작업 디렉토리 `server`).
  - `gdscript`: `gdtoolkit==4.*`로 `game/` 전체 `gdparse`(구문) + `gdlint`(스타일).
  - `tracks`: 표준 라이브러리로 전 트랙 JSON `json.load` + `game/tracks/official`↔`server/app/tracks` **바이트 동일성**(체크섬 계약, `server/app/seed.py`) + `index.json` 정합(등록 id↔파일 존재, 고아 파일 없음).
- 배포 워크플로 2종: §1~6 수동 절차(웹 export·정적 업로드·nginx reload·컨테이너 교체)의 자동화. 이미지 출처만 로컬 빌드 → GHCR.

### 7-2. 필요한 Secrets

등록 위치: **Settings → Secrets and variables → Actions**. public 저장소이므로 인프라 식별값(호스트·경로·포트·컨테이너명)은 로그·소스 노출 방지 위해 **Secret**으로 관리. placeholder는 자신의 서버 값으로 채움.

| 이름 | 종류 | 사용 워크플로 | 설명 |
|---|---|---|---|
| `VM1_SSH_HOST` | secret | deploy-web | 웹(정적) 호스트 접속 주소(퍼블릭 IP/도메인) |
| `VM1_SSH_USER` | secret | deploy-web | 웹 호스트 SSH 사용자(nginx 를 reload 할 권한) |
| `VM1_SSH_KEY` | secret | deploy-web | 웹 호스트 배포용 **개인키 전체**(BEGIN/END 포함) |
| `VM1_NGINX_HTML_PATH` | secret | deploy-web | 정적 루트의 호스트 경로(컨테이너면 `/usr/share/nginx/html` 의 마운트 경로) |
| `VM1_NGINX_CONTAINER` | secret | deploy-web | nginx 컨테이너 이름(nginx 를 컨테이너로 돌릴 때) |
| `VM2_SSH_HOST` | secret | deploy-server | API 호스트 접속 주소 |
| `VM2_SSH_USER` | secret | deploy-server | API 호스트 SSH 사용자(`docker` 실행 권한) |
| `VM2_SSH_KEY` | secret | deploy-server | API 호스트 배포용 개인키 전체 |
| `VM2_CONTAINER` | secret | deploy-server | API 컨테이너 이름(예: `overlock-server`) |
| `VM2_HOST_PORT` | secret | deploy-server | API 컨테이너가 매핑될 **호스트 포트**(컨테이너 내부는 8000 고정) |
| `CLOUDFLARE_API_TOKEN` | secret | deploy-web | 캐시 Purge 전용 토큰(권한 Zone → Cache Purge). Cloudflare 미사용이면 purge 스텝 제거 |
| `CLOUDFLARE_ZONE_ID` | secret | deploy-web | 게임 도메인 존 ID |
| `GITHUB_TOKEN` | **자동** | deploy-server | GHCR 로그인·푸시에 쓰는 내장 토큰. 등록 불필요(워크플로가 `packages: write` 로 요청) |

> `VM1_SSH_KEY`·`VM2_SSH_KEY`: 배포 키 1개 공유 또는 호스트별 분리 모두 가능. 웹·API가 한 호스트면 VM1_*/VM2_*에 동일 값. `VM1`/`VM2`는 "웹 호스트 / API 호스트" 라벨일 뿐.

### 7-3. 최초 1회 준비

**(1) 배포 전용 SSH 키 생성·등록** — CI 무인 접속 → 패스프레이즈 없는 전용 키. 개인 로그인 키 재사용 금지.

```bash
# 배포 전용 ed25519 키 생성(패스프레이즈 없음).
ssh-keygen -t ed25519 -C "overlock-deploy" -f ~/.ssh/overlock_deploy -N ""

# 공개키를 각 호스트 배포 사용자의 authorized_keys 에 등록.
ssh-copy-id -i ~/.ssh/overlock_deploy.pub <web-user>@<web-host>
ssh-copy-id -i ~/.ssh/overlock_deploy.pub <api-user>@<api-host>

# 개인키(전체 내용)를 GitHub Secret 으로 등록(gh CLI 는 저장소에서 실행).
gh secret set VM1_SSH_KEY < ~/.ssh/overlock_deploy
gh secret set VM2_SSH_KEY < ~/.ssh/overlock_deploy
```

**(2) 나머지 Secret 등록** — 값은 자신의 인프라에 맞춤.

```bash
gh secret set VM1_SSH_HOST        -b "<웹 호스트/IP>"
gh secret set VM1_SSH_USER        -b "<웹 호스트 사용자>"
gh secret set VM1_NGINX_HTML_PATH -b "<정적 루트의 호스트 경로>"
gh secret set VM1_NGINX_CONTAINER -b "<nginx 컨테이너 이름>"
gh secret set VM2_SSH_HOST        -b "<API 호스트>"
gh secret set VM2_SSH_USER        -b "<API 호스트 사용자>"
gh secret set VM2_CONTAINER       -b "overlock-server"
gh secret set VM2_HOST_PORT       -b "<API 호스트 포트>"
gh secret set CLOUDFLARE_ZONE_ID  -b "<게임 도메인 zone id>"
# Cloudflare 토큰: My Profile → API Tokens → Create Token → 권한 Zone·Cache Purge,
# 대상 Zone Resources = 게임 도메인 존 으로 만든 뒤 값만 붙여넣는다.
gh secret set CLOUDFLARE_API_TOKEN
```

**(3) GHCR 패키지 public 전환** — API 호스트 **무인증** `docker pull` 조건. `deploy-server` 1회 실행 → `ghcr.io/<owner>/overlock-server` 패키지 생성 → **프로필 → Packages → overlock-server → Package settings → Change visibility → Public**. GHCR 패키지 가시성은 저장소 public 여부와 **별개** — 미전환 시 호스트에서 `docker login ghcr.io` 필요.

**(4) docker 권한** — `VM2_SSH_USER`가 `sudo` 없이 `docker` 실행 가능해야 함(`sudo usermod -aG docker <user>` 후 재로그인). nginx 컨테이너 운용 시 웹 호스트 사용자도 해당 컨테이너 `docker exec` 권한 필요.

### 7-4. 수동 트리거

Actions 탭 → 워크플로 선택 → **Run workflow**, 또는 `gh`:

```bash
gh workflow run deploy-server.yml     # 현재 main 커밋으로 서버 배포
gh workflow run deploy-web.yml        # 현재 main 커밋으로 웹 배포
```

`ci.yml`은 push/PR 자동 실행 — 수동 트리거 불필요.

### 7-5. 자동 트리거 (선택)

배포 워크플로 2종: 경로 기반 자동 배포(`paths` 필터) 기본 ON. 수동 전용화 시 각 파일 `push:` 블록 주석 처리 또는 삭제.

- `deploy-server.yml`: `server/**` 변경 push → 서버 자동 배포.
- `deploy-web.yml`: `game/**` 변경 push → 웹 자동 배포.

### 7-6. 롤백

- **서버**: 이전 커밋 SHA 이미지가 GHCR에 잔존(태그 미삭제 시) → 그 SHA로 재배포. 재빌드 생략.

  ```bash
  gh workflow run deploy-server.yml -f image_tag=<이전-커밋-SHA>
  ```

- **웹**: Actions → **Deploy Web** → 이전 성공 run **Re-run all jobs**(그 커밋 소스로 재-export·배포). 또는 그 run의 아티팩트 `overlock-web-<sha>` 내려받아 §4 수동 업로드(아티팩트 보존 5일).
