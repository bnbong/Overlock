# Overlock 웹(HTML5) 배포 가이드

Overlock 클라이언트를 브라우저에서 돌아가는 정적 웹 빌드로 만들어 개인 도메인에 올리는
절차다. 빌드 산출물(`build/web/`)은 어떤 정적 호스팅에도 그대로 올라간다. 리더보드
기능까지 쓰려면 `server/`(FastAPI)를 따로 띄우고 클라이언트에서 그 주소를 지정한다.

- 대상 엔진: **Godot 4.6.1.stable** (`4.6.1.stable.official.14d19694e` 로 검증)
- 렌더러: **GL Compatibility** (WebGL 2.0). 웹 대비로 프로젝트에 이미 설정돼 있다.
- 스레드: **OFF**(단일 스레드). 이유는 아래 "스레드 OFF 결정"에 정리했다.

---

## 1. 사전 준비: 웹 export 템플릿

웹으로 내보내려면 설치된 Godot 버전과 **정확히 같은 버전**의 웹 export 템플릿이 있어야
한다. 버전이 다르면 export 가 거부된다.

설치 위치(운영체제별):

| OS | 경로 |
|---|---|
| macOS | `~/Library/Application Support/Godot/export_templates/4.6.1.stable/` |
| Linux | `~/.local/share/godot/export_templates/4.6.1.stable/` |
| Windows | `%APPDATA%\Godot\export_templates\4.6.1.stable\` |

이 폴더에 최소한 `web_nothreads_release.zip`(스레드 OFF 릴리스 템플릿)이 있으면 된다.
현재 저장소 작업 환경에는 8종 웹 템플릿 전부 + `version.txt`가 설치돼 있다.

### 방법 A — 에디터에서 설치 (권장)

가장 확실한 방법이다. 네트워크만 되면 버전이 자동으로 맞는다.

1. Godot 에디터 실행 → 상단 메뉴 **Editor → Manage Export Templates…**
2. **Download and Install** 클릭. 현재 에디터 버전(4.6.1.stable)에 맞는 템플릿을 내려받아
   위 경로에 자동 설치한다.

### 방법 B — 릴리스에서 직접 내려받아 설치 (CLI)

에디터를 열 수 없거나 CI 에서 자동화할 때 쓴다. `.tpz`는 실은 zip 이라 `unzip`으로 푼다.

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

> `.tpz` 전체 용량이 1GB 를 넘어 내려받기가 느릴 수 있다. 회선이 느리면 방법 A 로
> 에디터에서 설치하는 편이 낫다.

---

## 2. 웹 빌드하기

빌드 설정은 `game/export_presets.cfg` 의 **"Web"** 프리셋에 들어 있다. 저장소 루트에서
아래를 실행한다(경로 인자는 프로젝트 디렉토리 `game/` 기준 상대경로라 `../build/web/…`
로 저장소 루트의 `build/web/` 에 떨어진다).

```bash
GODOT=/path/to/Godot            # 예: /Users/you/Downloads/Godot.app/Contents/MacOS/Godot

mkdir -p build/web

# 리소스가 바뀐 뒤 첫 빌드라면 임포트를 먼저 한 번(선택)
"$GODOT" --headless --path game --import

# 릴리스 export
"$GODOT" --headless --path game --export-release "Web" ../build/web/index.html
```

exit code 0 이면 성공이다. `build/web/` 에 다음이 생긴다.

| 파일 | 크기(대략) | 설명 |
|---|---|---|
| `index.html` | 5 KB | 로더 셸. 이 파일이 진입점이다. |
| `index.js` | 308 KB | 엔진 로더/글루 코드. |
| `index.wasm` | **36 MB** | 엔진 바이너리. 첫 로드의 대부분을 차지한다. |
| `index.pck` | 3.9 MB | 게임 리소스 팩(씬·스크립트·오디오·트랙). |
| `index.audio.worklet.js` / `index.audio.position.worklet.js` | 각 3~7 KB | 오디오 워클릿. |
| `index.icon.png` / `index.apple-touch-icon.png` / `index.png` | 5~21 KB | 아이콘·스플래시. |

첫 방문 시 대략 **40 MB** 를 받는다. 호스트에서 gzip/brotli 압축을 켜면 `.wasm`·`.pck`
전송량이 크게 준다(아래 4-2 참고). 재방문은 브라우저 캐시로 훨씬 가볍다.

빌드 산출물 `build/` 는 저장소 루트 `.gitignore` 에 등록돼 커밋되지 않는다.

### 스레드 OFF 결정 (성능 트레이드오프)

프리셋에서 `variant/thread_support=false` 로 **멀티스레드를 껐다**. 근거는 이렇다.

- 스레드를 켜면 브라우저가 `SharedArrayBuffer` 를 요구한다. 이를 쓰려면 페이지가
  **교차 출처 격리(cross-origin isolation)** 상태여야 한다. 즉 서버가 모든 응답에
  `Cross-Origin-Opener-Policy: same-origin` 과 `Cross-Origin-Embedder-Policy: require-corp`
  헤더를 붙여야 한다. GitHub Pages·S3 정적 웹호스팅 같은 흔한 정적 호스팅은 이 헤더를
  세밀히 지정하기 어렵거나 아예 불가능하다.
- 스레드를 끄면 그 요구가 사라져 **아무 정적 호스팅에나 그대로 올려도 부팅**한다.
  호환성이 최우선이라 이 쪽을 택했다.
- 트레이드오프: 물리·리소스 로딩 등이 메인 스레드에서만 돈다. Overlock 은 2D
  GL Compatibility 렌더러의 가벼운 게임이라 체감 영향은 작지만 대형/무거운 씬을
  올릴 계획이라면 스레드 ON + 격리 헤더를 지원하는 호스팅으로 바꾸는 걸 검토한다.

부팅 로그의 `Build configuration: … single-threaded, no GDExtension support` 로 스레드
OFF 가 실제 반영됐는지 확인할 수 있다.

### 웹에서 달라지는 동작 (웹 가드)

데스크톱과 달리 브라우저에는 앱 종료 개념과 로컬 파일 시스템 접근이 없어 아래 지점만
웹 전용으로 대체했다. **그 외 그리기·검증·저장·플레이는 웹에서도 그대로 동작**한다.

- **메인 메뉴 Quit 버튼**: 웹에서는 숨긴다(브라우저 탭이 곧 앱 수명).
- **트랙 파일 불러오기(FileDialog)·드래그드롭**: 메인 메뉴와 트랙 에디터 모두 웹에서는
  비활성하고 "웹에서는 (파일/트랙) 불러오기 미지원 (Phase 2)" 안내로 대체한다.
- **커스텀 트랙 저장·로컬 기록**: `user://` 에 쓰며, 웹에서는 브라우저 **IndexedDB** 로
  영속한다. 즉 웹에서도 트랙을 그려 저장하고, 다시 열면 그대로 남아 있다.

---

## 3. 로컬에서 확인하기

`file://` 로 직접 열면 안 된다(브라우저가 `.wasm` 을 못 가져온다). 반드시 HTTP 로 서빙한다.
저장소에 로컬 서버 스크립트가 있다(표준 라이브러리만 사용, `.wasm` MIME 를 올바로 지정).

```bash
python3 tools/web_serve.py                 # http://127.0.0.1:8060/ 로 build/web 서빙
python3 tools/web_serve.py --port 9000     # 포트 변경
python3 tools/web_serve.py --coi           # COOP/COEP/CORP 헤더 부착(스레드 ON 실험용, 평소엔 불필요)
```

브라우저로 주소를 열고 아래 **확인 체크리스트**를 따라간다.

### 브라우저 확인 체크리스트

1. **부팅** — 주소를 열면 잠깐 로딩 후 메인 메뉴가 뜬다. 콘솔(F12)에 빨간 에러가 없어야
   한다. **Quit 버튼이 없어야** 정상(웹 가드).
2. **오디오(사용자 제스처)** — 브라우저는 사용자가 클릭하기 전엔 소리를 못 낸다. **Start
   버튼을 누른 뒤** BGM·재봉틀 틱·효과음이 나오는지 확인한다.
3. **키 입력** — 메뉴에서 ←/→(또는 A/D)로 트랙이 바뀌고, 플레이 중 조작 키가 반응하는지
   확인한다.
4. **기록 영속(IndexedDB)** — 한 판을 완주해 기록을 남긴 뒤, **페이지를 새로고침**해도
   메인 메뉴의 Best 기록이 유지되는지 확인한다. 트랙 에디터에서 커스텀 트랙을 저장한 뒤
   새로고침 후에도 목록에 남아 있으면 `user://` 영속이 정상이다.
5. **웹 가드 안내** — 메인 메뉴/에디터의 Import 버튼을 누르면 "미지원 (Phase 2)" 안내가
   뜨는지 확인한다(파일 다이얼로그가 열리면 안 됨).

> 참고(자동 점검): 헤드리스 크로미움으로 부팅을 점검한 결과 콘솔 에러 0, 페이지 에러 0,
> 캔버스 1280×720, 엔진 배너 `v4.6.1.stable … single-threaded` 를 확인했다. WebGL 2.0
> Compatibility 렌더러가 정상 동작한다.

---

## 4. 정적 호스팅에 올리기

