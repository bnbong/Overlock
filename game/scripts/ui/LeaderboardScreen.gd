extends Control
## 리더보드 조회 화면(재봉 스킨 목록). 선택한 트랙의 Top 100 기록을 GET /api/leaderboard로
## 받아 rank·닉네임·시간(MM:SS.mmm)·재봉 등급·accuracy·cuts로 렌더한다(기획서 §18 Phase 5
## 트랙별 Top 100). 정렬은 서버가 등급 우선 → 시간 차선으로 반환한다(§14.1). 등급은 서버
## grade 필드를 우선하고 없으면 로컬 유도한다(_grade_text). 로딩/에러/빈 상태를 표시한다.
##
## 진입 경로는 둘이다. 맵 선택 화면에서 "이 트랙 리더보드"로 열면 해당 트랙으로 시작하고,
## 메인에서 직접 열면 트랙 컨텍스트가 없으므로 첫 공식 트랙으로 자체 초기화한다. 어느
## 경우든 화면 안 ◀▶(및 ←→ 키)로 공식 트랙 사이를 전환할 수 있다(커스텀 트랙은 서버
## 제출/조회 대상이 아니라 제외). 뒤로가기는 진입한 곳(return_scene)으로 돌아간다.
##
## 조회 대상(track_id·difficulty·name)은 LeaderboardClient.view_* 에서 읽고 쓴다.

const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_SOFT: Color = Color(0.435, 0.337, 0.267)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)

# 열 최소 폭(헤더·데이터 행 공통으로 써 정렬을 맞춘다). Grade 열을 추가하며 Time/Acc/Cuts
# 를 소폭 줄이고 Name(확장 열)이 남는 폭을 흡수하게 했다 — 합계 min ≈ 482px 로 패널 내부
# 폭(≈524px) 안에 들어가 가로 넘침이 없다(clip_text 로 초과 문자열은 잘린다).
const _COL_RANK: float = 48.0
const _COL_NAME: float = 128.0
const _COL_TIME: float = 112.0
const _COL_GRADE: float = 52.0
const _COL_ACC: float = 64.0
const _COL_CUTS: float = 48.0

# 리더보드를 연 곳으로 돌아가기 위한 복귀 씬(메인 또는 맵 선택). 진입 직전 호출자가
# 이 정적 변수를 설정한다. 정적 변수라 씬 전환 사이에도 유지된다(오토로드 미사용).
static var return_scene: String = "res://scenes/Main.tscn"

# 공식 트랙 목록(◀▶ 전환 대상)과 현재 인덱스.
var _official: Array = []
var _index: int = 0

# 텍스트 색(기본 잉크). 다크 패널 스킨 적용 시 밝은 크림으로 전환해 가독성 유지.
var _c_main: Color = _INK
var _c_soft: Color = _INK_SOFT

@onready var _title_label: Label = $Panel/TitleLabel
@onready var _sub_label: Label = $Panel/TrackNav/SubLabel
@onready var _prev_button: Button = $Panel/TrackNav/PrevButton
@onready var _next_button: Button = $Panel/TrackNav/NextButton
@onready var _status_label: Label = $Panel/StatusLabel
@onready var _header_box: HBoxContainer = $Panel/HeaderRow
@onready var _list: VBoxContainer = $Panel/Scroll/List
@onready var _my_record_panel: PanelContainer = $Panel/MyRecordPanel
@onready var _my_record_label: Label = $Panel/MyRecordPanel/MyRecordLabel
@onready var _back_button: Button = $Panel/BackButton


