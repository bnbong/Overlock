class_name EffectTimerCard
extends Control
## 효과(골무·엄마찬스) 잔여시간 카드 (presentation.md §4 UI 스킨).
##
## 기존 좌하단 소형 배지(아이콘+초)를 대체한다. 아이템 아이콘 + 줄어드는 가로 게이지 바
## (남은시간/전체) + 남은 초 텍스트를 재봉 스킨(베이지 원단 + 박음질 테두리)으로 담는다.
## 시작 시 살짝 팝(스케일 백-이즈) 등장, 만료 임박(<1.0s) 알파 펄스 점멸, 종료 시 페이드 아웃한다.
## 순수 표현용이라 게임 값·판정에는 관여하지 않는다(HUD가 매 프레임 잔여시간을 주입).

# 상태 머신: HIDDEN=숨김, POPPING=팝 등장, ACTIVE=상시, FADING=페이드 아웃.
enum State { HIDDEN, POPPING, ACTIVE, FADING }

const CARD_SIZE: Vector2 = Vector2(196.0, 50.0)
const RADIUS: float = 12.0
const ICON: float = 34.0  # 아이콘 한 변(px)
const PAD_L: float = 10.0  # 좌측 여백(아이콘 시작)
const POP_TIME: float = 0.18  # 팝 등장 지속(s)
const FADE_TIME: float = 0.24  # 종료 페이드 아웃 지속(s)
const BLINK_THRESHOLD: float = 1.0  # 이 잔여시간(s) 미만이면 점멸
const BLINK_RATE: float = 10.0  # 점멸 각속도(rad/s)

var _icon: Texture2D = null
var _accent: Color = Color.WHITE  # 게이지 채움/점멸 강조색(골무=금색, 엄마=분홍)
var _accent_deep: Color = Color.WHITE  # 임박 텍스트 강조색
var _total: float = 1.0  # 전체 지속(Tuning.*_duration) — 게이지 분모
var _remaining: float = 0.0  # 남은 시간(HUD 주입)
var _state: int = State.HIDDEN
var _appear: float = 0.0  # 팝 진행(0..1, 현재 알파에서 이어받아 재개)
var _fade: float = 1.0  # 페이드 진행(1..0)
var _blink_phase: float = 0.0


## HUD가 1회 호출해 아이콘·강조색·전체 지속을 설정한다.
func setup(icon: Texture2D, accent: Color, accent_deep: Color, total: float) -> void:
	_icon = icon
	_accent = accent
	_accent_deep = accent_deep
	_total = maxf(total, 0.01)
	custom_minimum_size = CARD_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	modulate.a = 0.0


## 효과 활성 진입/유지. 숨김·페이드 중이면 현재 알파에서 이어 팝을 시작한다(재획득 시 자연스러운 재등장).
func activate() -> void:
	if _state == State.ACTIVE or _state == State.POPPING:
		return
	visible = true
	_appear = modulate.a  # 페이드 도중 재활성 시 튀지 않게 현재 알파에서 이어받는다.
	_state = State.POPPING


## 효과 종료. 상시·팝 중이면 현재 알파에서 페이드 아웃을 시작한다.
func deactivate() -> void:
	if _state == State.HIDDEN or _state == State.FADING:
		return
	_fade = modulate.a
	_state = State.FADING


## HUD가 매 프레임 남은 시간을 주입(활성 중에만 의미 있음).
func set_remaining(t: float) -> void:
	_remaining = maxf(t, 0.0)


func _process(delta: float) -> void:
	if _state == State.HIDDEN:
		return
	# 팝 스케일이 중심 기준으로 확대되도록 피벗을 매 프레임 중앙에 맞춘다(VBox가 크기를 정하므로).
	pivot_offset = size * 0.5
	_blink_phase += delta * BLINK_RATE
	match _state:
		State.POPPING:
			_appear = minf(_appear + delta / POP_TIME, 1.0)
			var e: float = _ease_out_back(_appear)
			var sc: float = lerpf(0.72, 1.0, e)
			scale = Vector2(sc, sc)
			modulate.a = _appear
			if _appear >= 1.0:
				_state = State.ACTIVE
		State.ACTIVE:
			scale = Vector2.ONE
			# 만료 임박 시 알파 펄스 점멸, 아니면 완전 불투명.
			if _remaining > 0.0 and _remaining < BLINK_THRESHOLD:
				modulate.a = 0.5 + 0.5 * (0.5 + 0.5 * sin(_blink_phase))
			else:
				modulate.a = 1.0
		State.FADING:
			scale = Vector2.ONE
			_fade = maxf(_fade - delta / FADE_TIME, 0.0)
			modulate.a = _fade
			if _fade <= 0.0:
				_state = State.HIDDEN
				visible = false
	queue_redraw()


## 백-이즈 아웃(살짝 오버슈트 후 안착) — 팝 등장 특유의 탄성감.
func _ease_out_back(t: float) -> float:
	var c1: float = 1.70158
	var c3: float = c1 + 1.0
	var u: float = t - 1.0
	return 1.0 + c3 * u * u * u + c1 * u * u


func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	var imminent: bool = _remaining > 0.0 and _remaining < BLINK_THRESHOLD
	# 재봉 패치(베이지 원단) + 박음질 테두리. 임박 시 테두리를 강조색으로 물들여 위급함을 보강한다.
	SewingSkin.draw_patch(self, rect, SewingSkin.FABRIC, RADIUS)
	var border_col: Color = _accent_deep if imminent else SewingSkin.THREAD_PURPLE
	SewingSkin.draw_stitch_border(self, rect, border_col, 7.0, RADIUS)
	# 아이콘(좌측, 세로 중앙).
	if _icon != null:
		var iy: float = (size.y - ICON) * 0.5
		draw_texture_rect(_icon, Rect2(Vector2(PAD_L, iy), Vector2(ICON, ICON)), false)
	var font: Font = ThemeDB.fallback_font
	var text_x: float = PAD_L + ICON + 8.0
	var right_w: float = size.x - text_x - 12.0
	# 남은 초(상단). 임박 시 강조색.
	var secs: String = "%.1fs" % _remaining
	var txt_col: Color = _accent_deep if imminent else SewingSkin.INK
	draw_string(font, Vector2(text_x, 23.0), secs, HORIZONTAL_ALIGNMENT_LEFT, right_w, 16, txt_col)
	# 게이지 바(하단): 홈 + 남은시간/전체 비율만큼 강조색으로 채움(왼쪽 고정, 오른쪽이 줄어든다).
	var gy: float = 31.0
	var gh: float = 10.0
	var groove: StyleBoxFlat = StyleBoxFlat.new()
	groove.bg_color = SewingSkin.FABRIC_DEEP
	groove.set_corner_radius_all(5)
	draw_style_box(groove, Rect2(Vector2(text_x, gy), Vector2(right_w, gh)))
	var frac: float = clampf(_remaining / _total, 0.0, 1.0)
	if frac > 0.001:
		var fill: StyleBoxFlat = StyleBoxFlat.new()
		fill.bg_color = _accent
		fill.set_corner_radius_all(5)
		draw_style_box(fill, Rect2(Vector2(text_x, gy), Vector2(right_w * frac, gh)))
