# Overlock 트랙 에디터 & 커스텀 트랙 로딩 설계

- 대상 엔진: Godot 4.x + GDScript (데스크톱 1차, 웹 export 고려)
- 범위: 유저가 마우스로 트랙을 그려 저장하고, 저장/외부 트랙을 불러와 플레이하는 기능
- 선행 문서: `docs/design/game_design.md` §9(트랙 데이터)·§15(구조), `docs/architecture.md` §5(트랙 파이프라인)·§6(시뮬레이션)·§8(미니맵)
- 이 문서는 **결정 사항**만 기술한다. 대안은 근거가 필요한 곳에 표로 남긴다. 코드는 의사코드다.
- 아트 의존 없음: 모든 에디터 UI는 현행 `SewingSkin`(_draw 기반 재봉 스킨)만으로 그린다.

---

## 1. 핵심 결정 요약

| 항목 | 결정 | 근거(요약) |
|---|---|---|
| 저장 포맷 | **`path`에 `{"type":"polyline"}` 세그먼트 추가**. bezier 피팅은 후속(커뮤니티 공유용 canonical 변환기)으로 연기 | 게임은 어차피 6px 폴리라인으로 재베이크. WYSIWYG(별 꼭짓점 보존). 피팅 품질 리스크 회피. 커스텀은 로컬 전용이라 포맷 단일성 비용이 아직 없음 |
| 피팅 방식 | 자유곡선 → **평활(Chaikin/이동평균) → RDP 데시메이트 → 균일 재샘플** → polyline. bezier 피팅 안 함 | 결정론·구현 단순·손 떨림 제거를 동시에 만족 |
| 닫힌 윤곽 처리 | 하트·별 같은 루프도 **open path로 저작**(시작≠끝, 작은 갭). heart_01의 기존 패턴 그대로 | 피니시 판정 `s ≥ length−1` 과 시작/끝 s-분리가 성립해야 함(§9-닫힌윤곽) |
| 검증 정책 | 최소 곡률반경(≥28px, **자동 필렛 보정** 가능) · 길이(권장 2500~4500) · **자기근접(윈도 추적 한계 반영, 호길이-차 기반 하드/소프트 2단)** | 현행 윈도 추적(architecture §5.3)이 감당 가능한 기하만 허용 |
| id 체계 | `track_id = "custom_" + 8hex(랜덤, 최초 저장 시 1회 생성)`, **파일명 = id** (`custom_ab12cd34.json`). 별도 `checksum`(경로 SHA-256) 병기 | 공식 id와 네임스페이스 분리(레코드 키 충돌 없음), 편집해도 기록 유지, import 중복 감지 |
| 저장 위치 | `user://tracks/custom/<id>.json` | 쓰기 가능 경로, 웹 포함 전 플랫폼 영속 |
| 목록화 | `user://tracks/custom/` **디렉토리 스캔**(DirAccess) → 메뉴 "Custom" 섹션 | user:// 스캔은 웹(IDBFS) 포함 안정적. 매니페스트 불필요(res:// 제약과 무관) |
| 리더보드 | 커스텀은 **로컬 기록만**, 온라인 제출 제외(`is_custom` 플래그) | 유저 자작 트랙은 서버 체크섬 검증 불가(§14.2) |
| 외부 불러오기 | 데스크톱 **파일 다이얼로그 + 드래그앤드롭** 1차, 웹 업로드는 후속 | 웹 FS 접근 제약. 데스크톱이 1차 목표 |

---

## 2. 저장 포맷 결정: polyline 세그먼트 추가 (안 A)

### 2.1 비교

| 기준 | 안 A: `type:"polyline"` 추가 | 안 B: bezier 피팅으로 기존 포맷 유지 |
|---|---|---|
| 다운스트림 영향 | `TrackData.bake()`에 타입 분기 1개 추가(가산적). 나머지 파이프라인(query·미니맵·FinishView·미리보기) 전부 불변 | 완전 무변경(포맷 단일) |
| 저작 구현 난이도 | 낮음(평활·데시메이트·재샘플만) | 높음(Schneider 피팅 + 코너 검출 + 오차 재분할, ~150줄, 튜닝 필요) |
| WYSIWYG | 그린 대로 재현(재샘플 오차만) | 피팅 근사 오차 — 별 꼭짓점이 둥글어지거나 직선이 흔들릴 수 있음 |
| 파일 크기 | 3000px·6px → 약 500점 ×2 = 수 KB | 세그먼트 수십 개, 작음 |
| 결정론 | polyline→bake 재샘플이 결정론적(입력 고정 시 동일) | bezier→bake 결정론적. 단 피팅 자체는 저작 시 1회 |
| 서버/커뮤니티 호환 | 스키마 확장 필요(후속) | 즉시 호환 |

### 2.2 결정과 근거

**안 A 채택.** 결정적 이유:

1. **게임 판정은 이미 폴리라인 기반이다.** `bake()`는 bezier든 polyline이든 결국 6px 폴리라인으로 만든다(`TrackData.gd:33`). 유저가 "플레이로 느끼는" 것은 폴리라인이지 bezier가 아니다 → bezier로 한 번 피팅했다가 다시 폴리라인으로 풀면 근사 오차만 이중으로 낀다.
2. **정체성이 WYSIWYG를 요구한다.** 이 기능의 핵심은 "하트·별 같은 재미있는 모양을 유저가 직접". 피팅이 꼭짓점을 둥글리거나 곡선을 흔들면 정체성이 훼손된다.
3. **구현 리스크 배분.** 한정된 구현 예산은 피팅 수학보다 **드로잉 UX + 검증**에 써야 한다(이쪽이 사용자 체감·안정성을 좌우). 피팅은 실패 시 디버깅이 어려운 반면 재샘플은 자명하다.
4. **포맷 단일성 비용이 아직 없다.** 커스텀 트랙은 로컬 전용(§7.4). 서버 검증·커뮤니티 교환은 후속 단계이고, 그때 polyline→bezier **canonical 변환기**를 별도로 붙이면 된다(§12). polyline 트랙은 그 뒤에도 계속 로드된다(가산적 확장).
5. **확장이 가산적이다.** `bake()`는 지금도 `type`을 검사하지 않고 p0~p3만 읽는다. 타입 분기를 넣는 것은 기존 bezier 경로를 건드리지 않는 추가일 뿐이다.

