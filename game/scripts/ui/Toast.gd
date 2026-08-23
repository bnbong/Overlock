class_name Toast
extends CanvasLayer
## 재사용 토스트 (재봉 스킨, 하단 중앙, 수 초 후 자동 소멸, 큐잉 가능).
##
## 씬(res://scenes/Toast.tscn)을 instantiate 해 현재 화면에 add_child 하고 push()로 메시지를
## 넣는다. 여러 메시지는 큐에 쌓여 하나씩 순차 표시된다. 최상위 CanvasLayer라 다른 UI 위에
## 뜨고, 입력은 통과시킨다(mouse_filter IGNORE). 순수 표현용 — 게임 값·판정과 무관.

const _DURATION: float = 3.6  # 완전 표시 유지 시간(초)
const _FADE: float = 0.28  # 페이드 인/아웃 시간(초)
const _BOTTOM_MARGIN: float = 64.0  # 화면 하단에서 띄우는 간격(px)

# 재봉 팔레트(SewingSkin 계승) — 베이지 원단 + 실 보라 테두리 + 짙은 갈색 글.
const _FABRIC: Color = Color(0.913, 0.856, 0.717)
const _THREAD: Color = Color(0.553, 0.384, 0.725)
const _INK: Color = Color(0.278, 0.203, 0.153)

var _queue: Array[String] = []
var _busy: bool = false
var _root: Control
var _panel: PanelContainer
var _label: Label


func _ready() -> void:
	layer = 128  # 항상 최상단.
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", _make_box())
	_panel.visible = false
	_panel.modulate.a = 0.0
	_root.add_child(_panel)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(360.0, 0.0)
	_label.add_theme_color_override("font_color", _INK)
	_label.add_theme_font_size_override("font_size", 16)
	_panel.add_child(_label)


## 토스트 메시지를 큐에 넣는다(표시 중이면 뒤에 쌓여 순차 표시).
func push(message: String) -> void:
	_queue.append(message)
	if not _busy:
		_show_next()


func _show_next() -> void:
	if _queue.is_empty():
		_busy = false
		_panel.visible = false
		return
	_busy = true
	_label.text = _queue.pop_front()
	_panel.visible = true
	_panel.modulate.a = 0.0
	# 콘텐츠 크기가 정해진 뒤 하단 중앙에 배치한다.
	await get_tree().process_frame
	_reposition()
	var tw: Tween = create_tween()
	tw.tween_property(_panel, "modulate:a", 1.0, _FADE)
	tw.tween_interval(_DURATION)
	tw.tween_property(_panel, "modulate:a", 0.0, _FADE)
	tw.tween_callback(_show_next)


func _reposition() -> void:
	var view: Vector2 = _root.size
	var ps: Vector2 = _panel.size
	_panel.position = Vector2((view.x - ps.x) * 0.5, view.y - ps.y - _BOTTOM_MARGIN)


func _make_box() -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = _FABRIC
	sb.border_color = _THREAD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.28)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb
