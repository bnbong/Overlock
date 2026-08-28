extends Control
## 맵 선택 화면(2단 네비게이션 2단). 메인의 Start로 진입한다. 트랙 캐러셀(◀▶ / ←→),
## 실루엣 미리보기, 트랙명·난이도·길이·CUSTOM 배지·트랙별 최고 기록을 보여주고,
## 플레이/트랙 만들기/불러오기/삭제/이 트랙 리더보드/뒤로 액션을 제공한다.
## (구 MainMenu의 트랙 선택 로직을 이 화면으로 이관했다 — 아키텍처 §2.1 갱신.)
##
## 트랙 모양 자체가 셀링 포인트이므로 선택된 트랙의 베이크된 폴리라인을 작은 미리보기
## 패널에 실루엣으로 그린다(TrackData 베이크 재사용). 미리보기는 별도 스크립트 노드
## 대신 Preview 컨트롤의 draw 시그널에 그려 넣는다.
##
## 마지막 선택 트랙은 LeaderboardClient.remember_last_track로 user://settings.json에
## 기록하고 재진입 시 복원한다.

const DEFAULT_TRACK: String = "cotton_01"
const MAIN_SCENE: String = "res://scenes/Main.tscn"
const EDITOR_SCENE: String = "res://scenes/TrackEditor.tscn"
const LEADERBOARD_SCENE: String = "res://scenes/Leaderboard.tscn"
const SELF_SCENE: String = "res://scenes/TrackSelect.tscn"

## 원단 재질 한국어 라벨. FabricSurface.FABRIC_BASE(presentation/FabricSurface.gd)가
## 실제로 렌더 지원하는 재질 목록과 맞춘다 — 목록에 없는 값(미지 재질)은 원문 그대로 노출.
const FABRIC_LABELS: Dictionary = {
	"cotton": "면",
	"denim": "데님",
	"silk": "실크",
	"knit": "니트",
	"felt": "펠트",
	"satin": "새틴",
	"wool": "울",
	"leather": "가죽",
}

# 리더보드 복귀 씬을 진입 직전 설정한다(맵 선택에서 열면 뒤로가기는 이 화면으로).
const LeaderboardScreenScript = preload("res://scripts/ui/LeaderboardScreen.gd")
const ToastScene = preload("res://scenes/Toast.tscn")

# --- 미리보기 패널 스타일(재봉 스킨 톤). 실루엣(밝은 라벤더)의 가독성을 지키려면
# 배경은 계속 어두워야 하므로 베이지 패치 대신 어두운 잉크 패널 + 박음질 테두리를 쓴다.
const _PREVIEW_BG_COLOR: Color = Color(0.16, 0.11, 0.10, 1.0)
const _PREVIEW_RADIUS: float = 10.0
const _PREVIEW_STITCH_INSET: float = 6.0

# --- 원단 스와치(정보 라인 옆 견본 이미지) 스타일. FabricSurface.swatch_source가 넘기는
# 텍스처/색을 이 크기로 라운드 패치 + 옅은 스티치 테두리로 그린다(재봉 UI 무드 통일).
const _SWATCH_SIZE: float = 24.0
const _SWATCH_GAP: float = 5.0
const _SWATCH_RADIUS: float = 6.0
const _SWATCH_STITCH_INSET: float = 2.0
const _SWATCH_STITCH_COLOR: Color = Color(0.97, 0.93, 0.85, 0.5)
const _SWATCH_UNKNOWN_COLOR: Color = Color(0.5, 0.5, 0.5, 1.0)
const _SWATCH_MAX_COUNT: int = 3

var _tracks: Array = []
var _index: int = 0
var _confirm: ConfirmationDialog
var _toast: Toast
# 현재 선택 트랙의 원단 토큰(스와치 draw 핸들러가 참조 — _update_fabric_row가 채운다).
var _swatch_tokens: PackedStringArray = PackedStringArray()
# 스와치 타일 텍스처 표시용 자식 TextureRect(_SWATCH_MAX_COUNT개, _ready에서 생성).
var _swatch_texture_rects: Array = []
# 웹 전용 파일 브리지(업로드/다운로드). 데스크톱에서는 null(FileDialog·드래그드롭을 씀).
var _web_bridge: WebFileBridge
# 데스크톱 내보내기 다이얼로그가 열려 있는 동안 캐러셀이 움직여도 대상이 흔들리지 않게 캡처.
var _export_id: String = ""
var _export_disp: String = ""

