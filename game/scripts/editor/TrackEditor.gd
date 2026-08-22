extends Control
## 트랙 에디터 컨트롤러 (track_editor.md §3·§4). 모드 상태기계 · 언두 스택 · 검증
## 호출 · 메타 입력 · 저장 흐름을 소유한다. DrawCanvas는 순수 뷰+입력이라 스트로크
## 데이터(중심선)는 여기서 소유해 언두 일관성을 지킨다.
##
## 흐름: 그리기 → 미리보기 → 최소 편집(지우기/실행취소/닫기) → 검증(게이트) →
## 메타 입력(이름·난이도·원단) → 저장 → 테스트 플레이/메뉴 복귀.
##
## 좌표는 월드 단위. 저장 시 polyline 세그먼트 1개로 직렬화하고 TrackLoader가
## id·checksum·length를 채운다.

# 에디터는 맵 선택 화면("트랙 만들기")에서 진입하므로 뒤로가기도 그 화면으로 돌아간다.
const MENU_SCENE: String = "res://scenes/TrackSelect.tscn"
const SNAP_RADIUS: float = 28.0  # 새 스트로크 시작이 기존 끝점 근처면 이어붙임
const ERASE_RADIUS: float = 22.0  # 지우기 브러시 반경
const TRIM_COUNT: int = 8  # Backspace 끝 트림 점 수
const UNDO_MAX: int = 30
const SUBDIV_STEP: float = 6.0
const FIT_TARGET_LENGTH: float = 3200.0  # "길이 맞추기" 목표

# 난이도 → 폭 프리셋(§4.5). id는 JSON/레코드 키에 쓰는 소문자.
const DIFFS: Array = [
	{"name": "Beginner", "id": "beginner", "perfect": 22.0, "safe": 52.0, "fail": 108.0},
	{"name": "Normal", "id": "normal", "perfect": 18.0, "safe": 42.0, "fail": 90.0},
	{"name": "Expert", "id": "expert", "perfect": 14.0, "safe": 34.0, "fail": 72.0},
	{"name": "Master", "id": "master", "perfect": 12.0, "safe": 28.0, "fail": 60.0},
]
const FABRICS: Array = ["cotton", "denim", "silk", "knit", "wool"]

const OK_COLOR: Color = Color(0.45, 0.92, 0.55, 1.0)
const WARN_COLOR: Color = Color(0.98, 0.72, 0.35, 1.0)
const FAIL_COLOR: Color = Color(0.92, 0.42, 0.42, 1.0)
const NEUTRAL_COLOR: Color = Color(0.968, 0.929, 0.847, 1.0)

var _proc: StrokeProcessor = StrokeProcessor.new()
var _validator: TrackValidator = TrackValidator.new()

var _centerline: PackedVector2Array = PackedVector2Array()
var _closed: bool = false
var _pre_close: PackedVector2Array = PackedVector2Array()
var _undo_stack: Array = []
var _validated: bool = false
var _dirty: bool = false
var _track_id: String = ""
var _saved_id: String = ""
var _confirm: ConfirmationDialog

@onready var _canvas: DrawCanvas = $Canvas
@onready var _mode_draw: Button = $Toolbar/ModeDraw
@onready var _mode_erase: Button = $Toolbar/ModeErase
@onready var _close_toggle: CheckButton = $Toolbar/CloseToggle
@onready var _undo_button: Button = $Toolbar/UndoButton
@onready var _clear_button: Button = $Toolbar/ClearButton
@onready var _autofix_button: Button = $Toolbar/AutoFixButton
@onready var _lengthfit_button: Button = $Toolbar/LengthFitButton
@onready var _validate_button: Button = $Toolbar/ValidateButton
@onready var _status_label: Label = $StatusLabel
@onready var _name_edit: LineEdit = $MetaPanel/Row1/NameEdit
@onready var _diff_option: OptionButton = $MetaPanel/Row1/DifficultyOption
@onready var _fabric_option: OptionButton = $MetaPanel/Row1/FabricOption
@onready var _save_button: Button = $MetaPanel/Row2/SaveButton
@onready var _testplay_button: Button = $MetaPanel/Row2/TestPlayButton
@onready var _import_button: Button = $MetaPanel/Row2/ImportButton
@onready var _back_button: Button = $MetaPanel/Row2/BackButton
@onready var _import_dialog: FileDialog = $ImportDialog


func _ready() -> void:
	_populate_options()
	_wire()
	_style_ui()
	_confirm = ConfirmationDialog.new()
	_confirm.dialog_text = "저장하지 않은 변경이 있습니다. 메뉴로 나갈까요?"
	_confirm.confirmed.connect(_go_menu)
	add_child(_confirm)
	_refresh_widths()
	_after_edit(false)


func _populate_options() -> void:
	for i in range(DIFFS.size()):
		_diff_option.add_item(str(DIFFS[i]["name"]), i)
	_diff_option.select(1)  # Normal
	for i in range(FABRICS.size()):
		_fabric_option.add_item(str(FABRICS[i]), i)
	_fabric_option.select(0)


func _wire() -> void:
	_canvas.stroke_committed.connect(_on_stroke_committed)
	_canvas.erase_begin.connect(_on_erase_begin)
	_canvas.erase_dragged.connect(_on_erase_dragged)
	_mode_draw.pressed.connect(_set_mode.bind(DrawCanvas.Mode.DRAW))
	_mode_erase.pressed.connect(_set_mode.bind(DrawCanvas.Mode.ERASE))
	_close_toggle.toggled.connect(_set_closed)
	_undo_button.pressed.connect(_undo)
	_clear_button.pressed.connect(_clear)
	_autofix_button.pressed.connect(_auto_fix)
	_lengthfit_button.pressed.connect(_length_fit)
	_validate_button.pressed.connect(_validate)
	_diff_option.item_selected.connect(_on_diff_changed)
	_save_button.pressed.connect(_save)
	_testplay_button.pressed.connect(_test_play)
	_back_button.pressed.connect(_on_back)
	# 웹 가드: 로컬 파일 접근이 없어 외부 JSON 불러오기·드래그드롭을 안내로 대체한다
	# (그리기·검증·자동수정·user:// 저장·테스트플레이는 웹에서도 그대로 동작).
	if OS.has_feature("web"):
		_import_button.pressed.connect(_on_web_import_blocked)
	else:
		_import_button.pressed.connect(func() -> void: _import_dialog.popup_centered())
		_import_dialog.file_selected.connect(_import_file)
		get_window().files_dropped.connect(_on_files_dropped)


# --- 편집 조작 ---


func _on_stroke_committed(raw: PackedVector2Array) -> void:
	if raw.size() < 2:
		return
	var seg: PackedVector2Array = _proc.process(raw, false)
	if seg.size() < 2:
		return
	_push_undo()
	if _centerline.size() < 2:
		_centerline = seg
	elif _centerline[_centerline.size() - 1].distance_to(seg[0]) <= SNAP_RADIUS:
		_append_segment(seg)  # 끝점 이어붙임(다중 스트로크)
	else:
		_centerline = seg  # 멀리서 새로 그림 → 교체(단일 스트로크 기본)
	_closed = false
	_close_toggle.set_pressed_no_signal(false)
	_after_edit()


## 기존 중심선 끝점에서 새 세그먼트까지 ≤6px로 이어 붙인다(단일 연속 경로 유지).
func _append_segment(seg: PackedVector2Array) -> void:
	var endp: Vector2 = _centerline[_centerline.size() - 1]
	for p in _subdivide(endp, seg[0], SUBDIV_STEP):
		_centerline.append(p)
	for k in range(1, seg.size()):
		_centerline.append(seg[k])


func _on_erase_begin() -> void:
	if _centerline.size() >= 2:
		_push_undo()


## 지우기: 브러시가 처음 닿는 점 이후를 잘라낸다(단일 경로 안전 트림).
func _on_erase_dragged(world_pos: Vector2) -> void:
	if _centerline.size() < 2:
		return
	var hit: int = -1
	for i in range(_centerline.size()):
		if _centerline[i].distance_to(world_pos) <= ERASE_RADIUS:
			hit = i
			break
	if hit < 0:
		return
	_centerline = _centerline.slice(0, hit)
	_closed = false
	_close_toggle.set_pressed_no_signal(false)
	_after_edit()