`build/web/` **안의 파일들**을 호스팅 루트(또는 원하는 하위 경로)에 그대로 업로드한다.
스레드 OFF 라서 특별한 격리 헤더 없이도 부팅한다.

### 4-1. 업로드

- **정적 호스팅(Nginx/Apache/S3+CloudFront/Netlify/개인 서버 등)**: `build/web/` 의 내용을
  올리고, 진입 URL 이 `…/index.html` 을 가리키게 한다.
- 하위 경로(예: `https://example.com/overlock/`)에 올려도 된다. 산출물은 상대경로로
  자기 옆의 `index.js`·`index.wasm`·`index.pck` 를 찾으므로 경로 이동에 강하다.

### 4-2. MIME 타입 주의 — `.wasm` 이 핵심

**`.wasm` 은 반드시 `application/wasm` 으로 서빙**해야 한다. 브라우저가 스트리밍으로
컴파일하려면 이 타입이어야 한다. `application/octet-stream` 같은 타입이면 부팅이 느려지거나
실패한다. 대부분의 최신 웹서버는 기본으로 맞지만 오래된 설정이면 명시해야 한다.

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

- `.pck` 는 `application/octet-stream` 이면 된다.
- `.js` 는 `text/javascript`(또는 `application/javascript`).
- 압축을 켜면 36 MB `.wasm` 의 전송량이 크게 준다. 미리 `*.wasm.br`/`*.wasm.gz` 를 만들어
  두는 precompressed 방식이면 서버 CPU 도 아낀다.

---

## 5. 리더보드 서버(server/) 연계

웹 클라이언트 자체는 서버 없이도 완전히 동작한다(로컬 기록만 남음). 온라인 리더보드를
쓰려면 `server/` 를 띄우고 클라이언트에서 그 주소를 지정한다.

### 5-1. 클라이언트에서 API 주소 지정

게임 안 **Settings(온라인 설정)** 화면에서 **닉네임**과 **서버 URL** 을 입력·저장한다.
저장값은 `user://settings.json`(웹에서는 IndexedDB)에 남는다. 서버 URL 을 비우면 온라인
기능은 조용히 비활성된다(오프라인).

- "서버 연결 확인" 버튼은 `GET /api/health` 로 연결성을 점검한다.
- 기록 제출/리더보드 조회는 실패해도 게임을 막지 않는다(조용히 실패).

### 5-2. 서버 CORS

`server/` 는 기본적으로 **모든 오리진 허용**(`OVERLOCK_CORS_ORIGINS=*`)이라 웹
클라이언트가 다른 도메인에서 API 를 불러도 CORS 로 막히지 않는다. 배포 시 오리진을
좁히려면 게임을 서비스하는 도메인으로 지정한다.

```bash
OVERLOCK_CORS_ORIGINS=https://overlock.example.com
```

자세한 서버 설정·배포(systemd·리버스 프록시·Docker)는 **`server/README.md`** 참고.

### 5-3. Mixed content 주의 — HTTPS 페이지에서 HTTP API 호출 금지

게임 페이지를 **HTTPS** 로 서비스하면서 서버 URL 을 **HTTP**(`http://…:8000`)로 지정하면,
브라우저가 이 요청을 **mixed content 로 차단**한다. 결과적으로 리더보드가 조용히 실패한다
(오프라인처럼 보임).

해결: **서버도 HTTPS 로 노출**한다. 서버 앱은 `127.0.0.1:8000` 에만 바인드하고 앞단에
TLS 리버스 프록시(Nginx 등)를 두어 `https://api.example.com` 같은 주소로 노출한 뒤,
클라이언트 Settings 에는 그 **HTTPS 주소**를 넣는다. 프록시 구성(TLS 종료·`X-Forwarded-For`
전달)은 `server/README.md` 의 "리버스 프록시(nginx)" 절을 그대로 따르면 된다.

> 요약: **게임 HTTPS ↔ API HTTPS** 로 맞춰라. 한쪽만 HTTP 면 mixed content 로 막힌다.

---

## 6. 문제 해결

| 증상 | 원인/해결 |
|---|---|
| 빈 화면 + 콘솔에 wasm 관련 에러 | `.wasm` MIME 가 `application/wasm` 인지 확인(4-2). |
| `file://` 로 열었더니 아무것도 안 뜸 | 정적 서버로 HTTP 서빙 필요(3장). |
| export 가 "template not found" 로 실패 | 설치된 엔진과 **같은 버전**의 웹 템플릿이 있는지 확인(1장). |
| 리더보드가 계속 오프라인 | 서버 URL 오타/미기동, 또는 HTTPS↔HTTP mixed content 차단(5-3). |
| 소리가 안 남 | 브라우저 정책상 Start(사용자 클릭) 이후에 재생됨. 정상. |
