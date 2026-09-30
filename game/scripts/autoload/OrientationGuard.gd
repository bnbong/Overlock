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
## 이 노드는 게임을 직접 일시정지하지 않고 시뮬레이션·판정·입력 액션에도 관여하지 않는다. 세로/가로가
## 바뀔 때 portrait_changed 신호만 보내고, 주행 중이면 RaceDirector가 이 신호로 자동 일시정지한다
## (docs/mobile.md §4.4). 오버레이는 GUI 클릭만 막는다(터치 버튼은 `_input`으로 받으므로 영향 없음).

## 웹에서는 탭 숨김·창 blur도 page_focus_lost 신호로 알린다(v2.2.1 보강). 엔진은 캔버스 focus/blur만
## 창 포커스 알림으로 바꾸고, window blur는 눌린 입력 해제에만 쓰며, visibilitychange는 듣지 않는다
## (4.6.1 웹 템플릿 godot.js). 캔버스가 포커스를 갖지 않은 모바일 탭 환경 등에서는 엔진 알림이 오지
## 않을 수 있어 document visibilitychange(hidden)·window blur·pagehide를 직접 듣는다. 웹이 아니면
## 아무것도 등록하지 않는다.

## 세로 여부가 바뀔 때마다 보낸다(true=세로 안내 표시). 처음 상태는 is_portrait()로 읽는다.
signal portrait_changed(portrait: bool)
## (웹 한정) 페이지가 숨겨지거나 창이 포커스를 잃었다. RaceDirector가 포커스 상실처럼 자동 정지한다.
signal page_focus_lost

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

## (웹 한정) 페이지 숨김·blur 리스너 등록/해제 스크립트. 전역 플래그로 중복 등록을 막는다.
const _PAGE_HOOK_JS: String = """
(function () {
	if (window.__overlockPageHooks) { return; }
	var fire = function () {
		try { if (window.__overlock_page_cb) { window.__overlock_page_cb(); } } catch (e) {}
	};
	var onVis = function () { if (document.hidden) { fire(); } };
	window.__overlockPageHooks = { vis: onVis, blur: fire, hide: fire };
	document.addEventListener('visibilitychange', onVis, false);
	window.addEventListener('blur', fire, false);
	window.addEventListener('pagehide', fire, false);
})();
"""
const _PAGE_UNHOOK_JS: String = """
(function () {
	var h = window.__overlockPageHooks;
	if (!h) { return; }
	document.removeEventListener('visibilitychange', h.vis, false);
	window.removeEventListener('blur', h.blur, false);
	window.removeEventListener('pagehide', h.hide, false);
	window.__overlockPageHooks = null;
	window.__overlock_page_cb = null;
})();
"""

var _root: Control
var _icon: _RotateIcon
var _title: Label
var _subtitle: Label
var _portrait: bool = false
# 웹 보강 콜백. create_callback 결과를 멤버로 붙잡아 두지 않으면 GC되어 JS에서 부를 수 없다
# (WebFileBridge와 같은 관례). 웹이 아니면 null로 남는다.
var _page_cb: JavaScriptObject = null


func _ready() -> void:
	layer = _LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	get_tree().root.size_changed.connect(_refresh)
	_refresh()
	if OS.has_feature("web"):
		JavaScriptBridge.eval(_ANDROID_LOCK_JS, true)
		_install_page_listeners()


func _exit_tree() -> void:
	if _page_cb != null and OS.has_feature("web"):
		JavaScriptBridge.eval(_PAGE_UNHOOK_JS, true)
		_page_cb = null


## (웹) visibilitychange(hidden)·window blur·pagehide 리스너를 한 번만 등록한다. 리스너는 전역
## window.__overlock_page_cb(아래에서 매단 GDScript 콜백)를 부른다. 이미 등록돼 있으면(전역 플래그)
## 다시 등록하지 않는다.
func _install_page_listeners() -> void:
	if _page_cb != null:
		return
	_page_cb = JavaScriptBridge.create_callback(_on_page_event)
	var window: Variant = JavaScriptBridge.get_interface("window")
	if window == null:
		_page_cb = null
		return
	window.__overlock_page_cb = _page_cb
	JavaScriptBridge.eval(_PAGE_HOOK_JS, true)


func _on_page_event(_args: Array) -> void:
	page_focus_lost.emit()


## (웹) 지금 문서가 숨겨져 있는가(document.hidden). 웹이 아니면 false.
func is_page_hidden() -> bool:
	if not OS.has_feature("web"):
		return false
	return bool(JavaScriptBridge.eval("document.hidden === true", true))


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


## 지금 세로 안내가 떠 있는가.
func is_portrait() -> bool:
	return _portrait


func _refresh() -> void:
	_apply_portrait(is_portrait_size(get_tree().root.size))


## 세로 여부를 반영한다(안내 표시·배치 + 바뀌었을 때만 신호). 헤드리스 회귀 검사도 이 함수로 회전을
## 흉내 낸다(헤드리스는 창 크기가 0이라 실제 회전을 만들 수 없다).
func _apply_portrait(portrait: bool) -> void:
	var changed: bool = portrait != _portrait
	_portrait = portrait
	visible = portrait
	if portrait:
		_layout()
	if changed:
		portrait_changed.emit(portrait)


func _layout() -> void:
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
