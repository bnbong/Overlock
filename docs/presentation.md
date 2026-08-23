# Overlock 표현 계층 재설계 (노루발 시점 유사 3D 뷰)

- 대상 엔진: Godot 4.6.1 (GL Compatibility, 웹 export 고려)
- 범위: **표현 계층(프레젠테이션)만** 재작업. 시뮬레이션(PlayerController / TrackData / RaceDirector 물리 루프 / RunStats / 판정) 불변(한 줄도 안 바꿈). 60Hz 고정 스텝·결정론 유지.
- 목표: 탑다운 2D → "재봉틀 노루발 시점 유사 3D(2.5D) 뷰". 상단에 크게 내려다보는 얼굴, 수평선 아래 원근 원단 + 보라 재봉 경로, 중앙 고정 노루발+바늘, 좌우 손, 빨간 스티치 트레일.
- 이 문서 = **결정 사항**. `architecture.md`는 참조만(수정 안 함). 본 재설계 = `architecture.md` §11 확장 지점 "2.5D 연출(§5.3) → World 레이어 → 원단 텍스처 레이어 + 원근 셰이더 추가, 판정(2D)과 분리" 구현.

---

## 0. 핵심 결정 요약

| 항목 | 결정 |
|---|---|
| 투영 방식 | **(a) SubViewport 탑다운 소스 → 풀스크린 Mode 7 바닥 원근 셰이더**. 셀프인터섹션 크래시 클래스를 구조적으로 제거하고 기존 `TrackRenderer`를 그대로 재사용 |
| 카메라 변형 | **translate-only + 셰이더 내 회전**. SubViewport 카메라는 플레이어를 정확히 중심에 두고(스무딩 OFF, 회전 0), heading 회전은 프래그먼트 셰이더가 처리 → 회전 래스터 시머 없음 |
| 시뮬 재사용 | `World`(TrackRenderer/FinishLine/Player) 서브트리를 SubViewport 안으로 **이동**. 판정·좌표는 월드 공간 그대로 |
| RaceDirector 변경 | 물리 루프·상태기계·판정 **불변**. `@onready` NodePath 3개만 새 트리 위치로 갱신(배선) |
| 노루발/바늘 | SubViewport 밖 **스크린 고정 오버레이**. 셰이더의 forward=0 행에 정렬 |
| 스티치 트레일 | 플레이어 실제 궤적을 호길이 간격으로 샘플링한 **링버퍼**, SubViewport 안 월드 공간 `_draw`(자동 원근) |
| 얼굴/손 | 스크린 고정 플레이스홀더(`_draw`/Polygon2D), 이미지 교체 가능 구조 |
| HUD | 미니맵(좌상단) · 진행도 바(신규) · TIME(우상단 SS.cc) · 속도 게이지(우하단 세로 쉐브론) · 리스크(노루발 근처) 재배치 |
| 오디오 | `AudioManager` 오토로드 API 설계만. 훅은 UI/프레젠테이션 계층에 심어 물리 루프와 분리(구현은 별도 워커) |
| 검증 | Godot 4.6.1 비-headless 창 + `CaptureBot` 오토로드가 카운트다운/주행/커브 3장 캡처 후 자동 종료. **스크래치패드 사본**에서만 실행 |

---

## 1. 투영 방식 결정: (a) SubViewport + Mode 7 바닥 원근 셰이더

### 1.1 세 후보 비교

평가 4기준: 급커브 셀프인터섹션 재발 위험 / 웹 성능 / 기존 코드 재사용 / 스티치·원단 확장성.

| 기준 | (a) SubViewport + Mode 7 셰이더 | (b) CPU 폴리라인 원근 `_draw` | (c) 실제 3D (Node3D + Camera3D) |
|---|---|---|---|
| **셀프인터섹션 견고성** | **최상**. 밴드는 이미 크래시 안전한 두께 폴리라인(삼각형 스트립)으로 래스터화된 뒤 **픽셀 단위로 워프**된다. 오프셋 폴리곤을 재구성하지 않으므로 bowtie/"triangulation failed" 크래시가 **원리적으로 불가능** | 중. 원근 폭 테이퍼 밴드를 CPU에서 다시 리본화해야 함. 삼각형을 직접 방출하면 크래시는 피하나 급커브 시각 겹침·리본 메싱 부담 재유입 | 상. 3D 리본을 삼각형 스트립으로 빌드하면 삼각분할 불필요(안전). 단 신규 메시 빌드 코드 |
| **웹 성능(GL Compat)** | 상. 값싼 2D 씬 1회 추가 렌더 + 풀스크린 경량 프래그먼트 셰이더. `TrackRenderer`는 draw-once, 카메라만 팬 | **최상**(경로만). 그러나 원단 텍스처를 원근화하려면 결국 셰이더 필요 → (a)로 수렴 | 하. 3D 렌더러 파이프라인 전체 유입. 단순 씬이라도 가장 무거움 |
| **기존 코드 재사용** | **최상**. `TrackRenderer`/`TrackData`/`FinishLine`/`Player`/`Camera2D`/`MiniMap` 모두 유지. World 서브트리를 SubViewport로 이동만 | 중. `TrackData` 윈도 패턴은 재사용, `TrackRenderer` 밴드 렌더는 폐기·재작성 | 하. World Node2D 렌더를 3D 서브시스템으로 대체 |
| **스티치/원단 확장성** | **최상**. 스티치 트레일·원단 텍스처를 같은 탑다운 소스에 레이어로 추가하면 동일 셰이더가 일관되게 원근 처리 | 중. 스티치는 벡터로 가능하나 원단 텍스처는 별도 셰이더/사전 워프 필요 → 경로와 정합 어려움 | 상(비용 큼). 전부 3D 머티리얼 |

### 1.2 확정: **(a)**

근거:
1. 밴드가 이미 검증된 두께 폴리라인 래스터를 **픽셀로 워프** → 옛 오프셋 quad의 급커브 "triangulation failed" 크래시 클래스 구조적 소멸(최우선 견고성 요건 충족).
2. `TrackRenderer`·`TrackData`·`FinishLine`·`MiniMap` 그대로 재사용 → 시뮬 결합면 최소(World 서브트리 이동 + RaceDirector NodePath 3줄만).
3. GL Compatibility에서 SubViewport 1회 추가 렌더 + 풀스크린 프래그먼트 셰이더 저렴, `TrackRenderer` draw-once라 매 프레임 재드로우 없음.
4. 스티치 트레일·원단 질감을 같은 소스 레이어로 → 하나의 셰이더가 경로/원단/스티치를 **일관된 원근** 처리(확장성 최고).
5. 기획서 §5.3("원단 레이어에 원근 왜곡 셰이더")·`architecture.md` §11 확장 지점이 지목한 경로.

### 1.3 카메라 변형: translate-only + 셰이더 내 회전 (확정)

하위 변형 2종:

- **heading-up 회전 카메라**: SubViewport `Camera2D`를 heading만큼 회전(정면=위). 셰이더는 순수 세로 바닥 워프. 소스는 전방 원뿔만 담아 근경 해상도 유리. 단 카메라 회전으로 **밴드 가장자리 서브픽셀 크롤링(시머)** 발생.
- **translate-only + 셰이더 회전 (확정)**: SubViewport `Camera2D`는 **회전 0, 스무딩 OFF**로 플레이어 위치만 정확 추종(자식이므로 오프셋 0). heading 회전은 프래그먼트 셰이더가 샘플 좌표에 적용. **회전 래스터 시머 없음**, 카메라 시맨틱 불변(회전 안 함), 소스는 월드 정렬로 안정. 대가: 소스가 플레이어 주변 **디스크**(반경 = 유효 관측거리 ~300px) 담아야 하나 밴드가 넓어 512² 소스로 충분.

확정 이유: 시머 제거 + 카메라 회전 시맨틱 불변(스무딩만 끔) + 셰이더 회전 비용 무시(2×2 회전). heading-up은 근경 고해상 필요 시 **폴백**으로만 문서화.

### 1.4 Mode 7 바닥 원근 수식

가상 카메라: 원단 평면 위 높이 `h`, 뒤로 `cam_back` 물러나 전방·하방 응시. 스크린 UV `(u,v) ∈ [0,1]`, `v`는 위→아래.

수평선 행 `H`(예: 0.40) 아래 프래그먼트에 대해:

```
dy      = v - H                         # (0, 1-H],  수평선에 가까울수록 0+
depth   = depth_scale / dy              # 카메라 기준 전방 거리(px). 수평선서 ∞
lateral = (u - 0.5) * depth * spread    # 월드 가로 오프셋(px). 거리 비례 확산
forward = depth - cam_back              # 플레이어 기준 전방(음수=플레이어 뒤=근경)
```

카메라-로컬 `(forward, lateral)`을 heading으로 회전해 플레이어 기준 월드 오프셋으로:

```
fwd = (cos heading, sin heading)        # 전방축(월드)
rgt = (-sin heading, cos heading)       # 좌우축 (부호는 하네스에서 좌/우 일치 검증)
world_off = fwd * forward + rgt * lateral
src_uv    = (0.5, 0.5) + world_off / coverage   # 플레이어 = 소스 중심
```

- 노루발(플레이어) 스크린 행: `forward=0 → depth=cam_back → dy=depth_scale/cam_back`, 즉 **`v_needle = H + depth_scale / cam_back`**. 스크린 고정 노루발 오버레이를 정확히 이 행에 배치(어긋나면 바늘이 재봉선 위에서 뜸).
- 시작 상수(하네스에서 스크린샷 맞춰 미세조정): `H=0.40`, `depth_scale=28`, `cam_back=140`, `spread=0.9`, `coverage=600` → `v_needle=0.60`. 목표: 노루발 행에서 fail 밴드(폭 90)가 화면 폭 ~70% 채움.
- 수평선 근처(dy→0)는 `depth` 커져 `src_uv`가 커버리지 밖이면 민무늬 원단색 폴백 → 원경이 자연스럽게 원단으로 흐려짐.