### 2.3 확장된 포맷

```json
{
  "track_id": "custom_ab12cd34",
  "name": "My Heart",
  "difficulty": "normal",
  "fabric": "cotton",
  "length": 2980,
  "width": { "perfect": 18, "safe": 42, "fail": 90 },
  "path": [
    { "type": "polyline", "points": [[-227,313],[-233,305], ...], "closed": false }
  ],
  "modifiers": [],
  "is_custom": true,
  "checksum": "sha256:....",
  "editor_version": "0.1.0"
}
```

- `path`는 polyline 세그먼트 1개(단일 스트로크) 또는 여러 개(다중 스트로크 이어붙임)일 수 있다.
- `points`는 저작 시 균일 재샘플(≤6px)된 좌표. `bake()`가 다시 ≤6px로 보정하므로 간격이 다소 커도 안전.
- **`closed`는 `bake()`/`query()`가 소비하지 않는다 — 순수 저작/재편집 힌트다.** 현행 아키텍처에는 "폐곡선"이라는 판정 개념이 없다. heart_01·star_01 같은 닫힌 트랙도 실은 시작·끝이 기하적으로 가까운 **open path**일 뿐이며(TrackData.gd:12-16 주석), s·피니시는 항상 선형 경로로 처리된다. 따라서 유저가 "루프 닫기"를 켜도 저장되는 `points`는 이미 갭을 둔 open 폴리라인이고(§9), `closed`는 나중에 에디터로 **다시 열어 편집할 때 UI 상태를 복원**하는 용도에 국한된다. 소비처가 없는 필드를 남기는 게 꺼려지면 v1에서는 아예 생략해도 무방하다(저작 상태는 시작/끝 근접으로 재추론 가능). **결코 `bake()`가 `closed=true`를 보고 끝→시작을 잇게 만들지 말 것** — 피니시가 깨진다(§9).
- `width`는 난이도 프리셋에서 채운다(§4.5). `modifiers`는 MVP 미사용(파싱만).
- 공식 트랙(bezier)·커스텀 트랙(polyline)이 **같은 `path` 스키마 안에서 공존**한다. 두 타입은 스키마에 **영구 공존**시키되(로드 시 몰래 bezier로 변환하지 않음 — §2.5), 정책적으로 공식=bezier / 커스텀=polyline으로 운용한다.

### 2.4 `bake()` 확장 (의사코드 — `TrackData.gd` 수정)

```gdscript
func bake(path_json: Array) -> void:
    points = PackedVector2Array()
    s_arr = PackedFloat32Array()
    for seg in path_json:
        match str(seg.get("type", "bezier")):
            "polyline":
                _bake_polyline(seg)     # 신규
            _:
                _bake_bezier(seg)       # 기존 로직을 이 함수로 추출(동작 불변)
    length = s_arr[s_arr.size() - 1] if s_arr.size() > 0 else 0.0

func _bake_polyline(seg: Dictionary) -> void:
    var raw: Array = seg.get("points", [])
    for k in range(raw.size()):
        var q: Vector2 = _to_vec(raw[k])
        if points.is_empty():
            _append(q); continue
        var last: Vector2 = points[points.size() - 1]
        if k == 0 and last.distance_to(q) < 0.01:
            continue                     # 이전 세그먼트 끝점과 공유 → 중복 제거
        # 긴 간격은 ≤ BAKE_INTERVAL(6px)로 잘게 나눠 넣어 query 윈도 가정을 지킨다.
        var n: int = maxi(1, ceili(last.distance_to(q) / BAKE_INTERVAL))
        for m in range(1, n):
            _append(last.lerp(q, float(m) / float(n)))
        _append(q)
```

> **함정(재샘플).** `query()`의 `FWD_WIN=12`·`RELOCALIZE_FWD_WIN=40`은 점 간격 ≈6px를 전제로 "앞 72px / 240px"를 의미한다. polyline을 재샘플하지 않고 30px 간격으로 그대로 넣으면 같은 인덱스 윈도가 360px·1200px 앞을 보게 되어 추적 거동이 달라진다. **`_bake_polyline`은 반드시 ≤6px로 세분해야 한다.**

### 2.5 로드 시점 자동 정규화 금지 (결정론)

polyline 트랙을 **로드 시점에 몰래 bezier로 변환하지 않는다.** 피팅/평활 알고리즘은 버전에 따라 결과가 미세하게 달라지므로, 로드마다 재변환하면 같은 저장 파일이 버전업 후 **모양·플레이·(후속)리플레이가 조용히 달라진다**(결정론 드리프트). polyline은 저장된 그대로 `bake()`에서 결정론적으로 폴리라인화될 뿐이다. bezier 변환이 필요한 경우(커뮤니티 공유·서버)에만 **명시적 "export/canonicalize" 단계**(§13)에서, 저작 시 1회, 유저가 인지한 채로 수행한다.

---

## 3. 에디터 씬 / 노드 구조

새 씬 `TrackEditor.tscn` 1개. 메인 메뉴에서 진입, 저장/취소 시 메뉴로 복귀.

