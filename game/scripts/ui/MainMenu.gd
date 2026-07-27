extends Control
## 메인 메뉴. 트랙 선택(◀▶ 버튼 / 키보드 ←→), 트랙명·난이도·길이·로컬 최고
## 기록 표시, 선택 트랙의 실루엣 미리보기, Start/Quit (아키텍처 §2.1).
##
## 트랙 모양 자체가 셀링 포인트이므로 선택된 트랙의 베이크된 폴리라인을
## 작은 미리보기 패널에 실루엣으로 그린다(TrackData 베이크 재사용). 미리보기는
## 별도 스크립트 노드 대신 Preview 컨트롤의 draw 시그널에 그려 넣는다.

const DEFAULT_TRACK: String = "cotton_01"

var _tracks: Array = []
var _index: int = 0

@onready var _preview: Control = $Menu/Preview
@onready var _track_label: Label = $Menu/Selector/TrackLabel
@onready var _prev_button: Button = $Menu/Selector/PrevButton
@onready var _next_button: Button = $Menu/Selector/NextButton
@onready var _info_label: Label = $Menu/InfoLabel
@onready var _best_time_label: Label = $Menu/BestTimeLabel
@onready var _start_button: Button = $Menu/StartButton
@onready var _quit_button: Button = $Menu/QuitButton


func _ready() -> void:
	_tracks = TrackLoader.list_tracks()
	if _tracks.is_empty():
		_tracks = [{"track_id": DEFAULT_TRACK, "name": "Cotton Warm-up", "difficulty": "normal"}]
	_index = 0
	_preview.draw.connect(_on_preview_draw)
	_preview.resized.connect(_preview.queue_redraw)
	_prev_button.pressed.connect(_cycle.bind(-1))
	_next_button.pressed.connect(_cycle.bind(1))
	_start_button.pressed.connect(_on_start_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_refresh()
	_start_button.grab_focus()


## ←/→(및 A/D)로 트랙을 순환한다. GUI 포커스 이동보다 먼저 소비한다.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_LEFT, KEY_A:
			_cycle(-1)
			get_viewport().set_input_as_handled()
		KEY_RIGHT, KEY_D:
			_cycle(1)
			get_viewport().set_input_as_handled()


func _cycle(dir: int) -> void:
	if _tracks.size() <= 1:
		return
	_index = wrapi(_index + dir, 0, _tracks.size())
	_refresh()


func _current_id() -> String:
	if _tracks.is_empty():
		return DEFAULT_TRACK
	return str(_tracks[_index].get("track_id", DEFAULT_TRACK))


func _current_difficulty() -> String:
	var entry: Dictionary = _tracks[_index]
	var diff: String = str(entry.get("difficulty", "normal"))
	# 트랙 JSON의 난이도를 우선(권위 있는 값).
	var track: TrackData = TrackLoader.load_track(_current_id())
	if track != null and track.difficulty != "":
		diff = track.difficulty
	return diff


func _refresh() -> void:
	var entry: Dictionary = _tracks[_index]
	var id: String = str(entry.get("track_id", DEFAULT_TRACK))
	var track: TrackData = TrackLoader.load_track(id)
	var disp_name: String = str(entry.get("name", id))
	var diff: String = str(entry.get("difficulty", "normal"))
	var length_px: int = 0
	if track != null:
		if track.track_name != "":
			disp_name = track.track_name
		if track.difficulty != "":
			diff = track.difficulty
		length_px = int(round(track.length))
	_track_label.text = disp_name
	_info_label.text = "%s    %d px    (%d / %d)" % [
		diff.to_upper(), length_px, _index + 1, _tracks.size()
	]
	_update_best(id, diff)
	_preview.queue_redraw()


func _update_best(id: String, diff: String) -> void:
	var best: Dictionary = RecordStore.best_for(id, diff)
	if best.is_empty():
		_best_time_label.text = "Best: --:--.---"
	else:
		_best_time_label.text = "Best: " + _format_ms(int(best.get("final_time_ms", 0)))


func _on_start_pressed() -> void:
	GameState.start_run(_current_id(), _current_difficulty())


func _on_quit_pressed() -> void:
	get_tree().quit()


## Preview 컨트롤의 draw 시그널 핸들러. 선택 트랙의 베이크 폴리라인을 패널에
## 맞춰 축소해 실루엣으로 그린다(시작점은 초록 마커).
func _on_preview_draw() -> void:
	var rect: Vector2 = _preview.size
	_preview.draw_rect(Rect2(Vector2.ZERO, rect), Color(0.08, 0.07, 0.11, 1.0))
	_preview.draw_rect(Rect2(Vector2.ZERO, rect), Color(0.32, 0.24, 0.44, 1.0), false, 2.0)
	var track: TrackData = TrackLoader.load_track(_current_id())
	if track == null or track.points.size() < 2:
		return
	var pts: PackedVector2Array = track.points
	var mn: Vector2 = pts[0]
	var mx: Vector2 = pts[0]
	for p in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	var span: Vector2 = mx - mn
	span.x = maxf(span.x, 1.0)
	span.y = maxf(span.y, 1.0)
	var pad: float = 18.0
	var sc: float = minf((rect.x - pad * 2.0) / span.x, (rect.y - pad * 2.0) / span.y)
	var off: Vector2 = (rect - span * sc) * 0.5 - mn * sc
	var mapped: PackedVector2Array = PackedVector2Array()
	for p in pts:
		mapped.append(p * sc + off)
	_preview.draw_polyline(mapped, Color(0.80, 0.62, 1.0, 0.95), 2.0)
	_preview.draw_circle(pts[0] * sc + off, 4.0, Color(0.42, 0.86, 0.42, 1.0))


static func _format_ms(ms: int) -> String:
	var minutes: int = ms / 60000
	var secs: int = (ms / 1000) % 60
	var millis: int = ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]
