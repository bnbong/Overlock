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

# 이산 입력 버퍼 (_unhandled_input에서 세팅, 물리 틱에서 소비).
var _buf_speed_delta: int = 0
var _buf_restart: bool = false
var _buf_pause: bool = false
var _buf_to_menu: bool = false  # 일시정지 중 M(메인 메뉴 복귀) 버퍼. 일시정지 상태에서만 세팅한다.
var _buf_finish_skip: bool = false  # FINISH_VIEW 중 아무 키 입력(스킵) 버퍼.

@onready var _player: PlayerController = $SimHost/FabricSource/World/Player
@onready var _track_renderer: TrackRenderer = $SimHost/FabricSource/World/TrackRenderer
@onready var _finish_line: FinishLine = $SimHost/FabricSource/World/FinishLine
@onready var _stitch: StitchTrail = $SimHost/FabricSource/World/StitchTrail
@onready var _skid: DriftSkid = get_node_or_null("SimHost/FabricSource/World/DriftSkid")
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
	_hud.set_pause_visible(false)
	_hud.show_countdown(ceili(_countdown_time))


func _unhandled_input(event: InputEvent) -> void:
	# 완주 줌아웃 중에는 아무 키 입력이 스킵으로 처리된다(R 재시작·Esc 일시정지 포함).
	# 모션(마우스 이동) 등 비-press 이벤트는 무시한다.
	if _state == State.FINISH_VIEW:
		if event.is_pressed() and not event.is_echo():
			_buf_finish_skip = true
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


func _physics_process(delta: float) -> void:
	if _track == null:
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
	tree.paused = not tree.paused
	_hud.set_pause_visible(tree.paused)


func _restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


## 일시정지 중 M 입력: 런을 파기하고 메인 메뉴로 돌아간다(확인창 없음, 재시작과 동일하게 즉시형).
func _to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _tick_countdown(delta: float) -> void:
	_countdown_time -= delta
	if _countdown_time > 0.0:
		_hud.show_countdown(ceili(_countdown_time))
	else:
		_hud.show_go()
		_state = State.RUNNING


func _tick_running(delta: float) -> void:
	_elapsed += delta
	var input: InputFrame = _sample_input()
	_player.simulate(input, delta)
	var probe: Dictionary = _track.query(_player.position, _hint)
	_hint = int(probe["idx"])
	var err: float = float(probe["error"])
	var band: int = _classify(err)
	# 맵 이탈 소프트 리셋(설계 §B): 정상 밴드(PERFECT/GOOD)에서만 복귀 기준점을 기억하고,
	# 오차가 임계를 RESET_DWELL 이상 지속 초과하면 마지막 정상 지점으로 되돌린 뒤 그 틱을 끝낸다.
	if band == RunStats.Band.PERFECT or band == RunStats.Band.GOOD:
		_last_good_hint = _hint
		_last_good_s = float(probe["s"])
	if err > maxf(RESET_ABS, _track.fail * RESET_FAIL_MULT):
		_offfabric_dwell += delta
		if _offfabric_dwell >= RESET_DWELL:
			_soft_reset_off_fabric()
			return
	else:
		_offfabric_dwell = 0.0
	_stats.accumulate(delta, _player.speed_index, band, err, _player.consume_just_cut())
	_hud.update_frame(_elapsed, _player, _track, float(probe["s"]), band)
	if float(probe["s"]) >= _track.length - FINISH_MARGIN:
		_finish()


## 마지막 정상 지점(센터라인 점 + 진행 방향)으로 플레이어를 되돌리고 페널티를 부과한다.
## _hint를 복원해 다음 query가 그 주변에서 재로컬라이즈하게 함으로써 s가 전진하지 않도록
## 막는다(리셋을 진행 단축에 악용하는 것을 차단). 부상 카운트는 건드리지 않는다.
func _soft_reset_off_fabric() -> void:
	var reset_pos: Vector2 = Vector2.ZERO
	if _track.points.size() > _last_good_hint:
		reset_pos = _track.points[_last_good_hint]
	_player.off_fabric_reset(reset_pos, _heading_at(_last_good_hint))
	_hint = _last_good_hint
	_stats.add_reset_penalty()
	_offfabric_dwell = 0.0


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
	return InputFrame.new(steer, speed_delta, false, drift)


func _classify(err: float) -> int:
	if err <= _track.perfect:
		return RunStats.Band.PERFECT
	if err <= _track.safe:
		return RunStats.Band.GOOD
	if err <= _track.fail:
		return RunStats.Band.OFF_SEAM
	return RunStats.Band.TEAR


func _finish() -> void:
	# 기록·통계는 지금 즉시 확정한다(타이밍 불변). 씬 전환만 FINISH_VIEW로 지연한다.
	var result: Dictionary = _stats.finalize(
		_elapsed, _track.safe, GameState.track_id, GameState.difficulty
	)
	var is_best: bool = RecordStore.submit(result)
	result["is_new_record"] = is_best
	_pending_result = result
	_state = State.FINISH_VIEW
	_finish_view_time = 0.0
	# 잔여 이산 입력 버퍼를 비워 줌아웃 진입 후 스킵/재시작이 섞이지 않게 한다.
	_buf_speed_delta = 0
	_buf_restart = false
	_buf_pause = false
	_buf_to_menu = false
	_buf_finish_skip = false
	if _hud != null:
		_hud.enter_finish_view()
	if _finish_view != null:
		var trail: PackedVector2Array = PackedVector2Array()
		if _stitch != null:
			trail = _stitch.get_full_points()
		# 드리프트 스키드 전체 자국도 줌아웃 뷰에 넘긴다(null-safe, 없으면 빈 배열).
		var skids: Array = _skid.get_full_marks() if _skid != null else []
		_finish_view.begin(_track, trail, _player.position, result, skids)


## 확정된 결과로 Result 씬으로 전환한다(중복 호출 방지 가드).
func _go_to_result() -> void:
	if _state == State.FINISHED:
		return
	_state = State.FINISHED
	GameState.to_result(_pending_result)


func _init_player() -> void:
	var start_pos: Vector2 = Vector2.ZERO
	if _track.points.size() > 0:
		start_pos = _track.points[0]
	_player.reset_state(start_pos, _track.start_heading())
	_hint = 0
	_last_good_hint = 0
	_last_good_s = 0.0
	_offfabric_dwell = 0.0


func _place_finish_line() -> void:
	var count: int = _track.points.size()
	if count >= 2:
		var last: Vector2 = _track.points[count - 1]
		var prev: Vector2 = _track.points[count - 2]
		_finish_line.position = last
		_finish_line.rotation = (last - prev).angle()
		_finish_line.setup(_track.fail)
