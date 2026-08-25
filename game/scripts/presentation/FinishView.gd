class_name FinishView
extends Control
## 완주 줌아웃 연출 오버레이 (presentation.md §13). 스크린 공간 Control _draw.
##
## 피니시 순간 RaceDirector가 begin()으로 트랙 중심선 전체·플레이어 스티치 전체
## 궤적·결과 dict를 넘긴다. 노루발 주변 스케일에서 전체 트랙 뷰로 ~1초 줌아웃한 뒤
## 홀드하며 서킷 모양(중심선)과 내 재봉 자국(빨간 트레일), 재봉 평점을 보여준다.
## Mode 7 SubViewport 카메라는 건드리지 않는다(스크린 공간 독립 오버레이).
##
## 애니메이션은 _process(렌더 프레임)에서 진행하고, 전환/스킵 타이밍은 RaceDirector가
## FINISH_VIEW 상태에서 소유한다. 이 노드는 순수 뷰다.

const ZOOM_DURATION: float = 1.0  # 노루발 근접 → 전체 뷰 줌아웃(초)
const ZOOM_START_FACTOR: float = 7.0  # 시작 배율(전체 뷰 대비). 종료는 1.0.
const FIT_PADDING: float = 0.80  # 전체 뷰에서 트랙 bbox를 화면의 이 비율에 맞춤.
const BG_FADE: float = 0.35  # 배경 페이드인(초).
const BG_MAX_ALPHA: float = 0.95
const TEXT_FADE_START: float = 0.75  # 줌아웃이 거의 끝날 때 텍스트가 떠오른다.
const TEXT_FADE_END: float = 1.25

const BG_COLOR: Color = Color(0.09, 0.072, 0.062)  # 웜톤 어두운 배경(재봉실 무드)
const BAND_COLOR: Color = Color(0.34, 0.24, 0.44, 0.28)  # 재봉 코리도(fail 폭, 옅게)
const CENTER_COLOR: Color = Color(0.72, 0.56, 0.96, 0.95)  # 서킷 윤곽(중심선, 실 보라)
const TRAIL_COLOR: Color = Color(0.90, 0.28, 0.26, 1.0)  # 내 재봉 자국(빨간 실)
# 드리프트 스키드(원경 단순화 톤). 원단 명암 변조를 흉내 낸 뮤트 탄색 — 빨간 트레일·보라
# 중심선과 구별되며 트레일 뒤에 옅게 깔린다(§13 줌아웃 반영).
const SKID_COLOR: Color = Color(0.82, 0.75, 0.44, 0.80)
const SKID_WIDTH: float = 2.5  # 줌아웃 스키드 dash 두께(스크린 고정)
const SKID_OFFSET: float = 5.0  # intensity=1에서 스크린 측방 오프셋(px)
const SKID_DASH: float = 3.5  # 융기 dash 반길이(px)
const START_COLOR: Color = Color(0.40, 0.90, 0.55, 1.0)
const FINISH_COLOR: Color = Color(0.98, 0.84, 0.34, 1.0)
const CAPTION_COLOR: Color = Color(0.86, 0.79, 0.66)  # 따뜻한 크림 캡션
const HEADLINE_COLOR: Color = Color(0.968, 0.929, 0.847)  # 밝은 크림 헤드라인

var _active: bool = false
var _time: float = 0.0
var _track_points: PackedVector2Array = PackedVector2Array()
var _trail_points: PackedVector2Array = PackedVector2Array()
var _skid_marks: Array = []  # 드리프트 스키드 자국(각 {"pos","dir","intensity"}, 줌아웃 반영)
var _fail_width: float = 90.0
var _player_pos: Vector2 = Vector2.ZERO
var _bbox: Rect2 = Rect2()
var _track_name: String = ""
var _grade: String = "-"
var _grade_color: Color = Color.WHITE
var _final_time: String = ""


func _ready() -> void:
	set_process(false)


## 재봉 평점 문자를 등급별 색으로 환산(ResultScreen과 공유하는 단일 소스).
static func grade_color(grade: String) -> Color:
	match grade:
		"S":
			return Color(1.0, 0.84, 0.30)  # 금색
		"A":
			return Color(0.45, 0.92, 0.55)  # 초록
		"B":
			return Color(0.42, 0.72, 0.98)  # 파랑
		"C":
			return Color(0.98, 0.70, 0.35)  # 주황
		_:
			return Color(0.86, 0.46, 0.46)  # D, 붉은 회색