```text
TrackEditor              (Control)              [TrackEditor.gd]  ← 모드·언두·저장 흐름 소유
├─ Background            (ColorRect)            어두운 배경(Main과 동일 톤)
├─ Canvas               (Control)              [DrawCanvas.gd]  전체 작업면, _draw + 마우스 입력
│   (재봉 패치 배경 · 원시 스트로크 · 평활 중심선 · fail 코리도 밴드 · 검증 마커 · 그리드)
├─ Toolbar              (HBoxContainer/Panel)  [SewingSkin 배경]
│   ├─ ModeDraw         (Button)  "그리기"   (기본)
│   ├─ ModeErase        (Button)  "지우기"
│   ├─ CloseToggle      (CheckButton) "루프 닫기"
│   ├─ UndoButton       (Button)  "실행취소(Ctrl+Z)"
│   ├─ ClearButton      (Button)  "전체 지우기"
│   └─ ValidateButton   (Button)  "검증"
├─ MetaPanel            (Control/VBox)         [SewingSkin 배경]  검증 통과 후 활성
│   ├─ NameEdit         (LineEdit) 이름
│   ├─ DifficultyOption (OptionButton) Beginner..Master
│   ├─ FabricOption     (OptionButton) cotton/denim/silk/knit/...
│   ├─ SaveButton       (Button)  "저장"
│   └─ TestPlayButton   (Button)  "테스트 플레이"
├─ StatusLabel          (Label)   검증 결과·안내(예: "곡률 2곳 위반")
└─ ImportDialog         (FileDialog) 데스크톱 외부 파일 불러오기(메뉴에서도 재사용 가능)
```

핵심:
- **`DrawCanvas`가 유일한 _draw 노드**다. 원시 입력·평활 결과·코리도·검증 마커를 한 곳에서 그린다(레이어 분리 불필요). `SewingSkin.draw_patch`/`draw_stitch_border`로 배경 패치를 그려 스킨을 통일한다.
- **world↔screen 변환**을 `DrawCanvas`가 보유한다(`_pan: Vector2`, `_zoom: float`). 트랙은 1000px 이상 넓을 수 있는데 화면은 1280×720이므로, **패닝(중클릭 드래그/스페이스+드래그)과 줌(휠)** 이 필요하다. 좌표는 항상 **월드 단위**로 저장하고 그릴 때만 변환한다.
- `TrackEditor.gd`는 모드 상태기계(DRAW/ERASE), 언두 스택, 검증 호출, 메타 입력, 저장을 소유한다. `DrawCanvas`는 순수 뷰+입력 수집으로 두고 스트로크 데이터는 `TrackEditor`가 소유(언두 일관성).

### 3.1 화면 레이아웃 (1280×720 예시)

```text
┌───────────────────────────────────────────────────────────────┐
│ [그리기][지우기] □루프닫기  [↶실행취소] [전체지우기]  [검증]   │  ← Toolbar(상단)
│                                                                 │
│            · · · · · · (연한 그리드) · · · · · ·                │
│                    ╭──────────────╮                             │
│                   ╱  그린 중심선   ╲   ← fail 코리도(옅은 밴드)  │
│                  │   (실 보라 선)   │                            │
│                   ╲                ╱   ● 시작(초록) ▣ 끝(체크)   │
│                    ╰──────────────╯                             │
│                                                                 │
│  이름:[__________]  난이도:[Normal ▾]  원단:[cotton ▾]          │  ← MetaPanel(하단, 검증 후)
│                                   [저장]   [테스트 플레이]       │
│  status: 검증 통과 — 길이 2980px, 최소반경 47px               │
└───────────────────────────────────────────────────────────────┘
```

---

## 4. 에디터 UX 흐름

`그리기 → 미리보기 → 최소 편집 → 검증 → 메타 입력 → 저장`

### 4.1 그리기 (마우스 필수)

| 입력 | 동작 |
|---|---|
| 좌클릭 드래그 | 자유곡선 그리기. `_gui_input`/`_input`의 마우스 모션에서 **최소 이동 4px마다** 월드 좌표를 원시 스트로크에 추가 |
| 좌클릭 릴리스 | 스트로크 확정 → 평활·재샘플 파이프라인 실행(§5) → 미리보기 갱신 → **언두 스택 push** |
| (기존 스트로크 있음) 다시 그리기 | 새 스트로크의 시작점이 기존 경로의 **가까운 끝점**(스냅 반경 내)이면 이어붙임(append). 아니면 교체 확인 |
| 중클릭 드래그 / Space+드래그 | 패닝 |
| 휠 | 줌 인/아웃(커서 기준) |

- 그리는 도중에는 원시 점을 **얇은 선**으로 즉시 그려 피드백. 릴리스 시 평활 결과(중심선 + 코리도 밴드)로 대체.
- 단일 연속 스트로크를 기본으로 하되, 다중 스트로크는 끝점 이어붙임으로 지원(구현 단순화를 원하면 1차엔 단일 스트로크만 허용하고 다중은 후속).

### 4.2 미리보기

- 평활된 **중심선**(실 보라, `SewingSkin.THREAD_PURPLE`)과 **fail 폭 코리도**(±fail, 옅은 밴드 — FinishView `BAND_COLOR` 재사용)를 그린다. 유저가 "실제 플레이 폭"을 즉시 본다.
- **시작점 초록 원 / 끝점 체크 마커**(FinishView의 START/FINISH 색 재사용)로 방향과 피니시 위치를 명시.
- 진행 방향 화살표(첫 두 점 접선)로 자동 전진 방향을 보여준다.

### 4.3 최소 편집

| 기능 | 조작 | 구현 |
|---|---|---|
| **실행취소(Ctrl+Z)** | Ctrl+Z / 툴바 버튼 | 스트로크/지우기/닫기토글 각 커밋을 스택에 push. **최소 1단계, 스택 권장.** 상태 스냅샷(원시 스트로크 배열)을 저장 |
| 부분 지우기 | "지우기" 모드에서 경로 근처 드래그 | 브러시 반경 내 점 삭제(스트로크 분할/트림). 삭제 커밋도 언두 스택에 |
| 끝에서 지우기 | Backspace | 마지막 N점 트림(간단 대안) |
| 전체 지우기 | Delete / 툴바 | 확인 후 초기화(언두 가능) |
| 루프 닫기 | C / 체크버튼 | 끝점을 시작점 근처(작은 갭)로 연결(§9). 토글 |

