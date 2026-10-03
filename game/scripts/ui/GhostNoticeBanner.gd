class_name GhostNoticeBanner
extends Control
## 개인 고스트 출발 안내 배너 (v2.3.0, docs/architecture.md §3.3, docs/mobile.md §4.2).
##
## 고스트를 재생하지 못하는 사유(트랙 변경·파일 없음·손상·불일치)가 있을 때만 출발(GO) 순간에 한 줄로
## 잠시 보인다. 주행 중 구간 시간차는 팝업으로 띄우지 않는다(구간 값은 GhostRun이 기록하고 결과 화면이
## 요약한다). 순수 표현용이라 게임 값·판정에 관여하지 않는다.
##
## 위치: 화면 위 가운데 RECT(1280×720 캔버스 기준). 미니맵(16~216)·터치 일시정지 버튼(946~1026)·
## TIME 패널(1042~1272)과 가로로 떨어져 있고, 부상 말풍선·RISK·아이템 슬롯·효과 카드·터치 버튼은 모두
## 화면 아래쪽에 있어 겹치지 않는다. 키보드·터치 모드 모두 같은 위치다(캔버스 고정, aspect keep).

const RECT: Rect2 = Rect2(440.0, 14.0, 400.0, 44.0)
const SHOW_TIME: float = 3.0
const FADE_TIME: float = 0.25
const RADIUS: float = 12.0
const FONT_SIZE: int = 18

var _label: Label
var _timer: float = 0.0


func _ready() -> void:
	name = "GhostNoticeBanner"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = RECT.position
	size = RECT.size
	visible = false
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size = RECT.size
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.add_theme_color_override("font_color", SewingSkin.INK)
	add_child(_label)


## 한 줄 안내를 SHOW_TIME 동안 보인다.
func show_notice(text: String) -> void:
	_label.text = text
	_timer = SHOW_TIME
	modulate.a = 1.0
	visible = true
	queue_redraw()


func notice_text() -> String:
	return _label.text if visible else ""


## 안내 글자 폭(px). 회귀 검사가 RECT 안에 들어가는지 본다.
func text_width() -> float:
	return _label.get_minimum_size().x


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