## RaceDirector가 피니시 순간 호출. 트랙·전체 트레일·결과로 줌아웃 연출을 시작한다.
## skid_marks는 선택 파라미터(기본 빈 배열)라 4-인자 기존 호출과 호환된다.
func begin(
	track: TrackData,
	trail: PackedVector2Array,
	player_pos: Vector2,
	result: Dictionary,
	skid_marks: Array = []
) -> void:
	_track_points = track.points
	_trail_points = trail
	_skid_marks = skid_marks
	_fail_width = track.fail
	_player_pos = player_pos
	_bbox = _compute_bbox()
	_track_name = (
		track.track_name if not track.track_name.is_empty() else str(result.get("track_id", ""))
	)
	_grade = str(result.get("grade", "-"))
	_grade_color = grade_color(_grade)
	_final_time = _format_ms(int(result.get("final_time_ms", 0)))
	_time = 0.0
	_active = true
	visible = true
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	if not _active:
		return
	_time += delta
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var vp: Vector2 = size
	# 배경 페이드인 — Mode 7 뷰·HUD를 덮어 오버레이가 잘 보이게 한다.
	var bg_a: float = minf(_time / BG_FADE, 1.0) * BG_MAX_ALPHA
	draw_rect(Rect2(Vector2.ZERO, vp), Color(BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, bg_a), true)
	if _track_points.size() >= 2:
		_draw_track(vp)
	_draw_text(vp)


## 줌아웃 이징으로 월드→스크린 변환을 만들고 코리도·중심선·트레일·마커를 그린다.
func _draw_track(vp: Vector2) -> void:
	var t: float = clampf(_time / ZOOM_DURATION, 0.0, 1.0)
	var eased: float = 1.0 - pow(1.0 - t, 3.0)  # ease-out cubic
	var fit: float = _fit_scale(vp)
	var scale: float = fit * lerpf(ZOOM_START_FACTOR, 1.0, eased)
	var focus: Vector2 = _player_pos.lerp(_bbox.get_center(), eased)
	var origin: Vector2 = vp * 0.5

	# 재봉 코리도(fail 폭). 월드 스케일에 비례하되 화면을 넘지 않게 클램프.
	var band_w: float = minf(_fail_width * 2.0 * scale, vp.y)
	var track_screen: PackedVector2Array = _project(_track_points, focus, scale, origin)
	draw_polyline(track_screen, BAND_COLOR, band_w)
	# 서킷 윤곽(중심선) — 스크린 고정 두께로 또렷하게.
	draw_polyline(track_screen, CENTER_COLOR, 2.5)
	# 드리프트 스키드 자국 — 트레일 뒤(아래)에 옅은 융기 dash로 먼저 깐다.
	if not _skid_marks.is_empty():
		_draw_skids(focus, scale, origin)
	# 내 재봉 자국(전체 궤적).
	if _trail_points.size() >= 2:
		draw_polyline(_project(_trail_points, focus, scale, origin), TRAIL_COLOR, 3.0)
	# 시작·피니시 마커.
	draw_circle(_project_point(_track_points[0], focus, scale, origin), 6.0, START_COLOR)
	var last: Vector2 = _track_points[_track_points.size() - 1]
	draw_circle(_project_point(last, focus, scale, origin), 6.0, FINISH_COLOR)


## 드리프트 스키드 자국을 줌아웃 뷰에 그린다(원경 단순화). 각 자국을 스크린으로 투영하고,
## 이웃 자국으로 접선을 추정해 드리프트 방향(dir 부호)으로 측방 오프셋된 짧은 융기 dash를
## 그린다. 원단 명암 변조를 흉내 낸 뮤트 톤(SKID_COLOR)으로 트레일 뒤에 옅게 깔린다.
func _draw_skids(focus: Vector2, scale: float, origin: Vector2) -> void:
	var count: int = _skid_marks.size()
	# 자국 위치를 미리 투영해 접선 추정에 재사용.
	var pts: PackedVector2Array = PackedVector2Array()
	pts.resize(count)
	for i in range(count):
		pts[i] = _project_point(Vector2(_skid_marks[i]["pos"]), focus, scale, origin)
	for i in range(count):
		var dir: float = float(_skid_marks[i]["dir"])
		var s: float = signf(dir)
		if s == 0.0:
			continue
		var intensity: float = clampf(float(_skid_marks[i]["intensity"]), 0.0, 1.0)
		var tangent: Vector2 = _skid_tangent(pts, i, count)
		var perp: Vector2 = Vector2(-tangent.y, tangent.x) * s
		var center: Vector2 = pts[i] + perp * (SKID_OFFSET * intensity)
		var half: Vector2 = tangent * (SKID_DASH + SKID_DASH * intensity)
		draw_line(center - half, center + half, SKID_COLOR, SKID_WIDTH)


## 투영된 자국 배열에서 인접 점 방향으로 접선을 추정(끝점은 한쪽 이웃만).
func _skid_tangent(pts: PackedVector2Array, i: int, count: int) -> Vector2:
	var a: Vector2
	var b: Vector2
	if count < 2:
		return Vector2.RIGHT
	if i == 0:
		a = pts[0]
		b = pts[1]
	elif i == count - 1:
		a = pts[count - 2]
		b = pts[count - 1]
	else:
		a = pts[i - 1]
		b = pts[i + 1]
	var d: Vector2 = b - a
	if d.length_squared() < 0.0001:
		return Vector2.RIGHT
	return d.normalized()


func _draw_text(vp: Vector2) -> void:
	var font: Font = get_theme_default_font()
	if font == null:
		return
	var a: float = clampf(
		(_time - TEXT_FADE_START) / maxf(TEXT_FADE_END - TEXT_FADE_START, 0.0001), 0.0, 1.0
	)
	if a <= 0.0:
		return
	var white: Color = Color(HEADLINE_COLOR.r, HEADLINE_COLOR.g, HEADLINE_COLOR.b, a)
	var caption: Color = Color(CAPTION_COLOR.r, CAPTION_COLOR.g, CAPTION_COLOR.b, a)
	# 상단 중앙: 완주 + 트랙명.
	draw_string(
		font, Vector2(0.0, 52.0), "TRACK COMPLETE", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 26, white
	)
	draw_string(
		font, Vector2(0.0, 84.0), _track_name, HORIZONTAL_ALIGNMENT_CENTER, vp.x, 20, caption
	)
	# 좌상단: 재봉 평점(큰 등급 문자).
	draw_string(
		font, Vector2(44.0, 128.0), "SEAM GRADE", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, caption
	)
	draw_string(
		font,
		Vector2(44.0, 208.0),
		_grade,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		84,
		Color(_grade_color.r, _grade_color.g, _grade_color.b, a)
	)
	# 하단 중앙: 최종 시간 + 스킵 힌트.
	draw_string(
		font,
		Vector2(0.0, vp.y - 58.0),
		"FINAL  " + _final_time,
		HORIZONTAL_ALIGNMENT_CENTER,
		vp.x,
		24,
		white
	)
	draw_string(
		font,
		Vector2(0.0, vp.y - 28.0),
		"Press any key to continue",
		HORIZONTAL_ALIGNMENT_CENTER,
		vp.x,
		15,
		caption
	)


## 트랙·트레일 전체를 감싸는 월드 바운딩 박스(fail 폭만큼 여백).
func _compute_bbox() -> Rect2:
	if _track_points.is_empty():
		return Rect2(_player_pos - Vector2(100.0, 100.0), Vector2(200.0, 200.0))
	var mn: Vector2 = _track_points[0]
	var mx: Vector2 = _track_points[0]
	for p in _track_points:
		mn = mn.min(p)
		mx = mx.max(p)
	for p in _trail_points:
		mn = mn.min(p)
		mx = mx.max(p)
	for m in _skid_marks:
		var sp: Vector2 = Vector2(m["pos"])
		mn = mn.min(sp)
		mx = mx.max(sp)
	var margin: Vector2 = Vector2(_fail_width, _fail_width)
	return Rect2(mn - margin, (mx + margin) - (mn - margin))


func _fit_scale(vp: Vector2) -> float:
	var s: Vector2 = _bbox.size
	if s.x <= 0.0 or s.y <= 0.0:
		return 1.0
	return FIT_PADDING * minf(vp.x / s.x, vp.y / s.y)


func _project(
	pts: PackedVector2Array, focus: Vector2, scale: float, origin: Vector2
) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(pts.size())
	for i in range(pts.size()):
		out[i] = origin + (pts[i] - focus) * scale
	return out


func _project_point(p: Vector2, focus: Vector2, scale: float, origin: Vector2) -> Vector2:
	return origin + (p - focus) * scale


static func _format_ms(ms: int) -> String:
	var minutes: int = ms / 60000
	var secs: int = (ms / 1000) % 60
	var millis: int = ms % 1000
	return "%02d:%02d.%03d" % [minutes, secs, millis]
