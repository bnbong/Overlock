class_name SpeedGauge
extends Control
## 속도 게이지 (기획서 §8.2, presentation.md §4.4).
##
## 세로로 쌓인 쉐브론 5개, 아래부터 speed_index개 채운다. 1~2단 초록, 3단 노랑,
## 4단 주황, 5단 빨강, 4~5단 점멸. 미충전은 어두운 회색. 쉐브론은 두께 폴리라인("^")
## 이라 삼각분할 없이 안전하게 그린다. 오디오 훅은 /root/AudioManager 가드 호출.

const GREEN: Color = Color(0.35, 0.72, 0.44, 1.0)
const YELLOW: Color = Color(0.93, 0.79, 0.24, 1.0)
const ORANGE: Color = Color(0.94, 0.62, 0.24, 1.0)
const RED: Color = Color(0.90, 0.29, 0.27, 1.0)
const EMPTY: Color = Color(0.66, 0.60, 0.50, 1.0)  # 미충전(원단 위 옅은 taupe)
const CHEVRON_WIDTH: float = 6.0
const PAD_X: float = 6.0
const PAD_Y: float = 4.0

var _stage: int = 1
var _blink_phase: float = 0.0


func set_stage(stage: int) -> void:
	var clamped: int = clampi(stage, 1, 5)
	if clamped != _stage:
		_stage = clamped
		queue_redraw()
		_on_speed_stage(clamped)


func _process(delta: float) -> void:
	if _stage >= 4:
		_blink_phase += delta * 6.0
		queue_redraw()


func _draw() -> void:
	# 사용자 제공 시트: 쉐브론 텍스처 5개를 상태별 modulate 틴트로. 플래그(SKIN_SPEED_CHEVRON)가
	# 꺼져 있거나 텍스처가 없으면 절차 폴백(세로 폴리라인 쉐브론)으로 원복한다.
	var tex: Texture2D = UiSkin.tex("chevron") if UiSkin.SKIN_SPEED_CHEVRON else null
	if tex != null:
		_draw_textured(tex)
	else:
		_draw_procedural()


func _draw_textured(tex: Texture2D) -> void:
	var w: float = size.x
	var h: float = size.y
	var slot_h: float = h / 5.0
	var cw: float = w - 2.0 * PAD_X
	var ch: float = minf(cw * float(tex.get_height()) / float(tex.get_width()), slot_h * 1.2)
	for stage_num in range(1, 6):
		var slot_from_top: int = 5 - stage_num
		var cy: float = float(slot_from_top) * slot_h + (slot_h - ch) * 0.5
		var filled: bool = stage_num <= _stage
		draw_texture_rect(tex, Rect2(PAD_X, cy, cw, ch), false, _stage_color(stage_num, filled))


func _draw_procedural() -> void:
	var w: float = size.x
	var h: float = size.y
	var slot_h: float = h / 5.0
	var x0: float = PAD_X
	var x1: float = w - PAD_X
	var cx: float = w * 0.5
	for stage_num in range(1, 6):
		var slot_from_top: int = 5 - stage_num
		var apex_y: float = float(slot_from_top) * slot_h + PAD_Y
		var base_y: float = apex_y + slot_h - 2.0 * PAD_Y
		var filled: bool = stage_num <= _stage
		var chevron: PackedVector2Array = PackedVector2Array(
			[Vector2(x0, base_y), Vector2(cx, apex_y), Vector2(x1, base_y)]
		)
		draw_polyline(chevron, _stage_color(stage_num, filled), CHEVRON_WIDTH)


func _stage_color(stage_num: int, filled: bool) -> Color:
	if not filled:
		return EMPTY
	var base: Color
	if stage_num <= 2:
		base = GREEN
	elif stage_num == 3:
		base = YELLOW
	elif stage_num == 4:
		base = ORANGE
	else:
		base = RED
	if stage_num >= 4 and stage_num <= _stage:
		var blink: float = 0.6 + 0.4 * sin(_blink_phase)
		base = base * blink
		base.a = 1.0
	return base


# --- 오디오 훅 (가드: /root/AudioManager 미등록 시 무시) ---


func _on_speed_stage(stage: int) -> void:
	var am: Node = get_node_or_null("/root/AudioManager")
	if am != null and am.has_method("on_speed_stage"):
		am.on_speed_stage(stage)
