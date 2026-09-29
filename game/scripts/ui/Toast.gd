class_name Toast
extends CanvasLayer
## 재사용 토스트 (재봉 스킨, 하단 중앙, 수 초 후 자동 소멸, 큐잉 가능).
##
## 씬(res://scenes/Toast.tscn)을 instantiate 해 현재 화면에 add_child 하고 push()로 메시지를
## 넣는다. 여러 메시지는 큐에 쌓여 하나씩 순차 표시된다. 최상위 CanvasLayer라 다른 UI 위에
## 뜨고, 입력은 통과시킨다(mouse_filter IGNORE). 순수 표현용 — 게임 값·판정과 무관.
##
## push(message, portrait)에 초상화 텍스처를 넘긴 항목만 "말풍선" 스타일로 뜬다: 원단 말풍선
## (보라 박음질 + 초상화 쪽을 향한 꼬리) 왼쪽 위에 초상화가 걸치고 대사는 그 오른쪽에 크게 쓴다.
## 스타일은 큐 항목이 실제로 표시되는 시점(_show_next)에 그 항목 기준으로 적용하므로, 표시 중인
## 토스트는 뒤에 쌓인 항목의 종류와 무관하고 다음 일반 항목에서는 일반 스타일로 모두 되돌아간다.

const _DURATION: float = 3.6  # 완전 표시 유지 시간(초)
const _FADE: float = 0.28  # 페이드 인/아웃 시간(초)
const _BOTTOM_MARGIN: float = 64.0  # 화면 하단에서 띄우는 간격(px)

# 재봉 팔레트(SewingSkin 계승) — 베이지 원단 + 실 보라 테두리 + 짙은 갈색 글.
const _FABRIC: Color = Color(0.913, 0.856, 0.717)
const _THREAD: Color = Color(0.553, 0.384, 0.725)
const _INK: Color = Color(0.278, 0.203, 0.153)

# 일반 스타일(기존 값 그대로).
const _FONT_SIZE: int = 16
const _LABEL_MIN: Vector2 = Vector2(360.0, 0.0)

# --- 말풍선(초상화) 스타일. 캔버스 1280×720 고정(stretch keep)이라 모바일도 같은 값을 쓴다. ---
# 말풍선 본체 크기. 위쪽 HUD 상태 글(원단 이탈 · 복귀, y 556~596)과 아래 조작 안내(y 684~)
# 사이에 들어가도록 높이를 정했다(바닥 y = 720 - _SCOLD_BOTTOM_MARGIN).
const _SCOLD_SIZE: Vector2 = Vector2(680.0, 82.0)
const _SCOLD_BOTTOM_MARGIN: float = 38.0
const _SCOLD_RADIUS: float = 26.0
const _SCOLD_STITCH_INSET: float = 7.0
const _SCOLD_FONT_SIZE: int = 40
const _SCOLD_EMBOLDEN: float = 0.6  # 굵은 대사(새 폰트 없이 FontVariation 굵기 보정)
# 대사 영역: 왼쪽은 초상화가 차지하는 폭 + 간격, 오른쪽은 박음질 안쪽 여백.
const _SCOLD_TEXT_LEFT: float = 206.0
const _SCOLD_TEXT_RIGHT: float = 30.0
# 초상화(정사각, 원본 1254×1254 비율 유지) 표시 크기와 말풍선 왼쪽 아래 기준 오프셋.
# 스티커 외곽 바닥(원본 y 1219)이 말풍선 바닥선과 거의 맞도록 아래로 조금 내린다.
const _PORTRAIT_SIDE: float = 212.0
const _PORTRAIT_OFFSET: Vector2 = Vector2(-12.0, 4.0)
# 꼬리: 말풍선 윗변의 밑변 구간(말풍선 왼쪽 기준 x)과 꼭짓점(엄마 얼굴 쪽 왼쪽 위).
const _TAIL_BASE_X: Vector2 = Vector2(200.0, 232.0)
const _TAIL_TIP: Vector2 = Vector2(188.0, -21.0)

var _queue: Array[Dictionary] = []  # {"text": String, "portrait": Texture2D 또는 null}
var _busy: bool = false
var _root: Control
# 패널·초상화를 함께 페이드하는 알림 그룹(clip 없음 → 말풍선 위로 올라온 머리도 잘리지 않는다).
var _group: Control
var _panel: PanelContainer
var _label: Label
var _portrait: TextureRect
var _normal_box: StyleBoxFlat
var _scold_box: StyleBoxEmpty
var _scold_font: FontVariation
var _scold: bool = false  # 현재 표시 중인 항목이 말풍선 스타일인지(꼬리·박음질 그리기)


func _ready() -> void:
	layer = 128  # 항상 최상단.
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_group = Control.new()
	_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_group.visible = false
	_group.modulate.a = 0.0
	_root.add_child(_group)

	_normal_box = _make_box()
	_scold_box = _make_scold_box()

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", _normal_box)
	_panel.draw.connect(_draw_scold_bubble)
	_group.add_child(_panel)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_color", _INK)
	_panel.add_child(_label)

	# 초상화는 패널의 형제(패널 위에 그림). 원본 비율 유지, 입력 통과.
	_portrait = TextureRect.new()
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.size = Vector2(_PORTRAIT_SIDE, _PORTRAIT_SIDE)
	_portrait.visible = false
	_group.add_child(_portrait)

	_scold_font = FontVariation.new()
	_scold_font.base_font = _label.get_theme_font("font")
	_scold_font.variation_embolden = _SCOLD_EMBOLDEN
	_apply_style(null)


## 토스트 메시지를 큐에 넣는다(표시 중이면 뒤에 쌓여 순차 표시). portrait를 주면 그 항목만
## 초상화 말풍선 스타일로 표시한다(기존 호출은 인자 없이 일반 스타일 그대로).
func push(message: String, portrait: Texture2D = null) -> void:
	_queue.append({"text": message, "portrait": portrait})
	if not _busy:
		_show_next()


func _show_next() -> void:
	if _queue.is_empty():
		_busy = false
		_group.visible = false
		return
	_busy = true
	var item: Dictionary = _queue.pop_front()
	_label.text = item["text"]
	# 이 항목 기준으로 스타일을 적용한다(초상화 없는 항목은 일반 스타일로 전부 복원).
	_apply_style(item["portrait"])
	_group.visible = true
	_group.modulate.a = 0.0
	# 콘텐츠 크기가 정해진 뒤 하단 중앙에 배치한다.
	await get_tree().process_frame
	_reposition()
	var tw: Tween = create_tween()
	tw.tween_property(_group, "modulate:a", 1.0, _FADE)
	tw.tween_interval(_DURATION)
	tw.tween_property(_group, "modulate:a", 0.0, _FADE)
	tw.tween_callback(_show_next)


## 항목 하나의 표시 스타일을 적용한다. portrait == null 이면 일반 토스트(기존 값) 스타일.
func _apply_style(portrait: Texture2D) -> void:
	_scold = portrait != null
	if _scold:
		_panel.add_theme_stylebox_override("panel", _scold_box)
		_panel.custom_minimum_size = _SCOLD_SIZE
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_label.custom_minimum_size = Vector2.ZERO
		_label.add_theme_font_size_override("font_size", _SCOLD_FONT_SIZE)
		_label.add_theme_font_override("font", _scold_font)
		_portrait.texture = portrait
		_portrait.visible = true
	else:
		_panel.add_theme_stylebox_override("panel", _normal_box)
		_panel.custom_minimum_size = Vector2.ZERO
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size = _LABEL_MIN
		_label.add_theme_font_size_override("font_size", _FONT_SIZE)
		_label.remove_theme_font_override("font")
		_portrait.texture = null
		_portrait.visible = false
	# 이전 항목(말풍선 등)의 큰 크기가 남지 않도록 현재 콘텐츠 최소 크기로 되돌린다.
	_panel.reset_size()
	_panel.queue_redraw()


func _reposition() -> void:
	_panel.reset_size()
	var view: Vector2 = _root.size
	var ps: Vector2 = _panel.size
	var margin: float = _SCOLD_BOTTOM_MARGIN if _scold else _BOTTOM_MARGIN
	_panel.position = Vector2((view.x - ps.x) * 0.5, view.y - ps.y - margin)
	if _scold:
		# 초상화: 말풍선 왼쪽 아래에 붙이고 머리는 말풍선 위로 올라오게(정사각 유지).
		_portrait.size = Vector2(_PORTRAIT_SIDE, _PORTRAIT_SIDE)
		_portrait.position = (
			_panel.position
			+ Vector2(_PORTRAIT_OFFSET.x, ps.y + _PORTRAIT_OFFSET.y - _PORTRAIT_SIDE)
		)


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


## 말풍선 스타일 패널: 배경은 _draw_scold_bubble이 직접 그리고, 여기서는 대사 여백만 잡는다.
func _make_scold_box() -> StyleBoxEmpty:
	var sb: StyleBoxEmpty = StyleBoxEmpty.new()
	sb.content_margin_left = _SCOLD_TEXT_LEFT
	sb.content_margin_right = _SCOLD_TEXT_RIGHT
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 10.0
	return sb


## 말풍선 외곽선(둥근 사각 + 윗변 꼬리) 폴리곤. 패널 로컬 좌표.
func scold_outline() -> PackedVector2Array:
	var rect: Rect2 = Rect2(Vector2.ZERO, _panel.size)
	var pts: PackedVector2Array = SewingSkin.rounded_rect_polyline(rect, _SCOLD_RADIUS, 6)
	# rounded_rect_polyline은 왼쪽 위 모서리 끝(x0+r, y0)에서 끝나고 닫힘 구간이 윗변(왼→오)이라
	# 끝에 꼬리 세 점을 이으면 윗변 위로 솟은 꼬리가 된다.
	pts.append(Vector2(_TAIL_BASE_X.x, 0.0))
	pts.append(_TAIL_TIP)
	pts.append(Vector2(_TAIL_BASE_X.y, 0.0))
	return pts


## 패널 draw 시그널(스타일박스 다음, 대사 Label 이전에 그려짐). 말풍선 스타일일 때만
## 그림자 → 원단 바탕 → 얇은 테두리 → 보라 박음질(꼬리 포함 안쪽 경로) 순으로 그린다.
func _draw_scold_bubble() -> void:
	if not _scold:
		return
	var outline: PackedVector2Array = scold_outline()
	var shadow: PackedVector2Array = PackedVector2Array()
	for p in outline:
		shadow.append(p + Vector2(0.0, 3.0))
	_panel.draw_colored_polygon(shadow, SewingSkin.SHADOW)
	_panel.draw_colored_polygon(outline, _FABRIC)
	var closed: PackedVector2Array = outline.duplicate()
	closed.append(outline[0])
	_panel.draw_polyline(closed, SewingSkin.FABRIC_DEEP, 2.0, true)
	var inner: Array[PackedVector2Array] = Geometry2D.offset_polygon(
		outline, -_SCOLD_STITCH_INSET, Geometry2D.JOIN_ROUND
	)
	if not inner.is_empty():
		SewingSkin.draw_running_stitch(_panel, inner[0], true, _THREAD, 6.0, 4.0, 2.0)
