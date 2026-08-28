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
## 골무 실드(부상 봉인) 활성 시 게이지 금색 톤. risk 값·채움 높이 로직은 불변 — 색만 덮는다.
const SHIELD_GOLD: Color = Color(1.0, 0.82, 0.28, 1.0)
const SHIELD_GOLD_DEEP: Color = Color(0.78, 0.58, 0.12, 1.0)

var _risk: float = 0.0
var _blink_phase: float = 0.0
## 골무 활성 여부(HUD가 player.thimble_timer>0을 주입). 활성 중엔 위험 경보색 대신 금색 톤 +
## 테두리 강조로 "부상 봉인 중"을 전달한다(risk 로직 불변).
var _shield: bool = false


func set_risk(value: float) -> void:
	_risk = clampf(value, 0.0, 1.0)
	queue_redraw()


## HUD가 골무(thimble) 활성 상태를 주입. 값이 바뀔 때만 다시 그린다.
func set_shield(active: bool) -> void:
	if active == _shield:
		return
	_shield = active
	queue_redraw()


func _process(delta: float) -> void:
	# 골무 실드 중엔 금색 테두리 셔머를 위해, 아니면 위험 경보 점멸을 위해 위상을 돌린다.
	if _shield or _risk >= 0.5:
		_blink_phase += delta * (4.0 + _risk * 8.0)
		queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	var alarmed: bool = _risk >= 0.5
	# 골무 실드 중엔 채움/제목/테두리를 금색으로 덮는다(위험 경보색보다 우선). fill_h(=risk)는 불변.
	var rc: Color = _shield_gold() if _shield else _risk_color()
	var font: Font = ThemeDB.fallback_font
	# 원단 패치 바탕.
	SewingSkin.draw_patch(self, rect, SewingSkin.FABRIC, RADIUS)
	# 제목: 평상 시 잉크색, 경고 시 위험 색, 골무 실드 중엔 금색.
	var title_col: Color = rc if (alarmed or _shield) else SewingSkin.INK
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
	# 튜브 외곽선: 골무 실드 중엔 짙은 금색으로 강조.
	draw_rect(tube, SHIELD_GOLD_DEEP if _shield else SewingSkin.FABRIC_DEEP, false, 1.5)
	# 박음질 테두리: 골무 실드=금색 강조(더 두껍게), 경고=위험 색 점멸, 평상=실 보라.
	var border_col: Color = rc if (alarmed or _shield) else SewingSkin.THREAD_PURPLE
	var border_w: float = 9.0 if _shield else 7.0
	SewingSkin.draw_stitch_border(self, rect, border_col, border_w, RADIUS)
	SewingSkin.draw_corner_buttons(self, rect, 12.0)


## 골무 실드 금색 톤. 은은한 셔머(맥동)로 "보호 중"을 전달한다(risk 값 로직과 무관, 색 전용).
func _shield_gold() -> Color:
	var shimmer: float = 0.82 + 0.18 * sin(_blink_phase)
	var c: Color = SHIELD_GOLD * shimmer
	c.a = 1.0
	return c


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
