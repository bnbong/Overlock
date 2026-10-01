class_name GhostSplitBanner
extends Control
## 개인 고스트 구간 시간차 배너 (v2.3.0, docs/architecture.md §3.3, docs/mobile.md §4.2).
##
## 구간(트랙 호길이 10등분)을 통과하면 "구간 3/10 · 0.42초 빠름"처럼 개인 최고 고스트와의 차이를
## 잠시 보인다. 비교 값은 (주행 시간 + 그때까지 누적 패널티)이므로 둘째 줄에 패널티 포함 비교임과,
## 미니맵 마커는 주행 시간 기준이라 앞뒤가 다를 수 있음을 적는다. 빠름/느림은 글자로 쓰고 색은 보조로만
## 쓴다(색만으로 구분하지 않음). 고스트를 못 읽은 사유 안내도 같은 자리에 잠시 띄운다.
##
## 위치: 화면 위 가운데 RECT(1280×720 캔버스 기준). 미니맵(16~216)·터치 일시정지 버튼(946~1026)·
## TIME 패널(1042~1272)과 가로로 떨어져 있고, 부상 말풍선·RISK·아이템 슬롯·효과 카드·터치 버튼은 모두
## 화면 아래쪽에 있어 겹치지 않는다. 키보드·터치 모드 모두 같은 위치다(캔버스 고정, aspect keep).
## 순수 표현용이라 게임 값·판정에 관여하지 않는다.

const RECT: Rect2 = Rect2(440.0, 14.0, 400.0, 66.0)
const SHOW_TIME: float = 2.6
const FADE_TIME: float = 0.25
const RADIUS: float = 12.0
const FASTER: Color = Color(0.20, 0.50, 0.30)
const SLOWER: Color = Color(0.72, 0.24, 0.20)
const SUB_TEXT: String = "개인 최고 대비 · 패널티 포함 (마커는 주행 시간 기준)"

var _main: Label
var _sub: Label
var _timer: float = 0.0


func _ready() -> void:
	name = "GhostSplitBanner"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = RECT.position
	size = RECT.size
	visible = false
	_main = _make_label(22, Vector2(0.0, 7.0), 30.0)
	_sub = _make_label(13, Vector2(0.0, 40.0), 18.0)
	_sub.add_theme_color_override("font_color", SewingSkin.INK_SOFT)


func _make_label(font_size: int, pos: Vector2, height: float) -> Label:
	var l: Label = Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = pos
	l.size = Vector2(RECT.size.x, height)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", SewingSkin.INK)
	add_child(l)
	return l


## 구간 index(0부터) 통과 결과. comparable=false면 비교 불가(복귀로 건너뜀 등)로 안내한다.
func show_split(index: int, delta_ms: int, comparable: bool) -> void:
	var head: String = "구간 %d/%d" % [index + 1, GhostRun.SPLIT_COUNT]
	if not comparable:
		_show(head + " · 비교 불가", "복귀로 건너뛴 구간은 비교하지 않습니다", SewingSkin.INK)
		return
	var secs: float = absf(float(delta_ms)) / 1000.0
	if delta_ms < 0:
		_show(head + " · %.2f초 빠름" % secs, SUB_TEXT, FASTER)
	elif delta_ms > 0:
		_show(head + " · %.2f초 느림" % secs, SUB_TEXT, SLOWER)
	else:
		_show(head + " · 개인 최고와 같음", SUB_TEXT, SewingSkin.INK)


## 고스트 관련 안내. "첫 줄\n둘째 줄"이면 둘째 줄을 아래 작은 줄에 쓴다.
func show_notice(text: String) -> void:
	var parts: PackedStringArray = text.split("\n", true, 1)
	_show(parts[0], parts[1] if parts.size() > 1 else "", SewingSkin.INK)
	_main.add_theme_font_size_override("font_size", 18)


func main_text() -> String:
	return _main.text if visible else ""


func _show(main: String, sub: String, color: Color) -> void:
	_main.text = main
	_main.add_theme_font_size_override("font_size", 22)
	_main.add_theme_color_override("font_color", color)
	_sub.text = sub
	_sub.visible = not sub.is_empty()
	_timer = SHOW_TIME
	modulate.a = 1.0
	visible = true
	queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	_timer -= delta
	if _timer <= 0.0:
		visible = false
		return
	modulate.a = clampf(_timer / FADE_TIME, 0.0, 1.0)


func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	SewingSkin.draw_patch(self, rect, Color(SewingSkin.FABRIC, 0.94), RADIUS)
	SewingSkin.draw_stitch_border(self, rect, SewingSkin.THREAD_PURPLE, 5.0, RADIUS, 1.5)
