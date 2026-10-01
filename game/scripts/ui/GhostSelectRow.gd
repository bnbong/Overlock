class_name GhostSelectRow
extends VBoxContainer
## 트랙 선택 화면의 개인 고스트 줄 (v2.3.0, docs/architecture.md §3.3).
##
## "개인 고스트" 켜기/끄기 토글(RecordStore.set_ghost_enabled, user://ghost_settings.json 영속, 기본 켜기)과
## 선택 트랙의 고스트 상태 문구, 로컬 최고와 온라인 순위의 기준 차이를 짧게 보인다.
## 상태 문구: 기록 없음 → "첫 완주 후 고스트가 생깁니다", 기록 당시와 트랙이 다름(편집) → 고스트를 쓸 수
## 없고 개인 최고를 갱신하면 새 고스트가 생긴다는 안내, 최고 기록에 고스트 파일이 없음(예전 기록 등) →
## 다음 최고부터 생긴다는 안내. 개발용 튜닝 오버라이드가 켜져 있으면 연습 기록으로 따로 저장한다는 안내를
## 앞에 붙인다.

const TEXT_COLOR: Color = Color(0.9, 0.86, 0.78, 1.0)
const POLICY_COLOR: Color = Color(0.78, 0.72, 0.86, 1.0)
const OUTLINE: Color = Color(0.278, 0.203, 0.153, 1.0)
const POLICY_TEXT: String = "로컬 최고·고스트는 패널티 포함 시간 기준이고, 온라인 순위는 등급을 먼저 봅니다."
const PRACTICE_TEXT: String = "개발용 튜닝 적용 중: 기록과 고스트를 연습 기록으로 따로 저장합니다. "
const STATE_TEXTS: Dictionary = {
	"ready": "개인 최고 고스트가 미니맵에서 함께 달립니다",
	"no_record": "첫 완주 후 고스트가 생깁니다",
	"track_changed": "트랙이 바뀌어 고스트를 쓸 수 없습니다 · 최고를 갱신하면 새로 생깁니다",
	"no_ghost": "이 최고 기록에는 고스트가 없습니다. 다음 최고 기록부터 생깁니다",
}

var _toggle: CheckButton
var _status: Label
var _policy: Label
var _save_failed: bool = false
var _id: String = ""
var _diff: String = ""


func _ready() -> void:
	name = "GhostRow"
	add_theme_constant_override("separation", 2)
	var row: HBoxContainer = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	add_child(row)
	_toggle = CheckButton.new()
	_toggle.name = "GhostToggle"
	_toggle.text = "개인 고스트"
	_toggle.button_pressed = RecordStore.ghost_enabled()
	_toggle.add_theme_font_size_override("font_size", 16)
	_style_text(_toggle)
	_toggle.toggled.connect(_on_toggled)
	row.add_child(_toggle)
	_status = _make_label(15, TEXT_COLOR)
	_status.name = "GhostStatus"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.add_child(_status)
	_policy = _make_label(13, POLICY_COLOR)
	_policy.name = "GhostPolicy"
	_policy.text = POLICY_TEXT
	add_child(_policy)


## 터치 배치: 토글을 메뉴 터치 버튼 크기(MenuTouch.MIN_H)로, 글자를 메뉴 터치 글자 하한으로 키운다.
func apply_touch() -> void:
	MenuTouch.button(_toggle)
	MenuTouch.texts([_status, _policy])
	_status.custom_minimum_size.x = 260.0


## 선택 트랙이 바뀔 때 상태 문구를 갱신한다.
func refresh(id: String, diff: String) -> void:
	_id = id
	_diff = diff
	var text: String = PRACTICE_TEXT if RecordStore.is_practice() else ""
	if not _toggle.button_pressed:
		text += "고스트를 끄면 미니맵 마커와 구간 시간차를 보이지 않습니다"
	else:
		text += str(STATE_TEXTS.get(RecordStore.ghost_state(id, diff), ""))
	if _save_failed:
		text += " (설정을 저장하지 못했습니다)"
	_status.text = text


func status_text() -> String:
	return _status.text


func toggle() -> CheckButton:
	return _toggle


func _on_toggled(on: bool) -> void:
	_save_failed = not RecordStore.set_ghost_enabled(on)
	refresh(_id, _diff)


func _make_label(font_size: int, color: Color) -> Label:
	var l: Label = Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 300.0
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", OUTLINE)
	l.add_theme_constant_override("outline_size", 3)
	return l


static func _style_text(b: Button) -> void:
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(key, TEXT_COLOR)
	b.add_theme_color_override("font_outline_color", OUTLINE)
	b.add_theme_constant_override("outline_size", 3)
