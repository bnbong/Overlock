extends Control
## 트랙 에디터 컨트롤러 (track_editor.md §3·§4, track-editor-ux 1·5·6단계). 편집 문서·undo/redo·
## dirty·검증 게이트·메타 입력·저장·불러오기·테스트 플레이 흐름을 소유한다. DrawCanvas는 순수
## 뷰+입력이라 문서 데이터는 여기서 소유해 undo 일관성을 지킨다.
##
## 상태 구분:
##  - 편집 문서(_doc, EditorDoc 참고): 경로·closed/pre_close·이름·난이도·원단·폭·아이템·로컬 id.
##    undo/redo는 문서 전체를 한 단위로 보관한다(최대 UNDO_MAX, 연속 이름 입력은 한 단위로 묶음).
##  - 저장 기준(_saved_serials): 문서 계보(doc_key)별 마지막 저장 직렬화. dirty = 현재 문서 직렬화와 비교.
##  - 검증 기준(_validated_geom): 검증을 통과한 경로+판정 폭 키. 이름·원단 변경은 검증을 유지한다.
##  - 화면 상태: zoom/pan(DrawCanvas)·선택 도구·선택 아이템. 문서가 아니라 undo·dirty 대상이 아니다.
##  - 틈(_doc["gap"]): 구간 지우기(EditorEraseTool)로 경로 중간을 지운 상태. 문서의 일부라 undo·dirty·
##    테스트 복귀 스냅샷에 포함되며, 이어질 때까지 검증·저장·테스트를 막는다.
##
## 테스트 플레이: 유효한 문서에서 누르면(미저장이면 "저장 후 테스트") 문서·저장 기준·undo/redo·
## 화면 상태를 GameState.editor_session에 맡기고 editor_test 출처로 Gameplay에 들어간다. 결과·일시정지의
## "편집으로 돌아가기"로 이 씬이 다시 열리면 스냅샷을 복원한다(메모리 전용, 앱 재실행 복구 아님).
##
## 좌표는 월드 단위. 저장 시 polyline 세그먼트 1개로 직렬화하고 TrackLoader가
## id·checksum·length를 채운다.

# 에디터는 맵 선택 화면("트랙 만들기")에서 진입하므로 뒤로가기도 그 화면으로 돌아간다.
const MENU_SCENE: String = "res://scenes/TrackSelect.tscn"
# 히트 영역: 화면 px 여유를 현재 배율의 월드 거리로 환산하되 월드 최소값 아래로 내려가지 않는다
# (최대 줌아웃 0.15에서 SNAP 24px ≈ 160 월드, zoom 1.0에서는 월드 최소값 28/22).
const SNAP_RADIUS: float = 28.0  # 새 스트로크 시작이 기존 끝점 근처여야 이어 그린다(월드 최소)
const SNAP_PX: float = 24.0
const TRIM_RADIUS: float = 22.0  # 끝부분 자르기 판정 반경(월드 최소)
const TRIM_PX: float = 18.0
const TRIM_COUNT: int = 8  # Backspace 끝 트림 점 수
const UNDO_MAX: int = 30
const SUBDIV_STEP: float = 6.0

const OK_COLOR: Color = Color(0.45, 0.92, 0.55, 1.0)
const FAIL_COLOR: Color = Color(0.92, 0.42, 0.42, 1.0)
const WARN_COLOR: Color = Color(0.98, 0.78, 0.40, 1.0)
const NEUTRAL_COLOR: Color = Color(0.968, 0.929, 0.847, 1.0)

var _proc: StrokeProcessor = StrokeProcessor.new()
var _validator: TrackValidator = TrackValidator.new()

var _doc: Dictionary = {}
var _undo_stack: Array = []
var _redo_stack: Array = []
var _saved_serials: Dictionary = {}  # doc_key -> 마지막 저장 serial
var _next_doc_key: int = 1
var _validated_geom: String = ""  # 검증 통과한 geom_key(없으면 "")
var _shown_geom: String = ""  # 현재 마커·상태 문구가 가리키는 geom_key
var _last_edit: String = ""  # 직전 undo 단위 종류(연속 이름 입력 묶기)
var _trim_tool: EditorTrimTool
var _erase_tool: EditorEraseTool  # 구간 지우기와 틈 잇기(v2.2.1)
var _hint_restore: Array = []  # 자르기 미리보기 안내 전 상태 문구 [text, color](안내 중일 때만)
var _selected_item: int = -1  # 선택 아이템(배치 도구는 뒤 단계, 화면 상태로만 보관)
var _pending: Callable = Callable()  # 확인창 확인 시 실행할 동작
var _confirm: ConfirmationDialog
var _length_dialog: EditorLengthDialog
var _item_tool: EditorItemTool
var _issues: Array = []  # 마지막 검증의 항목별 안내(EditorIssues.build)
var _issues_collapsed: bool = false
# 웹 전용 파일 브리지(업로드). 데스크톱에서는 null(FileDialog·드래그드롭을 씀).
var _web_bridge: WebFileBridge
var _fabric_note: Label  # 원단 견본 옆 주행 특성 문구(EditorSession.add_fabric_note)

@onready var _canvas: DrawCanvas = $Canvas
@onready var _mode_draw: Button = $Toolbar/ModeDraw
@onready var _mode_pan: Button = $Toolbar/ModePan
@onready var _mode_trim: Button = $Toolbar/ModeTrim
@onready var _mode_erase: Button = $Toolbar/ModeErase
@onready var _mode_item: Button = $Toolbar/ModeItem
@onready var _fabric_swatch: TextureRect = $MetaPanel/Row1/FabricSwatch
@onready var _close_toggle: CheckButton = $Toolbar/CloseToggle
@onready var _undo_button: Button = $Toolbar/UndoButton
@onready var _redo_button: Button = $Toolbar/RedoButton
@onready var _new_button: Button = $MetaPanel/Row2/NewDrawButton
@onready var _autofix_button: Button = $Toolbar/AutoFixButton
@onready var _length_button: Button = $Toolbar/LengthButton
@onready var _zoom_out_button: Button = $ViewBar/ZoomOutButton
@onready var _zoom_in_button: Button = $ViewBar/ZoomInButton
@onready var _zoom_label: Label = $ViewBar/ZoomLabel
@onready var _fit_button: Button = $ViewBar/FitButton
@onready var _review_row: HBoxContainer = $ReviewRow
@onready var _review_label: Label = $ReviewRow/ReviewLabel
@onready var _review_button: Button = $ReviewRow/ReviewConfirmButton
@onready var _validate_button: Button = $Toolbar/ValidateButton
@onready var _status_label: Label = $StatusLabel
@onready var _name_edit: LineEdit = $MetaPanel/Row1/NameEdit
@onready var _diff_option: OptionButton = $MetaPanel/Row1/DifficultyOption
@onready var _width_label: Label = $MetaPanel/Row1/WidthLabel
@onready var _fabric_option: OptionButton = $MetaPanel/Row1/FabricOption
@onready var _save_button: Button = $MetaPanel/Row2/SaveButton
@onready var _testplay_button: Button = $MetaPanel/Row2/TestPlayButton
@onready var _import_button: Button = $MetaPanel/Row2/ImportButton
@onready var _doc_state_label: Label = $MetaPanel/Row2/DocStateLabel
@onready var _back_button: Button = $MetaPanel/Row2/BackButton
@onready var _import_dialog: FileDialog = $ImportDialog


func _ready() -> void:
	EditorSession.populate_options(_diff_option, _fabric_option)
	_fabric_note = EditorSession.add_fabric_note($MetaPanel/Row1, _fabric_option)
	_fabric_swatch.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_item_tool = EditorItemTool.new(self)
	_trim_tool = EditorTrimTool.new(self)
	_erase_tool = EditorEraseTool.new(self)
	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_on_confirm_ok)
	_confirm.canceled.connect(_on_confirm_cancel)
	add_child(_confirm)
	_length_dialog = EditorLengthDialog.new()
	_length_dialog.preview_changed.connect(_canvas.set_preview)
	_length_dialog.confirmed.connect(_on_length_confirmed)
	_length_dialog.canceled.connect(_canvas.set_preview.bind(PackedVector2Array()))
	add_child(_length_dialog)
	_wire()
	EditorSkin.setup_chrome(self)
	_status_label.add_theme_color_override("font_color", NEUTRAL_COLOR)
	# 테스트 플레이(인게임 곡)·결과(BGM 정지)에서 돌아와도 메뉴 곡으로 맞춘다(같은 곡이면 유지).
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null and am.has_method("play_bgm"):
		am.play_bgm("menu")
	if GameState.has_editor_session():
		_restore_session(GameState.editor_session)
		GameState.clear_editor_test()
		return
	GameState.clear_editor_test()
	_doc = EditorDoc.make(_new_key())
	_saved_serials[_doc["doc_key"]] = EditorDoc.serial(_doc)
	var open_id: String = GameState.editor_open_id
	GameState.editor_open_id = ""
	_sync_ui()
	_after_edit()
	if not open_id.is_empty():
		_open_track(open_id)


func _wire() -> void:
	_canvas.stroke_committed.connect(_on_stroke_committed)
	_trim_tool.bind()
	_erase_tool.bind()
	_canvas.view_changed.connect(_on_view_changed)
	_mode_draw.pressed.connect(_set_mode.bind(DrawCanvas.Mode.DRAW))
	_mode_pan.pressed.connect(_set_mode.bind(DrawCanvas.Mode.PAN))
	_mode_trim.pressed.connect(_set_mode.bind(DrawCanvas.Mode.TRIM))
	_mode_item.pressed.connect(_set_mode.bind(DrawCanvas.Mode.ITEM))
	_item_tool.bind_ui()
	(get_node("IssuePanel/Box/Head/IssueToggle") as Button).pressed.connect(
		EditorIssues.toggle.bind(self)
	)
	_zoom_in_button.pressed.connect(_canvas.zoom_by.bind(DrawCanvas.ZOOM_BUTTON_STEP))
	_zoom_out_button.pressed.connect(_canvas.zoom_by.bind(1.0 / DrawCanvas.ZOOM_BUTTON_STEP))
	_fit_button.pressed.connect(_fit_view)
	_review_button.pressed.connect(_confirm_reviews)
	_close_toggle.toggled.connect(_set_closed)
	_undo_button.pressed.connect(_undo)
	_redo_button.pressed.connect(_redo)
	_new_button.pressed.connect(_on_new_pressed)
	_autofix_button.pressed.connect(_auto_fix)
	_length_button.pressed.connect(_open_length_dialog)
	_validate_button.pressed.connect(_validate)
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.focus_exited.connect(_on_name_focus_exited)
	_diff_option.item_selected.connect(_on_diff_changed)
	_fabric_option.item_selected.connect(_on_fabric_changed)
	_save_button.pressed.connect(_save)
	_testplay_button.pressed.connect(_test_play)
	_back_button.pressed.connect(_on_back)
	# 불러오기: 웹은 JavaScriptBridge 업로드, 데스크톱은 FileDialog + 드래그드롭. 두 경로 모두
	# _import_from_text 공용 파싱으로 수렴한다(그리기·검증·저장은 웹에서도 동작).
	_import_button.pressed.connect(_on_import_pressed)
	if OS.has_feature("web"):
		_web_bridge = WebFileBridge.new()
	else:
		_import_dialog.file_selected.connect(_import_file)
		get_window().files_dropped.connect(_on_files_dropped)


# --- 문서 상태 / undo ---


func _new_key() -> int:
	_next_doc_key += 1
	return _next_doc_key - 1


func _is_dirty() -> bool:
	return EditorDoc.serial(_doc) != str(_saved_serials.get(_doc["doc_key"], ""))


## 테스트 전에 저장이 필요한가(미저장 변경이 있거나 아직 파일이 없는 사본·새 트랙).
func _needs_save() -> bool:
	return _is_dirty() or str(_doc["local_id"]).is_empty()


## 저장·테스트 가능: 틈 없음 + 기하 검증 통과 + 검토 필요 아이템 없음.
func _can_commit() -> bool:
	return not EditorDoc.has_gap(_doc) and _is_validated() and _items_problem().is_empty()


## 실제 아이템 제약(개수·종류·s·lat·검토) 위반 사유. 검토 표시에만 의존하지 않는다.
func _items_problem() -> String:
	var w: float = float(_doc["width"]["fail"])
	return EditorDoc.items_problem(_doc["items"], EditorDoc.path_length(_doc["path"]), w)


func _is_validated() -> bool:
	return (
		not _validated_geom.is_empty()
		and (_doc["path"] as PackedVector2Array).size() >= 2
		and _validated_geom == EditorDoc.geom_key(_doc)
	)


## 문서를 바꾸기 직전에 호출한다. kind는 undo 단위 종류(이름 연속 입력만 한 단위로 묶는다).
## snapshot을 주면 그 상태(드래그 시작 전 문서 등)를 쌓는다.
func _push_undo(kind: String, snapshot: Dictionary = {}) -> void:
	_undo_stack.append(EditorDoc.copy(_doc) if snapshot.is_empty() else snapshot)
	if _undo_stack.size() > UNDO_MAX:
		_undo_stack.remove_at(0)
	_redo_stack.clear()
	_last_edit = kind


func _undo() -> void:
	if _undo_stack.is_empty():
		return
	_cancel_gestures()
	_redo_stack.append(EditorDoc.copy(_doc))
	_doc = _undo_stack.pop_back()
	_after_history("실행취소했습니다.")


func _redo() -> void:
	if _redo_stack.is_empty():
		return
	_cancel_gestures()
	_undo_stack.append(EditorDoc.copy(_doc))
	_doc = _redo_stack.pop_back()
	_after_history("다시 실행했습니다.")


## 진행 중인 아이템 드래그·스트로크·자르기·지우기를 문서 변경 없이 취소한다. 문서·경로를 바꾸는 모든
## 단축키·버튼(undo/redo·Backspace·C·Delete·검증·자동 수정·길이 조절·불러오기·난이도·틈 잇기 등)이 먼저 부른다.
func _cancel_gestures() -> void:
	_item_tool.cancel()
	_canvas.cancel_input()


func _after_history(msg: String) -> void:
	_last_edit = ""
	_selected_item = -1  # 아이템 배열이 바뀌므로 인덱스 선택은 다른 아이템을 가리킬 수 있다
	_sync_ui()
	var geom_before: String = _shown_geom
	_after_edit()
	if geom_before == _shown_geom:
		_set_status(msg, NEUTRAL_COLOR)


## 저장 id를 문서와, undo/redo 안의 같은 계보 스냅샷에 반영한다(실행취소 후 저장해도 같은 파일).
func _assign_local_id(id: String) -> void:
	var key: int = int(_doc["doc_key"])
	_doc["local_id"] = id
	for stack in [_undo_stack, _redo_stack]:
		for snap in stack:
			if int(snap["doc_key"]) == key:
				snap["local_id"] = id


# --- 편집 조작 ---


func _on_stroke_committed(raw: PackedVector2Array) -> void:
	if raw.size() < 2:
		return
	# 원시 점 간격(월드)을 넘겨 줌아웃에서 그린 곡선도 zoom 1.0과 같은 품질로 정규화한다.
	var raw_step: float = DrawCanvas.MIN_SAMPLE_PX / float(_canvas.get_view()["zoom"])
	var seg: PackedVector2Array = _proc.process(raw, false, StrokeProcessor.CLOSE_GAP, raw_step)
	if seg.size() < 2:
		return
	if EditorDoc.has_gap(_doc) and _erase_tool.gap_stroke(seg):
		return  # 틈 끝점에서 이어 그리기(잇기·늘리기)는 지우기 도구가 처리한다
	var path: PackedVector2Array = _doc["path"]
	var snap: float = _canvas.world_radius(SNAP_PX, SNAP_RADIUS)
	if path.size() >= 2 and path[path.size() - 1].distance_to(seg[0]) > snap:
		# 기존 경로를 조용히 바꾸지 않는다. 새 경로는 "새로 그리기"로만 시작한다.
		_set_status(
			"이어 그리기는 끝점(노란 점)에서 시작하세요. 새 경로는 '새로 그리기…'로 시작합니다.", WARN_COLOR
		)
		return
	_push_undo("stroke")
	if path.size() < 2:
		_doc["path"] = seg
		_doc["items"] = []
	else:
		_doc["path"] = EditorDoc.appended(path, seg, SUBDIV_STEP)  # 끝점 이어붙임(다중 스트로크). 아이템 s는 그대로
	_doc["closed"] = false
	_after_edit()


## 끝부분 자르기(EditorTrimTool)에 넘기는 얇은 입구(검사·단축키 공용).
func _trim_hit_index(world_pos: Vector2) -> int:
	return _trim_tool.hit_index(world_pos)


func _on_trim_hover(world_pos: Vector2) -> void:
	_trim_tool.hover(world_pos)


func _on_trim_hover_exit() -> void:
	_trim_tool.hover_exit()


