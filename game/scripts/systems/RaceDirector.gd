extends Node2D
## Gameplay 루트. 물리 루프 소유 + 상태기계 (아키텍처 §6).
##
## PlayerController는 자체 _physics_process를 두지 않는다. 여기서
## (이산 입력 소비 → 상태 분기 → 입력 샘플 → 플레이어 시뮬 → 트랙 질의 →
## 판정/집계 → HUD → 피니시 판정)을 정해진 순서로 60Hz 고정 스텝에 호출한다.
##
## 일시정지 처리: 이 노드의 process_mode를 ALWAYS로 두어 트리가 paused여도
## _unhandled_input과 _physics_process가 계속 돌게 한다. 그래야 버퍼링한
## pause/restart 플래그를 물리 틱에서 소비해 일시정지를 해제할 수 있다.
## 시뮬레이션 본체는 paused일 때 조기 반환한다.

## 완주 줌아웃 연출(presentation.md §13): 피니시 순간 기록·통계는 즉시 확정하되
## (finalize·RecordStore.submit 타이밍 유지) 씬 전환만 FINISH_VIEW 상태로 지연한다.
## 그 동안 FinishView 오버레이가 전체 서킷 모양과 재봉 자국을 줌아웃으로 보여주고,
## FINISH_VIEW_DURATION 경과 또는 아무 키 입력(스킵) 시 Result로 넘어간다.

## 아이템 슬롯(v2.2.1, docs/architecture.md §6.6): 필드 아이템을 밟으면 효과를 바로 내지 않고
## ITEM_SLOT_CAPACITY칸 FIFO 슬롯에 담는다. use_item 눌림 엣지(InputFrame.use_item)가 들어온 틱에
## 가장 먼저 담긴 아이템의 기존 효과(_apply_item)를 낸다. 슬롯이 가득 차면 밟은 아이템은 획득하지
## 않고 필드에 그대로 남는다. 한 틱 안의 순서는 사용(시뮬 전) → 시뮬 → 트랙 질의 → 획득이다.

## 개인 고스트(v2.3.0, docs/architecture.md §3.3): 주행 틱마다 GhostRun이 위치 스냅샷과 10구간 통과를
## 기록하고(일시정지·튜토리얼·카운트다운·완주 줌아웃 제외), 완주 시 RecordStore.submit_run이 최고 기록과
## 고스트를 함께 저장한다. 재생은 시작 시 읽은 개인 최고 고스트를 같은 주행 경과 시간으로 미니맵과 필드
## (GhostFieldLayer)에 그린다. 구간 통과는 고스트 데이터(splits)로만 기록하고 화면에는 보이지 않는다.
## 고스트는 시뮬레이션 상태를 읽기만 하므로 충돌·아이템·RISK·기록에 영향을 주지 않는다.
## 에디터 테스트 플레이·중도 포기·재시작은 저장하지 않는다(완주 경로가 아니거나 editor_test 분기).

## 자동 일시정지(v2.2.1, docs/mobile.md §4.4): 카운트다운·주행 중 세로 전환(OrientationGuard)이나
## 창·앱 포커스 상실 때 수동 일시정지와 같은 정지를 걸고 입력을 뗀다. 복귀해도 자동으로 풀지 않고
## "계속"(pause 액션)을 눌러야 재개한다. 이미 정지(수동) 중이면 아무것도 바꾸지 않는다.

## 조향 감도 체험(데모, GameState.is_calibration()): 입장마다 tutorial_seen과 무관하게 튜토리얼(데모 안내
## 한 줄 추가)을 띄우고, HUD 위에 SteerCalibrationPanel을 얹는다([ / ]로 ±1%). 데모는 무한 주행이다.
## 닫힌 순환 코스의 결승(s ≥ length − FINISH_MARGIN)에 닿으면 완주 대신 랩을 되감아(_rewind_calibration_lap)
## 진행 s·hint·복귀 기준점만 0으로 돌리고 플레이어는 그대로 달린다. 기록·고스트(녹화·재생)·결과 화면이
## 없고, 패널의 "나가기"나 일시정지 메뉴의 M(트랙 선택)으로만 끝난다. 둘 다(다시 달리기 포함) 패널의
## 디바운스 저장을 먼저 flush하고 재시작하거나 종류 선택으로 나간다. 무한 주행 동안 쌓이는 버퍼를 막으려고
## 고스트 녹화를 건너뛰고 StitchTrail의 줌아웃용 전체 궤적(keep_full)을 끈다.

enum State { COUNTDOWN, RUNNING, FINISH_VIEW, FINISHED }

const FINISH_MARGIN: float = 1.0
const COUNTDOWN_SECONDS: float = 3.0
const FINISH_VIEW_DURATION: float = 3.5  # 줌아웃(~1s) + 홀드(~2.5s) 후 자동 전환
# 진입 직후 스킵 유예(버그 3). 완주 순간 눌려 있던 키/키 반복(echo)이나 마무리
# 조작이 줌아웃이 뜨기도 전에 즉시 스킵시키는 것을 막는다. 이 시간 동안의 스킵
# 입력은 버리고, 유예 후 새로 눌린 키만 스킵으로 인정한다.
const FINISH_VIEW_SKIP_GRACE: float = 0.4

# 맵(원단) 이탈 소프트 리셋(설계 §B). 오차가 임계를 RESET_DWELL 이상 "지속" 초과하면
# 마지막 정상 지점으로 되돌린다. 임계는 절대값 하한(RESET_ABS)과 트랙 fail 폭 배수
# (fail*RESET_FAIL_MULT) 중 큰 값 — 넓은 트랙에서 관대하고 좁은 트랙에서도 오발동하지 않게.
# 순간적 이탈(코너 컷 등)은 dwell로 걸러내 정상 주행을 방해하지 않는다.
const RESET_ABS: float = 300.0
const RESET_FAIL_MULT: float = 3.5
const RESET_DWELL: float = 0.12