> 언두 스택은 원시 스트로크 배열의 얕은 스냅샷을 N단(예: 20) 보관. 평활 결과는 파생값이라 저장 불필요(재계산).

### 4.4 검증

- "검증" 버튼 → `TrackValidator`(§6) 실행. 결과를 **`DrawCanvas`에 오버레이 마커**로 표시:
  - 곡률 위반 구간: 빨간 원호 하이라이트.
  - 자기근접 위반 쌍: 두 구간을 잇는 빨간 점선.
  - 길이 이탈: StatusLabel에 텍스트.
- **통과해야 MetaPanel·저장이 활성**된다(잠금 게이트).

### 4.5 메타 입력

| 필드 | 값 | 비고 |
|---|---|---|
| 이름 | 자유 텍스트(1~24자) | 파일명과 무관(id는 해시/랜덤) |
| 난이도 | Beginner/Normal/Expert/Master | **width 프리셋을 결정**(아래) |
| 원단 | cotton/denim/silk/knit/... | 시각·(후속)물성. MVP는 표시용 |

난이도 → width 프리셋(단순화; 유저가 폭까지 정하지 않게 함):

| 난이도 | perfect | safe | fail |
|---|---:|---:|---:|
| Beginner | 22 | 52 | 108 |
| Normal | 18 | 42 | 90 |
| Expert | 14 | 34 | 72 |
| Master | 12 | 28 | 60 |

> 고급 사용자를 위한 폭 수동 오버라이드는 후속. 프리셋 하나로 시작하면 검증(자기근접 임계 = fail)이 난이도와 자동으로 맞물린다.

### 4.6 저장

- `TrackValidator` 재확인 → id 생성(최초) → `length` 계산 → `checksum` 산출 → `user://tracks/custom/<id>.json` 기록(§7).
- 저장 후 선택: "테스트 플레이"(→ `GameState.start_run(id, diff)`) 또는 메뉴 복귀(Custom 섹션에 등장).

### 4.7 조작 요약 (마우스 필수 · 키보드 보조)

| 입력 | 기능 |
|---|---|
| 좌클릭 드래그 | 그리기 / (지우기 모드) 지우기 |
| 중클릭·Space+드래그 | 패닝 |
| 휠 | 줌 |
| **Ctrl+Z** | 실행취소(≥1단) |
| C | 루프 닫기 토글 |
| Backspace | 끝에서 지우기 |
| Delete | 전체 지우기 |
| Enter | 검증(→통과 시 저장 포커스) |
| Esc | 취소(변경 있으면 확인) → 메뉴 |

---

## 5. 드로잉 파이프라인 (raw → smooth → decimate → resample → path)

`StrokeProcessor`(RefCounted). 원시 점 배열 → 저장 가능한 polyline 세그먼트.

```gdscript
# StrokeProcessor.process(raw: PackedVector2Array, closed: bool) -> PackedVector2Array
func process(raw: PackedVector2Array, closed: bool) -> PackedVector2Array:
    if raw.size() < 2:
        return raw
    var n := _normalize(raw)           # 0) 정규화: 중복점/0길이 제거, 좌표 quantize, 상한 클램프
    var corners := _detect_corners(n)  # 1) 코너 후보 표시(급격한 방향 전환점 = 별 꼭짓점 등)
    var s := _smooth(n, corners)       # 2) 평활(Chaikin 2회/이동평균 창5) — 코너 인덱스는 보존
    var d := _decimate_rdp(s, 2.0)     # 3) RDP 데시메이트(ε≈2px) — 곡률 노이즈↓
    var r := _resample_uniform(d, BAKE_INTERVAL, corners)  # 4) 균일 ≤6px 재샘플(코너 강제 삽입)
    if closed:
        r = _apply_close_gap(r)        # 5) 끝점을 시작점 근처로(작은 갭 유지, §9)
    return r
```

- **0) 정규화(저장 전 필수)**: 연속 중복점·0길이 세그먼트 제거, 최소 세그먼트 거리(예: 1px) 필터, 좌표 quantize(예: 0.1px 반올림 → 파일·checksum 안정), 점 수·좌표 범위 상한 클램프(악의적/퇴화 입력 차단).
- **1) 코너 검출 & 보존**: 인접 방향 전환각이 임계(예: >50°) 이상인 점을 **코너 후보로 표시**한다. 평활·재샘플이 이 점을 뭉개면 별 꼭짓점 같은 의도된 뾰족함이 6px 샘플 사이에 묻혀 사라진다 → **평활에서 코너 인덱스는 이동/제거하지 않고, 재샘플 시 코너 좌표를 강제 삽입**한다.
- **2) 평활**: Chaikin(코너 컷) 2회 또는 창 5 이동평균. 픽셀 지터 제거로 이후 곡률 측정이 의도를 반영하게 한다(코너 후보 구간은 약하게 적용).
- **3) 데시메이트(RDP)**: ε≈2px로 직선 구간 점 감소(파일·계산 절감).
- **4) 균일 재샘플**: 호길이 기준 ≤6px 등간격 + 코너 강제 삽입. `bake()` 재샘플과 이중 안전망.
- **5) 닫기 갭**: §9.

> 평활은 곡률을 **키우는** 방향이라 min-radius 검증 통과에 유리하다. 단, 유저가 의도한 뾰족함(별 꼭짓점)은 평활만으론 min-radius 아래로 남을 수 있음 → 검증 단계의 **자동 필렛**(§6.2)이 처리. 코너 보존(1)과 자동 필렛(§6.2)은 상보적이다: 보존은 "의도한 꼭짓점을 잃지 않게", 필렛은 "너무 뾰족해 주행/추적 불가한 꼭짓점만 최소반경으로 둥글게".

---

## 6. 검증 규칙

`TrackValidator`(RefCounted). 입력은 **재샘플된 폴리라인 + 판정 폭(width)**. 출력은 위반 목록(구간 인덱스·종류·자동수정 가능 여부).

