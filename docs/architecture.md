# Overlock 클라이언트 아키텍처 (MVP)

- 개발자 Comment : 이 문서는 구현 에이전트가 읽으라고 만든 문서입니다만 사람도 구현 의사 결정도 이해할 수 있도록 추가 윤문 작업을 수행하였습니다.
- 대상 엔진: Godot 4.x + GDScript (웹 export 고려)
- 범위: 기획서 §17 MVP 한정 — 자동 전진, 속도 5단계, 조향 누적/지연, 경로 판정, 손가락 부상/스턴, 스톱워치, 부분 미니맵, 결과 화면, 로컬 기록, 트랙 1개(JSON)
- 제외: 온라인 리더보드, 실 장력, 바늘 과열, 2.5D 연출 (확장 지점만 명시)
- 이 문서는 **결정 사항**만 기술한다. 대안은 근거가 필요한 곳에만 한 줄로 남긴다.

---

## 1. 개요

MVP의 목표(§17.1)는 "그래픽 없이도 고속 코너링이 재미있는가"를 검증하는 조작감 프로토타입이다. 따라서 아키텍처는 **결정론적 고정 스텝 시뮬레이션**과 **트랙 데이터 → 베이크 폴리라인 파이프라인**을 두 축으로 삼는다. 결정론은 조작감 튜닝 재현성과 향후 리플레이 재시뮬레이션(§14.3)을 동시에 만족시키는 핵심 설계 제약이다.

핵심 결정 요약:

| 항목 | 결정 |
|---|---|
| 씬 전환 | `change_scene_to_file`로 Main → Gameplay → Result, 데이터는 `GameState` 오토로드로 전달 |
| 월드 모델 | 트랙 고정, 플레이어 이동, `Camera2D`가 플레이어 추적(회전 X) |
| 시뮬레이션 구동 | `RaceDirector`가 `_physics_process`에서 플레이어를 **호출 구동**(플레이어는 자체 `_physics_process` 없음) |
| 트랙 파이프라인 | JSON bezier → 수동 De Casteljau 샘플링 → 누적 호길이 `s` 포함 폴리라인 → **윈도 최근접 탐색** |
| 미니맵 | `Control`의 커스텀 `_draw()` |
| 입력 맵 | 오토로드 `InputSetup`에서 `InputMap.add_action`으로 런타임 등록 |
| 튜닝값 | 오토로드 `Tuning`(코드 기본값 §19) + 선택적 `res://data/tuning.json` 오버라이드 |

---

## 2. 씬 / 노드 구조

씬은 3개다. 씬 간 상태 전달은 노드 트리가 아니라 `GameState` 오토로드가 담당한다.

### 2.1 Main.tscn (메뉴)

```text
Main                    (Control)            [MainMenu.gd]
├─ Background           (ColorRect)
└─ Menu                 (VBoxContainer)
   ├─ TitleLabel        (Label)   "OVERLOCK"
   ├─ TrackLabel        (Label)   현재 트랙명 (MVP 고정: Cotton Warm-up)
   ├─ BestTimeLabel     (Label)   RecordStore에서 조회한 로컬 최고 기록
   ├─ StartButton       (Button)  → GameState.start_run(...)
   └─ QuitButton        (Button)  데스크톱만
```

### 2.2 Gameplay.tscn

```text
Gameplay                (Node2D)             [RaceDirector.gd]  ← 물리 루프 소유
├─ World                (Node2D)             월드 공간(고정)
│  ├─ TrackRenderer     (Node2D)  [TrackRenderer.gd]  centerline/폭 _draw
│  ├─ FinishLine        (Node2D)            피니시 시각 마커
│  └─ Player            (Node2D)  [PlayerController.gd]  운동학 상태 보유
│     ├─ NeedleVisual   (Sprite2D/Polygon2D)  heading으로 회전(노드 본체는 회전 X)
│     └─ Camera2D                  position_smoothing on, 회전 0 고정
└─ HUD                  (CanvasLayer)        화면 고정 UI
   ├─ Stopwatch         (Label)   [Stopwatch.gd]
   ├─ SpeedGauge        (Control) [SpeedGauge.gd]  [1][2][3][4][5]
   ├─ RiskMeter         (Control/ProgressBar) [RiskMeter.gd]
   ├─ MiniMap           (Control) [MiniMap.gd]  커스텀 _draw
   ├─ StatusLabel       (Label)   Off-Seam / 부상 상태
   ├─ Countdown         (Label)   [Countdown.gd]  카운트다운 오버레이
   └─ PauseOverlay      (Control)  Esc, 기본은 hidden
```

핵심: **`Player` 노드 본체의 `rotation`은 항상 0**으로 유지하고, `heading`은 자식 `NeedleVisual`에만 반영한다. 이렇게 해야 `Player`의 자식인 `Camera2D`가 회전하지 않아 월드가 화면상 수평을 유지하고, 미니맵/HUD 좌표 계산이 단순해진다.

### 2.3 Result.tscn

```text
Result                  (Control)            [ResultScreen.gd]
├─ Background           (ColorRect)
└─ Panel                (VBoxContainer)
   ├─ (§8.4 항목 라벨들) Track / Difficulty / Finish Time / Penalty /
   │   Final Time / Accuracy / Perfect Rate / Off-Seam Time /
   │   Finger Cuts / Max Speed / Average Speed
   ├─ NewRecordLabel    (Label)   RecordStore가 신기록 판정 시 표시
   ├─ RetryButton       (Button)  → GameState.start_run(같은 트랙)
   └─ MenuButton        (Button)  → Main.tscn
```

Result는 `GameState.last_result`(Dictionary)만 읽어 렌더한다. Gameplay를 참조하지 않는다.

---

## 3. 오토로드 (싱글톤)

`project.godot`의 `[autoload]`에 아래 순서로 등록한다. **순서 중요**: 의존 대상이 먼저 초기화돼야 한다.

| 순서 | 오토로드 | 타입 | 책임 |
|---|---|---|---|
| 1 | `Tuning` | Node | §19 튜닝 파라미터 보유, `tuning.json` 오버라이드 병합 |
| 2 | `InputSetup` | Node | `InputMap.add_action`으로 입력 액션 런타임 등록(§7) |
| 3 | `TrackLoader` | Node | 트랙 JSON 로드 → `TrackData` 베이크, id별 캐시 |
| 4 | `RecordStore` | Node | `user://records.json` 로드/저장, 트랙·난이도별 신기록 판정(§3.2), 개인 고스트 연결(§3.3) |
| 5 | `GameState` | Node | 씬 전환 + 세션/결과 데이터 버스 |

`GameState`가 다른 오토로드를 참조하므로 마지막에 둔다.

```gdscript
# GameState.gd  (autoload)
extends Node

var track_id: String = "cotton_01"
var difficulty: String = "normal"
var mode: String = "time_attack"
var last_result: Dictionary = {}

func start_run(id: String, diff: String) -> void:
    track_id = id
    difficulty = diff
    get_tree().change_scene_to_file("res://scenes/Gameplay.tscn")

func to_result(result: Dictionary) -> void:
    last_result = result
    get_tree().change_scene_to_file("res://scenes/Result.tscn")
```

```gdscript
# RecordStore.gd  (autoload)
extends Node
const PATH := "user://records.json"
var _data: Dictionary = {}   # "track_id|difficulty" -> best result dict

func _ready() -> void: _load()

func best_for(id: String, diff: String) -> Dictionary:
    return _data.get(id + "|" + diff, {})

# 신기록이면 저장하고 true 반환
func submit(result: Dictionary) -> bool:
    var key: String = result["track_id"] + "|" + result["difficulty"]
    var prev: Dictionary = _data.get(key, {})
    var is_best := prev.is_empty() or result["final_time_ms"] < prev["final_time_ms"]
    if is_best:
        _data[key] = result
        _save()
    return is_best

func _save() -> void:
    var f := FileAccess.open(PATH, FileAccess.WRITE)
    f.store_string(JSON.stringify(_data))
```

### 3.1 RecordStore와 개인 고스트 (v2.3.0)

위 코드는 MVP 시점의 구조이다. v2.3.0부터 RecordStore는 트랙·난이도별 개인 최고 기록(§3.2)에 개인 고스트 파일(§3.3)을 연결한다. 고스트 파일 입출력과 안전한 파일 교체는 `GhostStore`(`scripts/systems/GhostStore.gd`)가 맡고, 샘플 기록과 재생은 `GhostRun`(`scripts/systems/GhostRun.gd`)이 맡는다. RaceDirector는 주행 틱마다 GhostRun에 위치를 넘기고, 완주하면 `RecordStore.submit_run(result, ghost, skip_reason)`으로 기록과 고스트를 함께 저장한다. 기존 `submit(result)`는 고스트 없이 기록만 제출하는 하위 호환 진입점으로 남겨 두었다.

| 함수 | 설명 |
|---|---|
| `is_practice()` | 개발용 튜닝 오버라이드가 물리에 쓰이는 값을 실제로 바꾸는지 돌려준다. 참이면 기록을 연습 기록으로 따로 저장한다. |
| `fingerprint_for(id)` | `TrackLoader.track_fingerprint(id)`를 돌려준다. |
| `best_for(id, diff)` | 이 트랙·난이도의 개인 최고 기록을 돌려준다. 연습 실행이면 연습 기록을 돌려준다. 트랙 선택 화면의 Best, 결과 화면, 리더보드 화면의 "내 기록"이 이 함수를 쓴다. |
| `ghost_state(id, diff)` | 트랙 선택 화면 문구에 쓰는 고스트 상태(`ready`, `no_record`, `no_ghost`, `track_changed`)를 돌려준다. |
| `load_ghost(id, diff)` | 개인 최고 기록의 고스트를 읽고 검사해서 돌려준다. |
| `submit_run(result, ghost, skip)` | 기록과 고스트를 §3.3의 저장 순서대로 저장한다. |
| `purge(track_id)`, `purge_for_delete(track_id)` | 해당 트랙의 모든 기록과 연결된 고스트 파일을 지운다. |
| `ghost_enabled()`, `set_ghost_enabled(v)` | 트랙 선택 화면의 "개인 고스트" 토글 값을 읽고 `user://ghost_settings.json`에 저장한다. |