## 아이템 슬롯 칸 수(FIFO).
const ITEM_SLOT_CAPACITY: int = 2
## 데스크톱 개발·캡처 자동화용 인자(`godot -- --no-focus-pause`). 창 포커스 상실 자동 일시정지만
## 끈다(세로 전환 자동 일시정지는 유지). 비-headless 드라이버가 포커스 없는 창에서 돌 때 쓴다.
const NO_FOCUS_PAUSE_ARG: String = "--no-focus-pause"
## 자동 일시정지 때 떼는 게임 입력 액션(키가 눌린 채 재개되지 않게).
const GAME_ACTIONS: Array[StringName] = [
	&"steer_left", &"steer_right", &"speed_up", &"speed_down", &"drift", &"use_item"
]

const TutorialDialogScene = preload("res://scenes/TutorialDialog.tscn")

var _track: TrackData
var _stats: RunStats
var _state: State = State.COUNTDOWN
var _hint: int = 0
var _elapsed: float = 0.0
var _countdown_time: float = COUNTDOWN_SECONDS
var _finish_view_time: float = 0.0
var _pending_result: Dictionary = {}

# 소프트 리셋용 "마지막 정상 지점"(PERFECT/GOOD 밴드에서만 갱신)과 이탈 지속 시간.
var _last_good_hint: int = 0
var _last_good_s: float = 0.0
var _offfabric_dwell: float = 0.0

# 필드 아이템 시뮬 상태(v1.1.0). _items는 트랙에서 로드한 아이템 배열(불변), _collected는 인덱스별
# 획득 여부(bool). _autopilot_s는 자동주행 중심선 진행 아크길이, _autopilot_grace_used는 핸드오프
# 곡률 연장에 이미 소비한 시간(초, autopilot_handoff_max_grace 상한). 전부 고정 틱에서만 갱신(결정론).
var _items: Array = []
var _collected: Array = []
# 획득 판정 순회 순서(ItemOrder 정규 순서의 원래 인덱스 배열). 배열 순서만 다른 같은 트랙이 같은 결과를 낸다.
var _item_order: Array = []
var _autopilot_s: float = 0.0
var _autopilot_grace_used: float = 0.0

# 아이템 슬롯(v2.2.1). _slots는 담긴 아이템 type 문자열의 FIFO(앞이 다음 사용), _full_touch는 인덱스별
# "가득 참으로 못 먹은 채 반경 안에 있음" 래치(반경 진입 1회만 피드백), _last_s는 직전 틱 진행 아크길이
# (시뮬 전에 쓰는 엄마 찬스 시작점). 전부 고정 틱에서만 갱신한다(결정론).
var _slots: Array[String] = []
var _full_touch: Array = []
var _last_s: float = 0.0

# 개인 고스트(v2.3.0). _ghost_rec는 이번 런 기록기(항상 기록), _ghost_play는 재생할 개인 최고 고스트
# (꺼짐·없음·손상이면 null), _ghost_notice는 고스트를 못 쓰는 사유 안내(출발 때 HUD에 잠깐 표시).
var _ghost_rec: GhostRun = null
var _ghost_play: GhostRun = null
var _ghost_notice: String = ""
# 필드 위 고스트 마커(ItemLayer 안, 재생할 고스트가 있을 때만 만든다).
var _ghost_field: GhostFieldLayer = null
# 이번 런의 원단 주행 특성 id(_apply_fabric_profile이 TrackData.fabric으로 정한다).
var _fabric_id: String = ""

# 자동 일시정지(세로 전환·포커스 상실)로 멈춘 상태인가. 수동 일시정지와 구분해 안내 문구만 바꾼다.
var _auto_paused: bool = false

# 이산 입력 버퍼 (_unhandled_input에서 세팅, 물리 틱에서 소비).
var _buf_speed_delta: int = 0
var _buf_use_item: bool = false  # use_item 눌림 엣지(주행 중·비정지일 때만 세팅, 1틱 1회로 합친다).
var _buf_restart: bool = false
var _buf_pause: bool = false
var _buf_to_menu: bool = false  # 일시정지 중 M(메인 메뉴 복귀) 버퍼. 일시정지 상태에서만 세팅한다.
var _buf_finish_skip: bool = false  # FINISH_VIEW 중 아무 키 입력(스킵) 버퍼.

# 최초 1회 튜토리얼 모달이 떠 있는 동안 true. 카운트다운·시뮬·입력 버퍼링을 모두 홀드한다
# (트리 pause는 쓰지 않는다 — 플래그 홀드만). 닫히면 false가 되고 카운트다운이 시작된다.
var _tutorial_open: bool = false

# 감도 체험(데모) 패널(.tscn 없음, 데모가 아니면 null).
var _calib_panel: SteerCalibrationPanel = null
# 감도 체험에서 결승을 지나 되감은 랩 수(무한 주행, 표시·기록에는 쓰지 않음. 회귀 검사용).
var _calib_laps: int = 0

@onready var _player: PlayerController = $SimHost/FabricSource/World/Player
@onready var _track_renderer: TrackRenderer = $SimHost/FabricSource/World/TrackRenderer
@onready var _finish_line: FinishLine = $SimHost/FabricSource/World/FinishLine
@onready var _stitch: StitchTrail = $SimHost/FabricSource/World/StitchTrail
@onready var _skid: DriftSkid = get_node_or_null("SimHost/FabricSource/World/DriftSkid")
# 필드 아이템 표현 노드. 표현 워커가 나중에 Gameplay.tscn에 추가한다 — 그 전까지 null이며,
# 시뮬은 이 노드 없이도 완전히 동작하므로 모든 참조·호출을 null-safe(has_method 가드)로 둔다.
@onready var _item_field: Node = get_node_or_null("SimHost/FabricSource/World/ItemField")
@onready var _finish_view: FinishView = $FinishViewLayer/FinishView
@onready var _hud: HUD = $HUD


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_stats = RunStats.new()
	_track = TrackLoader.load_track(GameState.track_id)
	if _track == null:
		push_error("RaceDirector: 트랙 로드 실패 " + GameState.track_id)
		return
	_track_renderer.setup(_track)
	_place_finish_line()
	_init_player()
	_hud.setup(_track)
	_hud.sync_minimap(_player, 0.0)
	_hud.set_pause_visible(false)
	_hud.set_item_slots(_slots)
	_setup_ghost()
	var guard: Node = get_node_or_null("/root/OrientationGuard")
	if guard != null and guard.has_signal("portrait_changed"):
		guard.portrait_changed.connect(_on_portrait_changed)
	# 웹 보강: 탭 숨김·창 blur는 엔진 알림으로 오지 않을 수 있어 OrientationGuard가 JS 이벤트를 신호로 전달한다.
	if guard != null and guard.has_signal("page_focus_lost"):
		guard.page_focus_lost.connect(_on_page_focus_lost)
	if GameState.is_calibration():
		_build_calibration_panel()
		# 무한 주행: 줌아웃(완주) 연출이 없으니 전체 궤적을 무제한으로 쌓지 않는다(근경 링버퍼만).
		if _stitch != null:
			_stitch.keep_full = false
	# 설치 후 첫 플레이(전역 1회)면 튜토리얼을 먼저 띄우고, 닫힌 뒤 카운트다운을 표시한다.
	# 감도 체험은 입장마다(재시작 리로드 제외) 튜토리얼을 띄운다.
	var calib_tutorial: bool = GameState.take_calibration_tutorial()
	if calib_tutorial or not LeaderboardClient.tutorial_seen:
		_open_tutorial()
	else:
		_hud.show_countdown(ceili(_countdown_time))
		_pause_if_unavailable()