### 1.5 셰이더 의사코드 (`res://shaders/fabric_mode7.gdshader`)

풀스크린 `TextureRect`/`ColorRect`에 `ShaderMaterial` 적용. `TEXTURE`(=SubViewport `ViewportTexture`)를 `source_tex`로 수신.

```glsl
shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D source_tex : filter_linear, repeat_disable; // 플레이어 중심·월드 정렬 탑다운(밉맵 근거는 §9 함정 12)
uniform float heading      = 0.0;    // 플레이어 진행각(rad)
uniform float horizon      = 0.40;   // 수평선 스크린 행
uniform float depth_scale  = 28.0;   // cam_height*focal 통합 상수(px). 클수록 멀리 봄
uniform float spread       = 0.9;    // 가로 원근 확산
uniform float cam_back     = 140.0;  // 카메라가 플레이어 뒤로 물러난 거리(px)
uniform float coverage     = 600.0;  // 소스가 담는 월드 정사각 한 변(px)
uniform vec4  fabric_color : source_color = vec4(0.72, 0.78, 0.34, 1.0); // 황록 원단(OOB 폴백)

void fragment() {
    if (UV.y <= horizon) {
        COLOR = vec4(0.0);                       // 수평선 위 → 투명(배경 얼굴이 비침)
    } else {
        float dy      = UV.y - horizon;
        float depth   = depth_scale / dy;
        float lateral = (UV.x - 0.5) * depth * spread;
        float forward = depth - cam_back;
        vec2  fwd     = vec2(cos(heading), sin(heading));
        vec2  rgt     = vec2(-fwd.y, fwd.x);     // 부호는 하네스에서 검증
        vec2  world_off = fwd * forward + rgt * lateral;
        vec2  src_uv  = vec2(0.5) + world_off / coverage;

        bool oob = src_uv.x < 0.0 || src_uv.x > 1.0 || src_uv.y < 0.0 || src_uv.y > 1.0;
        COLOR = oob ? fabric_color : texture(source_tex, src_uv);   // 소스는 원단 base 포함(불투명)

        float fade = smoothstep(0.0, 0.06, dy);  // 원경 앨리어싱 완화: 수평선 근처를 원단색으로
        COLOR.rgb = mix(fabric_color.rgb, COLOR.rgb, fade);
    }
}
```

`heading` uniform만 매 프레임 갱신(나머지 §1.4 상수). SubViewport 소스 드로잉 순서: **불투명 원단 base(FabricSurface) → 보라 밴드(TrackRenderer) → 스티치(StitchTrail) → FinishLine** → `texture(source_tex, …)`가 완성 이미지 제공.

---

## 2. 씬 / 노드 재구성

### 2.1 새 레이어 스택 (뒤→앞, CanvasLayer.layer로 순서 고정)

```text
Gameplay                      (Node2D)        [RaceDirector.gd]   ← 물리 루프 소유(불변)
├─ SimHost                    (Node2D)        시뮬 소스 호스트(화면 미표시)
│  └─ FabricSource            (SubViewport)   size≈512×512, update=ALWAYS, msaa_2d=2x, own_world_2d
│     └─ World                (Node2D)        ← 기존 World를 여기로 이동
│        ├─ FabricSurface     (Node2D)  [FabricSurface.gd]   황록 원단 base(월드, draw-once, 신규)
│        ├─ TrackRenderer     (Node2D)  [TrackRenderer.gd]   보라 밴드(불변)
│        ├─ StitchTrail       (Node2D)  [StitchTrail.gd]     빨간 스티치(월드, 신규)
│        ├─ FinishLine        (Node2D)  [FinishLine.gd]      피니시 마커(불변)
│        └─ Player            (Node2D)  [PlayerController.gd] 운동학 상태(불변)
│           ├─ NeedleVisual   (Polygon2D)   ← visible=false (바늘은 스크린 오버레이로 이동)
│           └─ Camera2D                       smoothing OFF, rotation 0 (translate-only)
├─ BackdropLayer              (CanvasLayer, layer=-20)
│  ├─ SkyRect                 (ColorRect)      수평선 위 배경 채움
│  └─ FaceView                (Node2D/Control) [BackgroundFace.gd]  내려다보는 얼굴(플레이스홀더, 신규)
├─ FabricLayer                (CanvasLayer, layer=-10)
│  └─ FabricWarp              (TextureRect)    풀스크린, ShaderMaterial=fabric_mode7 (신규)
├─ ForegroundLayer            (CanvasLayer, layer=0)
│  ├─ NeedleView              (Node2D)  [NeedleView.gd]   노루발+바늘, v_needle 정렬(신규)
│  └─ LeftHand / RightHand    (Node2D)  [HandView.gd]     좌우 손 플레이스홀더(신규)
├─ Presenter                  (Node)    [PresentationController.gd]  프레젠테이션 구동(신규)
└─ HUD                        (CanvasLayer, layer=10) [HUD.gd]
   ├─ MiniMap                 (Control)  [MiniMap.gd]       좌상단(리스타일)
   ├─ ProgressBar             (Control)  [ProgressBar.gd]   미니맵 아래(신규)
   ├─ Stopwatch               (Label)    [Stopwatch.gd]     우상단 TIME(SS.cc)
   ├─ SpeedGauge              (Control)  [SpeedGauge.gd]    우하단 세로 쉐브론(재작성)
   ├─ RiskMeter               (Control)  [RiskMeter.gd]     노루발 근처(재배치)
   ├─ SteerHint / SpeedHint   (Label)                      조작 힌트(신규)
   ├─ Countdown               (Label)    [Countdown.gd]     노루발 위로 재배치(로직 불변)
   ├─ StatusLabel             (Label)                       노루발 아래 Off-Seam/부상
   └─ PauseOverlay            (Control)                     불변
```

> `Countdown`·`StatusLabel`은 **HUD 자식 유지**, 앵커만 노루발 근처로. ForegroundLayer로 빼면 `HUD.gd`의 `@onready $Countdown`/`$StatusLabel` 깨짐 → HUD(풀스크린 CanvasLayer) 안에서 재배치. HUD가 layer=10(최상단)이라 카운트다운 "2"·상태 텍스트가 노루발 위에 겹침(의도).

### 2.2 유지 / 교체 / 이동 대상

| 노드/스크립트 | 처리 | 비고 |
|---|---|---|
| `PlayerController.gd`, `TrackData.gd`, `RunStats.gd`, `InputFrame.gd` | **불변** | 시뮬레이션 본체 |
| `RaceDirector.gd` | **이동에 따른 배선만**: `@onready` 3줄(`_player`/`_track_renderer`/`_finish_line`)을 `$SimHost/FabricSource/World/...`로 갱신. 물리 루프·상태기계·판정 불변. `_hud=$HUD` 유지 | §2.4 |
| `TrackRenderer.gd`, `FinishLine.gd` | **불변**, 위치만 이동 | draw-once 유지 |
| `Camera2D` | **SubViewport 내부로 이동**(Player 자식 유지). `position_smoothing_enabled=false`로 변경, rotation 0 유지 | §2.3 |
| `NeedleVisual` | `visible=false` | 바늘은 `NeedleView` 스크린 오버레이가 담당 |
| `MiniMap.gd` | 유지 + 리스타일(베이지 패널, 스티치 테두리, 지나온 궤적 점선) | §4.1 |
| `SpeedGauge.gd` | `_draw` 재작성(세로 쉐브론, 아래부터 채움) + 위치 이동 | §4.4 |
| `Stopwatch.gd` | 인게임 표시 포맷 `SS.cc` 메서드 추가(기존 `format_time` MM:SS.mmm는 결과용으로 보존) | §4.3 |
| `RiskMeter.gd` | 로직 유지, 위치·스타일만 재배치 | §4.5 |
| `Countdown.gd` | 로직 불변, 씬에서 노루발 위로 재배치 | §5 |
| `HUD.gd` | ProgressBar 참조·호출 추가, `update_frame`에 `track.length` 활용, 오디오 훅 호출 추가 | §4.2 |

### 2.3 Camera2D 처리 (확정)

- **제거하지 않고 SubViewport 내부로 이동**. Player 자식이므로 위치 자동 추종. 단 `position_smoothing_enabled=false`(워프가 정확한 플레이어 중심 소스 요구, 스무딩 지연 시 밴드가 중심에서 미끄러짐). `rotation=0`, `ignore_rotation`은 무관(회전 안 함).
- **루트(메인 창) 뷰포트에는 Camera2D 없음** → 기본 변형(원점 좌상단). 모든 오버레이는 CanvasLayer(스크린 공간)라 카메라 불필요.
- SubViewport `Camera2D`는 `enabled=true`여야 그 뷰포트의 활성 카메라(검게 나오면 이것부터 점검).

### 2.4 RaceDirector.gd 변경 (배선 3줄, 로직 불변)

```gdscript
# 변경 전
@onready var _player: PlayerController = $World/Player
@onready var _track_renderer: TrackRenderer = $World/TrackRenderer
@onready var _finish_line: FinishLine = $World/FinishLine
# 변경 후 (경로만 갱신, 나머지 코드는 그대로)
@onready var _player: PlayerController = $SimHost/FabricSource/World/Player
@onready var _track_renderer: TrackRenderer = $SimHost/FabricSource/World/TrackRenderer
@onready var _finish_line: FinishLine = $SimHost/FabricSource/World/FinishLine
```