func _set_mode(m: int) -> void:
	_canvas.set_mode(m)
	_mode_draw.set_pressed_no_signal(m == DrawCanvas.Mode.DRAW)
	_mode_erase.set_pressed_no_signal(m == DrawCanvas.Mode.ERASE)


func _set_closed(on: bool) -> void:
	if on:
		if _centerline.size() < 3:
			_close_toggle.set_pressed_no_signal(false)
			return
		_push_undo()
		_pre_close = _centerline.duplicate()
		_centerline = _proc.apply_close_gap(_centerline, _preset()["fail"])
		_closed = true
	else:
		if _pre_close.size() >= 2:
			_push_undo()
			_centerline = _pre_close.duplicate()
		_closed = false
	_after_edit()


func _clear() -> void:
	if _centerline.is_empty():
		return
	_push_undo()
	_centerline = PackedVector2Array()
	_closed = false
	_close_toggle.set_pressed_no_signal(false)
	_after_edit()


func _trim_end() -> void:
	if _centerline.size() <= 2:
		return
	_push_undo()
	_centerline = _centerline.slice(0, maxi(0, _centerline.size() - TRIM_COUNT))
	_after_edit()


func _push_undo() -> void:
	_undo_stack.append(
		{"line": _centerline.duplicate(), "closed": _closed, "pre_close": _pre_close.duplicate()}
	)
	if _undo_stack.size() > UNDO_MAX:
		_undo_stack.remove_at(0)


func _undo() -> void:
	if _undo_stack.is_empty():
		return
	var snap: Dictionary = _undo_stack.pop_back()
	_centerline = snap["line"]
	_closed = snap["closed"]
	_pre_close = snap["pre_close"]
	_close_toggle.set_pressed_no_signal(_closed)
	_after_edit(false)


# --- 검증 / 자동수정 / 길이맞추기 ---


func _validate() -> void:
	if _centerline.size() < 2:
		_set_status("트랙을 먼저 그리세요.", NEUTRAL_COLOR)
		return
	var res: Dictionary = _validator.validate(_centerline, _preset()["fail"])
	_canvas.set_markers(res["curvature"], res["proximity"])
	_validated = bool(res["ok"])
	_save_button.disabled = not _validated
	_autofix_button.disabled = not _has_hard_curvature(res)
	if _validated:
		var extra: String = ""
		if int(res["soft"]) > 0:
			extra = "  (경고 %d)" % int(res["soft"])
		var min_r: float = float(res["min_radius"])
		var rtxt: String = "∞" if min_r == INF else str(int(min_r))
		_set_status(
			"검증 통과 — 길이 %dpx · 최소반경 %spx%s" % [int(res["length"]), rtxt, extra], OK_COLOR
		)
	else:
		_set_status("검증 실패 — " + "  ·  ".join(res["messages"]), FAIL_COLOR)


func _auto_fix() -> void:
	if _centerline.size() < 5:
		return
	_push_undo()
	_centerline = _proc.relax_curvature(_centerline, TrackValidator.MIN_RADIUS)
	_after_edit()
	_validate()


func _length_fit() -> void:
	if _centerline.size() < 2:
		return
	var cur_len: float = _current_length()
	if cur_len < 1.0:
		return
	_push_undo()
	_centerline = _proc.scale_about_centroid(_centerline, FIT_TARGET_LENGTH / cur_len)
	_after_edit()
	_validate()


func _has_hard_curvature(res: Dictionary) -> bool:
	for v in res["curvature"]:
		if str(v["kind"]) == "hard":
			return true
	return false


# --- 메타 / 저장 / 플레이 ---


func _on_diff_changed(_idx: int) -> void:
	_refresh_widths()
	# fail 임계가 바뀌면 자기근접 판정도 바뀌므로 재검증을 요구한다.
	_invalidate()


func _save() -> void:
	if not _validated:
		return
	var dict: Dictionary = _build_track_dict()
	var id: String = TrackLoader.save_custom_track(dict)
	if id == "":
		_set_status("저장 실패 (파일 쓰기 오류)", FAIL_COLOR)
		return
	_track_id = id
	_saved_id = id
	_dirty = false
	_testplay_button.disabled = false
	_set_status("저장됨: %s  (%s)" % [_track_name(), id], OK_COLOR)


func _test_play() -> void:
	if _saved_id == "":
		return
	GameState.start_run(_saved_id, str(_preset()["id"]))


func _build_track_dict() -> Dictionary:
	var pts: Array = []
	for p in _centerline:
		pts.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
	var preset: Dictionary = _preset()
	return {
		"track_id": _track_id,
		"name": _track_name(),
		"difficulty": str(preset["id"]),
		"fabric": FABRICS[_fabric_option.get_selected_id()],
		"width":
		{"perfect": preset["perfect"], "safe": preset["safe"], "fail": preset["fail"]},
		"path": [{"type": "polyline", "points": pts, "closed": _closed}],
		"modifiers": [],
	}


func _track_name() -> String:
	var n: String = _name_edit.text.strip_edges()
	return n if not n.is_empty() else "Custom Track"


# --- 불러오기 ---


## 웹(HTML5)에서 외부 파일 불러오기 요청을 안내로 대체한다(Phase 2 예정).
func _on_web_import_blocked() -> void:
	_set_status("웹에서는 트랙 파일 불러오기 미지원 (Phase 2)", NEUTRAL_COLOR)


func _import_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		_set_status("파일 없음: " + path, FAIL_COLOR)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_set_status("파일 열기 실패", FAIL_COLOR)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		_set_status("JSON 파싱 실패", FAIL_COLOR)
		return
	var dict: Dictionary = parsed
	var td: TrackData = TrackData.new()
	td.bake(dict.get("path", []))
	if td.points.size() < 2:
		_set_status("경로가 비어있음", FAIL_COLOR)
		return
	_push_undo()
	_centerline = td.points.duplicate()
	_track_id = ""  # 로컬 새 id 부여(§8)
	_saved_id = ""
	_name_edit.text = str(dict.get("name", "Imported"))
	_select_difficulty(str(dict.get("difficulty", "normal")))
	_select_fabric(str(dict.get("fabric", "cotton")))
	_closed = false
	_close_toggle.set_pressed_no_signal(false)
	_after_edit()
	_validate()


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.ends_with(".json"):
			_import_file(f)
			return


func _select_difficulty(id: String) -> void:
	for i in range(DIFFS.size()):
		if str(DIFFS[i]["id"]) == id:
			_diff_option.select(i)
			break
	_refresh_widths()


func _select_fabric(name: String) -> void:
	for i in range(FABRICS.size()):
		if str(FABRICS[i]) == name:
			_fabric_option.select(i)
			return


# --- 공통 ---


func _preset() -> Dictionary:
	return DIFFS[clampi(_diff_option.get_selected_id(), 0, DIFFS.size() - 1)]


func _refresh_widths() -> void:
	var p: Dictionary = _preset()
	_canvas.set_track(_centerline, p["perfect"], p["safe"], p["fail"])


func _current_length() -> float:
	var total: float = 0.0
	for i in range(1, _centerline.size()):
		total += _centerline[i - 1].distance_to(_centerline[i])
	return total


## 편집 후 공통 갱신: 뷰 반영 + 검증 게이트 초기화.
func _after_edit(mark_dirty: bool = true) -> void:
	_refresh_widths()
	_undo_button.disabled = _undo_stack.is_empty()
	_lengthfit_button.disabled = _centerline.size() < 2
	if mark_dirty:
		_dirty = true
	_invalidate()


## 중심선/난이도가 바뀌면 저장 게이트를 잠그고 마커를 지운다(재검증 필요).
func _invalidate() -> void:
	_validated = false
	_save_button.disabled = true
	_testplay_button.disabled = true
	_autofix_button.disabled = true
	_canvas.clear_markers()
	if _centerline.size() >= 2:
		_set_status("검증하려면 '검증'(Enter)을 누르세요.", NEUTRAL_COLOR)
	else:
		_set_status("좌클릭 드래그로 트랙을 그리세요. 중클릭=이동, 휠=줌.", NEUTRAL_COLOR)