### 6.1 규칙 표

| 규칙 | 임계 | 판정 | 실패 처리 |
|---|---|---|---|
| 최소 점 수 | ≥ 8점 & 유효 길이 | 하드 | 저장 불가("너무 짧음") |
| **최소 곡률반경** | ≥ **28px**(하드), 권장 ≥45px | 하드(권장은 소프트) | **자동 필렛 제안**(§6.2) 또는 위반 하이라이트 |
| **길이** | 권장 **2500~4500px**. 하드 하한 1500 / 상한 8000 | 권장=소프트, 극단=하드 | 범위 밖이면 "스케일 맞추기" 제안(§6.4) 또는 경고 |
| **자기근접** | 호길이-차 기반 2단(§6.3) | 하드/소프트 | 하드는 위반 쌍 하이라이트→재편집 요구. 소프트는 경고만 |
| 시작/끝 분리 | 시작·끝 s가 최대한 떨어짐(open path) | 하드(닫기 시 자동보장) | §9로 자동 처리 |
| 자기교차(선택) | 인접 아닌 세그먼트 교차 없음 | 소프트 | 경고(코리도 겹침 안내). 교차 자체는 자기근접에 흡수 |

기본 임계 상수(추적 윈도에서 유도):

```gdscript
const MIN_RADIUS := 28.0                # 1단 회전반경 24px < 28 → 최저 기어로 주행 가능(여유)
const RADIUS_RECOMMEND := 45.0
const LEN_MIN := 2500.0; const LEN_MAX := 4500.0     # 권장
const LEN_HARD_MIN := 1500.0; const LEN_HARD_MAX := 8000.0
const ARC_EXEMPT := 110.0               # ≈ π·MIN_RADIUS·1.2 : 합법 최소반경 U턴 이웃 면제
const RELOCALIZE_REACH := 300.0         # ≈ RELOCALIZE_FWD_WIN(40)·BAKE(6)=240 + 여유
```

> **곡률 28px의 이중 근거.** (a) 주행성: architecture §6.3에서 1단 최소 회전반경 24px, 5단 75px. 28px면 1~2단으로 모든 커브 추종 가능(24px보다 여유). (b) 추적 안정성: 반경 R U턴의 반호 길이 πR가 `FWD_WIN`(72px)보다 커야 반대편이 정상 윈도에 안 들어온다 → R > 72/π ≈ 23px. 28px는 두 조건을 동시에 만족한다.

### 6.2 최소 곡률반경 — 자동 필렛(스무딩으로 자동 보정) vs 경고

**결정: 자동 필렛을 기본 제안, 실패 잔여는 경고.** 곡률은 **자동 보정 가능한 유일한 하드 규칙**이다.

- 이산 곡률(균일 간격이라 3점 원주율 Menger 공식):
  `R_i = (|AB|·|BC|·|CA|) / (4·Area(A,B,C))`, A=points[i-k], B=points[i], C=points[i+k].
  - **k는 ~15px 상당(≈2~3점)** 을 span하게 잡아 픽셀 노이즈 억제(단일 인접점은 지터에 취약).
- `R_i < MIN_RADIUS`인 정점은 **반경 MIN_RADIUS 원호(필렛)로 치환** 제안. 유저가 "자동 수정" 누르면 해당 코너만 둥글린다(별 꼭짓점이 살짝 둥글어짐 — 기존 star_01 꼭짓점도 둥근 bezier다: 좌표 [97,-397] 등 참조).
- 필렛으로도 못 살리는(너무 뾰족·자기근접 유발) 코너는 빨간 하이라이트 + 재편집 요구.

### 6.3 자기근접 — 윈도 추적 한계 반영 (가장 중요한 규칙)

현행 `query()`(architecture §5.3)는 인덱스 한계 윈도(뒤 `RELOCALIZE_BACK_WIN=12` / 앞 `RELOCALIZE_FWD_WIN=40`)로만 재로컬라이즈하므로, **호길이로 충분히 먼 가지는 절대 다른 가지로 s를 순간이동시키지 않는다.** 문제는 **호길이가 애매하게 가까운데(윈도 도달 범위) 공간적으로도 가까운** 두 구간이다 — 여기서 s가 튀어 피니시/미니맵이 깨진다(과거 heart_01·star_01 버그와 동종).

호길이-차(Δs)로 3구간 분류:

| Δs 구간 | 의미 | 판정 |
|---|---|---|
| Δs ≤ ARC_EXEMPT(≈110px) | 합법적 급커브(U턴)의 양쪽 — 추적이 인덱스로 자연 분리 | **면제** (곡률 규칙이 별도로 관장) |
| ARC_EXEMPT < Δs ≤ RELOCALIZE_REACH(≈300px) | **크로스락 위험대**: 윈도 도달권 안에서 공간적으로 가까우면 s 점프 가능 | 공간거리 < fail → **하드 리젝트** |
| Δs > RELOCALIZE_REACH | 인덱스 한계가 완전 보호(추적 안전). 단 코리도가 시각적으로 겹칠 수 있음 | 공간거리 < 1.5·fail → **소프트 경고**(플레이어 혼란만) |

```gdscript
# 공간 해시 그리드(셀=fail)로 근접쌍만 검사 → 사실상 O(n)
func check_self_proximity(pts, s_arr, fail) -> Array:
    var violations := []
    var grid := _build_spatial_hash(pts, fail)      # 셀 크기 = fail
    for i in range(pts.size()):
        for j in grid.neighbors(i, fail * 1.5):     # 반경 1.5·fail 후보만
            if j <= i: continue
            var ds := absf(s_arr[i] - s_arr[j])
            if ds <= ARC_EXEMPT: continue           # 합법 급커브 이웃 면제
            var d := pts[i].distance_to(pts[j])
            if ds <= RELOCALIZE_REACH and d < fail:
                violations.append({"i": i, "j": j, "kind": "hard"})
            elif d < fail * 1.5:
                violations.append({"i": i, "j": j, "kind": "soft"})
    return violations
```