@onready var _preview: Control = $Panel/Preview
@onready var _track_label: Label = $Panel/Selector/TrackLabel
@onready var _prev_button: Button = $Panel/Selector/PrevButton
@onready var _next_button: Button = $Panel/Selector/NextButton
@onready var _info_label: Label = $Panel/InfoLabel
@onready var _fabric_row: HBoxContainer = $Panel/FabricRow
@onready var _swatch_row: Control = $Panel/FabricRow/SwatchRow
@onready var _fabric_text_label: Label = $Panel/FabricRow/FabricTextLabel
@onready var _best_time_label: Label = $Panel/BestTimeLabel
@onready var _play_button: Button = $Panel/PlayButton
@onready var _create_button: Button = $Panel/ActionRow/CreateButton
@onready var _import_button: Button = $Panel/ActionRow/ImportButton
@onready var _export_button: Button = $Panel/ActionRow/ExportButton
@onready var _delete_button: Button = $Panel/ActionRow/DeleteButton
@onready var _leaderboard_button: Button = $Panel/LeaderboardButton
@onready var _back_button: Button = $Panel/BackButton
@onready var _import_dialog: FileDialog = $ImportDialog
@onready var _export_dialog: FileDialog = $ExportDialog


func _ready() -> void:
	_rebuild_tracks()
	_index = _index_of(LeaderboardClient.last_track_id)
	_preview.draw.connect(_on_preview_draw)
	_preview.resized.connect(_preview.queue_redraw)
	_swatch_row.draw.connect(_on_swatch_row_draw)
	for _i in range(_SWATCH_MAX_COUNT):
		var tr: TextureRect = TextureRect.new()
		tr.visible = false
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		# AtlasTexture 크롭 영역이 스와치보다 커서(중앙 크롭 확대), 최소 크기가 텍스처를
		# 따라가지 않게 한다 — 아니면 Control.set_size가 최소 크기로 다시 클램프해 버린다.
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_swatch_row.add_child(tr)
		_swatch_texture_rects.append(tr)
	_prev_button.pressed.connect(_cycle.bind(-1))
	_next_button.pressed.connect(_cycle.bind(1))
	_play_button.pressed.connect(_on_play_pressed)
	_create_button.pressed.connect(_on_create_pressed)
	_delete_button.pressed.connect(_on_delete_pressed)
	_leaderboard_button.pressed.connect(_on_leaderboard_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	_toast = ToastScene.instantiate()
	add_child(_toast)
	# 불러오기/내보내기: 웹은 JavaScriptBridge 업로드·Blob 다운로드, 데스크톱은 FileDialog +
	# 드래그드롭. 불러오기는 두 경로 모두 TrackLoader.import_custom_from_text 공용 파이프라인으로
	# 수렴하고, 내보내기는 커스텀 트랙 JSON 원본을 그대로 다운로드/저장한다(§8, Phase 2).
	_import_button.pressed.connect(_on_import_pressed)
	_export_button.pressed.connect(_on_export_pressed)
	if OS.has_feature("web"):
		_web_bridge = WebFileBridge.new()
	else:
		_import_dialog.file_selected.connect(_on_import_file_selected)
		_export_dialog.file_selected.connect(_on_export_file_selected)
		get_window().files_dropped.connect(_on_files_dropped)
	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_do_delete)
	add_child(_confirm)
	_apply_skin()
	_refresh()
	_play_button.grab_focus()
	_play_menu_bgm()


