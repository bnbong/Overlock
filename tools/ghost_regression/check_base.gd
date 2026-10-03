extends Node
## 개인 고스트 회귀 검사 공통 도우미(사본 프로젝트 전용). check_store.gd·check.gd 가 상속한다.
## Gameplay 씬은 루트에 붙이고 자동 물리 처리를 끈 뒤 RaceDirector._physics_process 를 고정 dt 로 직접
## 돌린다(같은 입력이면 같은 결과). user:// 는 run.sh 가 실행마다 만든 격리 디렉터리다.

const GameplayScene: PackedScene = preload("res://scenes/Gameplay.tscn")
const RD: GDScript = preload("res://scripts/systems/RaceDirector.gd")
const DT: float = 1.0 / 60.0
const TRACK: String = "cotton_01"
const DIFF: String = "normal"

var _passed: int = 0
var _failed: int = 0
var _done: Array[String] = []
var _mode: String = "keys"


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("PASS ", msg)
	else:
		_failed += 1
		print("FAIL ", msg)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## 기록·고스트·설정을 모두 지우고 RecordStore 를 빈 상태로 다시 읽는다.
func _reset_store() -> void:
	GhostStore.faults.clear()
	for f in [RecordStore.SAVE_PATH, RecordStore.SETTINGS_PATH, RecordStore.SAVE_PATH + ".tmp"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
	var root: DirAccess = DirAccess.open("user://")
	if root != null:
		for f in root.get_files():
			if f.begins_with("records.json.bak"):
				DirAccess.remove_absolute("user://" + f)
	var dir: DirAccess = DirAccess.open(GhostStore.DIR)
	if dir != null:
		for f in dir.get_files():
			DirAccess.remove_absolute(GhostStore.DIR + f)
	RecordStore._load()
	RecordStore._load_settings()


func _ghost_files() -> Array:
	var out: Array = []
	var dir: DirAccess = DirAccess.open(GhostStore.DIR)
	if dir != null:
		for f in dir.get_files():
			out.append(f)
	out.sort()
	return out


func _write_text(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## 기록용 결과 dict(최소 필드).
func _result(final_ms: int, penalty_ms: int = 0, id: String = TRACK) -> Dictionary:
	return {
		"track_id": id,
		"difficulty": DIFF,
		"finish_ms": final_ms - penalty_ms,
		"penalty_ms": penalty_ms,
		"final_time_ms": final_ms,
		"accuracy": 90.0,
		"perfect_rate": 50.0,
		"cuts": 0,
		"grade": "A",
	}


## 합성 고스트(직선 주행 + 완주). length 진행에 finish_ms 가 걸리는 등속 주행이며 구간은 모두 유효.
func _synthetic_ghost(result: Dictionary, length: float = 1000.0) -> GhostRun:
	var g: GhostRun = GhostRun.new()
	g.setup(length)
	g.begin(Vector2.ZERO, 0.0)
	var finish: float = float(result["finish_ms"]) / 1000.0
	var pen: float = float(result["penalty_ms"]) / 1000.0
	var t: float = 0.0
	while t + DT < finish:
		t += DT
		var s: float = length * t / finish
		g.on_tick(t, Vector2(s, 0.0), 0.0, s, pen * t / finish)
	g.on_finish(result, Vector2(length, 0.0), 0.0, length)
	return g


## Gameplay 를 루트에 붙이고 자동 물리를 끈다. running=true 면 카운트다운을 건너뛰고 첫 주행 틱까지 돈다.
func _new_game(running: bool = true) -> Node:
	get_tree().paused = false
	GameState.track_id = TRACK
	GameState.difficulty = DIFF
	var g: Node = GameplayScene.instantiate()
	get_tree().root.add_child(g)
	await _frames(2)
	g.set_physics_process(false)
	if running:
		g._countdown_time = 0.0001
		_step(g, 1)
	return g


func _free_game(g: Node) -> void:
	get_tree().paused = false
	_release_all()
	if is_instance_valid(g):
		g.queue_free()
	await _frames(2)


func _step(g: Node, n: int = 1, dt: float = DT) -> void:
	for i in n:
		g._physics_process(dt)


func _release_all() -> void:
	for a in RD.GAME_ACTIONS:
		Input.action_release(a)
	Input.flush_buffered_events()


## 결정론 입력 시퀀스(속도 올림·좌우 조향·드리프트).
func _drive_input(t: int) -> void:
	_release_all()
	if t == 5 or t == 7 or t == 9:
		var ev: InputEventAction = InputEventAction.new()
		ev.action = &"speed_up"
		ev.pressed = true
		Input.parse_input_event(ev)
		var up: InputEventAction = InputEventAction.new()
		up.action = &"speed_up"
		up.pressed = false
		Input.parse_input_event(up)
	var phase: int = int(t / 50.0) % 4
	if phase == 1:
		Input.action_press(&"steer_right")
	elif phase == 3:
		Input.action_press(&"steer_left")
	if t >= 220 and t < 250:
		Input.action_press(&"drift")
	Input.flush_buffered_events()


## 같은 입력으로 n 틱 주행한 틱별 상태 기록.
func _drive(g: Node, n: int) -> Array:
	var trace: Array = []
	for t in n:
		_drive_input(t)
		_step(g, 1)
		var p: PlayerController = g._player
		trace.append(
			[
				p.position,
				p.heading,
				p.speed,
				p.risk,
				p.speed_index,
				g._hint,
				g._stats.penalty_time,
				g._stats.cuts,
				g._stats.resets,
				g.item_slots(),
				int(g._state)
			]
		)
	_release_all()
	return trace


## 진행 중인 런을 완주 처리한다(실제 _finish 경로). 결과 dict 를 돌려준다.
func _finish(g: Node) -> Dictionary:
	g._finish()
	return g._pending_result