### 3.2 기록 키와 트랙 지문

**키.** 개인 최고 기록은 `track_id|difficulty` 키 하나로 보관한다. 같은 키 안에서 `final_time_ms`(패널티 포함)가 더 작은 기록을 신기록으로 판정하며, 동률이면 기존 기록을 유지한다. 원단 물리처럼 게임 규칙이 바뀌어도 기록을 규칙별로 나누지 않는다. 예전 버전에서 세운 기록도 그대로 현재 최고 기록이다.

**연습 기록.** 개발용 `res://data/tuning.json`이 물리와 판정에 쓰이는 Tuning 값을 실제로 바꾸면 `is_practice()`가 참이 되고, 기록을 `track_id|difficulty|practice` 키로 따로 저장해 정식 기록과 섞지 않는다. 판정할 때는 물리와 판정에 실제로 쓰이는 키 목록(`RecordStore.PHYSICS_TUNING_KEYS`, PlayerController와 RaceDirector가 읽는 Tuning 키)만 보고, 파일 값과 새 Tuning 인스턴스의 기본값을 비교한다. `foot_response_rate`처럼 소비되지 않는 키를 바꾸면 물리가 같으므로 연습으로 보지 않는다. `steer_expo`는 시작할 때 LeaderboardClient가 사용자 설정값으로 덮어써 tuning.json 값이 쓰이지 않으므로 빼고, `speed_table`은 `_load_overrides`가 덮어쓰지 않으므로 뺀다. 소비 코드가 새 키를 읽기 시작하면 목록에 더해야 하며, `tools/ghost_regression`이 두 파일의 `Tuning.<키>` 참조가 목록에 모두 있는지 확인한다. 결과 dict와 기록 엔트리의 `practice` 필드가 연습 여부를 나타낸다. 트랙 선택 화면은 "연습 Best"와 연습 기록 안내를 보이고, 결과 화면은 연습 기록이라는 안내를 보인다. 설정 화면의 조향 감도(`steer_expo`)는 사용자 선택이므로 연습 판정에 영향을 주지 않으며, 고스트 메타데이터에 참고값으로만 기록한다. 저장소에 들어 있는 tuning.json은 기본값과 같아야 하며, `tools/ghost_regression`이 이 조건을 확인한다.

**track_fingerprint.** 지문은 기록을 나누는 데 쓰지 않고 고스트를 쓸 수 있는지 판정하는 데만 쓴다. `TrackLoader.track_fingerprint(id)`는 트랙을 불러올 때 계산해서 캐시하는 `tf2:` 접두의 SHA-256 값이다. 공식 bezier 트랙과 커스텀 polyline 트랙 모두 베이크한 점 열을 기준으로 삼고, 점 열·닫힘·폭·재질의 직렬화에는 기존 `play_fingerprint`의 규칙(좌표 0.1 단위, 폭 수치 0.001 단위)을 재사용한다. 아이템은 `play_fingerprint`의 문자열 정렬 대신 `ItemOrder` 정규 순서(s 오름차순, 같으면 type, lat 순)로 이어 붙인다. 슬롯은 FIFO이므로 한 틱에 여러 아이템을 담는 순서가 플레이에 영향을 주는데, RaceDirector의 획득 판정도 같은 정규 순서로 아이템을 순회한다(§6.6). 그래서 파일의 items 배열 순서만 다른 트랙은 같은 지문을 가지며 실제 획득 순서도 같다. 지문에 들어가는 내용은 베이크 점 열, 닫힘(closed), 판정 폭, 재질(fabric), 아이템이다. 표시 이름, 작성자, 설명, track_id, checksum, length 같은 메타 정보는 넣지 않으므로 이름만 바꾼 트랙은 같은 지문을 가진다. modifiers는 TrackData에 파싱만 되고 시뮬레이션과 판정이 사용하지 않으므로 넣지 않았다. modifiers를 사용하는 코드가 생기면 지문에 포함하고 접두를 올려야 한다. 난이도는 기록 키에 따로 들어가므로 지문에서는 뺐다. 제출용 공식 트랙 체크섬(`LeaderboardClient.track_checksum`), 허브 매핑용 `custom_track_fingerprint`(fp1), 서버의 `content_hash`는 바꾸지 않았으며, 모두 이 지문과 의미가 다르다.

지문은 같은 기기와 같은 엔진 빌드에서 안정적으로 같은 값을 낸다. 다만 베이크가 부동소수 연산이므로 플랫폼이나 엔진 버전이 바뀌면 0.1 반올림 경계에 걸린 점이 달라질 가능성이 남아 있다. 기록은 로컬에만 저장되므로 같은 기기 안에서는 이 차이가 문제가 되지 않는다.

**트랙이 바뀐 경우.** 기록 엔트리에는 기록을 세울 때의 트랙 지문을 함께 저장한다. 같은 custom ID의 트랙을 편집해 경로, 닫힘, 원단, 폭, 아이템이 바뀌면 현재 지문과 엔트리의 지문이 달라진다. 이때 기록은 그대로 개인 최고로 두고, 그 기록의 고스트만 쓰지 않는다(`track_changed`). 트랙 선택 화면은 "트랙이 바뀌어 고스트를 쓸 수 없습니다 · 최고를 갱신하면 새로 생깁니다"를, 출발 배너는 같은 뜻의 안내를 보인다. 편집한 트랙에서 더 느리게 완주하면 신기록이 아니므로 고스트가 생기지 않으며, 결과 화면이 개인 최고를 갱신하면 새 고스트가 생긴다고 안내한다. 최고를 갱신하면 엔트리의 지문이 현재 지문으로 바뀌고 새 고스트가 생긴다. 이름만 바꾼 트랙은 지문이 같으므로 고스트를 계속 쓸 수 있다.

**기록 엔트리.** 엔트리는 결과 dict(`RunStats.finalize`가 만든 필드)에 아래 필드를 더한 것이다. 결과 화면에서만 쓰는 키(`is_new_record`, `ghost_status`, `ghost_reason`, `prev_best_ms`, `ghost_track_changed`, `split_deltas`, `editor_test`)는 저장하지 않는다.

| 필드 | 뜻 |
|---|---|
| `track_fingerprint` | 기록을 세울 때의 트랙 내용 지문(`tf2:…`). 고스트 유효성 판정에만 쓴다. |
| `practice` | 연습 기록(개발용 튜닝) 여부 |
| `ghost_run_id` | 연결된 고스트의 run_id이며, 고스트가 없으면 빈 문자열이다. |
| `ghost_file` | 고스트 파일 경로(`user://ghosts/<run_id>.json`)이며, 고스트가 없으면 빈 문자열이다. |
| `ghost_note` | 고스트를 만들지 못한 사유(예: `write_failed`, `too_many_samples`, `too_large`) |
| `saved_at` | 저장 시각(UTC, ISO 형식 문자열) |

**records.json 형식과 마이그레이션.** 현재 형식은 `{"format_version": 2, "records": {키: 엔트리}}`이다. v2 형식은 고스트 참조 필드를 담으려고 도입했다. 형식 버전이 없는 예전 파일(v1, `track_id|difficulty` → 결과)을 처음 읽으면 원본을 `records.json.bak`으로 복사한다. 이미 `.bak`이 있으면 `records.json.bak-<시각>`으로 복사한다. 백업이 성공하고 복사본이 원본과 같을 때만 v1 기록을 키와 필드 그대로 현재 최고 기록으로 옮겨 v2 형식으로 다시 저장한다. 옮긴 기록은 고스트 참조 필드가 비어 있으므로 트랙 선택 화면에 "고스트가 없습니다"로 보이고, 최고를 갱신하면 고스트가 생긴다. 백업에 실패하면 원본을 그대로 두고 메모리로만 읽으며(`load_state = migrated_readonly`), 이번 실행에서는 기록 쓰기를 보류하고 다음 기동에서 다시 시도한다. 개발 중에 잠시 쓰던 규칙 분리 키(`track_id|difficulty|규칙|지문`)와 `legacy` 묶음이 들어 있는 v2 파일은 읽을 때 현재 키로 합치며, 같은 키로 모이면 시간이 더 짧은 기록을 남긴다. JSON으로 읽을 수 없는 파일이나 지원하지 않는 형식 버전의 파일은 빈 저장소로 읽고, 처음 쓰기 전에 `records.json.bak-<시각>`으로 옮겨 보존한다.

**저장 방식.** records.json과 고스트 파일은 `GhostStore.write_atomic`으로 쓴다. 이 함수는 임시 파일(`<경로>.tmp`)에 쓰고 다시 읽어서 내용과 JSON 구조를 확인한 뒤 rename으로 교체한다. 기존 파일 위로 rename하지 못하는 플랫폼에서는 기존 파일을 `<경로>.prev`로 옮긴 뒤 rename하고, 그것도 실패하면 `.prev`를 원래 이름으로 되돌린다. 기존 파일을 지우는 경로는 없으며, 실패하면 기존 파일이 그대로 남고 `.tmp`와 `.prev`도 남기지 않는다. 다음 로드 직전에는 `GhostStore.recover_pending`이 중단 흔적을 정리한다. 본 파일이 있으면 그것이 확정본이므로 `.tmp`와 `.prev`를 지운다. 본 파일이 없을 때는 완전한 v2 형식이고 참조하는 고스트 파일이 모두 실제로 있는 records.json.tmp만 채택하고, 그렇지 않으면 `.prev`를 복원한다. 실패한 트랜잭션은 `.tmp`를 남기지 않으므로, 채택되는 `.tmp`는 rename 직전에 앱이 종료된 경우뿐이다. 파일이 있는데 열지 못하면(`unreadable`) 일시적인 실패일 수 있으므로 보존용 이름 변경이나 덮어쓰기 없이 이번 실행의 쓰기를 보류한다. 웹(IDBFS)에서는 기존 저장 코드와 같은 관례를 따른다. 엔진은 쓰기 모드로 연 user:// 파일을 닫을 때 동기화가 필요하다고 표시하고 메인 루프에서 동기화하므로, 명시적인 sync는 부르지 않는다.

### 3.3 개인 고스트

**기록 방식.** 고스트는 입력을 다시 시뮬레이션하는 리플레이가 아니라 위치 스냅샷이며, 서버 검증이나 치트 판정에는 쓰지 않는다. RaceDirector는 카운트다운이 끝나는 틱에 `GhostRun.begin`으로 출발 샘플을 남기고, 정상 주행 틱마다 시뮬레이션과 트랙 질의, 집계를 마친 뒤 `on_tick`을 부른다. 주행 경과 시간이 다음 50ms 격자(20Hz)를 넘은 틱에서만 샘플을 남기므로, 샘플 간격은 물리 주기가 아니라 경과 시간으로 정해진다. 맵 이탈 강제 복귀가 일어나면 `on_reset`이 복귀 직전 위치와 복귀 직후 위치를 같은 시각의 샘플 두 개로 남기고, 직후 샘플에 FLAG_JUMP를 붙인다. 완주하면 `on_finish`가 실제 완주 시각의 샘플에 FLAG_FINISH를 붙인다. 일시정지, 튜토리얼, 카운트다운, 완주 줌아웃 중에는 `_tick_running`이 실행되지 않으므로 이 구간은 기록에서 빠진다. GhostRun은 플레이어 상태를 읽기만 하므로 충돌, 아이템, RISK, 기록에 영향을 주지 않는다. 고스트 표시를 꺼도 기록은 계속하며, 토글은 재생 여부만 정한다.

**10구간.** 트랙 호길이를 10등분한 경계 1~9는 물리 틱마다 계산한다. 지금까지의 최대 진행도를 넘어선 경계만 이전 틱과 현재 틱의 진행도 사이에서 선형 보간해 최초 통과 시각을 정하므로, 후진하거나 같은 구간을 다시 지나도 중복으로 기록하지 않는다. 강제 복귀 때문에 아직 통과하지 않은 경계를 건너뛰게 되면 그 구간에는 가상의 통과 시각을 만들지 않고 비교 불가로 표시한다. 10번째 구간은 RaceDirector의 실제 완주 판정 시각(`finish_ms`)과 최종 패널티(`penalty_ms`)를 쓴다. 구간 값은 통과 시각에 그때까지 누적된 패널티를 더한 값이며, 마지막 구간의 값은 `final_time_ms`와 같다.

**파일 포맷.** 고스트 하나는 `user://ghosts/<run_id>.json` 파일 하나에 compact JSON으로 저장한다.

| 키 | 내용 |
|---|---|
| `format_version` | 1 |
| `run_id` | `g`에 시각과 난수를 16진으로 붙인 영숫자 문자열 |
| `track_id`, `difficulty` | 기록 키와 같다. |
| `track_fingerprint` | 고스트를 기록할 때의 트랙 지문. 재생 전에 현재 지문과 비교한다. |
| `finish_ms`, `penalty_ms`, `final_time_ms` | 결과 dict와 같다(finish + penalty = final). |
| `sample_count` | 샘플 수 |
| `meta` | 참고 메타데이터(`steer_expo`, `game_version`, `fabric`)이며, 비교에는 쓰지 않는다. |
| `samples` | 평면 숫자 배열이다. 샘플마다 `t_ms, x, y, heading, s, flag` 여섯 값을 넣는다(위치와 s는 0.1, heading은 0.001 단위). |
| `splits` | 구간 10개의 `[통과 시각 ms, 누적 패널티 ms, 유효 여부 1/0]` |

flag 값은 0(일반), 1(FLAG_JUMP: 출발과 복귀 직후), 2(FLAG_FINISH: 완주)이다.

**상한.** 샘플은 최대 24000개(20Hz 기준 약 20분이며 이벤트 샘플을 포함한다), 파일은 최대 2MiB이다. 샘플 수가 상한에 닿으면 그 런의 고스트를 만들지 않고(`too_many_samples`), 직렬화한 크기가 2MiB를 넘어도 저장하지 않는다(`too_large`). 두 경우 모두 기록 저장은 계속 진행하고 결과 화면에 사유를 보이며, 뒤가 잘린 고스트를 정상 파일로 쓰지 않는다.

**검사.** 쓰기 직전과 읽을 때 `GhostStore.validate`가 헤더 키, 형식 버전, `finish + penalty = final` 관계, 샘플 수와 배열 길이, 모든 값의 유한성, 시각의 단조 증가(같은 시각은 허용), 첫 시각 0, 마지막 샘플의 FLAG_FINISH와 그 시각이 `finish_ms`와 같은지(허용 오차 1ms), 구간 배열을 검사한다. 구간은 행마다 유효 여부가 0 또는 1이고, 시각이 -1(미통과) 또는 0..finish_ms 범위이며, 누적 패널티가 0..penalty_ms 범위여야 한다. 시각이 있는 행의 시각과 유효 행의 누적 패널티는 단조 증가해야 하고, 마지막 구간은 유효하며 헤더의 finish_ms·penalty_ms와 같아야 한다. 짧은 샘플 열에 긴 finish_ms를 붙인 손상 파일이 조기 도착을 표시하거나 거짓 구간 차이를 내지 않게 하려는 검사이다. 읽을 때는 크기 상한을 먼저 확인하고, 헤더의 track_id, difficulty, track_fingerprint, run_id, final_time_ms가 기록 엔트리와 현재 트랙 지문에 모두 맞을 때만 재생한다. 하나라도 어긋나면 고스트만 비활성화하며(사유 `corrupt`, `unsupported`, `invalid`, `mismatch`, `missing`, `too_large`), 기록을 지우거나 게임 진입을 막지 않는다. v2.3.0 개발 중에 만든 고스트 파일에 남아 있는 `physics_ruleset` 필드는 판정에 쓰지 않는다. 고스트를 읽지 못하면 출발 시점에 HUD 배너가 그 사실을 잠깐 안내한다.

**저장 순서.** `submit_run`은 다음 순서로 저장한다.

1. 신기록이 아니면(느리거나 동률이면) 아무것도 쓰지 않고, 기존 최고와 고스트를 유지한다.
2. 새 고스트에 run_id를 붙여 검사한 뒤 임시 파일에 쓰고, 다시 읽어 확인한 다음 최종 파일로 교체한다.
3. 기록 엔트리에 run_id와 파일 경로를 연결한다. 고스트 쓰기가 실패했으면 엔트리에 고스트가 없다는 사실과 사유를 적는다.
4. records.json을 임시 파일에 쓰고 교체한다.
5. 기록 저장이 성공한 뒤에만 이전 최고 기록의 고스트 파일을 지운다.

고스트 쓰기가 실패해도 최고 기록 저장은 시도하며, 새 최고 기록에는 고스트가 없다고 표시한다. 이전 고스트는 5단계에서 지우므로 새 최고 기록의 고스트처럼 보이지 않는다. records.json 저장이 실패하면 메모리를 이전 상태로 되돌리고 2단계에서 쓴 새 고스트 파일을 지우므로, 기존 최고 기록과 고스트가 그대로 남는다. 2단계와 4단계 사이에 앱이 종료되면 참조되지 않는 고스트 파일이 남을 수 있다. 이런 파일은 다음 실행 때 RecordStore가 `GhostStore.cleanup_orphans`로 지우며, 남은 임시 파일도 함께 지운다. 이 정리는 records.json을 정상으로 읽은 경우(`load_state == "ok"`)에만 실행한다. 손상, 미지원 버전, 읽기 실패, 마이그레이션 직후, 백업 실패 상태에서는 참조 목록을 확정할 수 없으므로 고스트를 지우지 않는다. 이 정리는 고스트 이름 형식(`g…json`, `g…json.tmp`)을 가진 파일만 건드린다.

**저장하지 않는 런.** 에디터 테스트 플레이(`GameState.is_editor_test`)는 결과에 `editor_test`를 표시하고 submit_run을 부르지 않으며, 고스트를 재생하지도 않는다. 재시작은 씬을 다시 불러오므로 기록기가 버려지고, 중도 포기(메뉴 복귀)는 완주 경로를 지나지 않으므로 두 경우 모두 저장하지 않는다.

**재생과 HUD.** 런을 시작할 때 고스트 표시가 켜져 있고 일반 플레이이면 `RecordStore.load_ghost`로 개인 최고 기록의 고스트를 읽는다. 기록 당시와 트랙 지문이 다르면 읽지 않고 출발 배너로 안내한다. 재생 위치는 `GhostRun.state_at(주행 경과 ms)`로 구하며, 인접한 두 샘플을 선형 보간하고 heading은 `lerp_angle`로 보간한다. 다음 샘플에 FLAG_JUMP가 있으면 보간하지 않고 그 시각에 바로 옮긴다. 같은 물리 경과 시간에서는 렌더 FPS와 관계없이 같은 위치가 나온다. 고스트가 먼저 완주하면 결승 위치에 멈추고, 미니맵이 3초 동안 "고스트 도착" 라벨을 보인다. 미니맵은 플레이어와 같은 좌표 변환을 적용해 반투명한 속 빈 마름모와 "고스트" 라벨을 그리고, 고스트가 부분 미니맵 밖에 있으면 테두리 안쪽에 방향 삼각형을 그린다. 플레이어는 채운 점과 화살표로 그리므로 모양과 라벨로 구분된다. 중앙 원단에는 두 번째 손이나 노루발을 그리지 않는다. 구간을 통과하면 화면 위 가운데 배너(`GhostSplitBanner`)가 "구간 3/10 · 0.42초 빠름"을 2.6초 동안 보이고, 둘째 줄에 "개인 최고 대비 · 패널티 포함 (마커는 주행 시간 기준)"이라고 적는다. 마커는 주행 시간을 기준으로 움직이고 구간 차이는 패널티를 포함해 계산하므로, 마커가 앞서 있어도 구간 차이는 느림으로 나올 수 있다. 마지막 구간의 차이는 HUD가 숨는 완주 줌아웃 대신 결과 화면의 구간별 차이에 나온다. 배너 배치는 docs/mobile.md §4.2에 정리했다.