func _ready() -> void:
	_title_label.text = "LEADERBOARD"
	_official = TrackLoader.list_tracks().duplicate(true)
	# 조회 대상이 비었거나(메인 직접 진입) 목록에 없으면 첫 공식 트랙으로 자체 초기화한다.
	_apply_track(_official_index_of(LeaderboardClient.view_track_id))
	_apply_skin()
	_fill_header()
	_my_record_panel.add_theme_stylebox_override("panel", _mine_box())
	_update_my_record()
	var single: bool = _official.size() <= 1
	_prev_button.disabled = single
	_next_button.disabled = single
	_prev_button.pressed.connect(_cycle_track.bind(-1))
	_next_button.pressed.connect(_cycle_track.bind(1))
	_back_button.pressed.connect(_on_back_pressed)
	LeaderboardClient.leaderboard_fetched.connect(_on_fetched)
	_back_button.grab_focus()
	_refetch()


## 사용자 제공 시트 스킨(있으면): 다크 패널을 리더보드 목록 배경으로 깔고 텍스트를
## 밝은 크림으로 전환(가독성). ◀▶는 정사각 나브 버튼, 뒤로는 소형 필. 없으면 절차 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		for b in [_prev_button, _next_button, _back_button]:
			_skin_button(b)
		return
	UiSkin.skin_panel(get_node("PanelBg"), "dark")
	_c_main = UiSkin.CREAM
	_c_soft = Color(0.80, 0.74, 0.64)
	_title_label.add_theme_color_override("font_color", UiSkin.CREAM)
	_sub_label.add_theme_color_override("font_color", _c_soft)
	_status_label.add_theme_color_override("font_color", _c_soft)
	for b in [_prev_button, _next_button]:
		UiSkin.skin_button(b, "square")
		b.custom_minimum_size = Vector2(46, 46)
	UiSkin.set_icon(_prev_button, "prev", 24, true)
	UiSkin.set_icon(_next_button, "next", 24, true)
	UiSkin.skin_button(_back_button, "small", 16)


## 현재 조회 대상을 공식 트랙 idx로 맞춘다(view_* 갱신 + 부제 갱신). 목록에 없으면
## idx=0로 보정한다. 트랙 JSON의 이름·난이도를 권위 있는 값으로 우선한다.
func _apply_track(idx: int) -> void:
	if _official.is_empty():
		return
	_index = clampi(idx, 0, _official.size() - 1)
	var entry: Dictionary = _official[_index]
	var id: String = str(entry.get("track_id", ""))
	var disp_name: String = str(entry.get("name", id))
	var diff: String = str(entry.get("difficulty", "normal"))
	var track: TrackData = TrackLoader.load_track(id)
	if track != null:
		if track.track_name != "":
			disp_name = track.track_name
		if track.difficulty != "":
			diff = track.difficulty
	LeaderboardClient.set_view_target(id, diff, disp_name)
	_sub_label.text = "%s — %s" % [disp_name, diff.to_upper()]


## view_track_id의 공식 목록 인덱스(없으면 0).
func _official_index_of(track_id: String) -> int:
	for i in range(_official.size()):
		if str(_official[i].get("track_id", "")) == track_id:
			return i
	return 0


## ◀▶ / ←→로 공식 트랙을 순환하고 새 트랙 리더보드를 다시 불러온다.
func _cycle_track(dir: int) -> void:
	if _official.size() <= 1:
		return
	_apply_track(wrapi(_index + dir, 0, _official.size()))
	_update_my_record()
	_refetch()


func _refetch() -> void:
	_clear_list()
	_status_label.text = "불러오는 중..."
	_status_label.visible = true
	LeaderboardClient.fetch_leaderboard(
		LeaderboardClient.view_track_id, LeaderboardClient.view_difficulty
	)


## ←/→로 트랙 전환, Esc로 진입한 곳으로 복귀. GUI 포커스 이동보다 먼저 소비한다.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_LEFT, KEY_A:
			_cycle_track(-1)
			get_viewport().set_input_as_handled()
		KEY_RIGHT, KEY_D:
			_cycle_track(1)
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			_on_back_pressed()
			get_viewport().set_input_as_handled()