> **왜 시작/끝 근접(heart_01 55~103px)은 통과하나:** 시작점과 끝점의 Δs는 전체 길이(~3000px) ≫ RELOCALIZE_REACH → "소프트 경고"에도 fail 거리 조건만 볼 뿐, 애초에 추적 안전. heart·star류 open 루프는 하드 리젝트에 안 걸린다.

### 6.4 길이 & 스케일 맞추기

- 재샘플 후 `length` 산출. 권장 2500~4500 밖이면 StatusLabel 경고.
- **"길이 맞추기" 옵션**: 전체 경로를 스칼라 배율 k로 스케일해 목표 길이(예: 3200)에 맞춤. **부수효과: 곡률반경도 ×k** — 작게 그린 뾰족한 그림을 키우면 min-radius를 자연히 통과(유리). 단 모양 비율은 유지(등방 스케일). 유저가 원치 않으면 스킵.

### 6.5 시작·끝 & 열림/닫힘

- **열린 경로**: 그린 그대로. 시작=첫 점, 피니시=끝 점. 자동 전진 방향=시작 접선.
- **닫힌 윤곽**(루프 닫기 on): §9의 open-루프 저작으로 처리. 검증상 시작/끝 s-분리 자동 보장.

### 6.6 검증 실패 UX

- 하드 위반 존재 → 저장 버튼 비활성 + `DrawCanvas` 오버레이 마커 + StatusLabel에 항목별 카운트("곡률 2 · 자기근접 1").
- 마커 클릭/호버 시 해당 구간으로 뷰 이동(선택). 자동수정 가능 항목엔 "자동 수정" 버튼 노출.
- 소프트 경고만 남으면 저장 허용(확인 다이얼로그 없이 배지 표시).

---

## 7. 저장 / 불러오기 / id / 삭제

### 7.1 id 체계 (충돌 방지)

- **`track_id = "custom_" + 8자리 hex`** — 최초 저장 시 1회 생성(랜덤; 예: `"%08x" % (randi())` 또는 시간+랜덤 해시), JSON에 박제. **파일명 = id** → `user://tracks/custom/custom_ab12cd34.json`.
- **랜덤 id를 콘텐츠 해시가 아니라 랜덤으로** 두는 이유: 편집해도 id 불변 → `RecordStore`의 `"id|difficulty"` 기록이 유지된다(콘텐츠 해시는 편집마다 기록 고아화).
- 별도 `checksum`(경로 좌표 SHA-256)을 병기: import 중복 감지 + 후속 서버 체크섬 대비.
- 공식 id(`cotton_01`…)와 `custom_` 접두로 **네임스페이스 완전 분리** → 레코드 키·로드 경로 충돌 없음.

### 7.2 저장 경로 & 디렉토리

- 루트: `user://tracks/custom/`. **첫 저장 전 `DirAccess.make_dir_recursive_absolute("user://tracks/custom")`** 필수(없으면 열기 실패 — 함정).
- 파일 = 확장 포맷(§2.3) JSON.

### 7.3 TrackLoader 확장 (수정 — 기존 최소 변경)

`TrackLoader`가 트랙 IO 단일 소유자이므로 커스텀 IO도 여기에 흡수(새 오토로드 추가 안 함).

```gdscript
const CUSTOM_DIR := "user://tracks/custom/"

# 로드: 공식 우선, custom_ 접두거나 공식에 없으면 user:// 조회
func load_track(track_id: String) -> TrackData:
    if _cache.has(track_id): return _cache[track_id]
    var path := (CUSTOM_DIR + track_id + ".json") if track_id.begins_with("custom_") \
                else (OFFICIAL_DIR + track_id + ".json")
    var data := _load_from_file(path)          # 기존 파서 재사용(폴리라인 bake는 §2.4)
    if data != null: _cache[track_id] = data
    return data

# 목록: user://tracks/custom/ 디렉토리 스캔(웹 IDBFS 포함 안정)
func list_custom_tracks() -> Array:
    var out := []
    var dir := DirAccess.open(CUSTOM_DIR)
    if dir == null: return out
    for f in dir.get_files():
        if not f.ends_with(".json"): continue
        var hdr := _read_header(CUSTOM_DIR + f)   # track_id/name/difficulty만 파싱
        if hdr != null: out.append(hdr)
    out.sort_custom(func(a, b): return a["name"] < b["name"])
    return out

# 저장/삭제
func save_custom_track(track_dict: Dictionary) -> String   # id 반환, 파일 기록
func delete_custom_track(track_id: String) -> bool         # 파일 삭제 + 캐시 무효화
```

> **매니페스트 불필요.** `TrackLoader` 주석이 경계한 것은 **`res://` 패킹 빌드에서 DirAccess 불안정**이었다. `user://`는 데스크톱·웹(IDBFS) 모두 `get_files()`가 동작하므로 커스텀은 디렉토리 스캔이 정석이다.

### 7.4 레코드 · 재봉 평점 호환

- `RecordStore`는 `"track_id|difficulty"` 키(custom id 고유) → **무변경으로 커스텀 기록 저장/조회**.
- `RunStats.finalize`의 재봉 평점(`grade`/`grade_score`)은 run 통계 + `track.safe`만 쓰므로 커스텀도 동일 동작 → **무변경**.
- 삭제 시 옵션: `RecordStore.purge(track_id)`(신규, 선택)로 고아 기록 정리. 안 지워도 무해(키가 고유·미참조).

### 7.5 메뉴 통합 (수정 — MainMenu/Main.tscn)

- `MainMenu._ready`의 `_tracks = TrackLoader.list_tracks()` 뒤에 **`_tracks += TrackLoader.list_custom_tracks()`**(각 항목에 `is_custom=true` 태그). 기존 ◀▶ 셀렉터가 그대로 커스텀까지 순환. InfoLabel에 "CUSTOM" 배지 표시.
- 신규 버튼 3개(메뉴 하단): **"트랙 만들기"**(→ TrackEditor.tscn), **"불러오기"**(→ ImportDialog), 그리고 현재 선택이 커스텀일 때만 **"삭제"** 노출.
- 미리보기(`_on_preview_draw`)는 `track.points`만 쓰므로 커스텀도 **무변경으로 실루엣 표시**.

---

## 8. 외부 파일 불러오기

| 플랫폼 | 방식 | 우선순위 |
|---|---|---|
| 데스크톱 | **`FileDialog`(OS 파일 열기)** → JSON 파싱 → 검증 → `save_custom_track`(새 id·checksum 부여, 중복이면 확인) | **1차** |
| 데스크톱 | **드래그앤드롭**: `get_window().files_dropped` 시그널로 경로 수신 → 동일 import 경로 | **1차** |
| 웹 | HTML5 파일 업로드: `JavaScriptBridge`로 `<input type=file>` 트리거 → 버퍼 수신 → import. 제약 큼 | 후속 |
| 웹(폴백) | **JSON 붙여넣기 textarea**(파일 없이 텍스트 직접) | 후속(간이) |

- import 시 **반드시 `TrackValidator`를 통과**시켜(외부 파일이 추적 불가 기하일 수 있음) 저장. 실패하면 거부 + 사유 표시.
- id는 원본 유지가 아니라 **로컬 새 id 부여**(다른 사람의 `custom_xxxx`가 내 것과 충돌 방지). 단 `checksum`이 이미 로컬에 있으면 "이미 있음"으로 중복 스킵.
- 단계 구분: **Phase 1 = 데스크톱 다이얼로그+드래그드롭**, Phase 2 = 웹 업로드/붙여넣기.

---

## 9. 닫힌 윤곽을 open path로 저작 (핵심 함정)

하트·별처럼 "닫힌 것처럼 보이는" 트랙도 **경로는 선형(open)** 이어야 한다. 이유:

- 피니시 판정은 `probe.s >= track.length − 1.0`(RaceDirector.gd:164). 경로가 literally 닫히면(끝=시작 좌표 동일) 끝 지점의 s가 시작과 붙어 **피니시가 영영 안 오거나** 시작/끝 최근접이 혼동된다.
- 기존 `heart_01`이 정답 패턴이다: 시작 `[-227,313]`, 끝 `[-162,393]` — **가깝지만 다른 점**, 그 사이에 작은 갭. 시작(초록)·피니시(체크) 마커가 이 갭에 놓인다.

**`_apply_close_gap` 규칙:**
- 유저가 "루프 닫기"를 켜면, 끝점을 시작점으로 **완전히 연결하지 않고** 시작점 근처(예: 시작 접선 방향으로 `fail`~`1.5·fail`만큼 못 미친 지점)에서 끊는다.
- 시작/끝 Δs = 전체 길이가 되도록 유지(§6.3에서 하드 리젝트 면제 보장).
- 시각적으로는 거의 닫힌 하트/별, 기능적으로는 s 단조 증가하는 open 트랙.

```gdscript
func _apply_close_gap(r: PackedVector2Array) -> PackedVector2Array:
    # 끝을 시작 근처로 당기되, 시작점과 GAP(=fail) 만큼 간격을 남긴다.
    var start := r[0]
    var gap := 90.0
    # 시작 접선 반대쪽으로 gap 떨어진 지점까지만 이어지도록 끝 구간을 트림/보간.
    return _trim_end_to_gap(r, start, gap)
```

---

## 10. 플레이 파이프라인 통합 영향

| 시스템 | 파일 | 영향 |
|---|---|---|
| 베이크 | `TrackData.gd` | **수정**: `bake()` 타입 분기 + `_bake_polyline`(§2.4). bezier 경로 불변 |
| 로드/목록 | `TrackLoader.gd` | **수정**: custom 로드/목록/저장/삭제(§7.3). 공식 경로 불변 |
| query·seam·피니시 | `TrackData.query`, `RaceDirector` | **무변경**. 폴리라인 소스에 무관(검증이 추적 가능 기하 보장) |
| 미니맵 | `MiniMap.gd` | **무변경**. s-윈도 폴리라인만 사용 |
| 완주 줌아웃 | `FinishView.gd` | **무변경**. `track.points` + trail 사용 |
| 메뉴 미리보기 | `MainMenu._on_preview_draw` | **무변경**. `track.points`만 사용 |
| 메뉴 목록/진입 | `MainMenu.gd`, `Main.tscn` | **수정**: Custom 섹션 + 만들기/불러오기/삭제 버튼 |
| 로컬 기록 | `RecordStore.gd` | **무변경**(키 고유). 선택적 `purge` 추가 |
| 재봉 평점 | `RunStats.gd` | **무변경** |
| 리더보드(후속) | (미구현) | 커스텀은 `is_custom`로 온라인 제출 **제외**. 로컬 기록만 |
| 씬 버스 | `GameState.gd` | **무변경**(id 기반 로드). 필요 시 `is_custom` 참고값만 |

---

## 11. 구현 파일 목록과 책임

기존 파일 수정 최소화 원칙. **신규 5 / 수정 4.**

### 신규

| 파일 | 타입 | 책임 |
|---|---|---|
| `scenes/TrackEditor.tscn` | Control 씬 | 에디터 레이아웃(§3). 모두 `SewingSkin`/`_draw`로 구성(아트 없음) |
| `scripts/editor/TrackEditor.gd` | Control | 모드 상태기계, **언두 스택**, 검증 호출, 메타 입력, 저장 흐름 소유 |
| `scripts/editor/DrawCanvas.gd` | Control | 유일한 `_draw`(패치 배경·원시 스트로크·중심선·코리도·검증 마커). 마우스 입력 수집, world↔screen(pan/zoom) |
| `scripts/editor/StrokeProcessor.gd` | RefCounted | 평활→RDP→균일 재샘플→닫기 갭(§5, §9). 원시 점 → polyline 세그먼트 |
| `scripts/track/TrackValidator.gd` | RefCounted | 곡률(Menger)·길이·**자기근접(공간해시)**·시작끝 검증(§6). 위반 목록 반환 |