`_tick_running`/`_sample_input`/`_classify`/`_finish`/`_place_finish_line`/`_init_player`는 손대지 않음. `_hud`는 여전히 `$HUD`.

### 2.5 프레젠테이션 구동 (`PresentationController.gd`, 신규)

프레젠테이션은 물리 루프와 분리, `_process`(렌더 프레임)에서 플레이어 상태 **읽기만**. 시뮬 결정론 무영향.

```gdscript
# Presenter._process(delta):
#  1. 셰이더 uniform 갱신:  warp_mat.set_shader_parameter("heading", player.heading)
#  2. ViewportTexture 연결(최초 1회):  warp_mat.set_shader_parameter("source_tex", subviewport.get_texture())
#  3. 스티치 샘플링(호길이 기반, §3)
#  4. NeedleView 바늘 상하 왕복 = f(player.speed)  (§5)
#  5. Hand 미세 진동 = f(player.speed);  얼굴 표정 = f(player.risk, player.stun_timer)
#  6. 화면 흔들림(스크린 셰이크) = f(player.risk, stun rising-edge)
#  7. 상승엣지 감지로 오디오 훅(부상/속도단계/off-seam 진입) (§7)
#  * "주행 중" 판정: player.position 변화량으로 추론(RaceDirector 상태 미조회 → 물리 루프 불변)
```

`ViewportTexture`는 씬 직렬화 시 경로 취약 → **코드에서 `get_texture()`로 연결**. SubViewport `render_target_update_mode=ALWAYS` 필수(아니면 갱신 안 됨).

---

## 3. 스티치 트레일

### 3.1 데이터 모델 (링버퍼 + 호길이 샘플링)

- 플레이어 **실제 궤적**(중심선 아님) 기록. 경로 이탈 시 스티치가 보라 밴드 밖으로 흔들려 정확도 피드백.
- 샘플 조건: 마지막 스티치 이후 **`STITCH_SPACING`(예: 10px) 이상 이동** 시 현재 `player.position` 한 점 기록. 이동량은 직전 기록 위치와의 거리 누적 → **프레임레이트 독립 간격**.
- 저장: `PackedVector2Array` 링버퍼, 상한 `MAX_STITCHES`(예: 96 → 96×10px=960px 궤적, 96×8B≈0.75KB). 초과 시 가장 오래된 것부터 폐기.
- **물리 루프와 무결합**: `PresentationController._process`가 `player.position`만 읽어 갱신. 시뮬 결정론 불변. 순수 시각.

```gdscript
# StitchTrail.gd (Node2D, SubViewport 안 = 월드 공간)
const STITCH_SPACING := 10.0
const MAX_STITCHES := 96
var _points: PackedVector2Array
var _last: Vector2
func push_if_moved(pos: Vector2) -> void:
    if _points.is_empty() or _last.distance_to(pos) >= STITCH_SPACING:
        _points.append(pos)
        if _points.size() > MAX_STITCHES:
            _points.remove_at(0)
        _last = pos
        queue_redraw()
```

### 3.2 렌더

- `StitchTrail`은 SubViewport 안 월드 공간 노드 → Mode 7 셰이더가 **자동 원근화**(전진할수록 스티치가 근경=화면 하단으로 흘러감).
- 각 스티치 = 진행 접선에 수직인 짧은 빨간 선분(길이≈6px) 또는 점. `_draw`에서 인접 두 점 방향으로 접선 구해 수직 대시.
- 색: 빨강 `Color(0.85, 0.15, 0.15)`. 리셋(재시작) 시 `_points` 비움. 씬 리로드로 자동 초기화되므로 별도 처리 불필요.
- 메모리 상한: `MAX_STITCHES` 고정. 가시 범위(노루발 뒤 ~40~60px)만 실제 표시되나 여유 둬 트레일 자연 연결.

---

## 4. HUD 재배치 스펙

스크린샷 관찰 구성 반영. 좌표는 1280×720 기준 예시(앵커).

### 4.1 미니맵 (좌상단, 리스타일)

- 위치 유지(offset 16,16 ~ 196,196), 필요 시 확대(예: 200×200).
- 스타일: `BG_COLOR`를 베이지(`Color(0.90,0.85,0.72,0.92)`), 테두리를 스티치풍 대시(짧은 선분 반복)로 교체.
- **지나온 궤적 점선 추가**: 현재 윈도 `[progress_s-back, progress_s+preview]`를 둘로 분리. `[progress_s-back, progress_s]`는 회색 대시(지나온 길), `[progress_s, progress_s+preview]`는 보라 실선(앞으로 갈 길). `_window_polyline`을 s 기준으로 나눠 두 번 그림.
- 플레이어=노란 화살표(기존 `ARROW_COLOR` 유지), 진행 방향 위(-Y) 정합(기존 회전식 유지). 급커브/피니시 마커 유지.
- 로직 골격(윈도·회전·스케일) 그대로. `_draw` 스타일·궤적 분리만 추가.

### 4.2 진행도 바 (신규, 미니맵 아래)

- 신규 위젯 `ProgressBar.gd`(Control 커스텀 `_draw`). 미니맵 바로 아래(offset_top≈204, 높이 24).
- 표시: 파란 실 느낌 트랙 바 + **바늘 아이콘 마커**가 `s/length` 위치. `fill = clampf(progress_s / track.length, 0, 1)`.
- `HUD.setup(track)`에서 `track.length` 보관 → `HUD.update_frame(..., progress_s, ...)`에서 `_progress.set_progress(progress_s / _length)`. RaceDirector는 이미 `progress_s` 전달 → **물리 변경 없음**.
- 색: 바 `Color(0.30,0.55,0.95)`, 바늘 아이콘 은색 삼각/핀.

### 4.3 TIME (우상단, SS.cc 형식)

- 인게임 `"88.24"`(초.센티초). `Stopwatch`에 표시 메서드 추가:
  ```gdscript
  # 인게임 HUD 전용. 결과 화면은 이 메서드를 쓰지 않는다.
  static func format_race_time(seconds: float) -> String:
      var cs := int(round(maxf(seconds, 0.0) * 100.0))   # 센티초
      return "%d.%02d" % [cs / 100, cs % 100]            # 88.24
  ```
- **기존 `format_time`(MM:SS.mmm) 보존**. 결과 화면은 `ResultScreen._format_ms`(별도, MM:SS.mmm) 사용하므로 이 변경과 무관(확인 완료). `HUD.update_frame`의 `_stopwatch.set_time` 내부를 `format_race_time` 호출로 교체.
- 우상단 패널(스티치 테두리) 안 표시. 앵커 우상단 유지.

### 4.4 속도 게이지 (우하단, 세로 쉐브론 5단)

- `SpeedGauge._draw` 재작성: **세로로 쌓인 쉐브론 5개**, **아래부터** `speed_index`개 채움.
- 색 그라데이션(채운 단계): 1~2단 초록(`0.35,0.75,0.45`), 3단 노랑(`0.95,0.85,0.25`), 4단 주황(`0.95,0.65,0.25`), 5단 빨강(`0.95,0.30,0.30`). 미충전 단계는 어두운 회색. 4~5단 점멸 유지(`_process` 블링크 로직 재사용).
- 위치: 우하단 세로 스택(예: anchor 우하단, offset_left≈-80, 높이≈180).
- 키 힌트: 게이지 위 "W/↑ 속도 상승", 아래 "S/↓ 속도 다운" 소형 라벨.
- 오디오 훅: `set_stage`에서 단계 변경 감지 시 `AudioManager.on_speed_stage(stage)`(§7).

### 4.5 리스크 미터 (노루발 근처)

- 스크린샷엔 없으나 기획서 §7.5/§8.1 "바늘 주변 또는 하단". **노루발 아래 중앙**(v_needle 바로 아래, 손 위)에 컴팩트 세로 바(손가락 부상 경고가 손·바늘과 시각적 연결).
- 로직(`set_risk`, 0.50/0.70/0.85/0.95 색·점멸) 그대로. 위치·형태만 세로로. 대안: `risk<0.5`면 숨기고 임계 초과 시 노루발 주변 붉은 글로우로 대체(연출 강화, 선택).

### 4.6 조작 힌트 / 상태 라벨

- "←/→ 방향 전환": 우하단 구석 소형 라벨(속도 힌트와 구분).
- `StatusLabel`(Off-Seam / FINGER CUT!): 노루발 **아래**로 이동해 액션과 함께 읽히게. 로직(`HUD._update_status`) 유지.

### 4.7 HUD 앵커 요약

| 위젯 | 앵커/위치 |
|---|---|
| MiniMap | 좌상단 (16,16)~(216,216) |
| ProgressBar | 미니맵 아래 (16,224)~(216,248) |
| Stopwatch(TIME) | 우상단 패널 |
| SpeedGauge | 우하단 세로 스택 |
| SpeedHint(상/하) | 게이지 상·하단 |
| SteerHint | 우하단 구석 |
| RiskMeter | 노루발 아래 중앙 |
| StatusLabel | 노루발 아래 |
| Countdown | 노루발 위(§5) |

### 4.8 재봉 스킨 통일 (2차 UI 아트)

HUD·화면 UI를 장면 아트(§14)와 같은 따뜻한 수공예 무드로 통일. 신규 이미지 에셋 없이 공용 드로잉 유틸 `scripts/ui/SewingSkin.gd`(팔레트 + 패치 패널·러닝 스티치 테두리·모서리 단추 정적 헬퍼)로 각 위젯 `_draw` 재도색(단순 패널은 `_draw`로 충분, SVG→PNG 파이프라인 불요).

