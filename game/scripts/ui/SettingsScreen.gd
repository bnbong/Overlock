extends Control
## 온라인 설정 화면(재봉 스킨 패널). 닉네임(1~16자)과 소리 크기(마스터/배경음/효과음)를
## 입력·저장한다(기획서 §18 Phase 5 닉네임 입력, §7 오디오 볼륨). 저장은 LeaderboardClient가
## user://settings.json에 영속하고, 버스 반영은 AudioManager가 담당한다.
##
## 서버 URL은 UI에서 제거했다(배포 시 데스크톱 기본값=프로덕션, 웹=same-origin 자동).
## 셀프호스팅/개발은 user://settings.json에 base_url을 수동으로 적어 우선시킨다. 닉네임 변경은
## 메인 화면의 닉네임 태그로도 가능하다(진입점 중복 허용).
##
## 저장 규칙(v2.2.1):
##  - 소리·조향 슬라이더는 자동 저장이다. 값이 바뀌면(value_changed: 마우스·터치 드래그, 키보드, 휠,
##    직접 값 변경 모두) 버스·Tuning에 바로 반영하고, 디스크 쓰기는 SAVE_DELAY 뒤 한 번으로 모은다.
##    드래그를 놓으면(drag_ended) 기다리지 않고 바로 쓴다. 뒤로 가거나 화면이 사라질 때, 창을 닫거나
##    앱이 백그라운드로 갈 때도 대기 중인 쓰기를 즉시 반영한다. 쓰기에 실패하면 상태 줄에 알리고,
##    그 상태로 뒤로를 누르면 한 번은 머물며 다시 알린다(두 번째에 저장 없이 나간다).
##  - 닉네임은 명시 저장이다. "닉네임 저장"(또는 Enter)만 저장하고, 저장하지 않은 수정은 화면을 떠나면
##    취소된다. 저장 실패는 상태 줄에 알리고 이전 닉네임을 유지한다(LeaderboardClient.save_nickname).
## 마스터/효과음 슬라이더는 조작 종료 시 효과음을 1회 미리듣기해 체감을 확인시킨다(배경음은 제외).
## 터치 기기에서는 MenuTouch 두 열 배치(왼쪽 닉네임, 오른쪽 슬라이더)를 쓰고, 닉네임 칸에 처음부터
## 포커스를 주지 않는다. 포커스를 받으면 웹 가상 키보드가 떠서 슬라이더를 가릴 수 있기 때문이다.
## 칸을 탭하면 포커스와 함께 키보드가 뜬다(docs/mobile.md §5.1.1).

const MAIN_SCENE: String = "res://scenes/Main.tscn"
## 자동 저장 지연(초). 키보드 연타·휠·드래그 중 값 변화를 이 간격 뒤 한 번의 디스크 쓰기로 모은다.
const SAVE_DELAY: float = 0.4
const AUTOSAVE_FAIL_MSG: String = "소리·조향 설정을 저장하지 못했습니다(이번 실행에만 적용)."
const LEAVE_WARN_MSG: String = "설정을 저장하지 못했습니다. 뒤로를 다시 누르면 그냥 나갑니다."
const NICK_PENDING_MSG: String = "'닉네임 저장'을 눌러야 바뀝니다. 그냥 나가면 취소됩니다."
const _WARN: Color = Color(0.72, 0.2, 0.16)

# 재봉 스킨 버튼 톤(MainMenu와 통일).
const _INK: Color = Color(0.278, 0.203, 0.153)
const _INK_HOVER: Color = Color(0.2, 0.14, 0.1)
# 볼륨 슬라이더 재봉 톤(SewingSkin 팔레트 계승).
const _THREAD: Color = Color(0.553, 0.384, 0.725)  # 실 보라(채운 구간)
const _THREAD_HI: Color = Color(0.616, 0.435, 0.784)  # 강조(하이라이트)
const _FABRIC_DEEP: Color = Color(0.796, 0.726, 0.576)  # 원단 그늘(트랙 바탕)
const _KNOT: Color = Color(0.478, 0.333, 0.243)  # 단추/매듭(그래버)
const _KNOT_HI: Color = Color(0.6, 0.44, 0.34)