func _on_fetched(success: bool, entries: Array, message: String) -> void:
	_clear_list()
	if not success:
		_status_label.text = message
		_status_label.visible = true
		return
	if entries.is_empty():
		_status_label.text = "아직 기록이 없습니다."
		_status_label.visible = true
		return
	_status_label.visible = false
	for i in range(entries.size()):
		if not (entries[i] is Dictionary):
			continue
		_list.add_child(_make_data_row(entries[i], i))


## 헤더 행 채우기(데이터 행과 동일 열 폭).
func _fill_header() -> void:
	_add_cell(_header_box, "#", _COL_RANK, _c_main, HORIZONTAL_ALIGNMENT_RIGHT)
	_add_cell(_header_box, "Player", _COL_NAME, _c_main, HORIZONTAL_ALIGNMENT_LEFT, true)
	_add_cell(_header_box, "Time", _COL_TIME, _c_main, HORIZONTAL_ALIGNMENT_RIGHT)
	_add_cell(_header_box, "Grade", _COL_GRADE, _c_main, HORIZONTAL_ALIGNMENT_CENTER)
	_add_cell(_header_box, "Acc", _COL_ACC, _c_main, HORIZONTAL_ALIGNMENT_RIGHT)
	_add_cell(_header_box, "Cuts", _COL_CUTS, _c_main, HORIZONTAL_ALIGNMENT_RIGHT)


## 한 엔트리를 행으로 만든다. rank는 응답 값 우선, 없으면 인덱스+1로 보정한다. 내 닉네임과
## 일치하는 행은 금색 하이라이트 박스(배경 틴트+테두리)로 감싸 top-3 색 강조와 구분한다.
func _make_data_row(entry: Dictionary, index: int) -> Control:
	var rank: int = int(entry.get("rank", index + 1))
	var name_text: String = str(entry.get("player_name", "-"))
	var time_text: String = _format_ms(int(entry.get("final_time_ms", 0)))
	var grade_text: String = _grade_text(entry)
	var acc_text: String = "%.1f%%" % float(entry.get("accuracy", 0.0))
	var cuts_text: String = str(int(entry.get("cuts", 0)))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	# top-3 강조(금/은/동 톤), 그 외는 옅은 잉크.
	var rank_color: Color = _rank_color(rank)
	_add_cell(row, str(rank), _COL_RANK, rank_color, HORIZONTAL_ALIGNMENT_RIGHT)
	_add_cell(row, name_text, _COL_NAME, _c_main, HORIZONTAL_ALIGNMENT_LEFT, true)
	_add_cell(row, time_text, _COL_TIME, _c_main, HORIZONTAL_ALIGNMENT_RIGHT)
	# 등급은 FinishView.grade_color 로 등급별 색(S 금 ~ D 붉은톤) — 결과 화면과 동일 팔레트.
	var grade_col: Color = FinishView.grade_color(grade_text)
	_add_cell(row, grade_text, _COL_GRADE, grade_col, HORIZONTAL_ALIGNMENT_CENTER)
	_add_cell(row, acc_text, _COL_ACC, _c_soft, HORIZONTAL_ALIGNMENT_RIGHT)
	_add_cell(row, cuts_text, _COL_CUTS, _c_soft, HORIZONTAL_ALIGNMENT_RIGHT)
	if not _is_mine(name_text):
		return row
	var mine: PanelContainer = PanelContainer.new()
	mine.add_theme_stylebox_override("panel", _mine_box())
	mine.add_child(row)
	return mine


## 행에 표시할 재봉 등급 문자. 서버 grade 필드를 권위 있는 값으로 우선한다(결과 화면
## 등급과 정확히 일치, 정렬 기준과도 동일). 구버전 서버가 grade 를 주지 않으면 응답
## 메트릭으로 로컬 유도한다(RunStats 와 동일 공식). 구버전은 perfect_rate 도 주지 않으므로
## accuracy 를 근사치로 대입하는 폴백이다(정확 값은 신버전 서버에서만).
func _grade_text(entry: Dictionary) -> String:
	var g: String = str(entry.get("grade", "")).strip_edges()
	if not g.is_empty():
		return g
	var accuracy: float = float(entry.get("accuracy", 0.0))
	var perfect: float = float(entry.get("perfect_rate", accuracy))
	var cuts: int = int(entry.get("cuts", 0))
	return RunStats.grade_from_metrics(accuracy, perfect, cuts)


## 리더보드 행/하단 기록에 쓰는 "내 것" 판정(닉네임 정확 일치, 빈 닉네임 제외).
func _is_mine(player_name: String) -> bool:
	var me: String = LeaderboardClient.nickname.strip_edges()
	return not me.is_empty() and player_name.strip_edges() == me


## 하단 고정 "내 기록" 행: 현재 트랙·난이도의 로컬 최고 기록(RecordStore) + 마지막 제출 시
## 서버가 돌려준 순위(캐시, "제출 시점"). 기록 없으면 안내만 표시한다.
func _update_my_record() -> void:
	_my_record_label.add_theme_color_override("font_color", _c_main)
	var rec: Dictionary = RecordStore.best_for(
		LeaderboardClient.view_track_id, LeaderboardClient.view_difficulty
	)
	if rec.is_empty():
		_my_record_label.text = "내 기록:  아직 기록 없음"
		return
	var line: String = (
		"내 기록:  %s   ·   %.1f%%   ·   Cuts %d"
		% [
			_format_ms(int(rec.get("final_time_ms", 0))),
			float(rec.get("accuracy", 0.0)),
			int(rec.get("cuts", 0)),
		]
	)
	var rank: int = LeaderboardClient.submitted_rank(
		LeaderboardClient.view_track_id, LeaderboardClient.view_difficulty
	)
	if rank > 0:
		line += "   ·   Rank #%d (제출 시점)" % rank
	_my_record_label.text = line


## 금색 하이라이트 박스(내 행·내 기록 공용). top-3 색 강조와 달리 배경 틴트+테두리다.
static func _mine_box() -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.96, 0.80, 0.32, 0.24)
	sb.border_color = Color(0.94, 0.75, 0.28)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(7)
	sb.content_margin_left = 5.0
	sb.content_margin_right = 5.0
	sb.content_margin_top = 3.0
	sb.content_margin_bottom = 3.0
	return sb


func _add_cell(
	box: HBoxContainer, text: String, min_w: float, color: Color, align: int, expand: bool = false
) -> void:
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(min_w, 0)
	label.horizontal_alignment = align
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 16)
	label.clip_text = true
	if expand:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(label)


## 상위 3위 강조 색(금/은/동), 그 외 본문색(패널 톤에 맞춰 잉크/크림).
func _rank_color(rank: int) -> Color:
	match rank:
		1:
			return Color(0.90, 0.72, 0.28)
		2:
			return Color(0.72, 0.74, 0.78)
		3:
			return Color(0.80, 0.56, 0.36)
	return _c_soft


func _clear_list() -> void:
	for child in _list.get_children():
		child.queue_free()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(return_scene)


func _skin_button(b: Button) -> void:
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", _INK)
	b.add_theme_color_override("font_hover_color", _INK_HOVER)
	b.add_theme_color_override("font_pressed_color", _INK_HOVER)
	b.add_theme_color_override("font_focus_color", _INK_HOVER)
	b.add_theme_color_override("font_disabled_color", Color(0.5, 0.44, 0.38))
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
	b.add_theme_stylebox_override(
		"disabled", _box(Color(0.6, 0.55, 0.47, 0.6), Color(0.45, 0.4, 0.34))
	)


static func _box(bg: Color, border: Color, bw: int = 2) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


static func _format_ms(ms: int) -> String:
	var minutes: int = ms / 60000
	var secs: int = (ms / 1000) % 60
	var millis: int = ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]
