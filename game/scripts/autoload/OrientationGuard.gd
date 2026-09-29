extends CanvasLayer
## 세로 화면 안내 오버레이 + (웹 Android) 가로 고정 시도 오토로드 (docs/mobile.md §8).
##
## 창(웹에서는 캔버스)이 세로로 길면 게임 화면(16:9 영역)을 덮는 "기기를 가로로 돌려 주세요"
## 안내를 띄우고, 가로가 되면 자동으로 걷는다. iOS 브라우저는 화면 방향을 코드로 고정할 수 없어서
## 이 안내가 유일한 수단이다.
##
## 웹 Android에서는 첫 터치(touchend, 사용자 활성화)에 전체 화면 진입 후
## `screen.orientation.lock("landscape")`를 한 번 시도한다. Android Chrome은 전체 화면이거나
## 설치된 PWA일 때만 lock을 허용하므로 전체 화면을 먼저 요청한다. 실패는 모두 무시한다.
##
## 순수 표현용이다. 게임을 일시정지하지 않고 시뮬레이션·판정·입력 액션에도 관여하지 않는다.
## 오버레이는 GUI 클릭만 막는다(터치 버튼은 `_input`으로 받으므로 영향 없음).

## Toast(128)보다 위.
const _LAYER: int = 1000

# 재봉 팔레트(SewingSkin 계승).
const _BG: Color = Color(0.165, 0.118, 0.090)  # 짙은 갈색 배경
const _CREAM: Color = Color(0.968, 0.929, 0.847)
const _FABRIC: Color = Color(0.913, 0.856, 0.717)
const _THREAD: Color = Color(0.553, 0.384, 0.725)

const _TITLE: String = "기기를 가로로 돌려 주세요"
const _SUBTITLE: String = "Overlock은 가로 화면에서 플레이합니다"

## 웹 Android 전용 1회성 가로 고정 스크립트. iOS·데스크톱에서는 아무것도 하지 않는다.
const _ANDROID_LOCK_JS: String = """
(function () {
	if (window.__overlockOrientation) { return; }
	window.__overlockOrientation = true;
	if (!/Android/i.test(navigator.userAgent || '')) { return; }
	var handler = function () {
		window.removeEventListener('touchend', handler, true);
		try {
			var so = screen.orientation;
			if (!so || !so.lock) { return; }
			var lock = function () { return so.lock('landscape').catch(function () {}); };
			var el = document.documentElement;
			var installed = window.matchMedia
				&& window.matchMedia('(display-mode: fullscreen), (display-mode: standalone)').matches;
			if (!installed && !document.fullscreenElement && el.requestFullscreen) {
				el.requestFullscreen({ navigationUI: 'hide' }).then(lock).catch(function () {});
			} else {
				lock();
			}
		} catch (e) {}
	};
	window.addEventListener('touchend', handler, true);
})();
"""

var _root: Control
var _icon: _RotateIcon
var _title: Label
var _subtitle: Label


func _ready() -> void:
	layer = _LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	get_tree().root.size_changed.connect(_refresh)
	_refresh()
	if OS.has_feature("web"):
		JavaScriptBridge.eval(_ANDROID_LOCK_JS, true)


## 현재 창이 세로인지(높이 > 너비). 창 크기가 0이면(헤드리스) false.
static func is_portrait_size(window_size: Vector2i) -> bool:
	return window_size.x > 0 and window_size.y > window_size.x


func _build() -> void:
	_root = ColorRect.new()
	(_root as ColorRect).color = _BG
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	_icon = _RotateIcon.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_icon)

	_title = _make_label(_TITLE, _CREAM)
	_subtitle = _make_label(_SUBTITLE, _FABRIC)


func _make_label(text: String, color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	_root.add_child(label)
	return label


func _refresh() -> void:
	visible = is_portrait_size(get_tree().root.size)
	if not visible:
		return
	# 기준 캔버스(1280x720) 좌표로 배치한다. stretch(canvas_items, keep)에서는 루트 뷰포트가
	# 16:9 영역만 그리므로(나머지는 창의 검은 레터박스) 이 영역을 꽉 채우고, 글자는 세로 폰의
	# 축소 배율(390px 폭 기준 약 0.3배)에서도 읽히도록 크게 잡는다.
	var view: Vector2 = get_viewport().get_visible_rect().size
	_root.position = Vector2.ZERO
	_root.size = view

	var icon_size: Vector2 = Vector2(300.0, 300.0)
	var title_h: float = 110.0
	var subtitle_h: float = 70.0
	var content_h: float = icon_size.y + 20.0 + title_h + subtitle_h
	var top: float = (view.y - content_h) * 0.5
	_icon.position = Vector2((view.x - icon_size.x) * 0.5, top)
	_icon.size = icon_size
	_icon.queue_redraw()

	var margin: float = 60.0
	var label_w: float = view.x - margin * 2.0
	_title.add_theme_font_size_override("font_size", 84)
	_subtitle.add_theme_font_size_override("font_size", 46)
	_title.position = Vector2(margin, top + icon_size.y + 20.0)
	_title.size = Vector2(label_w, title_h)
	_subtitle.position = Vector2(margin, _title.position.y + title_h)
	_subtitle.size = Vector2(label_w, subtitle_h)


## 세로 폰 → 가로 폰 회전 아이콘(폰 두 개 + 회전 화살표). 재봉 점선으로 그린다.
class _RotateIcon:
	extends Control

	func _draw() -> void:
		var s: float = minf(size.x, size.y)
		var c: Vector2 = size * 0.5
		var line: float = maxf(2.0, s * 0.03)
		# 세로 폰(흐림) → 가로 폰(강조).
		var tall: Rect2 = Rect2(c + Vector2(-s * 0.36, -s * 0.30), Vector2(s * 0.30, s * 0.52))
		var wide: Rect2 = Rect2(c + Vector2(-s * 0.06, -s * 0.02), Vector2(s * 0.52, s * 0.30))
		_draw_phone(tall, Color(_FABRIC, 0.45), line)
		_draw_phone(wide, _CREAM, line)
		# 회전 화살표(보라 실).
		var arc_c: Vector2 = c + Vector2(s * 0.12, -s * 0.14)
		var r: float = s * 0.2
		draw_arc(arc_c, r, -PI * 0.95, -PI * 0.15, 24, _THREAD, line, true)
		var tip: Vector2 = arc_c + Vector2(cos(-PI * 0.15), sin(-PI * 0.15)) * r
		var head: float = s * 0.07
		draw_colored_polygon(
			PackedVector2Array(
				[
					tip + Vector2(head * 0.6, -head * 0.2),
					tip + Vector2(-head * 0.6, -head * 0.5),
					tip + Vector2(-head * 0.1, head * 0.7)
				]
			),
			_THREAD
		)

	func _draw_phone(rect: Rect2, color: Color, line: float) -> void:
		draw_rect(rect, color, false, line)
		# 안쪽 박음질 점선.
		var inner: Rect2 = rect.grow(-line * 2.5)
		var pts: PackedVector2Array = PackedVector2Array(
			[
				inner.position,
				Vector2(inner.end.x, inner.position.y),
				inner.end,
				Vector2(inner.position.x, inner.end.y),
				inner.position
			]
		)
		for i in range(pts.size() - 1):
			draw_dashed_line(
				pts[i], pts[i + 1], Color(color, color.a * 0.6), maxf(1.0, line * 0.5), line * 2.0
			)