func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)


func _on_back() -> void:
	if _dirty and _centerline.size() >= 2:
		_confirm.popup_centered()
	else:
		_go_menu()


func _go_menu() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


static func _subdivide(a: Vector2, b: Vector2, step: float) -> PackedVector2Array:
	# a 제외, b 포함. a==b면 [b].
	var out: PackedVector2Array = PackedVector2Array()
	var d: float = a.distance_to(b)
	var n: int = maxi(1, ceili(d / step))
	for m in range(1, n + 1):
		out.append(a.lerp(b, float(m) / float(n)))
	return out


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo:
		return
	# 텍스트 입력 중에는 편집 단축키를 가로채지 않는다.
	var focus: Control = get_viewport().gui_get_focus_owner()
	var typing: bool = focus is LineEdit
	if key.keycode == KEY_Z and key.ctrl_pressed:
		_undo()
		get_viewport().set_input_as_handled()
		return
	if typing:
		return
	match key.keycode:
		KEY_C:
			_set_closed(not _closed)
			_close_toggle.set_pressed_no_signal(_closed)
			get_viewport().set_input_as_handled()
		KEY_BACKSPACE:
			_trim_end()
			get_viewport().set_input_as_handled()
		KEY_DELETE:
			_clear()
			get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER:
			_validate()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			_on_back()
			get_viewport().set_input_as_handled()


func _style_ui() -> void:
	var buttons: Array = [
		_mode_draw,
		_mode_erase,
		_undo_button,
		_clear_button,
		_autofix_button,
		_lengthfit_button,
		_validate_button,
		_save_button,
		_testplay_button,
		_import_button,
		_back_button,
	]
	# 에디터 툴바는 좁은 텍스트 버튼이 많아 시트의 필 버튼(양끝 단추 캡)이 텍스트를
	# 밀어내므로 절차 스킨을 유지한다(시트 필 버튼은 폭이 넉넉한 버튼에만 적합).
	for b in buttons:
		_skin_button(b)
	_skin_option(_diff_option)
	_skin_option(_fabric_option)
	_status_label.add_theme_color_override("font_color", NEUTRAL_COLOR)


func _skin_button(b: Button) -> void:
	b.add_theme_color_override("font_color", Color(0.278, 0.203, 0.153))
	b.add_theme_color_override("font_hover_color", Color(0.2, 0.14, 0.1))
	b.add_theme_color_override("font_pressed_color", Color(0.2, 0.14, 0.1))
	b.add_theme_color_override("font_focus_color", Color(0.2, 0.14, 0.1))
	b.add_theme_color_override("font_disabled_color", Color(0.5, 0.44, 0.36))
	_skin_control(b)
	b.add_theme_stylebox_override(
		"disabled", _box(Color(0.6, 0.55, 0.47, 0.6), Color(0.45, 0.4, 0.34))
	)


func _skin_option(o: OptionButton) -> void:
	o.add_theme_color_override("font_color", Color(0.278, 0.203, 0.153))
	_skin_control(o)


## normal/hover/pressed/focus 스타일박스를 공통 적용(버튼·옵션버튼 공유).
func _skin_control(c: Control) -> void:
	c.add_theme_stylebox_override(
		"normal", _box(Color(0.831, 0.753, 0.6), Color(0.553, 0.384, 0.725))
	)
	c.add_theme_stylebox_override(
		"hover", _box(Color(0.906, 0.835, 0.686), Color(0.616, 0.435, 0.784))
	)
	c.add_theme_stylebox_override(
		"pressed", _box(Color(0.761, 0.682, 0.541), Color(0.478, 0.333, 0.243))
	)
	c.add_theme_stylebox_override(
		"focus", _box(Color(0.906, 0.835, 0.686), Color(0.831, 0.278, 0.263), 3)
	)


static func _box(bg: Color, border: Color, bw: int = 2) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb
