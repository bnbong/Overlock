class_name SeamProgressBar
extends Control
## 진행도 바 (presentation.md §4.2). 미니맵 아래. s/length 위치에 바늘 마커.
##
## RaceDirector는 이미 progress_s를 넘기므로 물리 변경 없음. HUD가 progress_s/length를
## set_progress로 전달한다. 재봉 스킨: 웜톤 원단 홈 + 완주분을 "빨간 실 박음질"로 채우고
## 진행 위치에 은색 바늘 마커를 얹는다(어두운 네이비 바를 대체, 장면 아트와 통일).

const RADIUS: float = 8.0
const GROOVE: Color = Color(0.796, 0.726, 0.576, 1.0)  # 원단 홈(미완주)
const SEAM_FILL: Color = Color(0.831, 0.278, 0.263, 0.90)  # 완주분 빨간 실 채움
const SEAM_STITCH: Color = Color(0.94, 0.36, 0.34, 1.0)  # 박음질 대시(밝은 빨강)
const NEEDLE_COLOR: Color = Color(0.86, 0.88, 0.92, 1.0)  # 은색 바늘
const NEEDLE_EYE: Color = Color(0.36, 0.30, 0.26, 1.0)

var _progress: float = 0.0


func set_progress(fraction: float) -> void:
	_progress = clampf(fraction, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	# 사용자 제공 시트: 원단 홈 + 은색 바늘 마커 텍스처. 없으면 절차 폴백.
	var groove: Texture2D = UiSkin.tex("progress_groove")
	if groove == null:
		_draw_procedural()
		return
	var w: float = size.x
	var h: float = size.y
	draw_texture_rect(groove, Rect2(Vector2.ZERO, size), false)
	# 홈 슬롯(그루브 텍스처 안쪽 실 통로에 맞춘 채움 영역; 좌우 끝단추 사이).
	var chan: Rect2 = Rect2(Vector2(w * 0.12, h * 0.32), Vector2(w * 0.76, h * 0.36))
	var fill_w: float = chan.size.x * _progress
	if fill_w > 1.0:
		var fill_sb: StyleBoxFlat = StyleBoxFlat.new()
		fill_sb.bg_color = SEAM_FILL
		fill_sb.set_corner_radius_all(int(chan.size.y * 0.5))
		draw_style_box(fill_sb, Rect2(chan.position, Vector2(fill_w, chan.size.y)))
		var cy: float = chan.position.y + chan.size.y * 0.5
		var line: PackedVector2Array = PackedVector2Array(
			[Vector2(chan.position.x + 2.0, cy), Vector2(chan.position.x + fill_w - 2.0, cy)]
		)
		SewingSkin.draw_running_stitch(self, line, false, SEAM_STITCH, 6.0, 4.0, 2.0)
	# 진행 위치 은색 바늘 마커(텍스처).
	var x: float = chan.position.x + chan.size.x * _progress
	var needle: Texture2D = UiSkin.tex("needle_marker")
	if needle != null:
		var nh: float = h * 1.5
		var nw: float = nh * float(needle.get_width()) / float(needle.get_height())
		draw_texture_rect(needle, Rect2(x - nw * 0.5, h * 0.5 - nh * 0.5, nw, nh), false)
	else:
		_draw_needle_marker(Vector2(x, h * 0.5), h)


func _draw_procedural() -> void:
	var w: float = size.x
	var h: float = size.y
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	# 원단 패치 바탕.
	SewingSkin.draw_patch(self, rect, SewingSkin.FABRIC, RADIUS)
	# 실이 지나가는 홈(재봉 가이드).
	var chan: Rect2 = Rect2(Vector2(5.0, h * 0.5 - 5.0), Vector2(w - 10.0, 10.0))
	var chan_sb: StyleBoxFlat = StyleBoxFlat.new()
	chan_sb.bg_color = GROOVE
	chan_sb.set_corner_radius_all(5)
	draw_style_box(chan_sb, chan)
	# 완주분: 빨간 실 채움 + 그 위에 박음질 대시(바느질된 솔기).
	var fill_w: float = chan.size.x * _progress
	if fill_w > 1.0:
		var fill_sb: StyleBoxFlat = StyleBoxFlat.new()
		fill_sb.bg_color = SEAM_FILL
		fill_sb.set_corner_radius_all(5)
		draw_style_box(fill_sb, Rect2(chan.position, Vector2(fill_w, chan.size.y)))
		var cy: float = h * 0.5
		var line: PackedVector2Array = PackedVector2Array(
			[Vector2(chan.position.x + 2.0, cy), Vector2(chan.position.x + fill_w - 2.0, cy)]
		)
		SewingSkin.draw_running_stitch(self, line, false, SEAM_STITCH, 6.0, 4.0, 2.0)
	# 박음질 테두리.
	SewingSkin.draw_stitch_border(self, rect, SewingSkin.THREAD_PURPLE, 3.5, RADIUS, 1.5)
	# 진행 위치 바늘 마커.
	var x: float = chan.position.x + chan.size.x * _progress
	_draw_needle_marker(Vector2(x, h * 0.5), h)


func _draw_needle_marker(center: Vector2, h: float) -> void:
	var half: float = h * 0.5 + 2.0
	# 은색 바늘(세로 핀).
	draw_line(
		Vector2(center.x, center.y - half), Vector2(center.x, center.y + half), NEEDLE_COLOR, 2.4
	)
	# 바늘 머리(위쪽 작은 삼각) + 바늘귀.
	var head: PackedVector2Array = PackedVector2Array(
		[
			Vector2(center.x - 4.0, center.y - half),
			Vector2(center.x + 4.0, center.y - half),
			Vector2(center.x, center.y - half + 6.0),
		]
	)
	draw_colored_polygon(head, NEEDLE_COLOR)
	draw_circle(Vector2(center.x, center.y - half + 2.5), 1.0, NEEDLE_EYE)