var _save_timer: Timer
var _volumes_dirty: bool = false
var _steer_dirty: bool = false
var _autosave_failed: bool = false
var _leave_warned: bool = false
var _grabber_d: int = 18

@onready var _nick_edit: LineEdit = $Panel/NickRow/NickEdit
@onready var _hint_label: Label = $Panel/HintLabel
@onready var _status_label: Label = $Panel/StatusLabel
@onready var _save_button: Button = $Panel/SaveButton
@onready var _back_button: Button = $Panel/BackButton
@onready var _master_slider: HSlider = $Panel/MasterRow/MasterSlider
@onready var _master_value: Label = $Panel/MasterRow/MasterValue
@onready var _bgm_slider: HSlider = $Panel/BgmRow/BgmSlider
@onready var _bgm_value: Label = $Panel/BgmRow/BgmValue
@onready var _sfx_slider: HSlider = $Panel/SfxRow/SfxSlider
@onready var _sfx_value: Label = $Panel/SfxRow/SfxValue
@onready var _steer_slider: HSlider = $Panel/SteerRow/SteerSlider
@onready var _steer_value: Label = $Panel/SteerRow/SteerValue


func _ready() -> void:
	_nick_edit.max_length = LeaderboardClient.NICKNAME_MAX
	_nick_edit.text = LeaderboardClient.nickname
	_hint_label.text = "리더보드에 표시될 닉네임 (1~16자)"
	_save_button.text = "닉네임 저장"
	# 자동 저장 항목 표시(소리·조향은 바꾸면 바로 저장된다).
	var volume_title: Label = $Panel/VolumeTitle
	var steer_title: Label = $Panel/SteerTitle
	volume_title.text = "소리 크기 · 자동 저장"
	steer_title.text = "조향 감도 · 자동 저장"
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY
	_save_timer.timeout.connect(_flush_prefs)
	add_child(_save_timer)
	_apply_skin()
	_apply_touch_layout()
	_setup_volume()
	_setup_steer()
	_save_button.pressed.connect(_on_save_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	_nick_edit.text_submitted.connect(_on_nick_submitted)
	_nick_edit.text_changed.connect(_on_nick_changed)
	_status_label.text = ""
	# 상태 문구가 길어도 패널 폭을 밀지 않게 줄을 바꾼다(짧은 문구는 전과 같은 한 줄).
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if not MenuTouch.active():
		_nick_edit.grab_focus()


## 화면이 사라지거나 창을 닫거나 앱이 백그라운드로 가면 대기 중인 자동 저장을 즉시 쓴다.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_EXIT_TREE, NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED:
			_flush_prefs()
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_flush_prefs()


func _on_nick_submitted(_text: String) -> void:
	_on_save_pressed()


## 저장하지 않은 닉네임 수정이 있으면 저장 방법과 취소 규칙을 알린다.
func _on_nick_changed(text: String) -> void:
	if text.strip_edges() != LeaderboardClient.nickname.strip_edges():
		_set_status(NICK_PENDING_MSG)
	elif _status_label.text == NICK_PENDING_MSG:
		_set_status("")


## "닉네임 저장": 닉네임만 명시적으로 저장한다(소리·조향은 자동 저장이라 여기서 다루지 않는다).
func _on_save_pressed() -> void:
	var nick: String = _nick_edit.text.strip_edges()
	if nick.is_empty():
		_set_status("닉네임을 입력하세요 (1~16자)", true)
		return
	if not LeaderboardClient.save_nickname(nick):
		_set_status("닉네임 저장 실패: 설정 파일에 쓸 수 없습니다. 이전 닉네임을 유지합니다.", true)
		return
	# 정규화된 값으로 필드를 되비춘다(공백 제거 등).
	_nick_edit.text = LeaderboardClient.nickname
	_set_status("닉네임을 저장했습니다")


## 뒤로: 대기 중인 자동 저장을 쓰고 나간다. 저장하지 않은 닉네임 수정은 버린다(취소).
## 자동 저장에 실패한 상태면 한 번은 머물며 알리고, 다시 누르면 저장 없이 나간다.
func _on_back_pressed() -> void:
	if not _flush_prefs() and not _leave_warned:
		_leave_warned = true
		_set_status(LEAVE_WARN_MSG, true)
		return
	get_tree().change_scene_to_file(MAIN_SCENE)


func _set_status(text: String, warn: bool = false) -> void:
	_status_label.text = text
	var color: Color = _WARN if warn else Color(0.478, 0.333, 0.243)
	_status_label.add_theme_color_override("font_color", color)


# --- 자동 저장(소리·조향) ---


## 슬라이더 값이 바뀌었다: 쓰기를 SAVE_DELAY 뒤로 미룬다(연속 입력은 타이머를 다시 시작해 한 번으로 모은다).
func _mark_dirty(volumes: bool) -> void:
	if volumes:
		_volumes_dirty = true
	else:
		_steer_dirty = true
	if _save_timer != null and _save_timer.is_inside_tree():
		_save_timer.start()


## 대기 중인 소리·조향 변경을 지금 쓴다. 쓸 것이 없으면 true. 실패하면 다음 변경·떠날 때 다시 쓴다.
func _flush_prefs() -> bool:
	if _save_timer != null:
		_save_timer.stop()
	if not _volumes_dirty and not _steer_dirty:
		return true
	var ok: bool = true
	if _volumes_dirty:
		_volumes_dirty = not _persist_volumes()
		ok = ok and not _volumes_dirty
	if _steer_dirty:
		_steer_dirty = not _persist_steer()
		ok = ok and not _steer_dirty
	if not is_inside_tree():
		return ok
	if not ok:
		_autosave_failed = true
		_set_status(AUTOSAVE_FAIL_MSG, true)
	elif _autosave_failed:
		_autosave_failed = false
		_leave_warned = false
		_set_status("소리·조향 설정을 저장했습니다")
	return ok


## 터치 기기: 두 열(왼쪽 닉네임·저장·상태, 오른쪽 소리·조향 슬라이더)로 다시 배치하고 조작 영역을 키운다.
## 뒤로 버튼은 아래 가운데에 둔다. 데스크톱 배치는 그대로다.
func _apply_touch_layout() -> void:
	if not MenuTouch.active():
		return
	var panel: VBoxContainer = $Panel
	MenuTouch.set_box(get_node("PanelBg"), Vector2(620.0, 352.0))
	MenuTouch.set_box(panel, Vector2(566.0, 318.0))
	panel.add_theme_constant_override("separation", 12)
	var nick_row: HBoxContainer = $Panel/NickRow
	var left: Array = [nick_row, _hint_label, _save_button, _status_label]
	var right: Array = [$Panel/VolumeTitle, $Panel/MasterRow, $Panel/BgmRow, $Panel/SfxRow]
	right.append_array([$Panel/SteerTitle, $Panel/SteerRow])
	MenuTouch.columns(panel, 1, left, right, 36)
	_nick_edit.custom_minimum_size.x = 0.0
	MenuTouch.edit(_nick_edit)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	MenuTouch.buttons([_save_button, _back_button])
	_back_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_back_button.custom_minimum_size.x = 420.0
	for row in [nick_row] + right:
		for c in (row as Node).get_children():
			if c is Label:
				MenuTouch.text(c)
		if row is Label:
			MenuTouch.text(row)
	MenuTouch.texts([_hint_label, _status_label])
	for s in [_master_slider, _bgm_slider, _sfx_slider, _steer_slider]:
		(s as HSlider).custom_minimum_size.y = MenuTouch.SLIDER_H
	for v in [_master_value, _bgm_value, _sfx_value, _steer_value]:
		(v as Label).custom_minimum_size.x = 72.0
	_grabber_d = MenuTouch.GRABBER_D


# --- 볼륨(마스터/배경음/효과음) ---


## 세 슬라이더를 현재 버스 볼륨(AudioManager)으로 초기화하고 시그널을 배선한다. 값 설정을
## 시그널 연결보다 먼저 해 초기화 시 불필요한 set/미리듣기가 튀지 않게 한다.
func _setup_volume() -> void:
	_init_slider(_master_slider, _master_value, AudioManager.get_master_volume())
	_init_slider(_bgm_slider, _bgm_value, AudioManager.get_bgm_volume())
	_init_slider(_sfx_slider, _sfx_value, AudioManager.get_sfx_volume())
	_master_slider.value_changed.connect(_on_master_changed)
	_bgm_slider.value_changed.connect(_on_bgm_changed)
	_sfx_slider.value_changed.connect(_on_sfx_changed)
	# 조작 종료 시: 기다리지 않고 바로 영속. 마스터/효과음은 효과음 1회 미리듣기(preview=true).
	_master_slider.drag_ended.connect(_on_volume_drag_ended.bind(true))
	_bgm_slider.drag_ended.connect(_on_volume_drag_ended.bind(false))
	_sfx_slider.drag_ended.connect(_on_volume_drag_ended.bind(true))


func _init_slider(slider: HSlider, value_label: Label, linear: float) -> void:
	_skin_slider(slider)
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = roundf(linear * 100.0)
	_update_percent(value_label, slider.value)


func _update_percent(value_label: Label, percent: float) -> void:
	value_label.text = "%d%%" % int(round(percent))


func _on_master_changed(percent: float) -> void:
	AudioManager.set_master_volume(percent / 100.0)
	_update_percent(_master_value, percent)
	_mark_dirty(true)


func _on_bgm_changed(percent: float) -> void:
	AudioManager.set_bgm_volume(percent / 100.0)
	_update_percent(_bgm_value, percent)
	_mark_dirty(true)


func _on_sfx_changed(percent: float) -> void:
	AudioManager.set_sfx_volume(percent / 100.0)
	_update_percent(_sfx_value, percent)
	_mark_dirty(true)


## 슬라이더 조작 종료: 대기 중인 변경을 바로 쓰고, 마스터/효과음이면 효과음 미리듣기를 1회 재생한다.
func _on_volume_drag_ended(_value_changed: bool, preview: bool) -> void:
	_flush_prefs()
	if preview:
		AudioManager.preview_sfx()


## 현재 버스 볼륨(AudioManager 권위값)을 settings.json에 영속한다. 성공하면 true.
func _persist_volumes() -> bool:
	var master: float = AudioManager.get_master_volume()
	var bgm: float = AudioManager.get_bgm_volume()
	return LeaderboardClient.save_volumes(master, bgm, AudioManager.get_sfx_volume())


# --- 조향 감도(부드러움) — 볼륨 슬라이더와 동형. Tuning.steer_expo를 라이브로 구동하고
#     조작 종료/저장 시 LeaderboardClient가 settings.json에 영속한다. turn_power 배율(불공정
#     판정)이 아니라 heading 출력 expo만 바꾸므로 풀락 기하·리스크 판정은 불변이다.


## 슬라이더를 현재 Tuning.steer_expo로 초기화하고 시그널을 배선한다(값 설정을 연결보다 먼저 해
## 초기화 시 불필요한 set이 튀지 않게 한다 — 볼륨 패턴 동일).
func _setup_steer() -> void:
	_skin_slider(_steer_slider)
	_steer_slider.min_value = 0.0
	_steer_slider.max_value = 100.0
	_steer_slider.step = 1.0
	_steer_slider.value = roundf(_expo_to_percent(Tuning.steer_expo))
	_update_percent(_steer_value, _steer_slider.value)
	_steer_slider.value_changed.connect(_on_steer_changed)
	_steer_slider.drag_ended.connect(_on_steer_drag_ended)


func _on_steer_changed(percent: float) -> void:
	Tuning.steer_expo = _percent_to_expo(percent)
	_update_percent(_steer_value, percent)
	_mark_dirty(false)


## 슬라이더 조작 종료: 대기 중인 변경을 바로 쓴다(볼륨과 달리 미리듣기 없음).
func _on_steer_drag_ended(_value_changed: bool) -> void:
	_flush_prefs()


## 현재 Tuning.steer_expo를 settings.json에 영속한다(LeaderboardClient가 클램프 소유자). 성공하면 true.
func _persist_steer() -> bool:
	return LeaderboardClient.save_steer_expo(Tuning.steer_expo)


## steer_expo(∈[MIN,MAX]) → 부드러움 퍼센트(0..100). 슬라이더/표시용(볼륨 %와 동형).
func _expo_to_percent(expo: float) -> float:
	var span: float = LeaderboardClient.STEER_EXPO_MAX - LeaderboardClient.STEER_EXPO_MIN
	return clampf((expo - LeaderboardClient.STEER_EXPO_MIN) / span * 100.0, 0.0, 100.0)


## 부드러움 퍼센트(0..100) → steer_expo(∈[MIN,MAX]).
func _percent_to_expo(percent: float) -> float:
	var span: float = LeaderboardClient.STEER_EXPO_MAX - LeaderboardClient.STEER_EXPO_MIN
	return LeaderboardClient.STEER_EXPO_MIN + percent / 100.0 * span


## 재봉 톤 슬라이더 스타일: 원단 그늘 트랙 + 실 보라 채움 + 단추(매듭) 그래버.
func _skin_slider(slider: HSlider) -> void:
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = _FABRIC_DEEP
	track.set_corner_radius_all(4)
	# 터치 배치에서는 트랙을 두껍게(손가락으로 짚기 쉽게) 한다. 데스크톱은 4 그대로.
	var thick: float = 4.0 if _grabber_d <= 18 else 9.0
	track.content_margin_top = thick
	track.content_margin_bottom = thick
	slider.add_theme_stylebox_override("slider", track)
	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = _THREAD
	fill.set_corner_radius_all(4)
	slider.add_theme_stylebox_override("grabber_area", fill)
	var fill_hi: StyleBoxFlat = fill.duplicate()
	fill_hi.bg_color = _THREAD_HI
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_hi)
	slider.add_theme_icon_override("grabber", _make_grabber(_KNOT, _grabber_d))
	slider.add_theme_icon_override("grabber_highlight", _make_grabber(_KNOT_HI, _grabber_d))