## 경로를 앞 keep_count개 점만 남기고 자른다. 잘린 구간의 아이템은 같은 undo 단위로 제거한다.
func _cut_to(keep_count: int) -> void:
	var path: PackedVector2Array = _doc["path"]
	var g: int = EditorDoc.gap_index(_doc)
	if g >= 0 and keep_count < g + 2:
		keep_count = mini(keep_count, g)  # 틈 뒤 조각이 한 점 이하로 남으면 뒤 조각을 모두 자른다
	if keep_count >= path.size():
		return
	var new_path: PackedVector2Array = path.slice(0, maxi(keep_count, 0))
	var kept: Dictionary = EditorDoc.items_within(_doc["items"], EditorDoc.path_length(new_path))
	_push_undo("trim")
	_doc["path"] = new_path
	_doc["items"] = kept["items"]
	_doc["closed"] = false
	_doc["gap"] = g if keep_count >= g + 2 else -1
	_after_edit()
	var extra: String = "  (아이템 %d개 함께 제거)" % int(kept["removed"]) if kept["removed"] > 0 else ""
	_set_status("끝부분을 잘랐습니다" + extra, NEUTRAL_COLOR)


func _trim_tail() -> void:
	_cancel_gestures()
	var path: PackedVector2Array = _doc["path"]
	if path.size() <= 2:
		return
	_cut_to(maxi(0, path.size() - TRIM_COUNT))


func _set_mode(m: int) -> void:
	_canvas.set_mode(m)
	_trim_tool.hit = -1
	_trim_tool.clear_hint()
	_mode_draw.set_pressed_no_signal(m == DrawCanvas.Mode.DRAW)
	_mode_pan.set_pressed_no_signal(m == DrawCanvas.Mode.PAN)
	_mode_trim.set_pressed_no_signal(m == DrawCanvas.Mode.TRIM)
	_mode_item.set_pressed_no_signal(m == DrawCanvas.Mode.ITEM)
	_mode_erase.set_pressed_no_signal(m == DrawCanvas.Mode.ERASE)
	_erase_tool.on_mode(m)
	if m != DrawCanvas.Mode.ITEM:
		_selected_item = -1  # 선택은 아이템 도구 안에서만 유지한다
	if m == DrawCanvas.Mode.ITEM and _doc.has("path"):
		_set_status("아이템: 종류를 고르고 경로 가까이를 누르면 놓입니다. 마커를 끌면 옮겨집니다.", NEUTRAL_COLOR)
	if _doc.has("path"):
		_refresh()


func _set_closed(on: bool) -> void:
	_cancel_gestures()
	var path: PackedVector2Array = _doc["path"]
	if on == bool(_doc["closed"]):
		_close_toggle.set_pressed_no_signal(on)
		return
	if on:
		if path.size() < 3 or _erase_tool.blocked("루프를 닫을 수 없습니다"):
			_close_toggle.set_pressed_no_signal(false)
			return
		var closed_path: PackedVector2Array = _proc.apply_close_gap(
			path, float(_doc["width"]["fail"])
		)
		var kept: Dictionary = EditorDoc.items_within(
			_doc["items"], EditorDoc.path_length(closed_path)
		)
		_push_undo("close")
		_doc["pre_close"] = path.duplicate()
		_doc["path"] = closed_path
		_doc["items"] = kept["items"]
		_doc["closed"] = true
		_sync_ui()
		_after_edit()
		if int(kept["removed"]) > 0:
			_set_status("루프를 닫았습니다  (아이템 %d개 함께 제거)" % int(kept["removed"]), WARN_COLOR)
	else:
		_push_undo("close")
		var pre: PackedVector2Array = _doc["pre_close"]
		if pre.size() >= 2:
			# 닫기 해제도 경로 변경이므로 아이템을 새 경로에 다시 투영한다(닫은 뒤 편집이 없으면 그대로).
			_doc["items"] = EditorDoc.reproject_items(path, pre, _doc["items"])
			_doc["path"] = pre.duplicate()
		_doc["closed"] = false
		_sync_ui()
		_after_edit()


## "새로 그리기…": 경로와 아이템을 지우는 명시 동작(확인 후, undo 한 단위). 메타는 유지한다.
func _on_new_pressed() -> void:
	_cancel_gestures()
	var n_items: int = (_doc["items"] as Array).size()
	if (_doc["path"] as PackedVector2Array).is_empty() and n_items == 0:
		return
	var extra: String = " 아이템 %d개도 함께 지워집니다." % n_items if n_items > 0 else ""
	_ask(
		"현재 경로를 지우고 새로 그릴까요?%s\n(실행취소로 되돌릴 수 있습니다)" % extra,
		"새로 그리기",
		_clear_path
	)


func _clear_path() -> void:
	_push_undo("clear")
	_doc["path"] = PackedVector2Array()
	_doc["pre_close"] = PackedVector2Array()
	_doc["items"] = []
	_doc["closed"] = false
	_doc["gap"] = -1
	_selected_item = -1
	_sync_ui()
	_after_edit()


# --- 메타 ---


func _on_name_changed(text: String) -> void:
	if text == str(_doc["name"]):
		return
	if _last_edit != "name":
		_push_undo("name")
	_doc["name"] = text
	_refresh()


func _on_name_focus_exited() -> void:
	if _last_edit == "name":
		_last_edit = ""  # 다음 이름 입력은 새 undo 단위


## 난이도 선택 = 폭 프리셋 적용(사용자 지정 폭은 이때만 명시적으로 바뀐다). 검증을 다시 요구한다.
func _on_diff_changed(idx: int) -> void:
	_cancel_gestures()
	var id: String = str(EditorDoc.DIFFS[clampi(idx, 0, EditorDoc.DIFFS.size() - 1)]["id"])
	if id == str(_doc["difficulty"]) and not EditorDoc.is_custom_width(_doc):
		return
	var was_custom: bool = EditorDoc.is_custom_width(_doc)
	var old_w: String = EditorSession.width_text(_doc)
	_push_undo("difficulty")
	_doc["difficulty"] = id
	_doc["width"] = EditorDoc.preset_width(id)
	var n_lat: int = EditorDoc.flag_lat_overflow(_doc["items"], float(_doc["width"]["fail"]))
	_after_edit()
	var msg: String = "난이도를 %s(으)로 바꾸고 %s을(를) 적용했습니다." % [
		EditorSession.diff_name(id), EditorSession.width_text(_doc)
	]
	if was_custom:
		msg += " 이전 %s은 실행취소로 되돌릴 수 있습니다." % old_w
	if n_lat > 0:
		msg += " 옆 거리가 폭을 넘는 아이템 %d개는 검토가 필요합니다." % n_lat
	_set_status(msg, WARN_COLOR if (was_custom or n_lat > 0) else NEUTRAL_COLOR)


## 원단 변경은 dirty만 바꾸고 기하 검증은 유지한다.
func _on_fabric_changed(idx: int) -> void:
	var fabric: String = str(EditorDoc.FABRICS[clampi(idx, 0, EditorDoc.FABRICS.size() - 1)])
	if fabric == str(_doc["fabric"]):
		return
	_push_undo("fabric")
	_doc["fabric"] = fabric
	_refresh()


# --- 검증 / 자동수정 / 길이맞추기 ---


func _validate() -> void:
	_cancel_gestures()
	var path: PackedVector2Array = _doc["path"]
	_shown_geom = EditorDoc.geom_key(_doc)
	if path.size() < 2:
		_set_status("트랙을 먼저 그리세요.", NEUTRAL_COLOR)
		return
	if _erase_tool.blocked("검증할 수 없습니다"):
		return
	var res: Dictionary = _validator.validate(path, float(_doc["width"]["fail"]))
	_canvas.set_markers(res["curvature"], res["proximity"])
	_validated_geom = _shown_geom if bool(res["ok"]) else ""
	_autofix_button.disabled = not _has_hard_curvature(res)
	_issues = EditorIssues.build(res, path)
	EditorIssues.show(self, _issues)
	if bool(res["ok"]):
		var extra: String = ""
		if int(res["soft"]) > 0:
			extra = "  · 권장 경고 %d (저장 가능)" % EditorIssues.count(_issues, "soft")
		var min_r: float = float(res["min_radius"])
		var rtxt: String = "∞" if min_r == INF else str(int(min_r))
		_set_status(
			"검증 통과 — 트랙 길이 %d · 최소반경 %s%s" % [int(res["length"]), rtxt, extra], OK_COLOR
		)
	else:
		_set_status(
			"검증 실패 — 고칠 곳 %d개(오른쪽 목록의 '위치로'로 확인)" % EditorIssues.count(_issues, "hard"),
			FAIL_COLOR
		)
	_refresh()


## "자동 수정…": 급한 곡선을 둥글게 고친 결과를 미리 보여 주고(청록 선) 확인 후에만 적용한다.
## 아이템은 이전 중심선 위치를 새 경로에 투영하고, 크게 옮겨지거나 헷갈리는 것은 검토 필요로 표시한다.
func _auto_fix() -> void:
	_cancel_gestures()
	var path: PackedVector2Array = _doc["path"]
	if path.size() < 5 or _erase_tool.blocked("자동 수정할 수 없습니다"):
		return
	var fixed: PackedVector2Array = _proc.relax_curvature(path, TrackValidator.MIN_RADIUS)
	var items: Array = EditorDoc.reproject_items(path, fixed, _doc["items"])
	var before: Dictionary = _validator.validate(path, float(_doc["width"]["fail"]))
	var after: Dictionary = _validator.validate(fixed, float(_doc["width"]["fail"]))
	var n_review: int = EditorDoc.review_count(items)
	var review_txt: String = "\n검토 필요 아이템 %d개(적용 후 확인해야 저장할 수 있습니다)" % n_review
	_canvas.set_preview(fixed)
	_ask(
		(
			"자동 수정 미리보기(청록 선)\n급한 곡선 %d → %d곳 · 트랙 길이 %d → %d\n%s%s"
			% [
				_hard_curvature_count(before),
				_hard_curvature_count(after),
				roundi(EditorDoc.path_length(path)),
				roundi(EditorDoc.path_length(fixed)),
				EditorLengthDialog.describe(after),
				review_txt if n_review > 0 else ""
			]
		),
		"적용",
		_apply_path_edit.bind("autofix", fixed, items, PackedVector2Array())
	)


## 경로 전체를 바꾸는 편집(자동 수정·길이 조절)을 undo 한 단계로 적용한다. pre_close가 비어 있지
## 않으면 함께 바꾼다(루프 닫기 해제가 이전 배율로 돌아가지 않게). closed는 그대로 둔다.
func _apply_path_edit(
	kind: String, path: PackedVector2Array, items: Array, pre_close: PackedVector2Array
) -> void:
	_push_undo(kind)
	_doc["path"] = path
	_doc["items"] = items
	# 닫기 전 경로를 같은 변환으로 옮겼으면 그것을, 아니면(자동 수정) 비워 무효화한다. 닫기 해제가
	# 편집 전 경로로 되돌아가 아이템과 어긋나지 않게 한다.
	_doc["pre_close"] = pre_close
	_after_edit()
	_validate()
	var n_review: int = EditorDoc.review_count(items)
	if n_review > 0:
		_set_status(
			(
				"아이템 %d개의 위치를 확인하세요(빨간 테두리). 확인 전에는 저장·테스트할 수 없습니다."
				% n_review
			),
			WARN_COLOR
		)


## "트랙 길이 조절…": 목표 길이 입력 → 미리보기 → 적용(undo 한 단계). 긴 트랙을 자동 축소하지 않는다.
func _open_length_dialog() -> void:
	var path: PackedVector2Array = _doc["path"]
	if path.size() < 2 or _erase_tool.blocked("길이를 조절할 수 없습니다"):
		return
	_cancel_gestures()
	_length_dialog.open_for(path, _doc["pre_close"], float(_doc["width"]["fail"]))


func _on_length_confirmed() -> void:
	_canvas.set_preview(PackedVector2Array())
	_apply_length(_length_dialog.result)


## 길이 조절 결과 적용. 아이템 s는 진행 비율을 유지하고(최종 실제 길이 기준 상한), lat·closed는 그대로.
func _apply_length(r: Dictionary) -> void:
	if r.is_empty():
		return
	var old_len: float = EditorDoc.path_length(_doc["path"])
	var new_len: float = float(r["length"])
	var items: Array = EditorDoc.scale_items(_doc["items"], old_len, new_len)
	_apply_path_edit("length", r["path"], items, r["pre_close"])


## 검토 필요 아이템을 지금 위치로 확정한다(undo 한 단계). 개별 해결은 셋째 묶음의 아이템 도구가 한다.
func _confirm_reviews() -> void:
	_cancel_gestures()
	if EditorDoc.review_count(_doc["items"]) == 0:
		return
	_push_undo("review")
	var length: float = EditorDoc.path_length(_doc["path"])
	for it in _doc["items"]:
		if EditorDoc.needs_review(it):
			EditorDoc.resolve_item(it, length, float(_doc["width"]["fail"]))
	_after_edit()
	_set_status("아이템 위치를 확정했습니다.", NEUTRAL_COLOR)


func _hard_curvature_count(res: Dictionary) -> int:
	var n: int = 0
	for v in res["curvature"]:
		if str(v["kind"]) == "hard":
			n += 1
	return n


func _has_hard_curvature(res: Dictionary) -> bool:
	return _hard_curvature_count(res) > 0


# --- 저장 / 테스트 플레이 ---


## 검증을 통과한 문서를 저장한다. 성공 여부를 반환한다(테스트 출발 조건).
func _save() -> bool:
	if not _can_commit():
		if _erase_tool.blocked("저장할 수 없습니다"):
			pass
		elif _is_validated() and not _items_problem().is_empty():
			_set_status("저장할 수 없습니다: " + _items_problem(), FAIL_COLOR)
		return false
	var dict: Dictionary = EditorDoc.to_track_dict(_doc)
	var bad: String = EditorSession.check_saved(dict)  # 실제로 저장될 경로로 한 번 더 검사
	if not bad.is_empty():
		_set_status("저장할 수 없습니다: " + bad, FAIL_COLOR)
		return false
	var id: String = TrackLoader.save_custom_track(dict)
	if id.is_empty():
		_set_status("저장 실패 (파일 쓰기 오류)", FAIL_COLOR)
		return false
	_assign_local_id(id)
	_saved_serials[_doc["doc_key"]] = EditorDoc.serial(_doc)
	_refresh()
	_set_status("저장됨: %s  (%s)" % [EditorDoc.track_name(_doc), id], OK_COLOR)
	return true


func _test_play() -> void:
	if _erase_tool.blocked("테스트할 수 없습니다") or not _can_commit():
		return
	if _needs_save():
		var name_note: String = ""
		if str(_doc["name"]).strip_edges().is_empty():
			name_note = "\n이름이 비어 있어 '%s'(으)로 저장됩니다." % EditorDoc.DEFAULT_NAME
		_ask(
			(
				"테스트하려면 먼저 저장해야 합니다.\n'%s' 이름으로 저장한 뒤 테스트할까요?%s"
				% [EditorDoc.track_name(_doc), name_note]
			),
			"저장 후 테스트",
			_save_and_test
		)
		return
	_start_test()


func _save_and_test() -> void:
	if _save():
		_start_test()


func _start_test() -> void:
	_canvas.cancel_input()
	var session: Dictionary = EditorSession.make(self)
	GameState.start_editor_test(str(_doc["local_id"]), str(_doc["difficulty"]), session)


func _restore_session(s: Dictionary) -> void:
	EditorSession.restore(self, s)
	_sync_ui()
	_after_edit()
	_set_status("테스트에서 돌아왔습니다. " + _status_label.text, _status_color())


# --- 열기 / 불러오기 ---


## 트랙 id로 연다. 로컬 커스텀 트랙은 그 파일을 편집하고, 공식 트랙과 허브에서 받고 편집하지 않은
## 트랙은 원본을 두고 로컬 사본(저장 시 새 custom_ id)으로 편집한다.
func _open_track(id: String) -> void:
	var is_custom: bool = id.begins_with(TrackLoader.CUSTOM_PREFIX)
	var parsed: Dictionary = _parse_for_edit(EditorSession.track_text(id))
	if not bool(parsed["ok"]):
		_set_status("트랙을 열지 못했습니다: " + str(parsed["message"]), FAIL_COLOR)
		return
	var doc: Dictionary = parsed["doc"]
	var as_copy: bool = not is_custom or TrackLoader.is_unmodified_hub_download(id)
	doc["local_id"] = "" if as_copy else id
	_doc = doc
	_saved_serials[_doc["doc_key"]] = EditorDoc.serial(_doc)
	_sync_ui()
	_after_edit()
	_fit_view()
	_validate()
	var head: String = "'%s' 편집 중. " % EditorDoc.track_name(_doc)
	if as_copy:
		head = "'%s'의 사본을 편집합니다. 저장하면 새 로컬 트랙이 되고 원본은 그대로입니다. " % (
			EditorDoc.track_name(_doc)
		)
	_set_status(head + _status_label.text + str(parsed["note"]), _status_color())


## 텍스트 → 편집 문서(새 doc_key는 적용할 때만 소비). {ok, doc, note} 또는 {ok=false, message}.
func _parse_for_edit(text: String) -> Dictionary:
	if text.is_empty():
		return {"ok": false, "message": "파일이 비어 있음"}
	var prep: Dictionary = TrackLoader.prepare_edit_import(text)
	if not bool(prep["ok"]):
		return {"ok": false, "message": str(prep["message"])}
	var conv: Dictionary = EditorDoc.from_track_dict(prep["track_dict"], _next_doc_key)
	if not bool(conv["ok"]):
		return conv
	_new_key()
	return {"ok": true, "doc": conv["doc"], "note": str(prep.get("note", ""))}


## "불러오기" 버튼. 웹은 브라우저 파일 선택, 데스크톱은 FileDialog를 연다.
func _on_import_pressed() -> void:
	_cancel_gestures()
	if _web_bridge != null:
		_web_bridge.pick_file(_on_web_file_loaded)
	else:
		_import_dialog.popup_centered()


## 웹 업로드 콜백. status로 사유를 구분하고, 정상이면 텍스트를 캔버스에 올린다.
func _on_web_file_loaded(status: String, text: String, _filename: String) -> void:
	match status:
		"cancel":
			return
		"too_large":
			_set_status("파일이 너무 큼 (1MB 초과)", FAIL_COLOR)
		"error":
			_set_status("파일을 읽지 못했습니다", FAIL_COLOR)
		_:
			_import_from_text(text)


## 데스크톱 FileDialog/드래그드롭 → 파일 텍스트를 읽어 공용 파싱으로 넘긴다.
func _import_file(path: String) -> void:
	var r: Dictionary = EditorSession.read_file(path)
	if r.has("error"):
		_set_status(str(r["error"]), FAIL_COLOR)
		return
	_import_from_text(str(r["text"]))


## 공용 트랙 텍스트 파싱(TrackLoader.prepare_edit_import: items·폭·closed 보존, modifiers 제외 안내)
## → 편집 문서. 실패하면 기존 문서·ID·화면을 그대로 둔다. 성공 시 미저장 변경이 있으면 확인 후
## 교체하며, 교체는 undo 한 단위다. 불러온 트랙은 새 로컬 트랙(저장 시 새 id, §8)이다.
func _import_from_text(text: String) -> void:
	_cancel_gestures()
	var parsed: Dictionary = _parse_for_edit(text)
	if not bool(parsed["ok"]):
		_set_status("불러오기 실패 — " + str(parsed["message"]), FAIL_COLOR)
		return
	if _is_dirty():
		_ask(
			"저장하지 않은 변경이 있습니다. 불러온 트랙으로 바꿀까요?\n(실행취소로 되돌릴 수 있습니다)",
			"바꾸기",
			_apply_import.bind(parsed["doc"], str(parsed["note"]))
		)
		return
	_apply_import(parsed["doc"], str(parsed["note"]))


func _apply_import(doc: Dictionary, note: String) -> void:
	_push_undo("import")
	_doc = EditorDoc.copy(doc)
	_selected_item = -1
	_sync_ui()
	_after_edit()
	_fit_view()
	_validate()
	var n: int = (_doc["items"] as Array).size()
	var items_txt: String = " · 아이템 %d개" % n if n > 0 else ""
	_set_status(
		"불러왔습니다%s. %s%s" % [items_txt, _status_label.text, note], _status_color()
	)


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.ends_with(".json"):
			_import_file(f)
			return


# --- 공통 ---


## 문서 → 위젯(이름·난이도·원단·닫기). 신호 없이 반영한다.
func _sync_ui() -> void:
	if _name_edit.text != str(_doc["name"]):
		_name_edit.text = str(_doc["name"])
	var di: int = EditorDoc.preset_index(str(_doc["difficulty"]))
	if di >= 0 and _diff_option.selected != di:
		_diff_option.select(di)
	var fi: int = EditorDoc.FABRICS.find(str(_doc["fabric"]))
	if fi >= 0 and _fabric_option.selected != fi:
		_fabric_option.select(fi)
	_close_toggle.set_pressed_no_signal(bool(_doc["closed"]))


## 문서가 바뀐 뒤 공통 갱신. 경로·판정 폭이 바뀌었으면 마커를 지우고 재검증을 요구한다
## (이전에 통과했던 기하로 돌아온 경우는 조용히 다시 검증해 표시만 되살린다).
func _after_edit() -> void:
	var key: String = EditorDoc.geom_key(_doc)
	if key != _shown_geom:
		_shown_geom = key
		_canvas.clear_markers()
		_canvas.set_focus(PackedVector2Array())
		($IssuePanel as Control).visible = false
		_autofix_button.disabled = true
		if _is_validated():
			_validate()
		else:
			_set_idle_status()
	_refresh()


## 뷰와 버튼·상태 표시 갱신(문서는 바꾸지 않는다).
func _refresh() -> void:
	var path: PackedVector2Array = _doc["path"]
	var w: Dictionary = _doc["width"]
	_canvas.set_track(path, float(w["safe"]), float(w["fail"]), EditorDoc.gap_index(_doc))
	_erase_tool.refresh_row()
	var items: Array = _doc["items"]
	if _selected_item >= items.size():
		_selected_item = -1
	var marks: Array = []
	if path.size() >= 2:
		for i in range(items.size()):
			var sel: bool = i == _selected_item
			marks.append(
				{
					"pos": EditorDoc.item_world(path, items[i]),
					"type": str(items[i]["type"]),
					"review": EditorDoc.needs_review(items[i]),
					"selected": sel,
					"label": _item_tool.progress_label(i) if sel else "",
				}
			)
	_canvas.set_items(marks)
	_item_tool.refresh_bar()
	_fabric_swatch.texture = EditorSession.swatch(str(_doc["fabric"]))
	EditorSession.show_fabric_note(_fabric_note, str(_doc["fabric"]))
	_undo_button.disabled = _undo_stack.is_empty()
	_redo_button.disabled = _redo_stack.is_empty()
	_length_button.disabled = path.size() < 2
	_fit_button.disabled = path.size() < 2
	_new_button.disabled = path.is_empty() and (_doc["items"] as Array).is_empty()
	var ok: bool = _can_commit()
	_save_button.disabled = not ok
	_testplay_button.disabled = not ok
	var n_review: int = EditorDoc.review_count(_doc["items"])
	_review_row.visible = n_review > 0
	_review_label.text = "검토 필요 아이템 %d개(빨간 테두리)" % n_review
	_width_label.text = EditorSession.width_text(_doc)
	_width_label.tooltip_text = "난이도를 고르면 그 난이도의 프리셋 폭으로 바뀝니다(실행취소 가능)."
	var dirty: bool = _is_dirty()
	var state: String = "저장 안 됨" if dirty else "저장됨"
	if str(_doc["local_id"]).is_empty():
		state = "새 트랙 · 저장 전" if (dirty or path.size() >= 2) else "새 트랙"
	if EditorDoc.has_gap(_doc):
		state = "틈 있음 · 저장 불가"
	var n_items: int = (_doc["items"] as Array).size()
	_doc_state_label.text = "트랙 길이 %d · 아이템 %d · %s" % [
		int(EditorDoc.path_length(path)), n_items, state
	]


func _set_idle_status() -> void:
	if EditorDoc.has_gap(_doc):
		_set_status(EditorEraseTool.GAP_HINT, WARN_COLOR)
	elif (_doc["path"] as PackedVector2Array).size() >= 2:
		_set_status("검증하려면 '검증'(Enter)을 누르세요.", NEUTRAL_COLOR)
	else:
		_set_status(
			"왼쪽 드래그로 트랙을 그리세요. 화면 이동·확대는 '화면 이동'과 +/− 버튼(휠·중클릭도 됨).",
			NEUTRAL_COLOR
		)


func _set_status(text: String, color: Color) -> void:
	_hint_restore = []
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)


func _status_color() -> Color:
	return _status_label.get_theme_color("font_color")


## 확인창. ok_text 버튼을 누르면 action을 실행하고, 취소하면 아무것도 바꾸지 않는다.
func _ask(text: String, ok_text: String, action: Callable) -> void:
	_canvas.cancel_input()
	_pending = action
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok_text
	_confirm.popup_centered()


func _on_confirm_cancel() -> void:
	_pending = Callable()
	_canvas.set_preview(PackedVector2Array())


func _on_confirm_ok() -> void:
	var action: Callable = _pending
	_pending = Callable()
	_canvas.set_preview(PackedVector2Array())
	if action.is_valid():
		action.call()


func _on_back() -> void:
	if _is_dirty():
		_ask("저장하지 않은 변경이 있습니다. 메뉴로 나갈까요?", "나가기", _go_menu)
	else:
		_go_menu()


func _go_menu() -> void:
	GameState.clear_editor_test()
	get_tree().change_scene_to_file(MENU_SCENE)


## 확인창·파일 대화상자가 떠 있으면 true(캔버스 단축키를 가로채지 않는다).
func _modal_open() -> bool:
	return (
		(_confirm != null and _confirm.visible)
		or (_length_dialog != null and _length_dialog.visible)
		or _import_dialog.visible
	)


## "전체 보기": 경로 전체(+ 판정 폭·마커 여백)가 그리기 영역에 들어오게 카메라만 맞춘다.
func _fit_view() -> void:
	_canvas.fit_path(_doc["path"], float(_doc["width"]["fail"]))


func _on_view_changed() -> void:
	_zoom_label.text = "%d%%" % roundi(float(_canvas.get_view()["zoom"]) * 100.0)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo:
		return
	# 텍스트 입력·확인창 중에는 편집 단축키를 가로채지 않는다(Ctrl/Cmd+Z·Delete·Backspace 포함).
	if _modal_open():
		return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if _handle_shortcut(key):
		get_viewport().set_input_as_handled()


## 캔버스 편집 단축키. 처리했으면 true.
func _handle_shortcut(key: InputEventKey) -> bool:
	# macOS에서도 Ctrl+Z를 받도록 Ctrl과 Cmd를 모두 명령 키로 본다(안내 문구: Ctrl/Cmd+Z).
	var cmd: bool = key.ctrl_pressed or key.meta_pressed
	if cmd:
		if (key.keycode == KEY_Z and key.shift_pressed) or key.keycode == KEY_Y:
			_redo()
		elif key.keycode == KEY_Z:
			_undo()
		else:
			return false
		return true
	if key.alt_pressed:
		return false
	if key.keycode in [KEY_DELETE, KEY_BACKSPACE] and _canvas.mode == DrawCanvas.Mode.ITEM:
		# 아이템 도구에서는 선택 아이템만 지운다. 선택이 없으면 아무것도 하지 않는다(새로 그리기·끝 자르기 아님).
		_item_tool.delete_selected()
		return true
	match key.keycode:
		KEY_C:
			_set_closed(not bool(_doc["closed"]))
		KEY_BACKSPACE:
			_trim_tail()
		KEY_DELETE:
			_on_new_pressed()
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			_canvas.zoom_by(DrawCanvas.ZOOM_BUTTON_STEP)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_canvas.zoom_by(1.0 / DrawCanvas.ZOOM_BUTTON_STEP)
		KEY_F:
			_fit_view()
		KEY_ENTER, KEY_KP_ENTER:
			_validate()
		KEY_ESCAPE:
			_on_back()
		_:
			return false
	return true