## 사용자 제공 시트 스킨. 대형/소형 필 + 정사각 나브 버튼 + 의미별 아이콘.
## 미리보기는 절차적 유지(트랙 실루엣 가독성 — 다크 패널 장식이 작은 미리보기를 가림).
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		for b in [_create_button, _import_button, _export_button, _delete_button, _leaderboard_button]:
			_skin_button(b)
		return
	UiSkin.skin_button(_play_button, "large")
	_play_button.text = "Play"
	UiSkin.skin_button(_back_button, "small")
	for b in [_create_button, _import_button, _export_button, _delete_button, _leaderboard_button]:
		UiSkin.skin_button(b, "small", 15)
	# 트랙 변경 화살표: 정사각 단추 바탕을 제거하고 화살표 아이콘만 남긴다(투명 히트 영역
	# 48x48 유지, hover/pressed는 아이콘 틴트). focus_mode는 씬에서 0(순환 제외)이라 그대로.
	for b in [_prev_button, _next_button]:
		b.custom_minimum_size = Vector2(48, 48)
	UiSkin.skin_icon_nav(_prev_button, "prev", 26)
	UiSkin.skin_icon_nav(_next_button, "next", 26)


## 재봉 스킨 톤 버튼 스타일(액션 행 버튼을 기존 메뉴와 통일).
func _skin_button(b: Button) -> void:
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", Color(0.278, 0.203, 0.153))
	b.add_theme_color_override("font_hover_color", Color(0.2, 0.14, 0.1))
	b.add_theme_color_override("font_pressed_color", Color(0.2, 0.14, 0.1))
	b.add_theme_color_override("font_focus_color", Color(0.2, 0.14, 0.1))
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


## track_id의 현재 목록 인덱스(없으면 0). 마지막 선택 트랙 복원·import 선택 이동에 쓴다.
func _index_of(track_id: String) -> int:
	for i in range(_tracks.size()):
		if str(_tracks[i].get("track_id", "")) == track_id:
			return i
	return 0


## ←/→(및 A/D)로 트랙을 순환하고 Esc로 메인으로 돌아간다. GUI 포커스 이동보다 먼저 소비한다.
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
		KEY_ESCAPE:
			_on_back_pressed()
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
	var info_parts: PackedStringArray = PackedStringArray()
	info_parts.append("%s%s" % [badge, diff.to_upper()])
	info_parts.append("%d px" % length_px)
	info_parts.append("(%d / %d)" % [_index + 1, _tracks.size()])
	_info_label.text = "    ".join(info_parts)
	_update_fabric_row(track.fabric if track != null else "")
	_delete_button.visible = is_custom
	# 내보내기는 커스텀 트랙만(공식은 저장소에 있으니 공유 불필요 — §8).
	_export_button.visible = is_custom
	# 리더보드는 공식 트랙 + 온라인 활성일 때만(커스텀 트랙은 서버 제출/조회 대상 아님).
	_leaderboard_button.visible = not is_custom and LeaderboardClient.is_online_enabled()
	_update_best(id, diff)
	_preview.queue_redraw()


func _update_best(id: String, diff: String) -> void:
	var best: Dictionary = RecordStore.best_for(id, diff)
	if best.is_empty():
		_best_time_label.text = "Best: --:--.---"
	else:
		_best_time_label.text = "Best: " + _format_ms(int(best.get("final_time_ms", 0)))


# --- 액션 ---


func _on_play_pressed() -> void:
	_remember_current()
	GameState.start_run(_current_id(), _current_difficulty())


func _on_create_pressed() -> void:
	_remember_current()
	get_tree().change_scene_to_file(EDITOR_SCENE)


## 선택 트랙을 조회 대상으로 넘기고 리더보드 화면으로 전환한다(공식 트랙 전용).
## 복귀 씬을 이 화면으로 지정해 리더보드 뒤로가기가 맵 선택으로 돌아오게 한다.
func _on_leaderboard_pressed() -> void:
	var entry: Dictionary = _tracks[_index]
	var id: String = _current_id()
	var disp_name: String = str(entry.get("name", id))
	var track: TrackData = TrackLoader.load_track(id)
	if track != null and track.track_name != "":
		disp_name = track.track_name
	_remember_current()
	LeaderboardScreenScript.return_scene = SELF_SCENE
	LeaderboardClient.set_view_target(id, _current_difficulty(), disp_name)
	get_tree().change_scene_to_file(LEADERBOARD_SCENE)


func _on_back_pressed() -> void:
	_remember_current()
	get_tree().change_scene_to_file(MAIN_SCENE)


## 현재 선택 트랙을 마지막 선택 트랙으로 기록(재진입 복원용). 화면을 떠날 때만 호출한다.
func _remember_current() -> void:
	LeaderboardClient.remember_last_track(_current_id())


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
	# 삭제 후 포커스가 사라진 버튼에 남지 않게 안전한 곳으로 옮긴다.
	_play_button.grab_focus()
	_refresh()


# --- 불러오기 (import) ---


## "불러오기" 버튼. 웹은 브라우저 파일 선택, 데스크톱은 FileDialog를 연다.
func _on_import_pressed() -> void:
	if _web_bridge != null:
		_web_bridge.pick_file(_on_web_file_loaded)
	else:
		_import_dialog.popup_centered()


## 웹 업로드 콜백. status로 사유를 구분하고, 정상이면 공용 파이프라인으로 넘긴다.
func _on_web_file_loaded(status: String, text: String, filename: String) -> void:
	match status:
		"cancel":
			return
		"too_large":
			_toast.push("파일이 너무 큼 (1MB 초과)")
		"error":
			_toast.push("파일을 읽지 못했습니다")
		_:
			_run_import(text, _basename_no_ext(filename))


## 데스크톱 FileDialog 선택 → 파일 텍스트 → 공용 파이프라인.
func _on_import_file_selected(path: String) -> void:
	var loaded: Dictionary = _read_file_text(path)
	if not str(loaded.get("error", "")).is_empty():
		_toast.push(str(loaded["error"]))
		return
	_run_import(str(loaded["text"]), _basename_no_ext(path))


## 데스크톱 드래그드롭 → 첫 .json 파일을 공용 파이프라인으로.
func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.ends_with(".json"):
			var loaded: Dictionary = _read_file_text(f)
			if not str(loaded.get("error", "")).is_empty():
				_toast.push(str(loaded["error"]))
				return
			_run_import(str(loaded["text"]), _basename_no_ext(f))
			return


## 공용 임포트 실행. TrackLoader.import_custom_from_text로 파싱·검증·저장하고, 결과를
## 토스트로 알린 뒤 성공/중복이면 목록을 갱신해 해당 트랙을 선택 상태로 만든다.
func _run_import(text: String, suggested_name: String) -> void:
	var res: Dictionary = TrackLoader.import_custom_from_text(text, suggested_name)
	_toast.push(str(res["message"]))
	if bool(res["ok"]):
		_rebuild_tracks()
		_select_track(str(res["track_id"]))


## 파일 텍스트 읽기. {error, text} 반환(성공 시 error="").
func _read_file_text(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "파일 없음"}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "파일 열기 실패"}
	var text: String = file.get_as_text()
	file.close()
	return {"error": "", "text": text}


# --- 내보내기 (export) ---


## "내보내기" 버튼(커스텀 트랙 전용). 웹은 Blob 다운로드, 데스크톱은 저장 다이얼로그를 연다.
func _on_export_pressed() -> void:
	var entry: Dictionary = _tracks[_index]
	if not bool(entry.get("is_custom", false)):
		return
	var id: String = _current_id()
	var text: String = TrackLoader.read_custom_track_text(id)
	if text.is_empty():
		_toast.push("내보낼 트랙을 읽지 못했습니다")
		return
	var disp: String = _display_name(entry)
	var fname: String = "%s_%s.json" % [TrackLoader.sanitize_filename(disp), id]
	if _web_bridge != null:
		_web_bridge.download_text(fname, text)
		_toast.push("'%s' 트랙을 내보냈습니다" % disp)
		return
	# 데스크톱: 대상 트랙을 캡처(다이얼로그가 열린 사이 캐러셀 이동에 흔들리지 않게).
	_export_id = id
	_export_disp = disp
	_export_dialog.current_file = fname
	_export_dialog.popup_centered()


## 데스크톱 저장 다이얼로그 확정 → 커스텀 트랙 JSON 원본을 선택 경로에 그대로 복사.
func _on_export_file_selected(path: String) -> void:
	var text: String = TrackLoader.read_custom_track_text(_export_id)
	if text.is_empty():
		_toast.push("내보낼 트랙을 읽지 못했습니다")
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_toast.push("내보내기 실패 (파일 쓰기 오류)")
		return
	file.store_string(text)
	file.close()
	_toast.push("'%s' 트랙을 내보냈습니다" % _export_disp)


## 목록 항목의 표시 이름(트랙 파일의 name을 우선, 없으면 목록 캐시의 name).
func _display_name(entry: Dictionary) -> String:
	var id: String = str(entry.get("track_id", ""))
	var track: TrackData = TrackLoader.load_track(id)
	if track != null and track.track_name != "":
		return track.track_name
	return str(entry.get("name", id))


## 경로/파일명에서 확장자를 뗀 기본 이름(웹 업로드·데스크톱 공용). 예: ".../My Heart.json" → "My Heart".
static func _basename_no_ext(path: String) -> String:
	return path.get_file().get_basename()


func _select_track(track_id: String) -> void:
	_index = _index_of(track_id)
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


## InfoLabel 바로 옆(FabricRow)에 원단 스와치 + 재질 텍스트를 갱신한다. 스와치·텍스트가
## 같은 토큰 목록(_fabric_tokens)에서 파생돼 항상 일치한다. 재질 값이 비어 있는 트랙(빈
## 문자열/빈 배열)은 행 전체를 숨긴다(기존 InfoLabel이 fabric 세그먼트를 생략하던 동작과 동일).
func _update_fabric_row(fabric_value: Variant) -> void:
	var tokens: PackedStringArray = _fabric_tokens(fabric_value)
	_fabric_row.visible = not tokens.is_empty()
	if tokens.is_empty():
		_swatch_tokens = PackedStringArray()
		_hide_swatch_textures()
		return
	_fabric_text_label.text = _fabric_label(tokens)
	_swatch_tokens = tokens
	var count: int = mini(tokens.size(), _SWATCH_MAX_COUNT)
	var width: float = float(count) * _SWATCH_SIZE + float(maxi(count - 1, 0)) * _SWATCH_GAP
	_swatch_row.custom_minimum_size = Vector2(width, _SWATCH_SIZE)
	_layout_swatch_textures(tokens, count)
	_swatch_row.queue_redraw()


func _hide_swatch_textures() -> void:
	for tr in _swatch_texture_rects:
		tr.visible = false


## 스와치의 타일 텍스처는 자식 TextureRect(+AtlasTexture 크롭) 실 노드로 배치한다 — 방금
## load()한 CompressedTexture2D를 draw_texture_rect*로 직접 그리면 이 프로젝트 GL
## Compatibility 렌더러에서 "첫 draw가 빈 화면(흰색)으로 남는" 증상이 실측 확인됐다
## (TextureRect처럼 정식 노드 경로로 텍스처를 배정하면 해결됨 — 엔진/드라이버 쪽 텍스처
## 초기화 타이밍 문제로 추정, ImageTexture로 바꿔도 동일 증상이라 리소스 자체 문제는 아니다).
## 배경 패치·스티치 테두리는 계속 draw 시그널로 절차적으로 그린다(텍스처가 없어 문제없음).
func _layout_swatch_textures(tokens: PackedStringArray, count: int) -> void:
	var inset: float = _SWATCH_RADIUS * 0.5
	for i in range(_SWATCH_MAX_COUNT):
		var tr: TextureRect = _swatch_texture_rects[i]
		if i >= count:
			tr.visible = false
			continue
		var src: Dictionary = FabricSurface.swatch_source(tokens[i])
		var tex: Texture2D = src.get("texture", null)
		if tex == null:
			tr.visible = false
			continue
		var x: float = float(i) * (_SWATCH_SIZE + _SWATCH_GAP)
		tr.position = Vector2(x + inset, inset)
		tr.size = Vector2(_SWATCH_SIZE, _SWATCH_SIZE) - Vector2(inset, inset) * 2.0
		var tex_size: Vector2 = tex.get_size()
		var crop: float = minf(tex_size.x, tex_size.y) * 0.55
		var atlas: AtlasTexture = AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2((tex_size - Vector2(crop, crop)) * 0.5, Vector2(crop, crop))
		tr.texture = atlas
		tr.visible = true


## SwatchRow의 draw 시그널 핸들러. 토큰별로 나란히(최대 _SWATCH_MAX_COUNT개) 배경 패치 +
## 스티치 테두리를 그린다(다중 재질 배열 대비 §요구 3). 타일 텍스처 자체는
## _layout_swatch_textures가 배치한 자식 TextureRect가 그 위에 겹쳐 보여준다.
func _on_swatch_row_draw() -> void:
	var count: int = mini(_swatch_tokens.size(), _SWATCH_MAX_COUNT)
	for i in range(count):
		var x: float = float(i) * (_SWATCH_SIZE + _SWATCH_GAP)
		var rect: Rect2 = Rect2(Vector2(x, 0.0), Vector2(_SWATCH_SIZE, _SWATCH_SIZE))
		_draw_swatch(rect, _swatch_tokens[i])


## 스와치 1개의 배경 패치 + 스티치 테두리. FabricSurface.swatch_source(단일 소스:
## FABRIC_BASE/FABRIC_DIR)에서 대표색을 읽어 채운다(타일 텍스처가 있는 원단도 텍스처
## 로드 전 배경 겸 여백 색으로 쓰인다). 완전 미지 재질은 회색 패치로 폴백한다(§요구 4).
func _draw_swatch(rect: Rect2, token: String) -> void:
	var src: Dictionary = FabricSurface.swatch_source(token)
	var known: bool = bool(src.get("known", false))
	var fill: Color = src.get("color", _SWATCH_UNKNOWN_COLOR) if known else _SWATCH_UNKNOWN_COLOR
	SewingSkin.draw_patch(_swatch_row, rect, fill, _SWATCH_RADIUS, false)
	SewingSkin.draw_stitch_border(
		_swatch_row, rect, _SWATCH_STITCH_COLOR, _SWATCH_STITCH_INSET, _SWATCH_RADIUS, 1.0
	)


## 트랙의 fabric 값에서 개별 재질 토큰(공백 제거, 빈 값 제외)을 뽑는다. 문자열/배열 모두
## 그대로 수용한다(현재 트랙 JSON 스키마는 fabric을 단일 문자열로 고정하지만, 추후 트랙
## 1개에 원단 재질이 여러 개인 스키마 확장을 고려). _fabric_label과 스와치 렌더가 이
## 토큰 목록을 공유해 텍스트·스와치가 항상 같은 소스에서 파생된다.
static func _fabric_tokens(value: Variant) -> PackedStringArray:
	var raw: Array = value if value is Array else [value]
	var tokens: PackedStringArray = PackedStringArray()
	for item in raw:
		var trimmed: String = str(item).strip_edges()
		if not trimmed.is_empty():
			tokens.append(trimmed)
	return tokens


## 재질 토큰 목록 → 한국어 라벨 조인 텍스트(FABRIC_LABELS, 예: ["cotton","silk"] → "면 · 실크").
## 지원 목록에 없는 토큰은 원문을 그대로 쓴다. 빈 목록이면 "".
static func _fabric_label(tokens: PackedStringArray) -> String:
	var labels: PackedStringArray = PackedStringArray()
	for token in tokens:
		labels.append(str(FABRIC_LABELS.get(token, token)))
	return " · ".join(labels)


static func _format_ms(ms: int) -> String:
	var minutes: int = ms / 60000
	var secs: int = (ms / 1000) % 60
	var millis: int = ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]


## 메뉴 BGM(메뉴 곡)을 시작한다. /root/AudioManager 런타임 조회 + has_method 가드로 부르므로
## 오토로드가 없어도 안전하게 무시된다(AudioManager 훅 계약). 인게임(Locking_In)에서 이 화면으로
## 복귀하면 메뉴 곡(Sewed)으로 전환하고, 이미 메뉴 곡이 재생 중이면 재시작하지 않는다.
func _play_menu_bgm() -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null and am.has_method("play_bgm"):
		am.play_bgm("menu")