## 단추(매듭) 모양 그래버 텍스처(안티에일리어스 원). 시트 에셋 없이 톤을 통일한다. d는 지름(px).
static func _make_grabber(color: Color, d: int = 18) -> ImageTexture:
	var img: Image = Image.create(d, d, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var c: float = (d - 1) * 0.5
	var r: float = c - 1.0
	for y in range(d):
		for x in range(d):
			var dist: float = Vector2(x - c, y - c).length()
			if dist <= r:
				img.set_pixel(x, y, color)
			elif dist <= r + 1.0:
				img.set_pixel(x, y, Color(color.r, color.g, color.b, r + 1.0 - dist))
	return ImageTexture.create_from_image(img)


## 사용자 제공 시트 스킨(있으면): 베이지 카드 패널 + 소형 필 버튼. 없으면 절차 폴백.
func _apply_skin() -> void:
	if not UiSkin.has_skin():
		for b in [_save_button, _back_button]:
			_skin_button(b)
		return
	UiSkin.skin_panel(get_node("PanelBg"), "beige")
	for b in [_save_button, _back_button]:
		UiSkin.skin_button(b, "small", 16)


## 재봉 스킨 톤 버튼 스타일(MainMenu._skin_button와 동일 계열).
func _skin_button(b: Button) -> void:
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", _INK)
	b.add_theme_color_override("font_hover_color", _INK_HOVER)
	b.add_theme_color_override("font_pressed_color", _INK_HOVER)
	b.add_theme_color_override("font_focus_color", _INK_HOVER)
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
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb
