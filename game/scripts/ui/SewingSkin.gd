class_name SewingSkin
extends Control
## 재봉 스킨 공용 팔레트 + 패치 패널 드로잉 (presentation.md §4 UI 스킨).
##
## 두 가지로 쓴다.
##  1) 노드에 붙이면 배경 "재봉 패치"(웜톤 원단 + 박음질 점선 테두리 + 모서리 단추)를
##     그린다. TIME/속도/일시정지/결과 패널의 배경으로 씬에 배치한다.
##  2) 정적 헬퍼(`draw_patch`/`draw_running_stitch`/`draw_corner_buttons` 등)는
##     자체 `_draw`를 가진 위젯(미니맵·진행바·게이지·리스크)에서 재사용해 스킨을 통일한다.
##
## 순수 표현용이라 게임 값·판정에는 관여하지 않는다.

# --- 재봉 팔레트 (장면 아트 웜톤과 통일; menu_bg.svg 실 컬러 계승) ---
const FABRIC: Color = Color(0.913, 0.856, 0.717)  # 패널 베이지 원단
const FABRIC_DEEP: Color = Color(0.796, 0.726, 0.576)  # 원단 그늘/홈
const INK: Color = Color(0.278, 0.203, 0.153)  # 짙은 갈색 글/선
const INK_SOFT: Color = Color(0.435, 0.337, 0.267)  # 보조 글/선
const THREAD_PURPLE: Color = Color(0.553, 0.384, 0.725)  # 실 보라(주 박음질)
const CREAM: Color = Color(0.968, 0.929, 0.847)  # 어두운 배경 위 밝은 글
const KNOT: Color = Color(0.478, 0.333, 0.243)  # 단추/매듭 갈색
const SHADOW: Color = Color(0.0, 0.0, 0.0, 0.26)

# --- 인스턴스(배경 패치) 파라미터 ---
@export var fill_color: Color = FABRIC
@export var stitch_color: Color = THREAD_PURPLE
@export var corner_radius: float = 14.0
@export var stitch_inset: float = 8.0
@export var corner_buttons: bool = true
@export var drop_shadow: bool = true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	draw_patch(self, rect, fill_color, corner_radius, drop_shadow)
	draw_stitch_border(self, rect, stitch_color, stitch_inset, corner_radius)
	if corner_buttons:
		draw_corner_buttons(self, rect, stitch_inset + 5.0)


# --- 정적 헬퍼 (다른 위젯 _draw에서 재사용) ---


## 웜톤 원단 패치(둥근 모서리 + 얇은 테두리 + 선택적 드롭섀도).
static func draw_patch(
	ci: CanvasItem, rect: Rect2, fill: Color, radius: float = 14.0, shadow: bool = true
) -> void:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(int(radius))
	sb.border_color = FABRIC_DEEP
	sb.set_border_width_all(2)
	if shadow:
		sb.shadow_color = SHADOW
		sb.shadow_size = 5
		sb.shadow_offset = Vector2(0.0, 3.0)
	ci.draw_style_box(sb, rect)


## 박음질(러닝 스티치) 점선 테두리 — 둥근 사각 경로를 따라 연속 대시로 그린다.
static func draw_stitch_border(
	ci: CanvasItem,
	rect: Rect2,
	color: Color,
	inset: float = 8.0,
	radius: float = 14.0,
	width: float = 2.0,
) -> void:
	var inner: Rect2 = Rect2(
		rect.position + Vector2(inset, inset), rect.size - Vector2(inset, inset) * 2.0
	)
	if inner.size.x <= 2.0 or inner.size.y <= 2.0:
		return
	var pts: PackedVector2Array = rounded_rect_polyline(inner, maxf(radius - inset, 3.0))
	draw_running_stitch(ci, pts, true, color, 5.5, 4.0, width)


## 둥근 사각 둘레 폴리라인(시계방향, 닫힘 암시).
static func rounded_rect_polyline(rect: Rect2, radius: float, steps: int = 5) -> PackedVector2Array:
	var r: float = minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	var x0: float = rect.position.x
	var y0: float = rect.position.y
	var x1: float = x0 + rect.size.x
	var y1: float = y0 + rect.size.y
	var pts: PackedVector2Array = PackedVector2Array()
	var corners: Array = [
		[Vector2(x1 - r, y0 + r), -PI * 0.5, 0.0],  # top-right
		[Vector2(x1 - r, y1 - r), 0.0, PI * 0.5],  # bottom-right
		[Vector2(x0 + r, y1 - r), PI * 0.5, PI],  # bottom-left
		[Vector2(x0 + r, y0 + r), PI, PI * 1.5],  # top-left
	]
	for corner in corners:
		var c: Vector2 = corner[0]
		for s in range(steps + 1):
			var a: float = lerpf(corner[1], corner[2], float(s) / float(steps))
			pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts


## 폴리라인을 따라 대시(dash)-갭(gap)을 연속으로 이어 그린다(모서리 넘어 위상 유지 →
## 진짜 박음질처럼 균일). closed=true면 마지막→첫 점 세그먼트도 잇는다.
static func draw_running_stitch(
	ci: CanvasItem,
	pts: PackedVector2Array,
	closed: bool,
	color: Color,
	dash: float,
	gap: float,
	width: float = 2.0,
) -> void:
	if pts.size() < 2:
		return
	var seq: PackedVector2Array = pts.duplicate()
	if closed:
		seq.append(pts[0])
	var period: float = dash + gap
	var acc: float = 0.0  # 경로 시작부터 누적 거리(위상 유지용)
	for i in range(seq.size() - 1):
		var a: Vector2 = seq[i]
		var b: Vector2 = seq[i + 1]
		var seg: Vector2 = b - a
		var seg_len: float = seg.length()
		if seg_len < 0.001:
			continue
		var dir: Vector2 = seg / seg_len
		var t: float = 0.0
		while t < seg_len:
			var m: float = fmod(acc + t, period)
			if m < dash:
				var e: float = minf(t + (dash - m), seg_len)
				ci.draw_line(a + dir * t, a + dir * e, color, width)
				t = e
			else:
				t = minf(t + (period - m), seg_len)
		acc += seg_len


## 네 모서리 안쪽에 작은 "단추" 소품(재봉 라벨 태그 느낌).
static func draw_corner_buttons(ci: CanvasItem, rect: Rect2, margin: float) -> void:
	var m: float = margin
	var corners: PackedVector2Array = PackedVector2Array(
		[
			rect.position + Vector2(m, m),
			rect.position + Vector2(rect.size.x - m, m),
			rect.position + Vector2(rect.size.x - m, rect.size.y - m),
			rect.position + Vector2(m, rect.size.y - m),
		]
	)
	for c in corners:
		draw_button(ci, c, 4.5)


## 실 구멍 두 개짜리 작은 단추.
static func draw_button(ci: CanvasItem, center: Vector2, radius: float) -> void:
	ci.draw_circle(center, radius, Color(0.86, 0.80, 0.66))
	ci.draw_arc(center, radius, 0.0, TAU, 16, KNOT, 1.0)
	ci.draw_circle(center + Vector2(-radius * 0.35, 0.0), 0.9, KNOT)
	ci.draw_circle(center + Vector2(radius * 0.35, 0.0), 0.9, KNOT)
