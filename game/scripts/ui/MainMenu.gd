extends Control
## 메인 메뉴. 트랙 선택(◀▶ 버튼 / 키보드 ←→), 트랙명·난이도·길이·로컬 최고
## 기록 표시, 선택 트랙의 실루엣 미리보기, Start/Quit (아키텍처 §2.1).
##
## 트랙 모양 자체가 셀링 포인트이므로 선택된 트랙의 베이크된 폴리라인을
## 작은 미리보기 패널에 실루엣으로 그린다(TrackData 베이크 재사용). 미리보기는
## 별도 스크립트 노드 대신 Preview 컨트롤의 draw 시그널에 그려 넣는다.

const DEFAULT_TRACK: String = "cotton_01"
const EDITOR_SCENE: String = "res://scenes/TrackEditor.tscn"

# --- 미리보기 패널 스타일(재봉 스킨 톤). 실루엣(밝은 라벤더)의 가독성을 지키려면
# 배경은 계속 어두워야 하므로 베이지 패치 대신 어두운 잉크 패널 + 박음질 테두리를 쓴다.
const _PREVIEW_BG_COLOR: Color = Color(0.16, 0.11, 0.10, 1.0)
const _PREVIEW_RADIUS: float = 10.0
const _PREVIEW_STITCH_INSET: float = 6.0

var _tracks: Array = []
var _index: int = 0
var _confirm: ConfirmationDialog

@onready var _preview: Control = $Menu/Preview
@onready var _track_label: Label = $Menu/Selector/TrackLabel
@onready var _prev_button: Button = $Menu/Selector/PrevButton
@onready var _next_button: Button = $Menu/Selector/NextButton
@onready var _info_label: Label = $Menu/InfoLabel
@onready var _best_time_label: Label = $Menu/BestTimeLabel
@onready var _start_button: Button = $Menu/StartButton
@onready var _quit_button: Button = $Menu/QuitButton
@onready var _create_button: Button = $Menu/EditorRow/CreateButton
@onready var _import_button: Button = $Menu/EditorRow/ImportButton
@onready var _delete_button: Button = $Menu/EditorRow/DeleteButton
@onready var _import_dialog: FileDialog = $ImportDialog


func _ready() -> void:
	_rebuild_tracks()
	_index = 0
	_preview.draw.connect(_on_preview_draw)
	_preview.resized.connect(_preview.queue_redraw)
	_prev_button.pressed.connect(_cycle.bind(-1))
	_next_button.pressed.connect(_cycle.bind(1))
	_start_button.pressed.connect(_on_start_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_create_button.pressed.connect(_on_create_pressed)
	_import_button.pressed.connect(func() -> void: _import_dialog.popup_centered())
	_delete_button.pressed.connect(_on_delete_pressed)
	_import_dialog.file_selected.connect(_on_import_selected)
	get_window().files_dropped.connect(_on_files_dropped)
	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_do_delete)
	add_child(_confirm)
	for b in [_create_button, _import_button, _delete_button]:
		_skin_button(b)
	_refresh()
	_start_button.grab_focus()


## 재봉 스킨 톤 버튼 스타일(신규 EditorRow 버튼을 기존 메뉴와 통일).
func _skin_button(b: Button) -> void:
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", Color(0.278, 0.203, 0.153))
	b.add_theme_color_override("font_hover_color", Color(0.2, 0.14, 0.1))
	b.add_theme_color_override("font_pressed_color", Color(0.2, 0.14, 0.1))
	b.add_theme_stylebox_override(
		"normal", _box(Color(0.831, 0.753, 0.6), Color(0.553, 0.384, 0.725))
	)
	b.add_theme_stylebox_override(
		"hover", _box(Color(0.906, 0.835, 0.686), Color(0.616, 0.435, 0.784))
	)
	b.add_theme_stylebox_override(
		"pressed", _box(Color(0.761, 0.682, 0.541), Color(0.478, 0.333, 0.243))
	)
	b.add_theme_stylebox_override(
		"focus", _box(Color(0.906, 0.835, 0.686), Color(0.831, 0.278, 0.263), 3)
	)


static func _box(bg: Color, border: Color, bw: int = 2) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


## 공식(res://) + 커스텀(user:// 디렉토리 스캔) 트랙 목록을 합친다. 커스텀 항목은
## is_custom=true 태그가 붙어 있어 기존 ◀▶ 셀렉터가 그대로 순환한다(§7.5).
func _rebuild_tracks() -> void:
	_tracks = TrackLoader.list_tracks().duplicate(true)
	_tracks += TrackLoader.list_custom_tracks()
	if _tracks.is_empty():
		_tracks = [{"track_id": DEFAULT_TRACK, "name": "Cotton Warm-up", "difficulty": "normal"}]


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
	var is_custom: bool = bool(entry.get("is_custom", false))
	_track_label.text = disp_name
	var badge: String = "CUSTOM · " if is_custom else ""
	_info_label.text = "%s%s    %d px    (%d / %d)" % [
		badge, diff.to_upper(), length_px, _index + 1, _tracks.size()
	]
	_delete_button.visible = is_custom
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


func _on_create_pressed() -> void:
	get_tree().change_scene_to_file(EDITOR_SCENE)


## 삭제 확인 → 파일 삭제 + 로컬 기록 정리 + 목록 재구성(§7.4).
func _on_delete_pressed() -> void:
	if _tracks.is_empty():
		return
	var entry: Dictionary = _tracks[_index]
	if not bool(entry.get("is_custom", false)):
		return
	_confirm.dialog_text = "'%s' 커스텀 트랙을 삭제할까요?" % str(entry.get("name", ""))
	_confirm.popup_centered()


func _do_delete() -> void:
	var entry: Dictionary = _tracks[_index]
	var id: String = str(entry.get("track_id", ""))
	if not TrackLoader.delete_custom_track(id):
		_info_label.text = "삭제 실패"
		return
	RecordStore.purge(id)
	_rebuild_tracks()
	_index = clampi(_index, 0, _tracks.size() - 1)
	_refresh()


## 외부 JSON 불러오기(데스크톱 다이얼로그). 파싱 → 폴리라인 베이크 → 검증 →
## 로컬 새 id로 저장(§8). 중복(checksum)이면 스킵. 검증 실패면 거부 + 사유 표시.
func _on_import_selected(path: String) -> void:
	var msg: String = _import_track(path)
	if not msg.is_empty():
		_info_label.text = msg


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.ends_with(".json"):
			var msg: String = _import_track(f)
			if not msg.is_empty():
				_info_label.text = msg
			return


## 불러오기 실행. 실패 시 사유 문자열, 성공 시 빈 문자열 반환.
func _import_track(path: String) -> String:
	var loaded: Dictionary = _read_track_file(path)
	if not str(loaded.get("error", "")).is_empty():
		return str(loaded["error"])
	var td: TrackData = loaded["td"]
	var dict: Dictionary = loaded["dict"]
	var width: Dictionary = dict.get("width", {})
	var res: Dictionary = TrackValidator.new().validate(td.points, float(width.get("fail", 90.0)))
	if not bool(res["ok"]):
		return "검증 실패: " + "  ·  ".join(res["messages"])
	# 폴리라인으로 정규화(공식=bezier 파일도 커스텀은 polyline로 저장) + 로컬 새 id.
	var pts: Array = []
	for p in td.points:
		pts.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
	var out: Dictionary = {
		"track_id": "",
		"name": str(dict.get("name", "Imported")),
		"difficulty": str(dict.get("difficulty", "normal")),
		"fabric": str(dict.get("fabric", "cotton")),
		"width": width if not width.is_empty() else {"perfect": 18, "safe": 42, "fail": 90},
		"path": [{"type": "polyline", "points": pts, "closed": false}],
		"modifiers": [],
	}
	var existing: String = TrackLoader.find_by_checksum(TrackLoader.compute_checksum(out["path"]))
	if not existing.is_empty():
		_rebuild_tracks()
		_select_track(existing)
		return "이미 있음: " + str(dict.get("name", ""))
	var id: String = TrackLoader.save_custom_track(out)
	if id.is_empty():
		return "저장 실패"
	_rebuild_tracks()
	_select_track(id)
	return ""


## 파일 읽기 + JSON 파싱 + 폴리라인 베이크. {error, td, dict} 반환.
func _read_track_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "파일 없음"}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "파일 열기 실패"}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return {"error": "JSON 파싱 실패"}
	var dict: Dictionary = parsed
	var td: TrackData = TrackData.new()
	td.bake(dict.get("path", []))
	if td.points.size() < 2:
		return {"error": "불러오기 실패: 경로 없음"}
	return {"error": "", "td": td, "dict": dict}


func _select_track(track_id: String) -> void:
	for i in range(_tracks.size()):
		if str(_tracks[i].get("track_id", "")) == track_id:
			_index = i
			break
	_refresh()


## Preview 컨트롤의 draw 시그널 핸들러. 선택 트랙의 베이크 폴리라인을 패널에
## 맞춰 축소해 실루엣으로 그린다(시작점은 초록 마커).
func _on_preview_draw() -> void:
	var rect: Vector2 = _preview.size
	var patch_rect: Rect2 = Rect2(Vector2.ZERO, rect)
	SewingSkin.draw_patch(_preview, patch_rect, _PREVIEW_BG_COLOR, _PREVIEW_RADIUS, false)
	var track: TrackData = TrackLoader.load_track(_current_id())
	if track != null and track.points.size() >= 2:
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
	SewingSkin.draw_stitch_border(
		_preview, patch_rect, SewingSkin.THREAD_PURPLE, _PREVIEW_STITCH_INSET, _PREVIEW_RADIUS
	)


static func _format_ms(ms: int) -> String:
	var minutes: int = ms / 60000
	var secs: int = (ms / 1000) % 60
	var millis: int = ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]