**트랙 선택과 결과 화면.** 트랙 선택 화면의 Best 줄 아래에 있는 고스트 줄(`GhostSelectRow`)에는 "개인 고스트" 토글(기본값은 켜기)과 상태 문구가 있다. 기록이 없으면 "첫 완주 후 고스트가 생깁니다"를, 트랙이 바뀌었으면 고스트를 쓸 수 없고 최고를 갱신하면 새로 생긴다는 문구를, 고스트가 없는 기록(예전 버전 기록 등)이면 다음 최고 기록부터 생긴다는 문구를 보인다. 데스크톱 배치에서는 상태 문구가 늘 한 줄에 들어가도록 길이를 맞춰, 상태에 따라 버튼 위치가 바뀌지 않는다. 그 아래 줄에는 로컬 최고와 고스트는 패널티 포함 시간을 기준으로 하고 온라인 순위는 등급을 먼저 본다는 안내를 적는다. 결과 화면의 고스트 줄은 새 고스트의 저장 성공 여부와 실패 사유, 미갱신일 때 개인 최고와의 차이, 구간별 차이, 트랙이 바뀌어 이전 고스트를 쓸 수 없을 때의 안내, 연습 기록 여부를 보인다. 터치 배치는 글자가 커서 모든 문구가 함께 뜨면 카드가 화면을 넘을 수 있으므로, 짧은 문구를 쓰고 구간 차이를 빠름·느림·비교 불가 개수 한 줄로 줄인다.

**정리.** 커스텀 트랙을 삭제하면 트랙 선택 화면이 트랙 파일보다 먼저 `RecordStore.purge_for_delete(id)`로 기록을 정리한다. purge는 그 트랙의 정식 기록과 연습 기록을 모두 지우고, 저장이 성공하면 연결된 고스트 파일도 지운다. 저장에 실패하면 기록과 고스트를 그대로 두고 트랙 파일도 지우지 않으며, 같은 화면에서 다시 삭제를 시도할 수 있다. 트랙을 먼저 지우면 남은 기록이 고스트를 계속 참조하고 재시도할 트랙도 사라지기 때문에 이 순서를 택했다. 같은 custom ID를 편집해서 지문이 바뀌면 기록은 유지하고 고스트만 쓰지 않는다(§3.2 "트랙이 바뀐 경우").

**검증.** `tools/ghost_regression/run.sh`가 키보드, 터치, practice 세 모드로 이 절의 규칙을 검사한다.

---

## 4. 좌표 / 월드 모델

**결정: 트랙을 월드 공간에 고정하고 플레이어(바늘)가 이동한다. `Camera2D`가 플레이어를 추적한다.**

근거:
- 기획서 이동식(§7.4)이 `position += forward * speed * delta` 즉 **플레이어의 절대 월드 좌표**를 전제한다. 트랙을 스크롤시키는 대안은 이 모델과 상충하고 좌표 변환이 이중으로 든다.
- `seam_error`가 "플레이어 월드 좌표 ↔ 동일 공간에 베이크된 폴리라인" 거리로 단순 계산된다.
- 미니맵의 월드→미니맵 변환이 한 번의 아핀 변환으로 끝난다.

세부:
- 단위: **1 world unit = 1 px**. 속도는 px/s(§7.2, §19의 80 ~ 300).
- `Camera2D`: `position_smoothing_enabled = true`로 부드럽게 추적, `rotation`은 0 고정(월드 수평 유지). `Player` 자식으로 두어 위치만 따라가게 한다.
- `heading` 초기값은 트랙 시작 접선 방향으로 설정(첫 두 베이크 점의 방향). `Vector2(cos(heading), sin(heading))`가 전진 벡터.

---

## 5. 트랙 데이터 파이프라인

### 5.1 트랙 JSON (§9.2)

`res://tracks/official/cotton_01.json`. 포맷은 기획서 §9.2 그대로:

```json
{
  "track_id": "cotton_01",
  "name": "Cotton Warm-up",
  "difficulty": "normal",
  "fabric": "cotton",
  "length": 3200,
  "width": { "perfect": 18, "safe": 42, "fail": 90 },
  "path": [ { "type": "bezier", "p0": [0,0], "p1": [200,0], "p2": [300,120], "p3": [400,240] }, ... ],
  "modifiers": [ ... ]     // MVP에서는 파싱만 하고 무시
}
```

`width`(perfect/safe/fail)는 **트랙별 값**이므로 `Tuning`이 아니라 트랙 JSON에서 온다. §19의 18/42/90은 이 트랙의 기본값과 일치한다.

### 5.2 베이크: JSON bezier → 폴리라인(누적 s)

**결정: 각 cubic bezier를 수동 De Casteljau로 균일 근사 샘플링해 하나의 폴리라인으로 잇는다.** `Curve2D` 자동 베이크 대신 수동 샘플링을 택한 이유는 (a) 샘플 개수·간격이 완전히 예측 가능해 결정론적이고, (b) 향후 서버 재시뮬레이션과 동일 로직을 Python으로 재현하기 쉬우며, (c) 세그먼트 간 공유 끝점 핸들 변환 같은 `Curve2D` 특유의 실수 여지를 없애기 때문이다.

`TrackData`(RefCounted)가 보유하는 배열:

| 필드 | 타입 | 의미 |
|---|---|---|
| `points` | `PackedVector2Array` | 베이크된 폴리라인 점 |
| `s_arr` | `PackedFloat32Array` | 각 점까지의 누적 호길이 |
| `length` | `float` | 전체 호길이 |
| `perfect/safe/fail` | `float` | 판정 폭(트랙 JSON) |

```gdscript
# TrackData.gd  (RefCounted)  — TrackLoader가 생성
const BAKE_INTERVAL := 6.0     # 목표 점 간격(px)

func bake(path_json: Array) -> void:
    points = PackedVector2Array()
    s_arr = PackedFloat32Array()
    for seg in path_json:
        var p0 := _v(seg["p0"]); var p1 := _v(seg["p1"])
        var p2 := _v(seg["p2"]); var p3 := _v(seg["p3"])
        var rough := p0.distance_to(p1) + p1.distance_to(p2) + p2.distance_to(p3)
        var steps: int = max(2, ceili(rough / BAKE_INTERVAL))
        for j in range(steps + 1):
            if j == 0 and points.size() > 0:
                continue    # 이전 세그먼트 끝점과 공유 → 중복 제거
            _append(_bezier(p0, p1, p2, p3, float(j) / steps))
    length = s_arr[s_arr.size() - 1]

func _append(q: Vector2) -> void:
    if points.is_empty():
        s_arr.append(0.0)
    else:
        s_arr.append(s_arr[s_arr.size() - 1] + points[points.size() - 1].distance_to(q))
    points.append(q)

static func _bezier(a, b, c, d: Vector2, t: float) -> Vector2:
    var u := 1.0 - t
    return (u*u*u)*a + (3.0*u*u*t)*b + (3.0*u*t*t)*c + (t*t*t)*d
```

`TrackLoader`는 파일을 읽고 `TrackData.bake`를 호출한 뒤 **id별로 캐시**한다(재시작 시 재베이크 방지).

### 5.3 seam_error / 진행도 s: 윈도 최근접 탐색

**매 프레임 O(전체 점수) 탐색 금지.** 직전 프레임의 최근접 인덱스 `hint` 주변 윈도만 검사한다.

```gdscript
# TrackData.query(pos, hint) -> {error, s, idx}
const BACK_WIN := 6
const FWD_WIN := 12    # max_speed(300px/s)/60fps ≈ 5px, BAKE 6px → 여유 충분

func query(pos: Vector2, hint: int) -> Dictionary:
    var lo: int = max(hint - BACK_WIN, 0)
    var hi: int = min(hint + FWD_WIN, points.size() - 2)
    var best_d2 := INF
    var best_i := hint
    var best_s := s_arr[hint]
    for i in range(lo, hi + 1):
        var a := points[i]
        var ab := points[i + 1] - a
        var len2 := ab.length_squared()
        var t := 0.0 if len2 == 0.0 else clampf((pos - a).dot(ab) / len2, 0.0, 1.0)
        var proj := a + ab * t
        var d2 := pos.distance_squared_to(proj)
        if d2 < best_d2:
            best_d2 = d2
            best_i = i
            best_s = s_arr[i] + sqrt(len2) * t
    return { "error": sqrt(best_d2), "s": best_s, "idx": best_i }
```

- 반환된 `idx`를 다음 프레임 `hint`로 넘긴다.
- **방어 재로컬라이즈(한계 확장 윈도)**: 최소값이 정상 윈도 앞끝(`hi`)에서 나오고 오차가 `fail`보다 크면(코너 컷으로 윈도를 앞질렀거나 크게 이탈) `hint` 주변을 `[hint − RELOCALIZE_BACK_WIN, hint + RELOCALIZE_FWD_WIN]` 범위에서 다시 탐색한다. 앞쪽(`FWD=40≈240px`)은 코너 컷 따라잡기를 허용하도록 넉넉히, 뒤쪽(`BACK=12≈72px`)은 `s` 역행을 막도록 좁게 둔다.
  - **전역 스캔을 쓰지 않는 이유**: 닫힌·자기근접 윤곽(heart_01·star_01은 시작/끝이 55 ~ 103px)에서 전역 스캔은 기하적으로 가깝지만 `s`가 먼 **다른 가지**로 최근접을 잡아 `s`를 순간이동시킨다. 그러면 피니시 판정(`s ≥ length − 1`)이 영영 안 오고 `s` 기반 미니맵도 실제 위치와 어긋난다(사용자 보고 버그 1·2). 인덱스 한계를 둔 확장 윈도는 원거리 가지에 절대 도달하지 못하므로 다른 가지로의 `s` 순간이동을 구조적으로 배제한다. 방어 경로에서만 확장 탐색을 하고(정상 프레임은 O(윈도)), 결정론은 불변이다.
- `s`는 진행도이자 피니시/미니맵의 기준값이다.

---

## 6. 핵심 시스템 설계

### 6.1 구동 방식: RaceDirector가 물리 루프 소유

**결정: `PlayerController`는 자체 `_physics_process`를 두지 않는다.** `RaceDirector`가 `_physics_process(delta)` 한 곳에서 (입력 샘플링 → 플레이어 시뮬 → 트랙 질의 → 판정/집계 → HUD → 피니시 판정)을 **정해진 순서로** 호출한다.

근거:
- 노드별 `_physics_process` 실행 순서 비결정성을 제거한다(플레이어가 움직인 뒤에 트랙 질의·집계가 와야 함).
- 입력을 `InputFrame`으로 추상화해 `player.simulate(input, delta)`에 주입하면, 리플레이는 기록된 `InputFrame`을 그대로 먹이는 것으로 동일 시뮬레이션이 된다(§14.3 확장 대비).
- 고정 스텝: `project.godot`에서 `physics/common/physics_ticks_per_second = 60`. 리스크 누적·조향 지연이 프레임레이트에 의존하지 않게 하려면 `_physics_process` 고정 스텝이 필수다.

```gdscript
# RaceDirector.gd  (Gameplay 루트)
enum State { COUNTDOWN, RUNNING, FINISHED }
var _state := State.COUNTDOWN
var _hint := 0
var _elapsed := 0.0

func _physics_process(delta: float) -> void:
    match _state:
        State.COUNTDOWN:
            _tick_countdown(delta)   # 끝나면 _state = RUNNING
            return
        State.FINISHED:
            return
    _elapsed += delta
    var input := _sample_input()                 # InputFrame
    _player.simulate(input, delta)               # 조향/이동/리스크/스턴
    var probe := _track.query(_player.position, _hint)
    _hint = probe["idx"]
    var band := _classify(probe["error"])        # Perfect/Good/OffSeam/Tear
    _stats.accumulate(delta, _player.speed_index, band, probe["error"], _player.consume_just_cut())
    _update_hud(probe, band)
    if probe["s"] >= _track.length - 1.0:
        _finish()

func _classify(err: float) -> int:
    if err <= _track.perfect: return BAND.PERFECT
    if err <= _track.safe:    return BAND.GOOD
    if err <= _track.fail:    return BAND.OFF_SEAM
    return BAND.TEAR
```

`_sample_input()`은 연속 입력(조향)은 `Input.is_action_pressed`로, 이산 입력(속도 증감·재시작)은 `_unhandled_input`에서 버퍼링한 플래그를 소비해 만든다. **주의**: `is_action_just_pressed`를 `_physics_process`에서 직접 쓰면 렌더/물리 프레임 수 불일치 시 중복/누락될 수 있으므로 이산 입력은 반드시 버퍼링한다(§7 참고).

### 6.2 조향 (§7.3)

`PlayerController.simulate` 내부. `stun_timer > 0`이면 입력을 무시하고 조향을 0으로 복귀시킨다(부상 중 조작 잠금).

```gdscript
func _update_steering(input: InputFrame, delta: float) -> void:
    if stun_timer > 0.0:
        stun_timer -= delta
        target_steer = move_toward(target_steer, 0.0, T.stun_steer_return_rate * delta)
    elif input.steer != 0.0:
        var rate := T.steer_charge_rate
        if input.steer * target_steer < 0.0:      # 입력 부호 ≠ target 부호 → 반전 부스트
            rate *= T.steer_reversal_boost
        target_steer += signf(input.steer) * rate * delta
    else:
        target_steer = move_toward(target_steer, 0.0, T.steer_return_rate * delta)
    target_steer = clampf(target_steer, -1.0, 1.0)
    # 지연: actual이 target을 지수 평활(갭 비례)로 추종. steer_tau가 랙 질감(≈시간지연)을 정한다.
    actual_steer += (target_steer - actual_steer) * (1.0 - exp(-delta / T.steer_tau))
```

(`T`는 `Tuning`. `stun_steer_return_rate`는 §19에 없으므로 `foot_response_rate`를 재사용하거나 별도 기본값 추가.)

> **조향 동역학 재설계(조작감 v4 — "방향 전환이 힘들다" 대응).** 구(舊) 모델은 이중 지연이 과했다: target이 `steer_charge_rate=1.8`로 충전(풀 0.56s)되고 actual이 `move_toward(foot_response_rate=1.1)`로 추종(풀 0.91s)한다. `move_toward`는 갭이 커도 **고정 속도**라, 풀 반전(+1→−1)에서 actual이 2.0 구간을 1.1/s로 기어가 **실효 90% 반전에 ~1.65s**가 걸렸다(레이싱에 치명적). 재설계는 두 축을 바꾼다:
> 1. **actual 추종을 지수 평활로 교체** — `actual += (target−actual)·(1−exp(−dt/steer_tau))`. 갭 비례 속도라 반전 같은 큰 갭에선 즉시 빠르고 목표 근처에선 부드럽게 수렴한다. `move_toward`와 달리 추종 속도 상한이 없어 **병목이 follower에서 사라지고 charge_rate가 반전 시간을 직접 지배**한다. `steer_tau`(=0.16s)가 램프 입력에 대한 시간지연(≈랙 질감)을 정한다 — 지연을 0으로 없애지 않고 §4.3 정체성을 보존한다.
> 2. **충전 상향 + 반전 부스트** — `steer_charge_rate` 1.8→3.2, 그리고 입력 부호가 현재 `target` 부호와 반대일 때만(`input.steer*target_steer<0`) `steer_reversal_boost`(=2.0)를 곱한다. 같은 방향 누적은 평소 속도(§4.3 "누를수록 커진다" 유지), 잠긴 방향의 **되감기만 민첩**하다. `steer_return_rate` 2.4→4.5로 키 해제 직진 복귀도 빠르게 한다.
>
> 결과(Python 리플리카=Godot 4.6.1 헤드리스 비트 일치 검증): 무입력→체감 회전 0.12s / 무입력→풀 조향 실효 0.55s / **풀 반전 실효 90% 0.62s(구 1.65s)** / 키 해제 직진 복귀 0.50s / target 대비 actual 랙 ~0.12s. **회전반경(24/36/52/70/75px)은 불변** — steady 조향에서 actual이 여전히 1.0으로 수렴하고 `turn_power`·`steer_speed_floor`를 건드리지 않았다. `foot_response_rate`는 미사용이 된다(back-compat용 잔존).

### 6.3 이동 (§7.4)

```gdscript
func _update_movement(delta: float) -> void:
    # 회전 각속도의 speed_factor에 하한(steer_speed_floor)을 둔다. floor=1.0이면
    # 각속도가 속도와 무관 → 최소 회전반경 ∝ 속도(저속=급회전, 고속=완만한 큰 호).
    var turn_speed_factor := maxf(speed / T.max_speed, T.steer_speed_floor)
    heading += actual_steer * T.turn_power * turn_speed_factor * delta
    var forward := Vector2(cos(heading), sin(heading))
    position += forward * speed * delta       # 노드 position 갱신
    _needle_visual.rotation = heading          # 시각만 회전(노드 본체는 0)
```

속도 단계 변경은 이산 입력으로 `speed_index`를 1..5로 clamp 후 `speed = SPEED_TABLE[speed_index]`(80/120/170/230/300)로 매핑. 부상 발생 시 `speed_index`를 1로 강제 하락(§7.5).

> **조향 응답 튜닝(§21 "조작감이 답답함" 대응).** 구(舊) 모델은 `speed_factor = speed / max_speed`라 최소 회전반경이 `max_speed / turn_power`로 **전 속도 동일**(≈136px)이었다. cotton_01의 최소 곡률반경(≈53px, seg4 헤어핀)보다 커서 저속에서도 코너를 못 돌았다. `steer_speed_floor`(하한) + `turn_power`로 저속 최소 회전반경을 1단 24px / 2단 36px(≤ 0.7×53)로 낮춰 1 ~ 2단에서 모든 커브를 여유 있게 추종하게 했다. 조향 지연(§6.2 `steer_tau` 지수 추종)은 그대로 유지한다(§4.3 핵심 기믹). **동역학 v4는 회전반경 공식을 건드리지 않으므로 이 절의 회전반경(24/36/51/70px, 5단 75px)은 전부 불변이다.**
>
> **고속 코너링 완화(플레이테스트 v3).** 5단 최소 회전반경 91px가 헤어핀(53.5px)에 비해 과해 "고속 코너링이 어렵다"는 피드백을 받았다. `steer_speed_floor`는 `turn_speed_factor = max(speed/max_speed, floor)`의 하한이므로, floor를 **4단 비율(230/300=0.767)과 5단 비율(1.0) 사이인 0.825**로 낮추면 1 ~ 4단은 여전히 floor에 고정(factor=0.825)되고 5단만 자기 비율(1.0)을 쓴다. 여기에 `turn_power`를 3.3→4.0으로 올리되 `turn_power × floor = 3.3`을 유지해, **1 ~ 4단 회전반경은 24/36/51/70px로 완전히 동일(저속 조작감 불변)**하고 5단만 `300/4.0 = 75px`로 완화된다(헤어핀 53.5px보다 크게 유지해 감속 강제는 보존). 파라미터 전용 조정이며 `_update_movement` 공식은 그대로다.

### 6.4 리스크 / 부상 (§7.5)

기획서 §7.5 공식(속도 계수 × 조향 입력량 × 조향 지연 × 바늘 근접 계수)의 **구성 요소는 유지**하되, 구(舊) 구현이 부상을 사실상 낼 수 없던 두 결함을 교정한다.

1. **조향 입력량으로 `|target_steer|`를 쓰면 급반전 때 gain이 죽는다.** 좌↔우 반전 시 `target_steer`가 0을 지나는 순간 gain이 0이 되어, 가장 위험해야 할 급반전이 가장 안전했다. → `steer_mag = max(|target_steer|, |actual_steer|)`로 바꿔 반전 중에도 0이 되지 않게 한다.
2. **바늘 근접 계수가 상수 1.0이었다.** → `proximity = base + (1-base)·steer_mag`로 동적 승격(조향이 셀수록 손이 바늘에 접근 — 연출 기믹과 서사 일치).
3. **조향 지연항에 상시 바이어스 추가.** `(steer_gap + static_bias)`. 급반전은 `steer_gap`의 시간적분이 유지(hold)의 약 4배라 자연히 훨씬 위험해지고(별도 반전 승수 불필요), `static_bias`는 고속 "풀조향 유지"에도 위험을 쌓아 경고 UI(0.5)가 실제로 뜨게 한다.
4. **속도 계수를 `pow(_, risk_speed_exp)`로** 지수화해 저속을 강하게 억제(1 ~ 2단은 어떤 조향에도 사실상 무해).

```gdscript
func _update_risk(delta: float) -> void:
    var steer_gap := absf(target_steer - actual_steer)
    var speed_factor := inverse_lerp(T.min_speed, T.max_speed, speed)
    var speed_gate := pow(speed_factor, T.risk_speed_exp)          # 속도 계수(저속 억제)
    var steer_mag := maxf(absf(target_steer), absf(actual_steer))  # 조향 입력량(반전에 강건)
    var proximity := _finger_proximity(steer_mag)                  # 바늘 근접(동적)
    var gain := speed_gate * steer_mag * proximity * (steer_gap + T.risk_static_bias)
    if gain > T.danger_threshold:
        risk += gain * T.risk_gain_rate * delta
    else:
        risk = move_toward(risk, 0.0, T.risk_recover_rate * delta)
    if risk >= 1.0 and stun_timer <= 0.0:
        _trigger_cut()

func _trigger_cut() -> void:
    risk = 0.0
    stun_timer = T.stun_duration        # 2.0s 조작 잠금
    speed_index = 1                       # 최소 속도로 강제
    _just_cut = true                      # RaceDirector가 이번 틱에 소비 → cuts += 1
```

`_finger_proximity(steer_mag)`는 조향 편향에 비례한 동적 근접값을 반환한다. 확장 시 실제 손 위치 모델로 교체하는 지점. 결정론(60Hz 고정 스텝)은 불변이다. **부상 빈도 상향(플레이테스트 v3)**: "부상이 너무 드물다"는 피드백에 따라 `risk_gain_rate`(2.4→2.8)·`risk_static_bias`(0.10→0.14)·`risk_speed_exp`(2.0→1.5)를 재튜닝했다. 검증 결과 5단 급반전은 1회 내, 4단 급반전은 2 ~ 4회 내 부상, 5단 풀조향 유지는 경고 ~0.8s·부상 ~2.0s, 3단 급반전은 peak risk ≈0.33(경고만, 부상 없음), 1 ~ 2단은 어떤 조향에도 부상 불가(1단은 `speed_gate=0`으로 구조적 불가, 2단은 gain이 `danger_threshold`를 넘지 못함)로 나타난다.

**리스크 재튜닝(조향 동역학 v4).** §6.2에서 actual 추종을 지수 평활로 바꾸면 반전이 부드럽게 수렴해 `steer_gap`의 시간적분이 예전보다 짧아진다(구 모델은 느린 `move_toward`가 큰 갭을 ~1.65s 유지). 공식은 그대로 두고 파라미터만 다시 맞춰 기존 수용 기준을 보존한다: `risk_gain_rate` 2.8→3.6(짧아진 갭 보상), `danger_threshold` 0.09→0.07(3단 급반전 갭이 게이지에 반영되게), `risk_speed_exp` 1.5→1.1(3단이 경고 영역까지 게이지를 채우도록 속도별 위험을 완만화하되 1 ~ 2단은 여전히 무해), `risk_static_bias` 0.14→0.09(짧아진 갭 분포에서 5단 풀조향 유지 부상을 ~2.1s로), `risk_recover_rate` 0.5→0.65(3단 급반전을 40회 반복해도 누적→부상되지 않고 peak ~0.48에서 정체). **Godot 4.6.1 헤드리스 검증**: 5단 급반전 1회 부상 / 4단 2회 / 3단 부상 불가(단발 peak 0.22·연속 peak 0.48로 경고만) / 1 ~ 2단 부상 불가 / 5단 풀조향 유지 경고 0.63s·부상 2.08s / 4 ~ 5단 완만 조향 무위험. Python 리플리카와 비트 일치. `risk_proximity_base`(0.35)·`stun_duration`(2.0)·`stun_steer_return_rate`(1.1)는 불변.

경고 연출 임계(0.50/0.70/0.85/0.95)는 `RiskMeter.gd`가 `risk` 값을 받아 색/점멸만 처리(MVP는 시각 최소 구현).

### 6.5 판정 · 채점 · 페널티 (§7.6, §7.7)

`RunStats`(RefCounted)가 매 틱 누적, 피니시에 확정한다.

```gdscript
# RunStats.gd
const OFF_SEAM_PENALTY_PER_S := 0.5   # §7.7
const CUT_PENALTY := 2.0              # §7.7 (부상 1회 +2.0s)

var active_time := 0.0
var perfect_time := 0.0
var off_seam_time := 0.0
var error_sum := 0.0        # seam_error * dt 누적
var speed_index_sum := 0.0
var samples := 0
var max_speed_index := 1
var cuts := 0
var penalty_time := 0.0

func accumulate(dt, sidx: int, band: int, err: float, just_cut: bool) -> void:
    active_time += dt
    error_sum += err * dt
    speed_index_sum += sidx
    samples += 1
    max_speed_index = max(max_speed_index, sidx)
    match band:
        BAND.PERFECT:
            perfect_time += dt
        BAND.OFF_SEAM, BAND.TEAR:
            off_seam_time += dt
            penalty_time += OFF_SEAM_PENALTY_PER_S * dt
    if just_cut:
        cuts += 1
        penalty_time += CUT_PENALTY

func finalize(finish_time: float, safe_width: float, track_id: String, diff: String) -> Dictionary:
    var mean_err := error_sum / max(active_time, 0.0001)
    var normalized := mean_err / safe_width * 100.0          # §7.6
    var accuracy := clampf(100.0 - normalized, 0.0, 100.0)
    var perfect_rate := perfect_time / max(active_time, 0.0001) * 100.0
    # ms는 성분별 절사 후 합산: final_time 독립 절사는 floor(a+b)≥floor(a)+floor(b)로
    # final_time_ms를 1ms 부풀려 서버 페널티 일관성 검증(final==time+penalty)에 걸린다.
    var finish_ms := int(finish_time * 1000)
    var penalty_ms := int(penalty_time * 1000)
    return {
        "track_id": track_id, "difficulty": diff,
        "finish_ms": finish_ms,
        "penalty_ms": penalty_ms,
        "final_time_ms": finish_ms + penalty_ms,
        "accuracy": accuracy, "perfect_rate": perfect_rate,
        "off_seam_ms": int(off_seam_time * 1000),
        "cuts": cuts, "max_speed": max_speed_index,
        "avg_speed": speed_index_sum / max(samples, 1),
    }
```

판정 표(§7.6):

| 조건 | 밴드 | MVP 효과 |
|---|---|---|
| `err <= perfect(18)` | Perfect | perfect_time 누적, 콤보 증가(결과 표시용) |
| `err <= safe(42)` | Good | 정상 |
| `err <= fail(90)` | Off-Seam | off_seam_time 누적, `+0.5s/초` 페널티, 콤보 초기화 |
| `err > fail(90)` | Tear | MVP는 Off-Seam과 동일 집계(+0.5s/초)로 처리, accuracy 오차 최대 기여, 콤보 초기화 |

> Tear 전용 페널티(+5.0s)와 구간 재시작(§7.7)은 MVP에서 제외한다(과제 지정: MVP 페널티는 Off-Seam +0.5s/s, 부상 +2.0s/회만). Tear는 밴드로만 존재시키고 페널티는 Off-Seam에 흡수한다.

**피니시 판정**: `probe.s >= track.length - 1.0`. 진행도 `s`는 윈도 탐색으로 단조 증가에 가깝게 유지되므로 안정적이다. 피니시 시 `_stats.finalize(_elapsed, _track.safe, ...)` → `RecordStore.submit` → `GameState.to_result`.

콤보(§7.8)는 결과 화면 숙련도 지표로만 집계(최종 시간에 반영 안 함).

**재봉 평점(Seam Grade)**: `finalize`가 in-line 충실도를 등급으로 환산해 결과 dict에 `grade`(문자)·`grade_score`(0 ~ 100 수치)로 담는다. `grade_score = clamp(accuracy×0.6 + perfect_rate×0.4 − cuts×5, 0, 100)`, 등급 컷오프는 S≥95 / A≥88 / B≥75 / C≥60 / D. accuracy(평균 이탈의 역수)를 주 가중치로 두어 "재봉선대로 정직하게 완주"를 보상하고 부상(cuts)을 무겁게 감점한다. 리더보드 정렬 기준(`final_time_ms`)은 불변이며 등급은 성취 표시용이다(결과 화면·완주 줌아웃 연출에서 표시).

### 6.6 아이템 슬롯 (v2.2.1)

v2.2.1부터 필드 아이템(골무, 엄마 찬스)은 밟는 순간 효과를 내지 않고 두 칸짜리 슬롯에 담긴다. 플레이어는 원하는 때에 사용 입력(`use_item`, 키보드 Space, 터치 USE 버튼)을 눌러 가장 먼저 담은 아이템부터 쓴다. 슬롯 상태는 `RaceDirector`가 가지며, 모든 변경은 60Hz 고정 틱 안에서만 일어난다.

**담기 규칙**

- 슬롯은 `RaceDirector.ITEM_SLOT_CAPACITY`(2)칸의 FIFO 큐(`_slots`, 아이템 type 문자열 배열)이다. 앞쪽 원소가 다음에 쓸 아이템이다.
- 노루발이 아이템 반경(`Tuning.item_pickup_radius`) 안에 들어오면, 빈 칸이 있을 때 슬롯 맨 뒤에 담고 그 아이템을 획득한 것으로 처리한다(`_collected[i] = true`, `ItemField.on_collected`).
- 슬롯이 가득 차 있으면 아이템을 획득하지 않는다. 아이템은 필드에 그대로 남고, 반경에 들어온 첫 틱에만 HUD에 "가득 참" 피드백(슬롯 위젯 흔들림, 낮은 재봉틀 틱 소리)을 보낸다. 반경 안에 머무는 동안 슬롯이 비면 다음 틱에 정상적으로 담는다.
- 한 틱에 아이템 여러 개가 겹치면 `ItemOrder` 정규 순서(s 오름차순, 같으면 type, lat, 원래 인덱스 순)로 담는다(v2.3.0부터). 이전에는 배열 인덱스 순서였는데, 기록 지문(§3.2)과 같은 순서를 쓰도록 바꿔 파일의 배열 순서만 다른 트랙이 같은 결과를 내게 했다.

**사용 규칙**

- `use_item` 눌림은 속도 입력처럼 `_unhandled_input`에서 버퍼링하고, 다음 물리 틱의 `InputFrame.use_item`으로 소비한다. 키 반복(echo) 이벤트는 받지 않으므로 길게 눌러도 한 번만 쓰며, 한 틱 안에 여러 번 눌러도 한 번으로 합친다.
- 사용은 그 틱의 `simulate` 전에 처리한다. 슬롯 맨 앞 아이템을 꺼내 기존 효과 함수 `_apply_item`을 그대로 부르므로, 골무는 `grant_thimble`(부상 면역 `Tuning.thimble_duration`)이, 엄마 찬스는 `grant_autopilot`(자동 주행 `Tuning.autopilot_duration`)이 실행된다. 엄마 찬스의 자동 주행 시작점은 직전 틱의 트랙 질의 결과(`_last_s`)이다.
- 같은 효과가 이미 켜져 있을 때 다시 쓰면 타이머가 전체 지속 시간으로 갱신된다. 남은 시간에 더해지지는 않으며, 슬롯 도입 전에 아이템을 다시 먹었을 때와 같은 규칙이다. 서로 다른 효과는 함께 켜질 수 있다.
- 부상 대기(손 미끄러짐 사전 연출) 중에도 쓸 수 있다. 예전에는 아이템을 먹을 때 `grant_*`가 대기 중인 부상을 해제했는데, 이제는 사용할 때 같은 해제가 일어난다. 담기만 해서는 대기 중인 부상이 풀리지 않는다. 사용이 시뮬레이션보다 먼저 처리되므로, 대기가 끝나는 마지막 틱에 눌러도 그 틱의 부상을 막는다.
- 부상 스턴(`stun_timer`)과 원단 이탈 복귀 잠금(`offfabric_timer`) 중에는 속도 입력과 마찬가지로 조작 잠금으로 보고 사용을 무시한다. 슬롯은 그대로 남고 눌림은 버려지므로, 잠금이 풀린 뒤에 뒤늦게 쓰이지 않는다. 빈 슬롯에서 누른 경우와 함께 HUD에는 짧은 흔들림만 보낸다.
- 카운트다운, 일시정지, 완주 줌아웃 중의 눌림은 버퍼에 넣지 않는다. 일시정지를 걸거나 풀 때도 버퍼를 비운다.

**한 틱 안의 순서**는 입력 샘플 → 아이템 사용 → 자동 주행 타깃 주입 → `simulate` → 트랙 질의 → 아이템 담기 → 이탈 리셋 판정 → 집계 순이다. 그래서 슬롯이 가득 찬 상태에서 아이템 위를 지나며 사용 입력을 누르면, 먼저 앞 칸을 쓰고 같은 틱에 새 아이템을 뒤 칸에 담는다.

**완주와 재시작.** 완주하면 결과를 확정한 직후 남은 슬롯을 효과 없이 비운다. 기록과 등급에는 영향이 없다. 재시작은 씬을 다시 불러오므로 슬롯이 빈 상태로 시작한다.

**통계와 제출 스키마.** `RunStats`에는 아이템 관련 집계가 없으므로 결과 dict와 리더보드 제출 필드는 바뀌지 않았다. `tools/item_slot_regression`이 결과 dict의 키 목록을 확인한다.

**결정론.** 슬롯은 문자열 배열 하나이고, 담기와 사용이 모두 고정 틱 안에서만 바뀌며, 사용 입력은 `InputFrame`에 기록된다. 같은 입력 시퀀스를 두 번 실행하면 틱마다 위치, 방향, RISK, 슬롯, 효과 타이머가 같다는 것을 `tools/item_slot_regression`이 확인한다.

---

## 7. 입력 맵 (§11.1)

**결정: `InputSetup` 오토로드의 `_ready()`에서 `InputMap`으로 런타임 등록한다.** `project.godot`의 `[input]` 섹션에 `InputEventKey`를 직접 직렬화하는 방식은 손으로 쓰기 매우 취약(Object 직렬화, deadzone 필드 등)하므로 회피한다. Godot이 설치돼 있지 않아 에디터 Input Map 패널을 못 쓰는 이 프로젝트에는 코드 등록이 가장 견고하다.

```gdscript
# InputSetup.gd  (autoload)
extends Node
func _ready() -> void:
    _bind("steer_left",  [KEY_LEFT,  KEY_A])
    _bind("steer_right", [KEY_RIGHT, KEY_D])
    _bind("speed_up",    [KEY_UP,    KEY_W])
    _bind("speed_down",  [KEY_DOWN,  KEY_S])
    _bind("restart",     [KEY_R])
    _bind("pause",       [KEY_ESCAPE])
func _bind(action: StringName, keys: Array) -> void:
    if InputMap.has_action(action): return
    InputMap.add_action(action)
    for k in keys:
        var ev := InputEventKey.new()
        ev.physical_keycode = k       # 물리 키(레이아웃 무관) 권장
        InputMap.action_add_event(action, ev)
```

| 액션 | 키 | 처리 방식 |
|---|---|---|
| `steer_left` / `steer_right` | ←/A, →/D | 연속: `is_action_pressed` |
| `speed_up` / `speed_down` | ↑/W, ↓/S | 이산: `_unhandled_input` 버퍼링 |
| `restart` | R | 이산: Gameplay 재로드 |
| `pause` | Esc | 이산: PauseOverlay 토글 |
| `use_item` | Space | 이산: `_unhandled_input` 버퍼링 → `InputFrame.use_item`(v2.2.1, §6.6) |

`use_item`에 Ctrl을 쓰지 않은 이유는 두 가지다. 조향이 A/D, 속도가 W/S라서 웹 빌드에서 Ctrl+W(탭 닫기)·Ctrl+S·Ctrl+A·Ctrl+D가 브라우저 단축키와 겹치고, Ctrl+W는 페이지에서 막을 수 없다. macOS에서는 Ctrl+방향키가 데스크톱 전환이다. Space는 Godot 기본 `ui_accept`에도 들어 있지만, 주행 중에는 포커스를 가진 Control이 없어서 GUI가 Space를 소비하지 않고 `_unhandled_input`까지 전달된다(튜토리얼이 떠 있을 때는 "시작하기" 버튼이 포커스를 가지므로 Space가 Enter처럼 튜토리얼을 닫는다). 웹에서는 엔진의 캔버스 `keydown` 처리기가 모든 키 이벤트에 `preventDefault()`를 부르고 기본 셸의 `body`가 `overflow: hidden`이라서 Space가 페이지를 스크롤하지 않는다. 이 내용은 Godot 4.6.1 웹 템플릿의 `godot.js`에서 확인했으며, 실제 브라우저에서는 검증하지 않았다.

Tab(고스트 토글)은 MVP 제외.

---

## 8. 미니맵 (§8.3)

**결정: `Control`의 커스텀 `_draw()`.** SubViewport+제2 Camera2D 방식은 월드 씬을 한 번 더 렌더해 웹 성능에 불리하고, "주변 경로만 표시"(§4.5) 필터링을 자연스럽게 못 한다(뷰에 들어온 모든 것이 그려짐). 커스텀 draw는 `s` 윈도로 정확히 필요한 폴리라인 조각만 골라 그린다.

- 표시 범위: `preview_distance = speed * 4.0`, `back_distance = speed * 1.5`(§8.3). `s ∈ [progress_s - back, progress_s + preview]` 구간의 베이크 점만 사용.
- 변환: 플레이어를 중심에, **진행 방향이 화면 위(−Y)를 향하도록** 회전. 핵심 식:

```gdscript
# _draw() 안. player_pos/heading/progress_s/speed는 RaceDirector가 매 틱 주입.
func _draw() -> void:
    var preview := speed * 4.0
    var scale := (size.x * 0.5) / max(preview, 1.0)
    var center := size * 0.5
    var local := PackedVector2Array()
    for i in _window_indices(progress_s - speed * 1.5, progress_s + preview):
        var rel := (track.points[i] - player_pos).rotated(-heading - PI / 2.0) * scale
        local.append(center + rel)      # forward → 화면 위쪽에 매핑
    draw_polyline(local, PATH_COLOR, 2.0)
    draw_circle(center, 3.0, PLAYER_COLOR)             # 현재 위치
    draw_line(center, center + Vector2(0, -8), ARROW_COLOR, 2.0)  # 진행 방향 화살표
    # 급커브 경고/피니시 근접 마커는 윈도 내 곡률·s로 추가
```

- `clip_contents = true`로 반경 밖은 잘라낸다. `RaceDirector`가 매 틱 값 주입 후 `queue_redraw()` 호출.
- 회전 검증: forward `f=(cos h, sin h)`(각 `h`)를 `-h-π/2`만큼 회전하면 각이 `-π/2` → `(0,-1)` = 화면 위. 정합.

---

## 9. 튜닝 파라미터 (§19)

**결정: 오토로드 `Tuning`(Node)이 §19 값을 타입 지정 멤버 변수 기본값으로 보유하고, `_ready()`에서 `res://data/tuning.json`이 있으면 병합(오버라이드)한다.** 순수 GDScript라 Godot 없이 손으로 작성 가능하고, 웹에서 안전하며, JSON만 고쳐 즉시 재튜닝된다. 커스텀 `Resource(.tres)` 직접 손작성은 `uid`/`ext_resource`/`script_class` 헤더가 취약해 회피한다(에디터 도입 후 인스펙터 튜닝·난이도별 변형이 필요해지면 `TuningParams` Resource로 승격 — 확장 지점).