### 수정

| 파일 | 변경 | 규모 |
|---|---|---|
| `scripts/track/TrackData.gd` | `bake()` 타입 분기 + `_bake_polyline` | 소(가산적) |
| `scripts/autoload/TrackLoader.gd` | custom load/list/save/delete(§7.3) | 중 |
| `scripts/ui/MainMenu.gd` | Custom 섹션 병합 + 만들기/불러오기/삭제 버튼 핸들러 | 중 |
| `scenes/Main.tscn` | 버튼 3개 노드 + (선택)FileDialog 노드 추가 | 소 |

(선택) `RecordStore.gd`에 `purge(track_id)` 추가 — 삭제 정리용.

---

## 12. 구현 순서 · 규모 · 함정

### 12.1 권장 순서

1. `TrackData._bake_polyline` + `TrackLoader` custom load/list (백엔드부터 — 손으로 만든 polyline JSON을 넣어 플레이 검증 가능).
2. `TrackValidator`(곡률·길이·자기근접) — 단위 테스트 대상(순수 함수).
3. `StrokeProcessor`(평활·재샘플·닫기).
4. `DrawCanvas`(그리기·미리보기·마커) → `TrackEditor`(모드·언두·저장).
5. `MainMenu` 통합(Custom 섹션·진입·삭제).
6. import(데스크톱 다이얼로그+드래그드롭).
7. (후속) 웹 import, polyline→bezier canonical 변환기, 커뮤니티 공유/서버.

### 12.2 규모 추정

- **신규 5 파일 + 수정 4 파일.**
- **난이도: 중.** 순수 로직(bake·validator·processor)은 자명하고 테스트 가능. 실질 난도는 `DrawCanvas`의 마우스 UX(pan/zoom·모드·마커)와 `MainMenu` 통합에 집중.
- 대략 **4~5 개발일**(백엔드 1.5 + 에디터 UI 2 + 통합/삭제/import 1). 웹 import는 별도.

### 12.3 구현 워커가 주의할 함정

1. **자기근접 = 최우선 함정.** 검증이 느슨하면 그린 트랙에서 과거 heart/star의 s 순간이동·피니시 미발동 버그가 재현된다. §6.3의 Δs 3단 분류(면제/하드/소프트)를 반드시 지킬 것. 임계(ARC_EXEMPT·RELOCALIZE_REACH)는 추적 윈도 상수에서 유도된 값이다.
2. **닫힌 루프는 open으로 저작(§9).** 끝=시작 좌표로 literally 닫으면 피니시가 깨진다. heart_01의 "작은 갭" 패턴을 재현.
3. **polyline은 반드시 ≤6px 재샘플(§2.4).** query의 인덱스 윈도가 6px 간격을 전제한다. 성긴 폴리라인은 추적 거동을 바꾼다.
4. **id 네임스페이스·파일명=id.** `custom_` 접두 필수, 공식 로드가 커스텀을 가리지 않게 로드 경로를 접두로 분기.
5. **곡률은 평활 후 스텐실(±~15px)로 측정.** 인접 3점 생값으로 재면 손떨림에 모든 트랙이 곡률 실패.
6. **user:// 디렉토리 선행 생성**(`make_dir_recursive`) — 첫 저장 함정.
7. **좌표는 월드 단위로 저장, 그릴 때만 변환.** 화면 좌표로 저장하면 pan/zoom·해상도에 종속된다. 큰 트랙(±500px+)을 위한 pan/zoom 필수.
8. **커스텀은 리더보드 제외.** `is_custom`를 결과 dict까지 흘려 (후속)LeaderboardClient가 온라인 제출을 건너뛰게. 로컬 기록만.
9. **웹 FileDialog 부재.** 데스크톱 네이티브 다이얼로그/드래그드롭이 웹에 없다 — 웹 import는 JS 브리지/붙여넣기로 분리(후속).
10. **시작 heading·피니시 라인은 첫/끝 두 점에 의존.** 퇴화(모든 점 동일·2점 미만) 폴리라인을 검증에서 하드 리젝트(최소 점 수·유효 길이).
11. **코너가 6px 재샘플에 묻힌다.** 별 꼭짓점 같은 급전환점을 코너 후보로 표시해 재샘플 시 강제 삽입하지 않으면 의도한 뾰족함이 사라진다(§5-0/1). 저장 전 정규화(중복점 제거·quantize·상한)도 함께.
12. **`closed`를 판정에 쓰지 말 것.** 스키마의 `closed`는 에디터 재편집 힌트일 뿐, `bake()`/`query()`는 무시한다. `closed=true`로 끝→시작을 이으면 피니시가 깨진다(§2.3, §9).

---

## 13. 확장 지점

| 확장 | 진입 지점 | 방법 |
|---|---|---|
| polyline→bezier canonical 변환 | 저장/공유 export | Schneider 피팅기(오프라인·저작 시 1회). polyline 트랙은 이후에도 계속 로드 |
| 커뮤니티 공유 | `TrackLoader.save_custom_track` 결과 JSON | 파일 export/import + `checksum`으로 무결성. 큐레이션 후 `tracks/community/` 승격 |
| 서버 리더보드(커스텀) | `checksum` + 서버 검증 | 큐레이션·검증된 커스텀만 별도 랭킹(§14.2 등급화) |
| 폭 수동 오버라이드/원단 물성 | MetaPanel | 고급 폭 입력 + `modifiers` 저작 UI |
| 다중 스트로크·분기 | `StrokeProcessor` | 끝점 이어붙임/분기(§9.4 분기 경로) |