## 최초 1회 튜토리얼 모달을 HUD(CanvasLayer) 위에 띄우고 카운트다운을 홀드한다.
func _open_tutorial() -> void:
	var dlg: TutorialDialog = TutorialDialogScene.instantiate()
	dlg.demo_mode = GameState.is_calibration()
	_hud.add_child(dlg)
	_tutorial_open = true
	dlg.closed.connect(_on_tutorial_closed)


## 감도 체험 패널을 HUD(CanvasLayer) 위에 얹는다. 패널은 생성 시 스스로 UI를 만들고 현재 감도로 초기화한다.
func _build_calibration_panel() -> void:
	_calib_panel = SteerCalibrationPanel.new()
	_calib_panel.name = "SteerCalibrationPanel"
	_hud.add_child(_calib_panel)
	_calib_panel.restart_requested.connect(_on_calibration_restart)
	_calib_panel.finish_requested.connect(_exit_calibration)


## 감도 체험 패널의 디바운스 중인 감도 저장을 즉시 수행한다(실패 안내는 패널이 직접 표시).
func _flush_calibration() -> void:
	if is_instance_valid(_calib_panel):
		_calib_panel.flush_save()


func _on_calibration_restart() -> void:
	_restart()


## 감도 체험을 끝내고 종류 선택 화면으로 돌아간다(패널의 나가기·일시정지 메뉴 M 공통).
## 완주 경로(_go_to_result)도 방어적으로 여기로 오지만 데모는 랩을 되감아 도달하지 않는다.
func _exit_calibration() -> void:
	_flush_calibration()
	_state = State.FINISHED
	GameState.exit_calibration()


## 튜토리얼 해제: 처음 본 것이면 영속하고 카운트다운을 3부터 정상 시작한다.
## 이미 본 상태(감도 체험은 입장마다 튜토리얼을 띄운다)면 settings.json을 다시 쓰지 않는다.
func _on_tutorial_closed() -> void:
	_tutorial_open = false
	if not LeaderboardClient.tutorial_seen:
		LeaderboardClient.save_tutorial_seen()
	_hud.show_countdown(ceili(_countdown_time))
	_pause_if_unavailable()


# --- 자동 일시정지(세로 전환·포커스 상실) ---


## 창·앱 포커스 상실(탭 전환·앱 전환·화면 잠금 등)이면 자동 일시정지한다. 포커스 복귀는 무시한다
## (자동 재개 없음). --no-focus-pause 인자가 있으면 포커스 경로만 끈다.
func _notification(what: int) -> void:
	if (
		what == NOTIFICATION_APPLICATION_FOCUS_OUT
		or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT
		or what == NOTIFICATION_APPLICATION_PAUSED
	):
		if not focus_pause_disabled():
			request_auto_pause()


static func focus_pause_disabled() -> bool:
	return (
		NO_FOCUS_PAUSE_ARG in OS.get_cmdline_user_args()
		or NO_FOCUS_PAUSE_ARG in OS.get_cmdline_args()
	)


## OrientationGuard 신호: 세로가 되면 자동 일시정지, 가로 복귀는 무시한다(자동 재개 없음).
func _on_portrait_changed(portrait: bool) -> void:
	if portrait:
		request_auto_pause()


## OrientationGuard 웹 보강 신호(document 숨김·window blur). 포커스 상실과 같게 취급한다.
func _on_page_focus_lost() -> void:
	if not focus_pause_disabled():
		request_auto_pause()


## 카운트다운 시작 시점(진입·재시작·튜토리얼 해제)에 이미 세로이거나 화면을 볼 수 없는 상태(창 포커스
## 없음·웹 탭 숨김)면 곧바로 멈춘다. 포커스 판정은 --no-focus-pause면 건너뛴다.
func _pause_if_unavailable() -> void:
	if _is_portrait() or (not focus_pause_disabled() and _is_unfocused_at_start()):
		request_auto_pause()


## 시작 시 포커스 판정. 헤드리스는 창이 없어 판정하지 않는다. 웹은 캔버스 포커스 이벤트가 사용자
## 조작 전에는 오지 않을 수 있어 창 포커스 대신 document.hidden만 본다(OrientationGuard.is_page_hidden).
func _is_unfocused_at_start() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	if OS.has_feature("web"):
		var guard: Node = get_node_or_null("/root/OrientationGuard")
		return guard != null and guard.has_method("is_page_hidden") and bool(guard.is_page_hidden())
	return not get_window().has_focus()


func _is_portrait() -> bool:
	var guard: Node = get_node_or_null("/root/OrientationGuard")
	return guard != null and guard.has_method("is_portrait") and bool(guard.is_portrait())


## 자동 일시정지 요청. 카운트다운·주행 중이고 튜토리얼이 닫혀 있으며 아직 멈추지 않았을 때만 건다.
## 수동 일시정지 중이면 그대로 두고(회전 복구가 수동 정지를 풀지 않음), 완주 줌아웃·결과·메뉴에서는
## 아무것도 하지 않는다. 멈추면서 눌린 게임 입력과 이산 입력 버퍼를 비운다. 반환: 새로 멈췄는가.
func request_auto_pause() -> bool:
	if _track == null or _tutorial_open or not is_inside_tree():
		return false
	if _state != State.COUNTDOWN and _state != State.RUNNING:
		return false
	var tree: SceneTree = get_tree()
	if tree.paused:
		return false
	_auto_paused = true
	tree.paused = true
	_release_game_input()
	_hud.set_pause_visible(true, true)
	return true


## 자동 일시정지로 멈춰 있는가(수동 일시정지·비정지면 false).
func is_auto_paused() -> bool:
	return _auto_paused and is_inside_tree() and get_tree().paused


## 주행 틱(RUNNING) 중인가. 표현 계층(드리프트 주름)이 카운트다운·완주 줌아웃·결과 전환 동안 새
## 연출을 만들지 않도록 읽기만 한다(시뮬 상태 불변).
func is_racing() -> bool:
	return _state == State.RUNNING


## 눌린 게임 입력 액션을 떼고, 아직 소비하지 않은 이산 입력을 모두 버린다(속도·아이템 사용과 일시정지·
## 재시작·메뉴 복귀 메타 입력). 메타 버퍼가 남으면 다음 틱의 재시작이 자동 정지를 풀어 버린다.
## 키보드는 다음 실제 눌림부터 다시 인정되고, 터치 버튼은 HUD가 숨기면서 TouchControls가 뗀다.
func _release_game_input() -> void:
	for a in GAME_ACTIONS:
		if InputMap.has_action(a):
			Input.action_release(a)
	_buf_speed_delta = 0
	_buf_use_item = false
	_buf_pause = false
	_buf_restart = false
	_buf_to_menu = false


func _unhandled_input(event: InputEvent) -> void:
	# 튜토리얼 모달이 떠 있으면 게임 입력을 버퍼링하지 않는다(모달이 Esc를 먼저 소비하지만 이중 안전).
	if _tutorial_open:
		return
	# 완주 줌아웃 중에는 아무 키 입력이 스킵으로 처리된다(R 재시작·Esc 일시정지 포함).
	# 모션(마우스 이동) 등 비-press 이벤트는 무시한다.
	if _state == State.FINISH_VIEW:
		if event.is_pressed() and not event.is_echo():
			_buf_finish_skip = true
		return
	if _consume_calibration_key(event):
		return
	if event.is_action_pressed("pause"):
		_buf_pause = true
	elif event.is_action_pressed("restart"):
		_buf_restart = true
	elif event.is_action_pressed("to_menu"):
		# 일시정지 상태일 때만 유효. 그 외에는 아무 동작도 하지 않는다.
		if get_tree().paused:
			_buf_to_menu = true
	elif event.is_action_pressed("speed_up"):
		_buf_speed_delta += 1
	elif event.is_action_pressed("speed_down"):
		_buf_speed_delta -= 1
	elif event.is_action_pressed("use_item"):
		# 눌림 엣지만(키 반복 echo 제외) 받는다. 카운트다운·일시정지 중 누름은 버린다(재개 후 뒤늦게
		# 쓰이지 않게). 한 틱 안의 여러 누름은 1회로 합친다.
		if _state == State.RUNNING and not get_tree().paused:
			_buf_use_item = true


## 감도 체험 중 [ / ] 키로 감도를 ±1% 조절한다(홀드 echo 허용). 처리했으면 true.
## 조향키와 겹치지 않게 InputMap 액션 없이 키코드를 직접 비교한다.
func _consume_calibration_key(event: InputEvent) -> bool:
	if not is_instance_valid(_calib_panel):
		return false
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed:
		return false
	if key.keycode == KEY_BRACKETLEFT:
		_calib_panel.nudge(-1)
	elif key.keycode == KEY_BRACKETRIGHT:
		_calib_panel.nudge(1)
	else:
		return false
	get_viewport().set_input_as_handled()
	return true


func _physics_process(delta: float) -> void:
	if _track == null:
		return
	# 최초 튜토리얼 모달이 떠 있는 동안은 카운트다운·시뮬을 진행하지 않는다.
	if _tutorial_open:
		return
	# 완주 줌아웃은 일시정지·메타 입력과 무관하게 자체 타이머/스킵으로만 진행한다.
	if _state == State.FINISH_VIEW:
		_tick_finish_view(delta)
		return
	# 재시작을 소비했으면 reload_current_scene()으로 이 노드가 트리에서 detach된다.
	# 이후 get_tree()가 null이 되므로 이 물리 틱을 즉시 종료해 null 접근을 피한다.
	if _consume_meta_input():
		return
	if get_tree().paused:
		return
	match _state:
		State.COUNTDOWN:
			_tick_countdown(delta)
		State.RUNNING:
			_tick_running(delta)
		State.FINISHED:
			pass


## 완주 줌아웃 연출 진행. 지속 시간 경과 또는 스킵 입력 시 Result로 전환한다.
func _tick_finish_view(delta: float) -> void:
	_finish_view_time += delta
	# 진입 유예(버그 3): 유예 동안은 스킵 입력을 버려 줌아웃이 최소한 보이게 한다.
	# (_unhandled_input이 echo 이벤트는 이미 무시하므로, 여기서는 누른 키/마무리
	#  조작이 진입 즉시 스킵으로 소비되는 것을 유예로 한 번 더 막는다.)
	if _finish_view_time < FINISH_VIEW_SKIP_GRACE:
		_buf_finish_skip = false
		return
	if _buf_finish_skip or _finish_view_time >= FINISH_VIEW_DURATION:
		_buf_finish_skip = false
		_go_to_result()


## 이산 메타 입력(pause/restart)을 소비한다. 재시작을 처리했으면 true를 반환해
## 호출자가 그 틱을 즉시 끝내도록 한다(reload 후 get_tree() null 접근 방지).
func _consume_meta_input() -> bool:
	if _buf_pause:
		_buf_pause = false
		_toggle_pause()
	if _buf_restart:
		_buf_restart = false
		_restart()
		return true
	if _buf_to_menu:
		_buf_to_menu = false
		_to_menu()
		return true
	return false


func _toggle_pause() -> void:
	if _state == State.FINISHED:
		return
	var tree: SceneTree = get_tree()
	# 세로 안내가 덮고 있는 동안은 재개하지 않는다(가로로 돌린 뒤 "계속"을 눌러야 재개).
	if tree.paused and _is_portrait():
		return
	tree.paused = not tree.paused
	_auto_paused = false
	_buf_use_item = false
	_hud.set_pause_visible(tree.paused)


func _restart() -> void:
	_flush_calibration()
	get_tree().paused = false
	get_tree().reload_current_scene()


## 일시정지 중 M 입력: 런을 파기하고 메인 메뉴로 돌아간다(확인창 없음, 재시작과 동일하게 즉시형).
## 에디터 테스트 플레이면 메인 대신 편집 화면으로, 감도 체험이면 종류 선택으로 돌아간다.
func _to_menu() -> void:
	get_tree().paused = false
	if GameState.is_calibration():
		_exit_calibration()
		return
	if GameState.is_editor_test():
		GameState.return_to_editor()
		return
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _tick_countdown(delta: float) -> void:
	_countdown_time -= delta
	if _countdown_time > 0.0:
		_hud.show_countdown(ceili(_countdown_time))
	else:
		_hud.show_go()
		_state = State.RUNNING
		_ghost_rec.begin(_player.position, _player.heading)
		if not _ghost_notice.is_empty():
			_hud.show_ghost_notice(_ghost_notice)


func _tick_running(delta: float) -> void:
	_elapsed += delta
	var input: InputFrame = _sample_input()
	# 아이템 사용(v2.2.1)은 시뮬 전에 처리한다: 누른 틱의 시뮬부터 효과가 반영되고(부상 대기 중 골무로
	# 그 틱의 부상을 막을 수 있음), 엄마 찬스는 아래 자동주행 주입이 같은 틱에 이어받는다.
	if input.use_item:
		_use_item()
	# 오토파일럿 활성 중에는 simulate 전에 중심선 타깃을 주입한다(PlayerController._autopilot_update가
	# 소비). 진행 아크길이를 speed*delta 만큼 전진시키고, 만료 임박 틱에는 곡률 게이트로 급코너
	# 한복판 핸드오프를 grace 한도 내에서 지연한다.
	if _player.autopilot_timer > 0.0:
		_advance_autopilot(delta)
	_player.simulate(input, delta)
	# 이번 틱 부상 발생 여부는 simulate 직후 바로 소비한다. 아래 이탈 리셋 분기가 조기 return해도
	# 그 틱의 부상이 누락되거나 다음 틱으로 밀려 집계되지 않게 한다(부상 1회당 정확히 1회).
	var just_cut: bool = _player.consume_just_cut()
	var probe: Dictionary = _track.query(_player.position, _hint)
	_hint = int(probe["idx"])
	var err: float = float(probe["error"])
	var band: int = _classify(err)
	_last_s = float(probe["s"])
	# 아이템 픽업 판정(query 후, 고정 틱에서만 — 결정론). 획득한 아이템은 슬롯에 담는다(효과는 사용 시).
	_check_item_pickups()
	# 맵 이탈 소프트 리셋(설계 §B): 정상 밴드(PERFECT/GOOD)에서만 복귀 기준점을 기억하고,
	# 오차가 임계를 RESET_DWELL 이상 지속 초과하면 마지막 정상 지점으로 되돌린 뒤 그 틱을 끝낸다.
	if band == RunStats.Band.PERFECT or band == RunStats.Band.GOOD:
		_last_good_hint = _hint
		_last_good_s = float(probe["s"])
	if err > maxf(RESET_ABS, _track.fail * RESET_FAIL_MULT):
		_offfabric_dwell += delta
		if _offfabric_dwell >= RESET_DWELL:
			if just_cut:
				_stats.add_cut()
			_soft_reset_off_fabric()
			return
	else:
		_offfabric_dwell = 0.0
	_stats.accumulate(delta, _player.speed_index, band, err, just_cut)
	# 구간 통과는 고스트 데이터(splits)로만 기록한다(주행 중·결과 화면 모두 표시하지 않음).
	# 감도 체험은 고스트를 쓰지 않고 무한 주행이라 샘플이 끝없이 쌓이므로 녹화하지 않는다.
	if not GameState.is_calibration():
		_ghost_rec.on_tick(
			_elapsed, _player.position, _player.heading, _last_s, _stats.penalty_time
		)
	if _ghost_play != null:
		# 미니맵과 필드 마커가 같은 물리 시각의 고스트 상태를 쓴다.
		var gs: Dictionary = _ghost_play.state_at(_elapsed * 1000.0)
		_hud.set_ghost_state(gs)
		if _ghost_field != null:
			_ghost_field.set_state(gs)
	var at_finish: bool = float(probe["s"]) >= _track.length - FINISH_MARGIN
	if at_finish and GameState.is_calibration():
		_rewind_calibration_lap()
		_hud.update_frame(_elapsed, _player, _track, 0.0, band)
		return
	_hud.update_frame(_elapsed, _player, _track, float(probe["s"]), band)
	if at_finish:
		_finish()


## 감도 체험 랩 되감기(무한 주행): 결승에 닿으면 진행 s·hint·복귀 기준점·이탈 체류만 0으로 돌린다.
## 플레이어 위치·속도·heading은 그대로다(닫힌 코스라 결승 = 출발점, 주행이 끊기지 않는다).
## 다음 틱 query(pos, 0)는 창 [0, FWD_WIN]에서만 최근접을 찾는다. 바늘은 이음새(points[0] 근처)에 있으니
## 세그먼트 0 부근이 최근접(오차는 원래 재봉선 오차 그대로)이 되어 s≈0으로 잡히고, idx가 창 앞끝(hi)이
## 아니라 재로컬라이즈도 걸리지 않는다. 마지막 세그먼트들은 창 밖이라 s가 length 쪽으로 되튀지 않는다.
func _rewind_calibration_lap() -> void:
	_hint = 0
	_last_s = 0.0
	_last_good_hint = 0
	_last_good_s = 0.0
	_offfabric_dwell = 0.0
	_calib_laps += 1