- 팔레트: 베이지 원단 패널 + 실 보라 러닝 스티치 테두리, 포인트로 실 빨강. 짙은 갈색 잉크 글자.
- TIME(우상단)·속도 게이지(우하단)·일시정지·결과 패널: `SewingSkin` 배경 패치 노드 위에 라벨/게이지.
- 미니맵: 베이지 패치 + 둥근 러닝 스티치 테두리 + 모서리 단추. 궤적/윈도/보간 로직 불변.
- 진행도 바: 어두운 네이비 → 웜톤 원단 홈 + "빨간 실 박음질" 채움 + 은색 바늘 마커.
- 리스크 미터: 노루발·양손 중앙 겹침 해소 위해 **좌하단 패치 게이지로 재배치**. `set_risk`·임계(0.5/0.7/0.85/0.95) 색·점멸 로직 불변, 경고 시 테두리·라벨이 위험 색으로 점멸.
- 카운트다운/상태 라벨: 큰 숫자 외곽선·그림자(§14 아트 무드), 상태 라벨 외곽선으로 가독성.
- 완주 줌아웃(`FinishView`): 텍스트·색만 웜톤 크림. 줌아웃 로직·투영·타이밍 불변.

기능·값·판정·위젯 API(`set_stage`/`set_risk`/`set_progress`/`update_frame`)·RaceDirector/HUD 배선 불변. 검증: gdlint 클린 + 비-headless 캡처(주행/경고/일시정지/줌아웃/결과) + 헤드리스 E2E(cotton·heart, FINISH_VIEW 유예·스킵 회귀 포함) 에러 0.

### 4.9 사용자 제공 시트 스킨 (3차 UI 아트)

절차적 `SewingSkin`을 폴백으로 남긴 채, 사용자 제공 재봉 UI 시트를 도입해 위젯을 실제 텍스처로 교체. 시트는 요소별로 분해해 `assets/gfx/ui/`에 개별 PNG로 저장(대형/소형 필 버튼·정사각 버튼 바탕, 베이지·다크 패널, 태그 라벨, 쉐브론, 진행 홈, 바늘 마커, 하단 아이콘 8종), 원본 시트는 `assets/gfx/src/ui_sheet_v1.png`(`.gdignore`)로 이동.

- 로더 `scripts/ui/UiSkin.gd`: 9패치 `StyleBoxTexture`(버튼, 캡의 단추/둥근 끝 보존 마진 실측), `NinePatchRect`(패널, 모서리 실패·핀쿠션·패치 장식 보존 마진 실측), `TextureRect`(TIME 태그)로 배선. 텍스처 미로드 시 모든 팩토리가 조용히 `SewingSkin` 절차 스킨으로 폴백.
- 적용: 메인·맵 선택·설정·결과·일시정지의 필/아이콘 버튼과 카드 패널(베이지), 리더보드는 다크 패널을 목록 배경으로 깔고 텍스트를 밝은 크림으로 전환(가독성). HUD는 TIME=태그 라벨, 속도 게이지=쉐브론(상태별 modulate 틴트), 진행 바=원단 홈+은색 바늘 마커. 아이콘은 의미별 매핑(Play/◀▶/바늘/다운로드/휴지통/톱니/트로피).
- 절차 유지(판단): 미니맵·리스크 미터(장식이 게이지/궤적 가독성 해침), 트랙 미리보기(작은 실루엣을 다크 패널 장식이 가림), 에디터 툴바(좁은 텍스트 버튼은 필 버튼 양끝 캡이 글자를 밀어냄).
- 기능·레이아웃·판정·위젯 API·RaceDirector/HUD 배선 불변. 검증: gdlint 클린, 사본 `--import` 에러 0, 비-headless 캡처(메인·맵 선택·설정·리더보드·주행 HUD·결과·일시정지), 헤드리스 네비 E2E(메인→맵 선택→주행 완주→Result→복귀) 에러 0.

**결함 수정(대형 필 버튼 캡)**: 초기 배경 분리에서 `btn_large_normal`/`btn_large_pressed`의 오른쪽 캡(단추+둥근 끝)이 크롭에 잘려 9패치 우측 마진이 뭉개진 단추 렌더. 필 버튼은 좌우 대칭 → 깨끗한 왼쪽 절반을 수평 미러링해 오른쪽 캡 복원 + 알파 페더 halo 초크(부분 알파 13%→8%). 텍스처 크기·9패치 마진·배선 불변(에셋 재베이크만).

**재베이크 v2(사용자 신규 시트 6종 교체)**: 대형/소형 필 버튼·정사각 버튼·베이지/다크 패널을 새 원본으로 교체.
- 원본 여백 큼(대형 2172×724 중 실요소 2059×423, 베이지 1254×1254 중 1193×977) → 알파 bbox 트림 후 프리멀티플라이 알파 LANCZOS 다운스케일 재샘플.
- 9패치 코너는 텍스처 px가 화면 px로 1:1 렌더(경험 검증) → 캡 둥근 단추가 세로로 안 찌그러지게 버튼 텍스처 높이를 화면 높이에 맞춤. 크기: 버튼 273×56·190×48·정사각 98×96, 패널 베이지 573×469·다크 757×440.
- 9패치 마진 재실측: large 36/36/7/7, small 34/34/7/7, square 13, panel_beige 140/138/140/136, panel_dark 156/140/130/170(l/r/t/b).
- 러닝 스티치·모서리 장식이 세로로 긴 패널(Result·Leaderboard)에서 늘어져 번지지 않도록 패널 `NinePatchRect`·버튼 `StyleBoxTexture`에 `TILE_FIT` 축 스트레치 적용(원단 필 균일·그라디언트 없음 → 타일 이음매 안 보임).
- 알파 페더 halo는 엣지 국소 초크(a<9% → 0, a≥25% 불변)로 제거, 다크 패널 내부 불투명도(≈0.99) 보존.
- 버튼 텍스트 좌우 여백은 새 캡 폭에 맞춘 하한(large 26·small 25·square 8px)으로 글자가 단추 안 덮게.
- 텍스처·9패치·content margin·`TILE_FIT` 외 기능·배선 불변. 검증: gdlint 클린, 사본 `--import` 0, 헤드리스 네비 E2E(메인→맵선택→설정→리더보드→완주→Result→맵선택) OK, 6화면 비-headless 캡처 전/후 대조(캡 대칭·선명, 페더 halo 소멸, 세로 패널 무번짐).

**결함 수정(맵 선택 ◀▶ 나브 버튼)**: 트랙 변경 화살표에서 정사각 단추 바탕(`btn_square_blank` StyleBox) 제거, 화살표 아이콘만 유지. `UiSkin.skin_icon_nav`가 배경 StyleBox 4상태를 `StyleBoxEmpty`로 덮어 투명 히트 영역(48×48)만 유지, hover=빨강·pressed=짙은 잉크로 아이콘 modulate 틴트만 피드백. `focus_mode=0`(순환 제외)은 씬 그대로.

**결함 수정(HUD TIME 태그 / 속도 게이지), 위젯별 결정**: 초기 추출본 오염(태그=우측 보라 리본 조각+회색 그림자, 쉐브론=드롭섀도 베이크로 틴트 탁화)을 사용자가 지적. `UiSkin`에 위젯별 토글(`SKIN_TIME_TAG`/`SKIN_SPEED_CHEVRON`)을 둬 위젯 단위로 시트 스킨↔절차 폴백 전환.
- **TIME 태그 = 재추출 성공(텍스처 유지)**: 소스 시트에서 태그 몸통+빨간 리본만 타이트 재크롭(x[34..418]·상단 버튼 잔재 제외, 우측 보라 리본 x≥418 제외). faint alpha 초크로 그림자 halo 제거 → `tag_label.png`(379×149). 확대 크롭에서 리본 조각·그림자 소멸 확인.
- **속도 게이지 = 절차 원복(`SKIN_SPEED_CHEVRON=false`)**: 쉐브론을 무채색 정규화+드롭섀도 제거로 재추출하니 1~3단은 깨끗해졌으나, 4~5단 점멸(`base*blink`, 저점 0.2배)에서 채워진 직물 쉐브론이 거의 검은 덩어리로 뭉개져 "탁한 덩어리" 증상이 위상 의존으로 재현(점멸은 텍스처·절차 공통 로직). 절차 폴리라인 쉐브론은 점멸 저점에서도 가느다란 유채색 선으로 읽혀 사용자 명시 허용 원복 방향·스펙(§4.4·§8.2)에 부합 → 게이지만 절차 원복(재추출본 `chevron.png`는 정리 상태로 보존, 토글 시 즉시 재사용 가능).
- 검증: gdlint/gdformat 클린, 사본 `--import` 에러 0, 헤드리스 네비 E2E(cotton) OK, 비-headless 주행 캡처(HUD 전경+TIME·게이지 확대 크롭 전/후), 맵 선택 화살표 캡처. 격리(사본 `config/name` 변경, `user://` 분리)로 실제 userdata 미접촉.

### 4.10 닉네임·서버 연결 UX 개편 (배포 직전)

서버 URL 입력을 유저에게 노출하지 않고 닉네임 확정·온라인 상태·순위 피드백을 화면 흐름에 녹임. 시뮬레이션·판정·물리 루프 불변, `game/scripts/ui/` + `LeaderboardClient.gd`만 수정.

- **서버 URL UI 제거**: 데스크톱 기본 `base_url`=프로덕션(`https://overlock.bnbong.com`), 디버그 데스크톱=`http://localhost:8000`(`OS.is_debug_build() and not web`). 웹은 디버그 여부 무관하게 프로덕션 기본 사용 → `_resolve_base_url`의 same-origin 대체를 그대로 탐(웹 로직 불변). 셀프호스팅/개발은 `user://settings.json`에 `base_url` **수동** 기입 시 우선. 과거 프리필 기본값(localhost/프로덕션)·빈 값은 "수동 아님"으로 보고 코드 기본값 사용 → 기본 서버 변경 자동 반영 + 기존 사용자 파일 호환. `SettingsScreen`은 닉네임 관리로 단순화.
- **최초 실행 닉네임 모달**(`NicknameDialog`, 재봉 스킨): 닉네임 미설정 메인 진입 시 표시. 추천 닉네임(`Stitcher-####`, UI 전용 `randi`) 프리필, 확인/Enter/Esc 모두 확정. 빈 입력·규칙 위반이면 프리필로 확정해 **항상 닉네임 존재** 보장(1~16자). 타이틀 태그 클릭에서 재사용.
- **메인 정체성 바**(좌상단): 현재 닉네임 태그 + 온라인/오프라인 상태 점. 진입 시 백그라운드 `health_check`로 점 갱신, 미연결이면 **세션당 1회** 안내 토스트(메뉴 재방문 반복 없음).
- **리더보드**: 내 닉네임 일치 행을 금색 하이라이트(배경 틴트+테두리, top3 색 강조와 구분). 하단 고정 "내 기록" 행에 RecordStore 로컬 최고 + 마지막 제출 시 서버 rank(캐시) 표기. rank는 "제출 시점 순위"라 `(제출 시점)` 단서 부착, 기록 없으면 "아직 기록 없음". 페이지에 내 행 없어도 하단 행으로 확인. rank 캐시는 `settings.json`의 `submitted_ranks`("track|difficulty" → rank)에 영속(하위 호환: 키 없으면 빈 dict).
- **토스트**(`Toast`, 재봉 스킨, 하단 중앙, 수 초 자동 소멸, 큐잉): 오프라인 안내·제출 성공/실패 공용. 최상위 CanvasLayer라 입력 통과, 순수 표현.
- **오프라인 게이팅**: `health_known && !server_reachable`이면 Result 제출 버튼 숨김(health 미확인 전이면 낙관적 허용, 제출 실패는 조용히 + 토스트). Leaderboard 버튼은 유지(열면 기존 에러 상태).
- 신규: `Toast.gd`/`Toast.tscn`, `NicknameDialog.gd`/`NicknameDialog.tscn`. 검증: gdlint/gdformat 클린, 사본 `--import` 0, 목 서버 E2E 16/16(닉네임 자동 확정·제출 `player_name` 정합·rank 캐시·내 행 하이라이트·내 기록 행·오프라인 버튼 숨김·무크래시), 5화면 비-headless 캡처, 헤드리스 네비 E2E(메인→맵선택→주행→Result→복귀) 에러 0, `user://` 격리로 실제 userdata 미접촉.

---

## 5. 카운트다운

- 기존 전체 화면 중앙 → **노루발 위치 기준** 이동. `Countdown`(Label)을 `ForegroundLayer` 아래 두고 노루발(v_needle≈0.60) **바로 위**(예: v≈0.42~0.50, 화면 중앙 가로)에 크게(폰트 96~120) 배치.
- `Countdown.gd` 로직 불변(`show_number`/`show_go`/자동 숨김). 씬 노드 위치·앵커만 변경.
- 오디오 훅: `show_number`에서 `AudioManager.play_countdown_beep(value)`, `show_go`에서 `play_go()`(§7).

---

## 6. 검증 하네스 (비-headless 창 + 스크립트 스크린샷)

**스크래치패드 사본에서만 실행.** 실제 `game/project.godot` 수정 금지 → 사본 project.godot에만 `CaptureBot` 오토로드 추가.

### 6.1 절차

1. `game/`를 스크래치패드로 복사.
2. 사본 `project.godot`에 오토로드 추가:  `CaptureBot="*res://scripts/dev/CaptureBot.gd"`.
3. Godot 4.6.1을 **비-headless**로 실행(실제 창 렌더 → 뷰포트 텍스처 유효):
   `/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot --path <copy>/game -- --capture`
4. `CaptureBot`이 `--capture` 플래그 감지 시 자동 주행·캡처·종료.

### 6.2 CaptureBot.gd (사본 전용)

```gdscript
extends Node
# 사본 전용 캡처 봇. 실제 게임 로직/씬은 건드리지 않는다.
func _ready() -> void:
    if not "--capture" in OS.get_cmdline_user_args():
        return
    await get_tree().process_frame
    GameState.track_id = "cotton_01"
    GameState.difficulty = "normal"
    get_tree().change_scene_to_file("res://scenes/Gameplay.tscn")
    _run()

func _run() -> void:
    await _shoot(1.5, "01_countdown")     # 카운트다운("2") 표시 구간
    _press("speed_up"); _press("speed_up")# 속도 올려 커브 조기 도달 + 게이지 확인
    await _shoot(3.0, "02_straight")      # GO 직후 직선 주행
    await _shoot(6.0, "03_curve")         # 첫 커브 구간
    get_tree().quit()

func _shoot(wait_s: float, name: String) -> void:
    await get_tree().create_timer(wait_s).timeout
    await RenderingServer.frame_post_draw   # 프레임 완성 후 캡처
    var img := get_viewport().get_texture().get_image()
    img.save_png("user://%s.png" % name)    # user:// → globalize 경로 출력
    print("[cap] ", ProjectSettings.globalize_path("user://%s.png" % name))

func _press(action: String) -> void:       # 이산 입력 주입
    var ev := InputEventAction.new(); ev.action = action; ev.pressed = true
    Input.parse_input_event(ev)
```

- 안전 타임아웃: 별도 `create_timer(15.0)`에 `get_tree().quit` 연결(무한 실행 방지).
- 각 캡처 전 `await RenderingServer.frame_post_draw`로 SubViewport 워프까지 합성된 최종 프레임 포착.
- 커브 캡처 시각은 속도/트랙에 따라 조정. cotton_01은 첫 세그먼트(0~352px) 직선, 이후 커브 → 속도 3~4단이면 GO 후 ~3~4s에 커브 진입.
- 저장 경로 확인: 실행 로그의 `[cap]` globalize 경로에서 PNG 수거. 래퍼 스크립트가 `user://`(사본 기준 `~/Library/Application Support/Godot/app_userdata/Overlock/`)에서 스크래치패드로 복사.

### 6.3 래퍼 셸(스케치)

```bash
COPY=<scratchpad>/overlock_copy
rsync -a --delete <repo>/game/ "$COPY/game/"
mkdir -p "$COPY/game/scripts/dev"
# CaptureBot.gd 배치 + 사본 project.godot에 오토로드 라인 추가(사본만)
/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot --path "$COPY/game" -- --capture
# user:// 에서 01_countdown.png / 02_straight.png / 03_curve.png 수거
```

---

## 7. 오디오 연결 지점 (설계만, 구현은 별도 워커)

**원칙**: 훅을 UI/프레젠테이션 계층(Countdown / SpeedGauge / HUD / PresentationController / ResultScreen)에 심어 **물리 루프(RaceDirector)와 완전 분리**. `AudioManager`는 후속에 오토로드로 추가(그때 `project.godot` 수정). 현 재설계 코드에 `AudioManager` 없을 수 있으므로 호출부는 `if Engine.has_singleton(...) / AudioManager != null` 가드 또는 나중에 삽입.

### 7.1 AudioManager API 표면

```gdscript
extends Node   # autoload "AudioManager"
func play_bgm(loop_id: String) -> void
func stop_bgm() -> void
func play_countdown_beep(n: int) -> void      # 3,2,1
func play_go() -> void
func on_speed_stage(stage: int) -> void        # 단계 변경 시 틱/휘프
func set_machine_rate(speed_norm: float) -> void  # 재봉틀 틱 루프 피치/템포(0..1)
func play_injury() -> void                     # 손가락 부상
func on_band_enter(band: int) -> void          # Off-Seam 진입 등
func play_finish() -> void
func set_master_volume/set_bgm_volume/set_sfx_volume(linear: float) -> void  # 0..1→버스 dB(0=뮤트), get_*/preview_sfx 카운터파트 — SettingsScreen 슬라이더가 구동, LeaderboardClient가 settings.json 영속
```

### 7.2 훅 위치 표

| 이벤트 | 훅 지점(계층) | 호출 |
|---|---|---|
| BGM 루프 | `RaceDirector._ready` 또는 `HUD.setup` (UI 진입) | `play_bgm("gameplay")` |
| 카운트다운 비프 | `Countdown.show_number` | `play_countdown_beep(value)` |
| GO | `Countdown.show_go` | `play_go()` |
| 속도 단계 변경 | `SpeedGauge.set_stage`(변경 감지 지점) | `on_speed_stage(stage)` |
| 속도 비례 재봉틀 틱 루프 | `PresentationController._process` | `set_machine_rate(player.speed / Tuning.max_speed)` (주행 중만) |
| 손가락 부상 | `PresentationController` (player.stun_timer 상승엣지) | `play_injury()` |
| Off-Seam 진입 | `HUD._update_status` / `PresentationController` (band 전이) | `on_band_enter(band)` |
| 피니시 | `ResultScreen._ready` (씬 전환 후) | `play_finish()` |

부상·off-seam은 상승엣지(직전 상태 저장 후 전이 감지)로 1회만 트리거. 재봉틀 틱 루프는 매 프레임 rate만 갱신(재생 자체는 루프). **어느 훅도 RaceDirector 물리 루프를 수정하지 않음.**

---

## 8. 구현 순서 권장

1. 씬 재구성: World를 SubViewport로 이동 + RaceDirector NodePath 3줄 갱신 + 레이어 스택 골격. (탑다운 소스가 SubViewport에서 정상 렌더되는지부터 확인)
2. `fabric_mode7.gdshader` + `FabricWarp` + `PresentationController`(heading uniform, ViewportTexture 연결). 하네스로 워프·노루발 정합(v_needle) 튜닝.
3. `FabricSurface`(원단 base) + `NeedleView`(v_needle 정렬) + `BackgroundFace` + `HandView` 플레이스홀더.
4. `StitchTrail`(링버퍼 + 월드 `_draw`).
5. HUD 재배치: MiniMap 리스타일, ProgressBar 신규, TIME 포맷, SpeedGauge 세로 쉐브론, RiskMeter/힌트/Countdown 재배치.
6. 오디오 훅 자리만 삽입(AudioManager 도입은 별도).
7. 하네스 3장 캡처로 회귀 확인.

---

## 9. 함정 (구현 워커 주의)

1. **ViewportTexture는 코드로 연결**: 씬 직렬화 대신 `PresentationController._ready`에서 `warp_mat.set_shader_parameter("source_tex", subviewport.get_texture())`. SubViewport `render_target_update_mode=ALWAYS` 아니면 갱신 안 됨. 검게 나오면 (a) 카메라 `enabled`, (b) update mode, (c) 텍스처 연결 순으로 점검.
2. **Camera2D 스무딩 OFF**: 워프는 플레이어를 정확히 소스 중심에 요구. 스무딩 남으면 밴드가 중심에서 미끄러짐.
3. **in-world NeedleVisual 숨김**: `visible=false`. 안 그러면 회전하는 바늘이 원단 안에 중복 그려짐.
4. **좌우 부호 검증**: 셰이더 `rgt` 부호 틀리면 조향 좌/우가 화면에서 뒤집힘. 하네스 스크린샷(오른쪽 조향 시 밴드가 오른쪽으로)으로 1줄 확인.
5. **노루발 행 정합**: 스크린 노루발 오버레이 y는 `v_needle = horizon + depth_scale/cam_back`과 **같은 상수에서 유도**. 상수를 두 곳에 하드코딩해 어긋나면 바늘이 재봉선 위에서 뜸(상수를 공유 소스/uniform로).
6. **수평선 경계·OOB 가드**: `UV.y<=horizon` discard로 0-나눗셈 회피, `src_uv` 커버리지 밖은 원단색 폴백. 소스 샘플러 `repeat_disable`(텍스처 랩으로 반대편 원단 새는 것 방지).
7. **커버리지 vs 해상도**: 커버리지 작으면 전방 밴드 잘림, 크면 밴드 픽셀화. `coverage≈600 @ 512²`에서 perfect(18px) 밴드 읽히는지 확인 후 조정.
8. **스티치는 호길이 샘플링**: 프레임당이 아니라 이동거리 기준. 링버퍼 상한으로 메모리 고정. `player.position`만 읽어 시뮬 결정론 불변.
9. **translate-only에서 카메라 회전 금지**: heading 회전은 셰이더 전담. 카메라도 회전시키면 이중 회전.
10. **TIME 포맷 분리**: 인게임 SS.cc는 새 메서드로. 결과 화면 MM:SS.mmm(`ResultScreen._format_ms`)는 별개라 영향 없음. 기존 `Stopwatch.format_time`을 지우지 말 것.
11. **project.godot 불변**: 실제 리포 수정 금지. 캡처 오토로드·오디오 오토로드는 각각 사본/후속 작업에서만 추가.
12. **MSAA/앨리어싱**: SubViewport `msaa_2d=2x`, 워프 샘플러는 `filter_linear`(구현 확정). GL Compatibility의 SubViewport 텍스처는 밉맵 체인 미생성 → `filter_linear_mipmap`을 걸어도 밉맵 없어 효과 없고 오히려 수평선 근처 페이드 과다 흐림 → `filter_linear` 명시. 2px 중심선은 원경에서 시머 → 수평선 근처 페이드(`smoothstep`)로 완화하거나 원경에서 생략.
13. **얼굴/손/노루발은 이미지 교체 가능 구조로**: 각 플레이스홀더 스크립트에 `@export var texture: Texture2D`를 두고, null이면 `_draw` 도형, 있으면 스프라이트로 렌더하는 분기.
14. **캡처는 비-headless**: `--headless`면 뷰포트 텍스처 무효. 반드시 실제 창으로 실행하고 `frame_post_draw` 후 캡처.

---

## 10. 파일 목록

### 변경
- `game/scenes/Gameplay.tscn` — 레이어 스택 재구성(World→SubViewport, Backdrop/Fabric/Foreground/Presenter 추가, HUD 위젯 재배치)
- `game/scripts/systems/RaceDirector.gd` — `@onready` NodePath 3줄만(로직 불변)
- `game/scripts/ui/HUD.gd` — ProgressBar 참조·호출, `track.length` 활용, 오디오 훅 호출
- `game/scripts/ui/MiniMap.gd` — 베이지 패널·스티치 테두리·지나온 궤적 점선
- `game/scripts/ui/SpeedGauge.gd` — `_draw` 세로 쉐브론 재작성
- `game/scripts/ui/Stopwatch.gd` — 인게임 `format_race_time`(SS.cc) 추가(기존 보존)
- `game/scripts/ui/RiskMeter.gd` — 재배치/세로 스타일(로직 불변)
- `game/scripts/ui/Countdown.gd` — 오디오 훅만(로직 불변, 위치는 씬에서)

### 신규
- `game/shaders/fabric_mode7.gdshader` — Mode 7 바닥 원근 셰이더
- `game/scripts/presentation/PresentationController.gd` — 프레젠테이션 구동(uniform/스티치/애니/셰이크/오디오 상승엣지)
- `game/scripts/presentation/FabricSurface.gd` — 황록 원단 base(월드, draw-once)
- `game/scripts/presentation/StitchTrail.gd` — 빨간 스티치 링버퍼(월드 `_draw`)
- `game/scripts/presentation/BackgroundFace.gd` — 얼굴 플레이스홀더(이미지 교체 가능)
- `game/scripts/presentation/NeedleView.gd` — 노루발+바늘 스크린 오버레이(바늘 왕복)
- `game/scripts/presentation/HandView.gd` — 손 플레이스홀더 ×2(이미지 교체 가능)
- `game/scripts/ui/ProgressBar.gd` — 진행도 바(s/length + 바늘 아이콘)
- `game/scripts/autoload/AudioManager.gd` — **설계만**(후속 워커가 구현 + `project.godot` 오토로드 등록)

### 하네스 (스크래치패드 사본 전용, 리포에 커밋 안 함)
- `<copy>/game/scripts/dev/CaptureBot.gd` — 자동 주행·캡처·종료
- 래퍼 셸 스크립트(rsync + Godot 실행 + PNG 수거)

---

## 11. 확장 지점(열어둠)

| 확장 | 진입 지점 |
|---|---|
| 실제 원단 위브 텍스처 | `FabricSurface`를 월드 타일 스프라이트로 교체(스크롤 자동) |
| 얼굴/손/노루발 아트 | 각 플레이스홀더 `@export texture` 분기에 이미지 주입 |
| heading-up 근경 고해상 | translate-only → 회전 카메라 + 순수 세로 워프로 스왑(§1.3 폴백) |
| 속도별 화면 진동·비네트 | `PresentationController`의 셰이크/후처리 계수 |
| 원단 물성(modifiers) 연출 | `s` 구간 진입 시 셰이더 색/왜곡 파라미터 변조(판정과 분리 유지) |

---

## 12. 표현 연출 보강 (참고작 §5.1 구도 대조 갱신)

참고작('용과 같이' 재봉 미니게임) 스크린샷과 대조해 프레젠테이션 구도 갱신. 시뮬레이션(player)은 읽기만, 값·구조 불변.

### 12.1 손 구도 (`HandView.gd`)

- 기존 1인칭(화면 하단→손끝 위로) 폐기. 캐릭터 얼굴이 지평선 위에서 카메라를 마주보므로, **손은 화면 좌우측에서 뻗어 나와 손등이 위를, 손끝(손톱)이 재봉선 쪽(화면 중앙~하단)을 향함.** `_draw`는 바깥(가장자리)에서 들어오는 팔뚝 → 손등 → 재봉선 쪽으로 굽은 손가락 4개 + 엄지 순으로 구성, 각 손끝에 손톱(밝은 색) 얹음. `mirror`로 좌우 반전.
- 노루발과 간격 좁힘(씬: LeftHand `(460,445)` / RightHand `(820,445)`, 노루발 `(640,432)`). 손끝이 노루발 좌우로 근접해 "바늘 옆 손가락" 위험 서사 읽힘.

### 12.2 조향 연출 (`actual_steer` 구동, 뷰에서 추가 보간)

`PresentationController`가 매 프레임 `player.actual_steer`(-1..1, 음수=좌)를 각 뷰에 주입, 뷰는 프레임 독립적 지수 감쇠로 보간(과한 튐 방지).

- **얼굴 고개 꺾기 (`BackgroundFace.set_steer`)**: 하단 피벗 기준 회전(±`MAX_HEAD_TILT`≈0.11rad) + 수평 이동(±`HEAD_LEAN_PX`). 조향 방향으로 고개 기움.
- **손 누름 강조 (`HandView.set_steer`)**: 조향 방향의 손이 `press>0` → 아래(`PRESS_DOWN`)·안쪽(`PRESS_INWARD`) 이동 + 확대(`PRESS_SCALE`), 반대 손은 `press<0` → 이완(축소·후퇴).

### 12.3 속도 비례 집중 표정 (`BackgroundFace.set_expression`)

`speed_index`(1..5)를 `focus=(idx-1)/4`로 환산 → 단계 오를수록 눈썹 안쪽 내려오고 눈 가늘어짐(5단에서 집중 최대). 표정 우선순위: **부상(X자 눈) > 고위험(risk) > 속도별 집중 > 평상**. risk와 속도 집중은 같은 '집중' 축이라 `max(risk, focus)`로 통합(더 큰 값 우선).

### 12.4 인게임 구도 결함 3건 수정 + 표정 텍스처 스왑 구조 (참고작 재대조)

실플레이 스크린샷을 참고작과 재대조해 세 구도 결함 수정 + 상태별 얼굴 텍스처 교체 적용. 시뮬레이션(player)은 읽기만, 값·구조 불변.

1. **손 재구성(`HandView` 배치 + 방향)**: 화면 중앙에 작게 떠 노루발을 양쪽에서 집던 손을, 좌우 가장자리에서 크게 들어오는 참고작 구도로 변경. 캐릭터가 화면 건너편에서 앞으로 뻗은 손이라 **손목·소매가 위·바깥(캐릭터 몸 쪽)으로 빠져 화면 밖 잘리고 손끝·손톱이 아래·안쪽(카메라 쪽 재봉선)을 향함**. 씬 배치: 스케일 1.2배 + 앵커를 하단 좌우 사분면(LeftHand `(175,276)` `mirror=true` / RightHand `(1105,276)`)으로 낮춤. 두 손끝이 노루발 아래 재봉선 좌우 밴드 가장자리에 근접(그 틈으로 빨간 스티치 흐름)해 원단을 누름(참고작 대비 과대해 얼굴·트랙을 덮던 1.8배·`(98,237)`/`(1182,237)`에서 축소·하향 재조정). 기준 텍스처(`hand.png`)는 손목 우상단·손끝 좌하단의 우측 손, 좌측 손은 노드 `mirror=true`로 반전. 이전 가공에서 이 손을 ~150° 돌려 손끝이 위를 향해 1인칭처럼 뒤집혀 보이던 결함 수정, `HandView`의 `mirror`·누름 부호도 새 방향에 맞춰 조정(자기 쪽 조향에서 누름, 안쪽 이동 `-flip`). 누름·조향·속도 진동은 노드 트랜스폼이라 스케일 위에 그대로 보존.
2. **얼굴 배치(`BackgroundFace` draw rect)**: 720px 전체 높이로 그려 수평선이 눈을 잘라(헤어밴드·앞머리만) 보이던 문제를, 텍스처를 상단부 `face_rect`(스케일 0.72 + 세로 오프셋 -24px)에 그려 해소. 눈·코가 수평선 위에 온전. 표정 오버레이 앵커·고개꺾기 피벗도 `face_rect` 기준으로 유도해 정합 유지. 아트 재래스터화 없이 draw rect만 조정 → 품질 손실 없음.
3. **수평선-원단 이음새**: 수평선 상수 0.40→0.42로 소폭 내려 얼굴 스트립 넓히고, 셰이더 수평선 페이드 대역 좁힌 뒤(`horizon_fade` 0.028) 수평선 바로 아래에 테이블 모서리 트림(어두운 라인, `edge_darkness` 0.55 / `edge_width` 0.022) 얹어 원단이 '놓여 있는' 느낌으로 봉합. fade·OOB 폴백색(`FabricSurface.FABRIC_BASE`)을 각 타일 PNG 실제 평균색으로 맞춰 단색 띠 방지(cotton·silk 캡처 확인). `horizon`·`v_needle`·노루발 y는 `PresentationController` 단일 소스에서 유도(v_needle = 0.42 + 28/140 = 0.62 → 노루발 y ≈ 446px).

**눈 오버레이 스왑(현행 기본)**: `BackgroundFace`는 눈 없는 고정 베이스(`face_base_clean.png`) 위에 상태별 눈 오버레이(`eyes_normal`/`eyes_focus`/`eyes_injured`)를 얹음. 상태 전환 시 **눈 오버레이만** 0.2s 상보 알파 디졸브(옛 오버레이 α=1→0, 새 오버레이 α=0→1). 텍스처는 `Gameplay.tscn`이 아니라 `BackgroundFace.gd`의 **스크립트 preload 기본값**으로 배선(씬 미수정). 부상(stun)→injured, 집중 강도(속도·리스크 통합 `tension ≥ 0.5`)→focus, 그 외→normal 상태 결정 로직 불변. 베이스가 매 프레임 동일·불투명이라 전환 내내 머리카락·헤어밴드·볼 외곽 무진동(구 전체-얼굴 스왑의 윤곽 떨림 차단), 눈 오버레이가 투명 배경이라 눈 주변 밴드 경계 소멸. 눈은 앞머리 위에 그려지는 애니메이션 관례 구도. `eyes_offset_y`(세로 px)·`eyes_scale`(앵커 중점 `(640,248)` 기준 전체 배율) export로 PNG 재가공 없이 미세 조정(사용자 확정값 2026-08-22: `eyes_offset_y=50`·`eyes_scale=0.9`, 눈을 아래로 내리고 0.9배 축소한 취향 확정값, 임의 롤백 금지). 눈 파츠는 소스 시트에서 각 눈을 자기 동공 중심 기준으로 확대(동공 앵커 `(454,248)`/`(826,248)` 고정)해 레거시 `face_normal` 홍채 폭(측정 ~105px)과 같거나 약간 큰 크기(~112px, +6%)로 가공(구 가공 ~59px이 "눈이 너무 작다" 피드백 받아 재가공). 땀방울은 `sweat.png` 스프라이트로 집중 강도에 비례해 오른쪽 눈 바깥 관자놀이(눈 오버레이 rect 기준 `EYE_SWEAT_FRAC`)에 표시. 앵커가 눈 오버레이 rect 기준이라 `eyes_offset_y`·`eyes_scale` 변경 시 땀 위치·크기가 눈을 그대로 따라옴(구 독립 `expr_sweat_frac` 앵커는 절차 폴백 전용으로만 잔존).

새 얼굴 시트(`src/face_sheet_v2.png`) 분해·정규화 파이프라인, 눈 좌/우 판별 근거, 정규화 수치, 크로스페이드 계약: `assets/gfx/README.md` "눈 오버레이 스왑" 절 참고.

*레거시*: 구 전체-얼굴 텍스처 스왑(`face_normal`/`face_focus`/`face_injured`, 표정 시트 `src/expressions_sheet_v1.png`를 `face_base` 위에 합성)은 `Gameplay.tscn`이 uid로 참조 중이라 제자리 보존하되 오버레이 모드가 우선해 미사용. `base_clean`을 비우면 전체-얼굴 스왑으로, 그 슬롯마저 비우면 단일 `face_base` + 절차적 라인아트로 순차 복귀(회귀 금지 경로).

---

## 13. 완주 줌아웃 연출 (`FinishView.gd`)

트랙 윤곽선(서킷) 모양이 이 게임의 성취 요소. 완주 시 전체 서킷 + 내가 지나간 재봉 자국을 잠시 공개하는 보상 연출. 시뮬레이션(RunStats·RecordStore) 불변.

### 13.1 상태 흐름

- 피니시 순간 `RaceDirector._finish`는 **기록·통계를 지금처럼 즉시 확정**(`RunStats.finalize` → `RecordStore.submit` 타이밍 불변). **씬 전환만** 지연.
- 상태기계에 `FINISH_VIEW` 추가: `_finish`가 `State.FINISH_VIEW`로 전이, 결과를 `_pending_result`에 보관한 뒤 `FinishView.begin(track, trail, player_pos, result)` 호출.
- `_physics_process`의 `FINISH_VIEW` 분기는 자체 타이머(`FINISH_VIEW_DURATION≈3.5s`)만 돌리고, 경과 또는 스킵 입력 시 `GameState.to_result(_pending_result)`로 전환. 흐름: **피니시 → (즉시 finalize/submit) → FINISH_VIEW 줌아웃·홀드 → Result**.

### 13.2 오버레이 (스크린 공간 Control `_draw`)

- `Gameplay.tscn`에 `FinishViewLayer`(CanvasLayer, layer=15 → HUD보다 위) + `FinishView`(Control, 풀스크린) 추가. **Mode 7 SubViewport 카메라는 건드리지 않음**(스크린 공간 독립 오버레이라 가장 안전). HUD는 `enter_finish_view()`로 숨기고, 오버레이가 배경 페이드인해 화면 덮음.
- 렌더: 트랙 중심선 전체(서킷 윤곽) + 플레이어 실제 스티치 트레일(빨간 재봉 자국)을 트랙 바운딩 박스에 맞춰 스케일링. **노루발 근접 스케일 → 전체 뷰로 ~1s 줌아웃(ease-out) → ~2.5s 홀드 → Result**. 트랙명·최종 시간·재봉 평점(§6.5, 큰 등급 문자) 함께 표시.
- **스킵**: FINISH_VIEW 중 아무 키(마우스/조이 포함) 누르면 즉시 Result로. R(재시작)·Esc(일시정지)도 이 구간에선 스킵으로 처리(`_unhandled_input`이 press를 스킵 버퍼로 흡수).

### 13.3 전체 궤적 보존 (`StitchTrail`)

- 주행 중 렌더는 링버퍼(`_points`, `MAX_STITCHES`)로 근경 윈도만 유지하나, 줌아웃은 초반부터의 **전체 궤적** 필요. 상한 없는 `_full_points`에 같은 호길이 샘플을 함께 쌓고 `get_full_points()`로 노출(트랙 3200px대 → 수백 점, 수 KB로 메모리 무해).

---

## 14. 장면 아트 통합 (1차, 도형 플레이스홀더 → 오리지널 아트)

플레이스홀더 도형을 자체 제작 오리지널 아트로 교체. 소스는 코드로 저작한 SVG를 cairosvg로 래스터라이즈한 PNG(`game/assets/gfx/`, 소스 SVG는 `src/`+`.gdignore`, 라이선스는 `assets/gfx/README.md`에 MIT 자체 제작 명시). 스타일: 따뜻한 수공예 플랫 벡터(라인 최소, 음영 1~2단), 팔레트는 원단 웜톤(황록·베이지)+실 보라/빨강. '용과 같이' 재봉 미니게임은 구도 참고만, 에셋·UI 미모사(§15.2 IP 주의).

- **얼굴(`BackgroundFace`)**: 텍스처 베이스(머리·피부·머리카락·코·헤어밴드)+절차적 표정 오버레이(눈썹·눈·부상 X자 눈). `_draw`가 텍스처 깔고 그 위에 표정 항상 그려 조향 고개꺾기·속도 집중·고위험·부상 X눈 기믹 전부 보존. 텍스처 눈 소켓은 절차적 눈 좌표(`cx±0.19w`, `0.33h`)에 맞춰 저작.
- **손(`HandView`)**: 단일 손 스프라이트(우측 지향, 반대편은 노드 `mirror`). 누름·조향 연출은 노드 트랜스폼이라 스프라이트에 그대로 적용 → 보존.
- **노루발+바늘(`NeedleView`)**: `foot_texture`(정적)+`needle_texture`(왕복)로 파츠 분리해 바늘 상하 왕복(`_bob`) 보존. `ForegroundLayer` 그리기 순서는 손→노루발이라 노루발+바늘이 손 위에 또렷.
- **원단(`FabricSurface`)**: 트랙 JSON `fabric`(cotton/denim/silk/knit)별 타일 텍스처를 `set_fabric`으로 로드, 셰이더 `fabric_color`(OOB·수평선 페이드)를 원단 대표색으로 맞춤. 배선은 `PresentationController._setup_fabric`(읽기 전용 → 시뮬 결정론 불변). 128² seamless 타일 + `texture_repeat=ENABLED`로 Mode 7 워프 아래 이음매 없이 반복.
- **배경**: `BackdropLayer/BackdropArt`(재봉실 무드: 창·선반·실패 실루엣, 상단만 노출), `Main/BackgroundArt`(메뉴 무드) + 타이틀 텍스트 스타일링.
- **주의(tscn)**: 스크립트 정의 `@export texture`는 `script=` **뒤에** 지정해야 적용(Control/Node2D 네이티브 프로퍼티 아님). 원단 타일은 런타임 `load()` 경로 참조이므로 export 패키징 시 `assets/gfx/` 포함 필수.

### 14.1 2차 아트 교체 (AI 생성 시트 → 게임 에셋)

1차 SVG 플레이스홀더를 사용자가 GPT Image 2로 생성해 제공한 단일 스프라이트 시트로 교체. 원본 시트는 `assets/gfx/src/graphics_sheet_v1.png`에 보존(`src/`는 `.gdignore`라 임포트 제외). 1차 SVG(`src/*.svg`)도 롤백 대비로 유지. 파일명·규격은 1차와 동일 유지해 `.import`/uid·씬 배선 보존(`title_plaque.png`만 신규).

- **분해**: 알파 임계 + dilation 라벨링으로 얼굴·손·노루발·바늘·원단 4종·주야 배경·플라크 분리. 손↔노루발↔바늘처럼 사각 크롭 겹치는 성분은 라벨 마스크로 정리.
- **얼굴(`BackgroundFace`)**: 새 얼굴은 앞머리가 눈(구 절차적 좌표 `0.31w/0.69w`, `0.33h`)을 덮음. 그 위에 절차적 눈을 항상 그리면 머리카락 위에 눈이 떠 어색 → 평상시 표정은 생략(앞머리 가려진 콘셉트)하고 **상태일 때만** 앞머리 사이 드러난 피부 창에 라인 아트 얹음. 집중(속도·리스크)=찡그린 눈썹+치켜뜬 결의 눈매+관자놀이 땀방울(강도 비례), 부상(스턴)=만화적 X자 눈. **속도 집중·부상 시각 피드백은 형태만 바뀌고 보존**. 피부 창 좌표(양쪽 눈은 중앙 대비 `±0.145w`, `0.345h`)는 알파/피부색 맵으로 잡아 `expr_eye_dx_frac`/`expr_eye_y_frac`/`expr_sweat_frac` export로 조정. 조향 고개 꺾기 트랜스폼·도형 폴백 보존. 이 절차적 오버레이와, 그 뒤 base 위에 표정 시트 합성한 전체-얼굴 텍스처 스왑(`face_normal`/`face_focus`/`face_injured`)은 모두 하위 폴백으로 남고, **현행 우선 경로는 새 얼굴 시트(`src/face_sheet_v2.png`)로 만든 눈 오버레이 스왑**(눈 없는 `face_base_clean` + `eyes_*`/`sweat`, 눈만 크로스페이드 → 얼굴 윤곽 떨림·밴드 경계 차단; §12.4 · README).
- **손(`HandView`)**: 시트의 손(손목 우상단·손끝 좌하단)을 **회전 없이** 그대로 화면 우측 손(`mirror=false`: 손목 위·바깥, 손끝 아래·안쪽)으로 삼고, 좌측 손은 노드 `mirror=true`로 반전. 이전 ~150° 회전(손끝이 위로 뒤집혀 1인칭처럼 보이던 결함) 제거하고 시트 원방향으로 재크롭. 노드 트랜스폼(누름·조향·진동) 불변, 누름 부호만 새 방향에 맞춰 조정(§12.4).
- **원단(seamless)**: AI 텍스처는 seamless 아니고 저주파 명암(특히 새틴 광택)이 타일 반복 시 얼룩으로 드러남. 저주파 평탄화 후 대치 경계 페더 블렌딩해 128² 실제 seamless로 만들고 `texture_repeat=ENABLED` 유지. 대칭 `MIRROR`는 능직(denim)에 다이아몬드, 니트에 모래시계 이음매 생겨 배제(캡처 비교로 확정).
- **바늘/노루발**: `NeedleView` 정렬 상수(`FOOT_TOP`/`NEEDLE_TOP_OFFSET`)에 맞춰 규격화 → 바늘이 노루발 슬롯 사이로 오르내리는 왕복 보존.
- **배경/타이틀**: 재봉실 원화를 Lanczos로 1280×720 커버 업스케일(야간=`backdrop_room`, 주간=`menu_bg`). 타이틀은 글자 없는 자수 플라크(`title_plaque.png`) 깔고 그 위에 `OVERLOCK` 텍스트를 외곽선으로 겹침(`Main.tscn`의 `Menu/TitlePlaque`). `MainMenu.gd`는 `TitleLabel` 미참조라 배선 변경 없이 교체, 플라크·배경 배선 그대로. 단 트랙 선택·미리보기는 §14.2 맵 선택 화면으로 이동.

### 14.2 메뉴 2단 네비게이션 (메인 → 맵 선택)

한 화면에 몰려 있던 메뉴를 두 단계로 분리. 메인(`Main.tscn`)은 타이틀 플라크 + 세로 4버튼(Start / Settings / Leaderboard / Quit)만, 트랙 캐러셀·미리보기·에디터 진입·불러오기·삭제는 Start로 들어가는 맵 선택 화면(`TrackSelect.tscn`)으로 이동. 화면 흐름: `메인 → Start → 맵 선택 → 플레이 → 결과 → (Menu) → 맵 선택`, 맵 선택 "뒤로"로 메인 4버튼 복귀. 결과 화면 "Menu"는 방금 플레이한 트랙이 살아 있는 맵 선택으로 이어져 최고 기록 갱신 즉시 확인·다른 트랙 선택·재도전 가능.

- **키보드**: 메인은 ↑↓로 버튼 포커스 이동 + Enter 실행(포커스는 빨간 테두리 스타일박스). 맵 선택·리더보드는 ←→로 트랙 순환 + Esc 뒤로.
- **마지막 선택 트랙 기억**: 맵 선택 떠날 때 현재 트랙 id를 `LeaderboardClient`의 `user://settings.json`에 `last_track_id` 키로 기록(구조 확장은 키 추가뿐), 재진입 시 복원. 삭제된 커스텀 트랙이면 첫 트랙으로 폴백.
- **리더보드 트랙 전환**: 리더보드 화면에 공식 트랙 ◀▶ 전환 추가. 맵 선택의 "이 트랙 리더보드"로 열면 해당 트랙으로 시작, 메인에서 직접 열면 첫 공식 트랙으로 자체 초기화. 뒤로가기는 진입한 곳(`return_scene` 정적 변수)으로 복귀.
- **보존**: 설정 게이팅(온라인 URL·닉네임 조건), 커스텀 트랙 서버 제출/조회 제외, 웹 가드(Quit 숨김·데스크톱 전용 불러오기) 그대로. 에디터 "뒤로"도 맵 선택으로.
- **개발자 프로필 칩**: 메인 우하단에 소형 재봉 칩(원형 아바타 + `bnbong`), 클릭 시 개발자 프로필 팝업(`ProfileDialog`, GitHub 링크는 데스크톱 `OS.shell_open`·웹 `window.open` 동기 호출) 오픈. 마우스 전용(`FOCUS_NONE`)이라 4버튼 키보드 순환 무방해.