```gdscript
# Tuning.gd  (autoload)
extends Node
var min_speed := 80.0
var max_speed := 300.0
var speed_step_count := 5
var speed_table := [80.0, 120.0, 170.0, 230.0, 300.0]   # index 1..5
var steer_charge_rate := 3.2         # 조향 v4: 충전 상향(구 1.8) — 반전/복귀 민첩화
var steer_return_rate := 4.5         # 조향 v4: 키 해제 직진 복귀 상향(구 2.4)
var foot_response_rate := 1.1        # (구 move_toward 추종) steer_tau 지수 평활로 대체 → 미사용
var steer_tau := 0.16                # §19에 없음 → 지수 추종 시간상수(랙 질감). actual+=(target-actual)*(1-exp(-dt/tau))
var steer_reversal_boost := 2.0      # §19에 없음 → 입력 부호≠target 부호일 때 충전 배수(반전만 민첩)
var turn_power := 4.0                 # 고속 코너링 완화 재튜닝(구 3.3), steer_speed_floor와 함께
var steer_speed_floor := 0.825        # 4단 비율(0.767)과 5단 비율(1.0) 사이 → 5단만 완화(§6.3)
var risk_gain_rate := 3.6           # 조향 v4: 짧아진 갭 보상 상향(구 2.8)
var risk_recover_rate := 0.65        # 조향 v4: 3단 급반전 반복이 부상으로 누적되지 않게(구 0.5)
var danger_threshold := 0.07         # 조향 v4: 3단 급반전 갭을 게이지에 반영(구 0.09)
var risk_speed_exp := 1.1            # 조향 v4: 3단이 경고 영역까지(속도별 위험 완만화, 구 1.5)
var risk_proximity_base := 0.35      # §19에 없음 → 바늘 근접 계수 하한(동적 근접의 base)
var risk_static_bias := 0.09         # 조향 v4: 짧아진 갭 분포에서 5단 유지 부상 ~2.1s(구 0.14)
var stun_duration := 2.0
var stun_steer_return_rate := 1.1    # §19에 없음 → foot_response_rate 재사용

func _ready() -> void:
    var path := "res://data/tuning.json"
    if FileAccess.file_exists(path):
        var d = JSON.parse_string(FileAccess.open(path, FileAccess.READ).get_as_text())
        if d is Dictionary:
            for k in d: if k in self: set(k, d[k])
```

> `perfect_width/safe_width/fail_width`(§19)는 **트랙별**이므로 `Tuning`이 아니라 트랙 JSON `width`에서 온다. `danger_threshold`와 `stun_steer_return_rate`는 §19 표에 없어 초기값을 추정 지정했으니 조작감 테스트에서 우선 조정한다.

---

## 10. 파일 목록과 책임

`game/` 하위. §15 저장소 구조를 따르되 MVP 필수만.

```text
game/
  project.godot
  scenes/
    Main.tscn
    Gameplay.tscn
    Result.tscn
  scripts/
    autoload/
      Tuning.gd
      InputSetup.gd
      TrackLoader.gd
      RecordStore.gd
      GameState.gd
    player/
      PlayerController.gd
    track/
      TrackData.gd
      TrackRenderer.gd
      FinishLine.gd
    systems/
      RaceDirector.gd
      RunStats.gd
      InputFrame.gd
    ui/
      MainMenu.gd
      ResultScreen.gd
      HUD.gd
      MiniMap.gd
      SpeedGauge.gd
      RiskMeter.gd
      Stopwatch.gd
      Countdown.gd
  data/
    tuning.json            # 선택적 오버라이드
  tracks/
    official/
      cotton_01.json
```

| 파일 | 책임 |
|---|---|
| `project.godot` | main scene = `Main.tscn`, `[autoload]` 5개(순서 §3), `physics_ticks_per_second=60`, 렌더러 설정 |
| `Tuning.gd` | §19 파라미터 + JSON 오버라이드 |
| `InputSetup.gd` | 입력 액션 런타임 등록(§7) |
| `TrackLoader.gd` | 트랙 JSON 로드 → `TrackData.bake`, id별 캐시 |
| `RecordStore.gd` | `user://records.json` 로드/저장, 트랙·난이도별 신기록 판정, 개인 고스트 연결, 고스트 표시 설정(§3.1~§3.3) |
| `GhostRun.gd` | RefCounted. 고스트 샘플 기록(20Hz, 복귀·완주 이벤트), 10구간 통과, 재생 보간(`state_at`)(§3.3) |
| `GhostStore.gd` | RefCounted 정적 도우미. 고스트 파일 저장·검사·고아 정리, 임시 파일 교체 쓰기(`write_atomic`)와 중단 복구(`recover_pending`)(§3.2, §3.3) |
| `ItemOrder.gd` | RefCounted 정적 도우미. 필드 아이템 정규 순서(s→type→lat→인덱스). 획득 판정과 기록 지문이 함께 쓴다(§3.2, §6.6) |
| `GhostSplitBanner.gd` | 화면 위 가운데 구간 시간차·고스트 안내 배너(§3.3, docs/mobile.md §4.2) |
| `GhostSelectRow.gd` | 트랙 선택 화면의 개인 고스트 토글·상태 문구(§3.3) |
| `GameState.gd` | 씬 전환, 세션/결과 데이터 버스 |
| `PlayerController.gd` | 운동학 상태(position/heading/speed/steer/risk/stun). `simulate(input, delta)` — 조향/이동/리스크/스턴. 자체 `_physics_process` 없음 |
| `TrackData.gd` | RefCounted. 베이크 폴리라인(`points/s_arr/length`), 판정 폭, `query(pos, hint)` 윈도 최근접 |
| `TrackRenderer.gd` | `Node2D._draw`로 centerline + perfect/safe/fail 폭 시각화 |
| `FinishLine.gd` | `Node2D._draw`로 피니시 시각 마커(경로에 수직인 라인). RaceDirector가 위치·회전·폭 설정 |
| `RaceDirector.gd` | Gameplay 루트. 물리 루프 소유, 상태기계(COUNTDOWN/RUNNING/FINISHED), 스톱워치, 판정·집계 호출, 피니시, 전환. `is_racing()`은 표현 계층이 RUNNING 여부를 읽기만 하는 조회 함수다 |
| `RunStats.gd` | RefCounted. accuracy/perfect_rate/off_seam/cuts/penalty 누적 및 `finalize` |
| `InputFrame.gd` | RefCounted. 한 틱 입력 스냅샷(steer 방향, speed 증감, restart) — 실시간·리플레이 공통 입력 |
| `MainMenu.gd` | 트랙명·최고기록 표시, Start/Quit |
| `ResultScreen.gd` | `GameState.last_result` 렌더(§8.4 항목), 신기록 라벨, Retry/Menu |
| `HUD.gd` | HUD 자식(Stopwatch/SpeedGauge/RiskMeter/MiniMap/Status/Countdown) 갱신 중계 |
| `MiniMap.gd` | 커스텀 `_draw`, s 윈도 폴리라인 + 위치/방향 |
| `SpeedGauge.gd` | `[1] ~ [5]` 단계 표시(4 ~ 5단 경고 연출) |
| `RiskMeter.gd` | risk 게이지, 0.50/0.70/0.85/0.95 경고 색/점멸 |
| `Stopwatch.gd` | `_elapsed` → `MM:SS.mmm` 포맷 |
| `Countdown.gd` | 시작 카운트다운 오버레이 |
| `DriftSkid.gd` | (표현) 드리프트 원단 주름 데이터 소스. 패치 위치·방향·강도·생성 시각 기록, 바닥 잔여 흔적, 완주 뷰용 `get_full_marks()`(docs/presentation.md §15) |
| `DriftFoldLayer.gd` | (표현) 주름 패치를 Mode 7과 같은 카메라로 투영하는 2.5D 레이어. 활성 12개, 셰이더 `drift_fold.gdshader` |
| `DriftFoldShape.gd` | (표현) 높이맵 공유 격자·파생 텍스처·시간 모델 정적 캐시 |
| `cotton_01.json` | MVP 트랙(§9.2 포맷) |

---

## 11. 확장 지점

MVP 코드에 미리 열어둔 확장 포인트만 명시한다.

| 확장(기획서) | 진입 지점 | 방법 |
|---|---|---|
| 온라인 리더보드(§13, §14) | **구현됨** — `LeaderboardClient` 오토로드(HTTPRequest 기반 비동기 submit/fetch/health, 5s 타임아웃·조용한 실패) | 결과 dict를 §13.3 `POST /api/runs` 스키마로 매핑(`player_name`=닉네임, `time_ms`=`finish_ms`, `game_version`="0.2.0", `track_checksum`=공식 트랙 JSON 바이트 SHA-256; `replay_hash`는 §14.2 Unverified 운영이라 생략). 설정(닉네임·서버 URL)은 `user://settings.json`. UI: 메인 메뉴 `Settings`/`Leaderboard` 진입, 결과 화면 `Submit to Leaderboard`(공식 트랙+URL+닉네임 조건, 커스텀 트랙은 숨김). `Verified` 리플레이 검증은 후속(아래 행) |
| 리플레이 검증(§14.3) | `RaceDirector._sample_input` | 입력 소스를 실시간/기록 소스로 분기. `InputFrame` 시퀀스만 저장하면 결정론적 고정 스텝이라 서버(Python) 재시뮬레이션 가능 |
| 실 장력(§7.9) | `PlayerController.simulate` 말미 | `thread_tension` 상태 + 갱신 함수 추가, 임계 초과 시 페널티. `RunStats`에 필드 추가 |
| 바늘 과열(§7.10) | 속도/원단 갱신부 | `needle_heat` 상태, 과열 시 `speed_index` 상한 제한 훅 |
| 원단 물성(§9.2 modifiers) | `RaceDirector` 틱, `s` 기준 | 이미 JSON `modifiers` 파싱해 둠(MVP는 무시). `s`가 modifier 구간 진입 시 `Tuning` 계수(마찰/미끄러짐) 일시 적용 |
| 2.5D 연출(§5.3) | `World` 레이어 | 원단 텍스처 레이어 + 원근 셰이더 추가, 판정(2D)과 분리. `NeedleVisual`을 스프라이트/3D로 교체 |
| 튜닝 인스펙터/난이도별 변형 | `Tuning` | `class_name TuningParams extends Resource`로 승격, 난이도별 `.tres` 분리 |
