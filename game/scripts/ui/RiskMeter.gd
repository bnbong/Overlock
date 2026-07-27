class_name RiskMeter
extends Control
## 손가락 부상 위험도 게이지. 0.50/0.70/0.85/0.95 경고 색/점멸 (기획서 §7.5, §8.1).
##
## 재배치(좌하단 패치 패널): 노루발·양손 중앙 겹침을 피하고 게이지 가독성을 확보한다.
## 로직(set_risk, 임계 색/점멸)은 불변, 아래부터 채운다. 임계 초과 시 패널 테두리와
## 라벨이 위험 색으로 점멸해 손가락 부상 경고 전달력을 유지한다.

const THRESHOLDS: Array[float] = [0.5, 0.7, 0.85, 0.95]
const RADIUS: float = 12.0
const TUBE_GROOVE: Color = Color(0.796, 0.726, 0.576, 1.0)

var _risk: float = 0.0
var _blink_phase: float = 0.0


func set_risk(value: float) -> void:
	_risk = clampf(value, 0.0, 1.0)
	queue_redraw()


func _process(delta: float) -> void:
	if _risk >= 0.5:
		_blink_phase += delta * (4.0 + _risk * 8.0)
		queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	var alarmed: bool = _risk >= 0.5
	var rc: Color = _risk_color()
	var font: Font = ThemeDB.fallback_font
	# 원단 패치 바탕.
	SewingSkin.draw_patch(self, rect, SewingSkin.FABRIC, RADIUS)
	# 제목: 평상 시 잉크색, 경고 시 위험 색으로 점멸.
	var title_col: Color = rc if alarmed else SewingSkin.INK
	draw_string(font, Vector2(0.0, 21.0), "RISK", HORIZONTAL_ALIGNMENT_CENTER, w, 15, title_col)
	# 세로 게이지 튜브(가운데).
	var tube: Rect2 = Rect2(Vector2(w * 0.5 - 17.0, 30.0), Vector2(34.0, h - 42.0))
	var groove_sb: StyleBoxFlat = StyleBoxFlat.new()
	groove_sb.bg_color = TUBE_GROOVE
	groove_sb.set_corner_radius_all(6)
	draw_style_box(groove_sb, tube)
	# 아래부터 채움(위험이 차오르는 느낌).
	var fill_h: float = tube.size.y * _risk
	if fill_h > 1.0:
		draw_rect(
			Rect2(
				Vector2(tube.position.x + 2.0, tube.position.y + tube.size.y - fill_h),
				Vector2(tube.size.x - 4.0, fill_h)
			),
			rc,
			true
		)
	# 임계 눈금.
	for threshold in THRESHOLDS:
		var y: float = tube.position.y + tube.size.y - tube.size.y * threshold
		draw_line(
			Vector2(tube.position.x + 1.0, y),
			Vector2(tube.position.x + tube.size.x - 1.0, y),
			SewingSkin.INK_SOFT,
			1.0
		)
	# 튜브 외곽선.
	draw_rect(tube, SewingSkin.FABRIC_DEEP, false, 1.5)
	# 박음질 테두리: 경고 시 위험 색으로 점멸(부상 경고 전달), 평상 시 실 보라.
	var border_col: Color = rc if alarmed else SewingSkin.THREAD_PURPLE
	SewingSkin.draw_stitch_border(self, rect, border_col, 7.0, RADIUS)
	SewingSkin.draw_corner_buttons(self, rect, 12.0)


func _risk_color() -> Color:
	var base: Color
	if _risk >= 0.95:
		base = Color(1.0, 0.15, 0.15)
	elif _risk >= 0.85:
		base = Color(1.0, 0.35, 0.20)
	elif _risk >= 0.70:
		base = Color(1.0, 0.55, 0.20)
	elif _risk >= 0.50:
		base = Color(0.95, 0.85, 0.25)
	else:
		base = Color(0.40, 0.70, 0.50)
	if _risk >= 0.5:
		var blink: float = 0.6 + 0.4 * sin(_blink_phase)
		base = base * blink
		base.a = 1.0
	return base
