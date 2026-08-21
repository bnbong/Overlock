# Overlock 클라이언트 아키텍처 (MVP)

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
| 4 | `RecordStore` | Node | `user://records.json` 로드/저장, 신기록 판정 |
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

---

## 4. 좌표 / 월드 모델

**결정: 트랙을 월드 공간에 고정하고 플레이어(바늘)가 이동한다. `Camera2D`가 플레이어를 추적한다.**

근거:
- 기획서 이동식(§7.4)이 `position += forward * speed * delta` 즉 **플레이어의 절대 월드 좌표**를 전제한다. 트랙을 스크롤시키는 대안은 이 모델과 상충하고 좌표 변환이 이중으로 든다.
- `seam_error`가 "플레이어 월드 좌표 ↔ 동일 공간에 베이크된 폴리라인" 거리로 단순 계산된다.
- 미니맵의 월드→미니맵 변환이 한 번의 아핀 변환으로 끝난다.

세부:
- 단위: **1 world unit = 1 px**. 속도는 px/s(§7.2, §19의 80~300).
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
  - **전역 스캔을 쓰지 않는 이유**: 닫힌·자기근접 윤곽(heart_01·star_01은 시작/끝이 55~103px)에서 전역 스캔은 기하적으로 가깝지만 `s`가 먼 **다른 가지**로 최근접을 잡아 `s`를 순간이동시킨다. 그러면 피니시 판정(`s ≥ length − 1`)이 영영 안 오고 `s` 기반 미니맵도 실제 위치와 어긋난다(사용자 보고 버그 1·2). 인덱스 한계를 둔 확장 윈도는 원거리 가지에 절대 도달하지 못하므로 다른 가지로의 `s` 순간이동을 구조적으로 배제한다. 방어 경로에서만 확장 탐색을 하고(정상 프레임은 O(윈도)), 결정론은 불변이다.
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

> **조향 응답 튜닝(§21 "조작감이 답답함" 대응).** 구(舊) 모델은 `speed_factor = speed / max_speed`라 최소 회전반경이 `max_speed / turn_power`로 **전 속도 동일**(≈136px)이었다. cotton_01의 최소 곡률반경(≈53px, seg4 헤어핀)보다 커서 저속에서도 코너를 못 돌았다. `steer_speed_floor`(하한) + `turn_power`로 저속 최소 회전반경을 1단 24px / 2단 36px(≤ 0.7×53)로 낮춰 1~2단에서 모든 커브를 여유 있게 추종하게 했다. 조향 지연(§6.2 `steer_tau` 지수 추종)은 그대로 유지한다(§4.3 핵심 기믹). **동역학 v4는 회전반경 공식을 건드리지 않으므로 이 절의 회전반경(24/36/51/70px, 5단 75px)은 전부 불변이다.**
>
> **고속 코너링 완화(플레이테스트 v3).** 5단 최소 회전반경 91px가 헤어핀(53.5px)에 비해 과해 "고속 코너링이 어렵다"는 피드백을 받았다. `steer_speed_floor`는 `turn_speed_factor = max(speed/max_speed, floor)`의 하한이므로, floor를 **4단 비율(230/300=0.767)과 5단 비율(1.0) 사이인 0.825**로 낮추면 1~4단은 여전히 floor에 고정(factor=0.825)되고 5단만 자기 비율(1.0)을 쓴다. 여기에 `turn_power`를 3.3→4.0으로 올리되 `turn_power × floor = 3.3`을 유지해, **1~4단 회전반경은 24/36/51/70px로 완전히 동일(저속 조작감 불변)**하고 5단만 `300/4.0 = 75px`로 완화된다(헤어핀 53.5px보다 크게 유지해 감속 강제는 보존). 파라미터 전용 조정이며 `_update_movement` 공식은 그대로다.

### 6.4 리스크 / 부상 (§7.5)

기획서 §7.5 공식(속도 계수 × 조향 입력량 × 조향 지연 × 바늘 근접 계수)의 **구성 요소는 유지**하되, 구(舊) 구현이 부상을 사실상 낼 수 없던 두 결함을 교정한다.

1. **조향 입력량으로 `|target_steer|`를 쓰면 급반전 때 gain이 죽는다.** 좌↔우 반전 시 `target_steer`가 0을 지나는 순간 gain이 0이 되어, 가장 위험해야 할 급반전이 가장 안전했다. → `steer_mag = max(|target_steer|, |actual_steer|)`로 바꿔 반전 중에도 0이 되지 않게 한다.
2. **바늘 근접 계수가 상수 1.0이었다.** → `proximity = base + (1-base)·steer_mag`로 동적 승격(조향이 셀수록 손이 바늘에 접근 — 연출 기믹과 서사 일치).
3. **조향 지연항에 상시 바이어스 추가.** `(steer_gap + static_bias)`. 급반전은 `steer_gap`의 시간적분이 유지(hold)의 약 4배라 자연히 훨씬 위험해지고(별도 반전 승수 불필요), `static_bias`는 고속 "풀조향 유지"에도 위험을 쌓아 경고 UI(0.5)가 실제로 뜨게 한다.
4. **속도 계수를 `pow(_, risk_speed_exp)`로** 지수화해 저속을 강하게 억제(1~2단은 어떤 조향에도 사실상 무해).

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

`_finger_proximity(steer_mag)`는 조향 편향에 비례한 동적 근접값을 반환한다. 확장 시 실제 손 위치 모델로 교체하는 지점. 결정론(60Hz 고정 스텝)은 불변이다. **부상 빈도 상향(플레이테스트 v3)**: "부상이 너무 드물다"는 피드백에 따라 `risk_gain_rate`(2.4→2.8)·`risk_static_bias`(0.10→0.14)·`risk_speed_exp`(2.0→1.5)를 재튜닝했다. 검증 결과 5단 급반전은 1회 내, 4단 급반전은 2~4회 내 부상, 5단 풀조향 유지는 경고 ~0.8s·부상 ~2.0s, 3단 급반전은 peak risk ≈0.33(경고만, 부상 없음), 1~2단은 어떤 조향에도 부상 불가(1단은 `speed_gate=0`으로 구조적 불가, 2단은 gain이 `danger_threshold`를 넘지 못함)로 나타난다.

**리스크 재튜닝(조향 동역학 v4).** §6.2에서 actual 추종을 지수 평활로 바꾸면 반전이 부드럽게 수렴해 `steer_gap`의 시간적분이 예전보다 짧아진다(구 모델은 느린 `move_toward`가 큰 갭을 ~1.65s 유지). 공식은 그대로 두고 파라미터만 다시 맞춰 기존 수용 기준을 보존한다: `risk_gain_rate` 2.8→3.6(짧아진 갭 보상), `danger_threshold` 0.09→0.07(3단 급반전 갭이 게이지에 반영되게), `risk_speed_exp` 1.5→1.1(3단이 경고 영역까지 게이지를 채우도록 속도별 위험을 완만화하되 1~2단은 여전히 무해), `risk_static_bias` 0.14→0.09(짧아진 갭 분포에서 5단 풀조향 유지 부상을 ~2.1s로), `risk_recover_rate` 0.5→0.65(3단 급반전을 40회 반복해도 누적→부상되지 않고 peak~0.48에서 정체). **Godot 4.6.1 헤드리스 검증**: 5단 급반전 1회 부상 / 4단 2회 / 3단 부상 불가(단발 peak 0.22·연속 peak 0.48로 경고만) / 1~2단 부상 불가 / 5단 풀조향 유지 경고 0.63s·부상 2.08s / 4~5단 완만 조향 무위험. Python 리플리카와 비트 일치. `risk_proximity_base`(0.35)·`stun_duration`(2.0)·`stun_steer_return_rate`(1.1)는 불변.

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
    var final_time := finish_time + penalty_time
    return {
        "track_id": track_id, "difficulty": diff,
        "finish_ms": int(finish_time * 1000),
        "penalty_ms": int(penalty_time * 1000),
        "final_time_ms": int(final_time * 1000),
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

**재봉 평점(Seam Grade)**: `finalize`가 in-line 충실도를 등급으로 환산해 결과 dict에 `grade`(문자)·`grade_score`(0~100 수치)로 담는다. `grade_score = clamp(accuracy×0.6 + perfect_rate×0.4 − cuts×5, 0, 100)`, 등급 컷오프는 S≥95 / A≥88 / B≥75 / C≥60 / D. accuracy(평균 이탈의 역수)를 주 가중치로 두어 "재봉선대로 정직하게 완주"를 보상하고 부상(cuts)을 무겁게 감점한다. 리더보드 정렬 기준(`final_time_ms`)은 불변이며 등급은 성취 표시용이다(결과 화면·완주 줌아웃 연출에서 표시).

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
| `RecordStore.gd` | `user://records.json` 로드/저장, 신기록 판정 |
| `GameState.gd` | 씬 전환, 세션/결과 데이터 버스 |
| `PlayerController.gd` | 운동학 상태(position/heading/speed/steer/risk/stun). `simulate(input, delta)` — 조향/이동/리스크/스턴. 자체 `_physics_process` 없음 |
| `TrackData.gd` | RefCounted. 베이크 폴리라인(`points/s_arr/length`), 판정 폭, `query(pos, hint)` 윈도 최근접 |
| `TrackRenderer.gd` | `Node2D._draw`로 centerline + perfect/safe/fail 폭 시각화 |
| `FinishLine.gd` | `Node2D._draw`로 피니시 시각 마커(경로에 수직인 라인). RaceDirector가 위치·회전·폭 설정 |
| `RaceDirector.gd` | Gameplay 루트. 물리 루프 소유, 상태기계(COUNTDOWN/RUNNING/FINISHED), 스톱워치, 판정·집계 호출, 피니시, 전환 |
| `RunStats.gd` | RefCounted. accuracy/perfect_rate/off_seam/cuts/penalty 누적 및 `finalize` |
| `InputFrame.gd` | RefCounted. 한 틱 입력 스냅샷(steer 방향, speed 증감, restart) — 실시간·리플레이 공통 입력 |
| `MainMenu.gd` | 트랙명·최고기록 표시, Start/Quit |
| `ResultScreen.gd` | `GameState.last_result` 렌더(§8.4 항목), 신기록 라벨, Retry/Menu |
| `HUD.gd` | HUD 자식(Stopwatch/SpeedGauge/RiskMeter/MiniMap/Status/Countdown) 갱신 중계 |
| `MiniMap.gd` | 커스텀 `_draw`, s 윈도 폴리라인 + 위치/방향 |
| `SpeedGauge.gd` | `[1]~[5]` 단계 표시(4~5단 경고 연출) |
| `RiskMeter.gd` | risk 게이지, 0.50/0.70/0.85/0.95 경고 색/점멸 |
| `Stopwatch.gd` | `_elapsed` → `MM:SS.mmm` 포맷 |
| `Countdown.gd` | 시작 카운트다운 오버레이 |
| `cotton_01.json` | MVP 트랙(§9.2 포맷) |

---

## 11. 확장 지점

MVP 코드에 미리 열어둔 확장 포인트만 명시한다.

| 확장(기획서) | 진입 지점 | 방법 |
|---|---|---|
| 온라인 리더보드(§13, §14) | `RecordStore.submit` 이후 | `LeaderboardClient`(HTTPRequest) 추가, `RunStats.finalize` 결과 dict가 이미 `POST /api/runs` 스키마(§13.3)와 필드 일치. `game_version/track_checksum/replay_hash`만 보강 |
| 리플레이 검증(§14.3) | `RaceDirector._sample_input` | 입력 소스를 실시간/기록 소스로 분기. `InputFrame` 시퀀스만 저장하면 결정론적 고정 스텝이라 서버(Python) 재시뮬레이션 가능 |
| 실 장력(§7.9) | `PlayerController.simulate` 말미 | `thread_tension` 상태 + 갱신 함수 추가, 임계 초과 시 페널티. `RunStats`에 필드 추가 |
| 바늘 과열(§7.10) | 속도/원단 갱신부 | `needle_heat` 상태, 과열 시 `speed_index` 상한 제한 훅 |
| 원단 물성(§9.2 modifiers) | `RaceDirector` 틱, `s` 기준 | 이미 JSON `modifiers` 파싱해 둠(MVP는 무시). `s`가 modifier 구간 진입 시 `Tuning` 계수(마찰/미끄러짐) 일시 적용 |
| 2.5D 연출(§5.3) | `World` 레이어 | 원단 텍스처 레이어 + 원근 셰이더 추가, 판정(2D)과 분리. `NeedleVisual`을 스프라이트/3D로 교체 |
| 튜닝 인스펙터/난이도별 변형 | `Tuning` | `class_name TuningParams extends Resource`로 승격, 난이도별 `.tres` 분리 |