## 오토파일럿 자동주행 타깃 주입(simulate 전). 진행 아크길이를 전진시키고, 만료 임박 틱이면
## 곡률 게이트로 핸드오프를 grace 한도 내에서 지연한 뒤 중심선 타깃을 세팅한다. 실제 만료 시엔
## 조향(target/actual_steer)을 0으로 동기해 수동 조작이 접선 방향으로 곧게 재개되게 한다.
func _advance_autopilot(delta: float) -> void:
	_autopilot_s = clampf(_autopilot_s + _player.speed * delta, 0.0, _track.length)
	# 이번 틱 simulate의 타이머 감소로 autopilot_timer가 0 이하가 되는가(=만료 임박)?
	var will_expire: bool = _player.autopilot_timer <= delta
	if will_expire:
		var curv: float = _track.curvature_at_s(_autopilot_s)
		if (
			curv > Tuning.autopilot_handoff_curvature
			and _autopilot_grace_used < Tuning.autopilot_handoff_max_grace
		):
			# grace 한도 내에서 자동주행을 연장한다(곡률이 낮아질 때까지 핸드오프 지연).
			var ext: float = minf(delta, Tuning.autopilot_handoff_max_grace - _autopilot_grace_used)
			_player.autopilot_timer += ext
			_autopilot_grace_used += ext
			will_expire = _player.autopilot_timer <= delta
	_player.autopilot_target_pos = _track.point_at_s(_autopilot_s)
	_player.autopilot_target_heading = _track.tangent_at_s(_autopilot_s).angle()
	if will_expire:
		# 핸드오프: 조향을 0으로 맞춰 수동 재개 시 중심선 접선 방향으로 곧게 이어가게 한다.
		_player.target_steer = 0.0
		_player.actual_steer = 0.0


## 아이템 픽업 판정(고정 틱). 미획득 아이템의 월드 좌표(point_at_s + lat*접선법선)와 노루발 위치의
## 거리가 item_pickup_radius 이하이면 획득 처리: 슬롯 맨 뒤에 담고 표현 노드에 통지한다(null-safe).
## 슬롯이 가득 차 있으면 획득하지 않고 아이템을 필드에 그대로 둔다. 이때 반경에 들어온 첫 틱에만
## HUD에 "가득 참" 피드백을 보내고(_full_touch 래치), 반경을 벗어나면 래치를 푼다. 반경 안에 있는
## 동안 슬롯이 비면 다음 틱에 정상 획득한다. 한 틱에 여러 개가 겹치면 ItemOrder 정규 순서(s→type→lat→
## 인덱스)로 담는다(기록 지문과 같은 순서라 배열 순서만 다른 트랙도 같은 결과).
func _check_item_pickups() -> void:
	if _items.is_empty():
		return
	var ppos: Vector2 = _player.position
	var changed: bool = false
	for i in _item_order:
		if bool(_collected[i]):
			continue
		var item: Dictionary = _items[i]
		var item_s: float = float(item.get("s", 0.0))
		var lat: float = float(item.get("lat", 0.0))
		var world: Vector2 = (
			_track.point_at_s(item_s) + _track.tangent_at_s(item_s).orthogonal() * lat
		)
		if ppos.distance_to(world) > Tuning.item_pickup_radius:
			_full_touch[i] = false
			continue
		if _slots.size() >= ITEM_SLOT_CAPACITY:
			if not bool(_full_touch[i]):
				_full_touch[i] = true
				_hud.on_item_slots_full()
			continue
		_collected[i] = true
		_full_touch[i] = false
		_slots.append(str(item.get("type", "")))
		changed = true
		if _item_field != null and _item_field.has_method("on_collected"):
			_item_field.on_collected(i)
	if changed:
		_hud.set_item_slots(_slots)


## 아이템 사용(use_item 엣지가 든 틱, 시뮬 전). 슬롯 맨 앞 아이템을 꺼내 기존 효과(_apply_item)를 낸다.
## 부상 스턴·원단 이탈 복귀 잠금 중에는 속도 입력처럼 조작 잠금으로 보고 무시한다(슬롯 유지). 빈
## 슬롯이면 아무 일도 없다. 두 경우 모두 HUD에 거절 피드백만 보낸다. 부상 대기(손 미끄러짐) 중에는
## 사용할 수 있고, 골무·엄마 찬스의 기존 grant가 대기 중인 부상을 해제한다.
func _use_item() -> void:
	if _slots.is_empty() or _player.stun_timer > 0.0 or _player.offfabric_timer > 0.0:
		_hud.on_item_use_rejected()
		return
	var type: String = _slots.pop_front()
	_apply_item({"type": type}, _last_s)
	_hud.set_item_slots(_slots)


## 현재 슬롯 내용(앞이 다음 사용, 복사본). HUD·회귀 검사용 읽기 전용.
func item_slots() -> Array[String]:
	return _slots.duplicate()


## 아이템 type별 효과 적용. thimble→골무(부상 봉인), autopilot(엄마찬스)→오토파일럿 자동주행.
## 엄마찬스는 현재 진행 아크길이(probe_s, 사용 시점에는 직전 틱 트랙 질의 값)에서 자동주행을 시작하도록
## _autopilot_s를 맞추고 grace를 리셋한다. 미지원 type은 무시한다(가산적 확장 여지). 이미 같은 효과가
## 활성이면 grant가 타이머를 전체 지속으로 갱신한다(연장·누적 아님, 슬롯 도입 전 재획득과 같은 규칙).
func _apply_item(item: Dictionary, probe_s: float) -> void:
	match str(item.get("type", "")):
		"thimble":
			_player.grant_thimble()
		"autopilot":
			_player.grant_autopilot()
			_autopilot_s = probe_s
			_autopilot_grace_used = 0.0
		_:
			pass


## 마지막 정상 지점(센터라인 점 + 진행 방향)으로 플레이어를 되돌리고 페널티를 부과한다.
## _hint를 복원해 다음 query가 그 주변에서 재로컬라이즈하게 함으로써 s가 전진하지 않도록
## 막는다(리셋을 진행 단축에 악용하는 것을 차단). 부상 카운트는 건드리지 않는다.
func _soft_reset_off_fabric() -> void:
	var reset_pos: Vector2 = Vector2.ZERO
	if _track.points.size() > _last_good_hint:
		reset_pos = _track.points[_last_good_hint]
	var pre_pos: Vector2 = _player.position
	var pre_heading: float = _player.heading
	var pre_s: float = _last_s
	_player.off_fabric_reset(reset_pos, _heading_at(_last_good_hint))
	_hint = _last_good_hint
	_last_s = _last_good_s
	_stats.add_reset_penalty()
	_offfabric_dwell = 0.0
	# 감도 체험은 고스트를 녹화하지 않는다(무한 주행 누적 차단, _tick_running과 같은 규칙).
	if GameState.is_calibration():
		return
	# 고스트 기록: 복귀 전후를 같은 시각의 두 샘플로 남겨 재생이 트랙을 가로질러 보간하지 않게 한다.
	_ghost_rec.on_reset(
		_elapsed, pre_pos, pre_heading, pre_s, _player.position, _player.heading, _last_good_s
	)


## 폴리라인 인덱스 idx에서의 진행(접선) 방향 각도. 세그먼트가 없으면 0.
func _heading_at(idx: int) -> float:
	var n: int = _track.points.size()
	if n < 2:
		return 0.0
	var i: int = clampi(idx, 0, n - 2)
	return (_track.points[i + 1] - _track.points[i]).angle()


func _sample_input() -> InputFrame:
	var steer: float = 0.0
	if Input.is_action_pressed("steer_left"):
		steer -= 1.0
	if Input.is_action_pressed("steer_right"):
		steer += 1.0
	var speed_delta: int = _buf_speed_delta
	_buf_speed_delta = 0
	var drift: bool = Input.is_action_pressed("drift")
	var use_item: bool = _buf_use_item
	_buf_use_item = false
	return InputFrame.new(steer, speed_delta, false, drift, use_item)


func _classify(err: float) -> int:
	if err <= _track.perfect:
		return RunStats.Band.PERFECT
	if err <= _track.safe:
		return RunStats.Band.GOOD
	if err <= _track.fail:
		return RunStats.Band.OFF_SEAM
	return RunStats.Band.TEAR


func _finish() -> void:
	# 완주 후에는 시뮬이 더 돌지 않으므로 부상 사전 연출(pending)이 남아 있으면 지금 부상을 확정하고
	# 결과 확정 전에 정확히 1회 집계한다(예전 즉시 부상과 같은 결과 — 완주 직전 창에서 면제 없음).
	# 이번 틱에 이미 부상이 실행됐다면 pending이 아니므로 아무것도 하지 않는다(이중 집계 없음).
	if _player.is_cut_pending():
		_player.resolve_cut_pending_now()
		if _player.consume_just_cut():
			_stats.add_cut()
	# 기록·통계는 지금 즉시 확정한다(타이밍 불변). 씬 전환만 FINISH_VIEW로 지연한다.
	var result: Dictionary = _stats.finalize(
		_elapsed, _track.safe, GameState.track_id, GameState.difficulty
	)
	# 기록 메타(docs/architecture.md §3.2): 연습(개발용 튜닝) 여부는 기록 키를, 트랙 지문은 고스트 유효성을 정한다.
	result["practice"] = RecordStore.is_practice()
	result["track_fingerprint"] = RecordStore.fingerprint_for(GameState.track_id)
	_ghost_rec.on_finish(result, _player.position, _player.heading, _last_s)
	# 에디터 테스트 플레이는 결과 통계만 보여 주고 개인 최고 기록·고스트를 갱신하지 않는다(서버 제출도
	# 결과 화면이 editor_test 표시로 막는다). 감도 체험도 기록·고스트를 남기지 않는다(결과 화면도 없음,
	# 데모는 랩 되감기로 여기 도달하지 않는다. 방어적 분기).
	# 일반 플레이는 기존대로 즉시 기록한다.
	var is_best: bool = false
	if GameState.is_calibration():
		result["calibration"] = true
	elif GameState.is_editor_test():
		result["editor_test"] = true
	else:
		is_best = _submit_record(result)
	result["is_new_record"] = is_best
	_pending_result = result
	_state = State.FINISH_VIEW
	_finish_view_time = 0.0
	# 잔여 이산 입력 버퍼를 비워 줌아웃 진입 후 스킵/재시작이 섞이지 않게 한다.
	_buf_speed_delta = 0
	_buf_use_item = false
	_buf_restart = false
	_buf_pause = false
	_buf_to_menu = false
	_buf_finish_skip = false
	# 감도 체험: 도달하지 않음(랩 되감기, _rewind_calibration_lap). 방어적으로 남겨 둔다. 줌아웃 중 패널
	# 버튼(다시 달리기·나가기)으로 리로드/전환이 끼어들지 않게 숨기고, 디바운스 중인 감도는 지금 저장한다
	# ([ / ]는 위 FINISH_VIEW 입력 분기에서 이미 막힌다).
	if is_instance_valid(_calib_panel):
		_flush_calibration()
		_calib_panel.visible = false
	# 완주 시 슬롯에 남은 아이템은 효과 없이 사라진다(기록·점수와 무관, 위에서 결과는 이미 확정).
	_slots.clear()
	if _hud != null:
		_hud.set_item_slots(_slots)
		_hud.enter_finish_view()
	if _finish_view != null:
		var trail: PackedVector2Array = PackedVector2Array()
		if _stitch != null:
			trail = _stitch.get_full_points()
		# 드리프트 스키드 전체 자국도 줌아웃 뷰에 넘긴다(null-safe, 없으면 빈 배열).
		var skids: Array = _skid.get_full_marks() if _skid != null else []
		_finish_view.begin(_track, trail, _player.position, result, skids)


## 확정된 결과로 Result 씬으로 전환한다(중복 호출 방지 가드). 감도 체험은 결과 없이 종류 선택으로 간다
## (도달하지 않음, 랩 되감기. 방어적 분기).
func _go_to_result() -> void:
	if _state == State.FINISHED:
		return
	if GameState.is_calibration():
		_exit_calibration()
		return
	_state = State.FINISHED
	GameState.to_result(_pending_result)


func _init_player() -> void:
	var start_pos: Vector2 = Vector2.ZERO
	if _track.points.size() > 0:
		start_pos = _track.points[0]
	_apply_fabric_profile()
	_player.reset_state(start_pos, _track.start_heading())
	_hint = 0
	_last_good_hint = 0
	_last_good_s = 0.0
	_offfabric_dwell = 0.0
	# 필드 아이템 로드·초기화(씬 재로드 시 여기서 전부 리셋된다). ItemField 표현 노드가 있으면
	# 셋업을 통지한다(null-safe). 표현 노드는 track.items로 시각을 구성한다.
	_items = _track.items
	_item_order = ItemOrder.indices(_items)
	_collected.clear()
	_full_touch.clear()
	for _i in _items.size():
		_collected.append(false)
		_full_touch.append(false)
	_slots.clear()
	_last_s = 0.0
	_autopilot_s = 0.0
	_autopilot_grace_used = 0.0
	if _item_field != null and _item_field.has_method("setup"):
		_item_field.setup(_track)


func _place_finish_line() -> void:
	var count: int = _track.points.size()
	if count >= 2:
		var last: Vector2 = _track.points[count - 1]
		var prev: Vector2 = _track.points[count - 2]
		_finish_line.position = last
		_finish_line.rotation = (last - prev).angle()
		_finish_line.setup(_track.fail)


# --- 원단 주행 특성 연결 지점 ---


## 런 시작 시 트랙 원단(TrackData.fabric)으로 이번 런의 주행 특성(FabricProfile)을 정해 PlayerController에
## 고정 전달한다. 빈 값·지원하지 않는 값·혼합 원단의 면(cotton) fallback 판정은 FabricProfile 한 곳에서 한다
## (계획서 §2 "물리 연결"). reset_state보다 먼저 불려 속도 대입이 같은 계수를 쓰게 한다. 엄마 찬스 자동주행
## 거리(_advance_autopilot)는 이미 effective 속도인 _player.speed를 쓴다.
func _apply_fabric_profile() -> void:
	var profile: Dictionary = FabricProfile.for_fabric(_track.fabric)
	_player.set_fabric_profile(profile)
	_fabric_id = str(profile["fabric"])


func fabric_id() -> String:
	return _fabric_id


# --- 개인 고스트 (v2.3.0) ---


## 기록기를 준비하고, 고스트 표시가 켜져 있고 일반 플레이(에디터 테스트·감도 체험 제외)면 개인 최고 기록의 고스트를 읽는다. 기록 당시와
## 트랙 지문이 다르거나 파일이 손상되면 재생 없이 진행하고 사유를 출발 때 안내한다.
func _setup_ghost() -> void:
	_ghost_rec = GhostRun.new()
	_ghost_rec.setup(_track.length)
	_ghost_play = null
	_ghost_notice = ""
	var skip_ghost: bool = GameState.is_editor_test() or GameState.is_calibration()
	if skip_ghost or not RecordStore.ghost_enabled():
		_hud.setup_ghost(false)
		return
	var loaded: Dictionary = RecordStore.load_ghost(GameState.track_id, GameState.difficulty)
	if bool(loaded["ok"]):
		_ghost_play = loaded["run"]
		_build_ghost_field()
	else:
		_ghost_notice = ghost_notice_text(str(loaded["reason"]))
	_hud.setup_ghost(_ghost_play != null)


## 필드 위 고스트 마커 레이어를 ItemLayer 맨 아래(아이템 빌보드보다 먼저)에 붙인다. 손·노루발·바늘
## (ForegroundLayer)과 HUD는 그 위에 그려진다. ItemLayer가 없는 씬이면 만들지 않는다(null-safe).
func _build_ghost_field() -> void:
	var layer: Node = get_node_or_null("ItemLayer")
	if layer == null:
		return
	_ghost_field = GhostFieldLayer.new()
	layer.add_child(_ghost_field)
	layer.move_child(_ghost_field, 0)
	_ghost_field.setup(_player)


## 필드 고스트 마커(없으면 null). 회귀 검사용 읽기 전용.
func ghost_field() -> GhostFieldLayer:
	return _ghost_field


## 고스트를 재생하지 못한 사유 → 출발 한 줄 안내(안내가 필요 없는 사유는 빈 문자열, GhostNoticeBanner).
static func ghost_notice_text(reason: String) -> String:
	match reason:
		RecordStore.STATE_NO_RECORD, RecordStore.STATE_NO_GHOST:
			return ""
		RecordStore.STATE_TRACK_CHANGED:
			return "트랙이 바뀌어 고스트를 쓸 수 없습니다"
		GhostStore.R_MISSING:
			return "고스트 파일이 없어 고스트 없이 달립니다"
		GhostStore.R_MISMATCH:
			return "고스트가 트랙과 맞지 않아 쓰지 않습니다"
	return "고스트 파일을 읽지 못해 고스트 없이 달립니다"


## 재생 중인 고스트(없으면 null). HUD·회귀 검사용 읽기 전용.
func ghost_playback() -> GhostRun:
	return _ghost_play


## 완주 결과와 고스트를 저장하고 결과 화면용 메타를 채운다. 반환: 신기록(저장 성공) 여부.
func _submit_record(result: Dictionary) -> bool:
	var id: String = GameState.track_id
	var diff: String = GameState.difficulty
	var prev: Dictionary = RecordStore.best_for(id, diff)
	var track_changed: bool = RecordStore.track_changed_since_best(id, diff)
	var meta: Dictionary = {
		"steer_expo": Tuning.steer_expo,
		"game_version": LeaderboardClient.GAME_VERSION,
		"fabric": _fabric_id,
	}
	var ghost: Dictionary = _ghost_rec.to_ghost(result, meta)
	var outcome: Dictionary = RecordStore.submit_run(result, ghost, _ghost_rec.skip_reason())
	result["ghost_status"] = outcome["ghost_status"]
	result["ghost_reason"] = outcome["ghost_reason"]
	result["prev_best_ms"] = int(prev.get("final_time_ms", -1)) if not prev.is_empty() else -1
	result["ghost_track_changed"] = track_changed
	result["prev_best_grade"] = RecordStore.grade_of(prev) if not prev.is_empty() else ""
	return bool(outcome["is_best"])
