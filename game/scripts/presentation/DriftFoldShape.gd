class_name DriftFoldShape
extends RefCounted
## 드리프트 주름 형태 데이터 (presentation.md §15). 표현 전용 정적 캐시.
##
## fold_height.png(R 채널 = 높이, 능선은 이미지 세로 방향)를 한 번 읽어 공유 격자로 바꾼다.
## 격자의 u 축은 측방(재봉선에서 바깥쪽), v 축은 진행 접선이다. 모든 주름 패치가 이 격자 하나를
## 공유하고, 패치마다 다른 것은 바닥 위치·방향·크기·높이뿐이다.
##
## 함께 만드는 것:
##  - 높이 h, 기울기 hu/hv, 골짜기 차폐 ao, 접지 그림자 sh, 표면 알파 a (격자 정점별 PackedFloat32Array)
##  - 원경·잔여 흔적용 음영 텍스처(residue_tex)와 완주 줌아웃용 능선 마스크(crest_tex)
##  - 패치 시간 모델(amp01)과 깊이 정렬용 삼각형 인덱스(grid_indices)
## 엔진 import는 lossless(compress/mode=0)이고 텍스처를 색으로 쓰지 않는다(CPU에서 R 값만 읽음).
## 생성 이미지라 경계값을 믿지 않고 clamp와 가장자리 smoothstep 감쇠로 경계 높이를 0으로 만든다.

const HEIGHT_PATH: String = "res://assets/gfx/drift_folds/fold_height.png"

## 공유 격자 셀 수. u(측방)는 능선 3개가 셀 2~3개 이상 걸치도록 촘촘히, v(접선)는 능선이 천천히
## 휘므로 성기게 둔다. 16×16에서 시작해 능선 폭이 1셀 남짓으로 깨지는 것을 보고 이 값으로 맞췄다.
const NU: int = 22
const NV: int = 12
## 원본 이미지에서 쓰는 영역(능선 밖 검정 여백을 잘라 격자를 능선에 집중). 비율 좌표.
const CROP_U0: float = 0.17
const CROP_U1: float = 0.83
const CROP_V0: float = 0.05
const CROP_V1: float = 0.95
## 패치 가장자리 감쇠 폭(격자 비율). 이 안에서 높이가 smoothstep으로 0까지 줄어 사각 경계가 없다.
const EDGE_U: float = 0.14
const EDGE_V: float = 0.12
## 접선 방향 기준 행(v=0 패치 뒤쪽 끝=근경, v=1 바늘 쪽). 능선 개수·폭 측정에 쓰는 가운데 행이다.
const PEAK_V: float = 0.5
## 긴 드리프트에서 겹친 패치들이 하나의 긴 주름으로 이어지도록, 높이를 v 방향으로 거의 일정한 단면(봉우리
## 행 근처 평균)과 원래 높이맵의 섞음으로 만든다. 1이면 완전히 곧은 능선, 0이면 원래 높이맵.
const STRAIGHT_MIX: float = 0.75
## v 방향 봉우리 고원: 양 끝 FADE_V 구간만 0으로 줄이고 가운데는 거의 평평하다. 패치 간격보다 고원이 길어
## 이웃 패치와 겹친 구간에서 높이가 꺼지지 않는다.
const FADE_V: float = 0.28
## 능선을 둥글고 넓게 만드는 격자 흐림 횟수(3×3 상자). 생성 이미지의 능선은 좁고 날카로워서 그대로
## 쓰면 원근에서 속도선처럼 읽힌다(캡처로 확인). 4회면 능선 세 개가 각각 측방 셀 5~7개 폭의 둥근
## 언덕이 되고 사이 골짜기는 얕아진다.
const ROUND_PASSES: int = 4
## 표면 알파: 높이가 이 구간을 지나며 0→1. 평평한 곳은 투명이라 바닥(같은 원단)이 그대로 보이고
## 뒤쪽 패치의 능선을 잘라 먹지 않는다.
const ALPHA_LO: float = 0.02
const ALPHA_HI: float = 0.16
## 잔여 흔적·완주 마스크 텍스처 해상도.
const TEX_SIZE: int = 64

# --- 시간 모델(표현 시간, 초). 주행 표현 시계가 멈추면(일시정지) 그대로 멈춘다. ---
## 생성 후 솟는 시간.
const RISE: float = 0.12
## 스트로크(드리프트 유지)가 살아 있는 동안 패치의 relax 값. 이 동안은 완화하지 않고 솟은 높이를 유지하며,
## 스트로크가 끝나는 순간 그 스트로크의 모든 패치가 함께 완화를 시작한다(DriftSkid.end_stroke).
const HELD: float = 1.0e9
## 완화 시간(최대 높이 → 잔여 높이).
const RELAX: float = 0.60
## 완화 뒤 남는 낮은 높이 비율.
const RESIDUE: float = 0.15
## 잔여 높이가 0으로 사라지는 시간(바닥 음영 흔적은 계속 남는다).
const RESIDUE_FADE: float = 2.5

static var _ready_ok: bool = false
static var _tried: bool = false
static var grid_h: PackedFloat32Array = PackedFloat32Array()
static var grid_hu: PackedFloat32Array = PackedFloat32Array()
static var grid_hv: PackedFloat32Array = PackedFloat32Array()
static var grid_ao: PackedFloat32Array = PackedFloat32Array()
static var grid_sh: PackedFloat32Array = PackedFloat32Array()
static var grid_a: PackedFloat32Array = PackedFloat32Array()
static var residue_tex: ImageTexture = null
static var crest_tex: ImageTexture = null
static var _index_cache: Dictionary = {}
static var _bake_usec: int = -1
static var _bake_count: int = 0


## 형태 데이터를 (최초 1회) 만든다. 이미지가 없거나 읽을 수 없으면 false(주름을 그리지 않음).
static func ensure() -> bool:
	if _tried:
		return _ready_ok
	_tried = true
	var t0: int = Time.get_ticks_usec()
	var img: Image = _load_height_image()
	if img == null:
		push_warning("DriftFoldShape: 높이맵을 읽지 못해 주름 연출을 끕니다")
		return false
	_build_grid(img)
	var hgt64: PackedFloat32Array = _sample_heights(img, TEX_SIZE - 1, TEX_SIZE - 1)
	residue_tex = _build_residue_texture(hgt64)
	crest_tex = _build_crest_texture(hgt64)
	_ready_ok = true
	_bake_count += 1
	_bake_usec = Time.get_ticks_usec() - t0
	return true


## 높이맵 베이크(격자·텍스처 생성)에 걸린 시간(µs, 프로세스당 한 번). 아직 안 했으면 -1.
static func bake_usec() -> int:
	return _bake_usec


## 이 프로세스에서 베이크한 횟수(정적 캐시라 재시작해도 1).
static func bake_count() -> int:
	return _bake_count


static func is_ready() -> bool:
	return _ready_ok


static func _load_height_image() -> Image:
	if not ResourceLoader.exists(HEIGHT_PATH):
		return null
	var tex: Texture2D = load(HEIGHT_PATH) as Texture2D
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	img = img.duplicate()
	img.convert(Image.FORMAT_RGB8)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var rect: Rect2i = Rect2i(
		int(w * CROP_U0), int(h * CROP_V0),
		int(w * (CROP_U1 - CROP_U0)), int(h * (CROP_V1 - CROP_V0))
	)
	return img.get_region(rect)


## 잘라낸 높이 이미지를 (cols+1)×(rows+1) 정점 높이로 샘플한다(미리 줄여 앨리어싱을 막는다).
## 최대값으로 정규화하고 clamp한 뒤 가장자리 감쇠를 곱한다.
static func _sample_heights(img: Image, cols: int, rows: int) -> PackedFloat32Array:
	var small: Image = img.duplicate()
	small.resize(cols * 3 + 1, rows * 3 + 1, Image.INTERPOLATE_LANCZOS)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize((cols + 1) * (rows + 1))
	var peak: float = 0.0
	for j in range(rows + 1):
		for i in range(cols + 1):
			var r: float = small.get_pixel(i * 3, j * 3).r
			out[j * (cols + 1) + i] = r
			peak = maxf(peak, r)
	peak = maxf(peak, 0.001)
	# 곧은 단면: 가운데 행(v 0.35 ~ 0.65) 평균. 이웃 패치와 능선 위치가 맞아 긴 주름으로 이어진다.
	var profile: PackedFloat32Array = PackedFloat32Array()
	profile.resize(cols + 1)
	var j0: int = int(round(0.35 * rows))
	var j1: int = int(round(0.65 * rows))
	for i in range(cols + 1):
		var acc: float = 0.0
		for j in range(j0, j1 + 1):
			acc += out[j * (cols + 1) + i]
		profile[i] = acc / float(j1 - j0 + 1)
	for j in range(rows + 1):
		var v: float = float(j) / float(rows)
		var ev: float = smoothstep(0.0, FADE_V, v) * smoothstep(0.0, FADE_V, 1.0 - v)
		for i in range(cols + 1):
			var u: float = float(i) / float(cols)
			var eu: float = smoothstep(0.0, EDGE_U, u) * smoothstep(0.0, EDGE_U, 1.0 - u)
			var k: int = j * (cols + 1) + i
			var r: float = lerpf(out[k], profile[i], STRAIGHT_MIX)
			out[k] = clampf(r / peak, 0.0, 1.0) * eu * ev
	return out


## 공유 격자 높이를 (u, v) ∈ 0..1에서 쌍선형 보간한다(회귀 검사의 연속성 측정용).
static func height_at(u: float, v: float) -> float:
	var x: float = clampf(u, 0.0, 1.0) * float(NU)
	var y: float = clampf(v, 0.0, 1.0) * float(NV)
	var i: int = mini(int(x), NU - 1)
	var j: int = mini(int(y), NV - 1)
	var fx: float = x - float(i)
	var fy: float = y - float(j)
	var w: int = NU + 1
	var top: float = lerpf(grid_h[j * w + i], grid_h[j * w + i + 1], fx)
	var bot: float = lerpf(grid_h[(j + 1) * w + i], grid_h[(j + 1) * w + i + 1], fx)
	return lerpf(top, bot, fy)


## 분리 가능 상자 흐림((2r+1)×(2r+1), 가로 한 번 + 세로 한 번)을 passes번. 경계는 가장자리 복제.
## 3×3을 9번 읽던 방식과 같은 결과를 6번 읽기로 낸다. 골짜기 차폐·접지 그림자·잔여 흔적 원천.
static func _blur(
	src: PackedFloat32Array, cols: int, rows: int, passes: int, radius: int = 1
) -> PackedFloat32Array:
	var cur: PackedFloat32Array = src.duplicate()
	var w: int = cols + 1
	var inv: float = 1.0 / float(2 * radius + 1)
	var tmp: PackedFloat32Array = PackedFloat32Array()
	tmp.resize(cur.size())
	for _p in range(passes):
		for j in range(rows + 1):
			var row: int = j * w
			for i in range(w):
				var acc: float = 0.0
				for d in range(-radius, radius + 1):
					acc += cur[row + clampi(i + d, 0, cols)]
				tmp[row + i] = acc * inv
		for j in range(rows + 1):
			for i in range(w):
				var acc2: float = 0.0
				for d in range(-radius, radius + 1):
					acc2 += tmp[clampi(j + d, 0, rows) * w + i]
				cur[j * w + i] = acc2 * inv
	return cur


static func _build_grid(img: Image) -> void:
	grid_h = _blur(_sample_heights(img, NU, NV), NU, NV, ROUND_PASSES)
	# 흐림이 테두리로 번진 높이를 가장자리 감쇠로 다시 0까지 눌러 경계 높이 0을 보장한다.
	var top: float = 0.001
	for j in range(NV + 1):
		var v: float = float(j) / float(NV)
		var ev: float = smoothstep(0.0, EDGE_V, v) * smoothstep(0.0, EDGE_V, 1.0 - v)
		for i in range(NU + 1):
			var u: float = float(i) / float(NU)
			var eu: float = smoothstep(0.0, EDGE_U, u) * smoothstep(0.0, EDGE_U, 1.0 - u)
			var k: int = j * (NU + 1) + i
			grid_h[k] *= eu * ev
			top = maxf(top, grid_h[k])
	for k in range(grid_h.size()):
		grid_h[k] = clampf(grid_h[k] / top, 0.0, 1.0)
	var w: int = NU + 1
	var n: int = w * (NV + 1)
	grid_hu = PackedFloat32Array()
	grid_hv = PackedFloat32Array()
	grid_a = PackedFloat32Array()
	grid_ao = PackedFloat32Array()
	grid_hu.resize(n)
	grid_hv.resize(n)
	grid_a.resize(n)
	grid_ao.resize(n)
	var near_blur: PackedFloat32Array = _blur(grid_h, NU, NV, 2)
	# 접지 그림자 가중치: 능선 양옆 밑동과 골짜기(흐린 높이가 실제 높이보다 큰 곳)에 짧고 진하게.
	var side_blur: PackedFloat32Array = _blur(grid_h, NU, NV, 3)
	grid_sh = PackedFloat32Array()
	grid_sh.resize(n)
	for k in range(n):
		grid_sh[k] = clampf((side_blur[k] - grid_h[k] * 0.6) * 2.4, 0.0, 1.0)
	for j in range(NV + 1):
		for i in range(w):
			var k: int = j * w + i
			var i0: int = maxi(i - 1, 0)
			var i1: int = mini(i + 1, NU)
			var j0: int = maxi(j - 1, 0)
			var j1: int = mini(j + 1, NV)
			# 정규화 격자 좌표(u,v ∈ 0..1)에 대한 기울기.
			grid_hu[k] = (grid_h[j * w + i1] - grid_h[j * w + i0]) * float(NU) / float(i1 - i0)
			grid_hv[k] = (grid_h[j1 * w + i] - grid_h[j0 * w + i]) * float(NV) / float(j1 - j0)
			grid_a[k] = smoothstep(ALPHA_LO, ALPHA_HI, grid_h[k])
			# 이웃보다 낮은 곳(능선 사이 골짜기·밑동)일수록 1에 가깝다.
			grid_ao[k] = clampf((near_blur[k] - grid_h[k]) * 3.0, 0.0, 1.0)


## 바닥에 평평하게 칠하는 잔여 흔적 텍스처. 작은 흐림 − 큰 흐림(DoG)으로 능선은 밝게, 골짜기와
## 밑동은 어둡게 만든다. 광원 방향과 무관한 음영이라 좌우 반전·회전해도 그림자가 뒤집히지 않는다.
## 큰 흐림은 반경 2 상자를 두 번(3×3 여섯 번과 같은 분산) 적용한다.
static func _build_residue_texture(hgt: PackedFloat32Array) -> ImageTexture:
	var n: int = TEX_SIZE - 1
	var small: PackedFloat32Array = _blur(hgt, n, n, 1)
	var large: PackedFloat32Array = _blur(hgt, n, n, 2, 2)
	var peak: float = 0.0001
	for k in range(hgt.size()):
		peak = maxf(peak, absf(small[k] - large[k]))
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(TEX_SIZE * TEX_SIZE * 4)
	for k in range(TEX_SIZE * TEX_SIZE):
		var d: float = (small[k] - large[k]) / peak
		var lum: int = 255 if d >= 0.0 else 0
		var a: float = d * 0.55 if d >= 0.0 else -d * 0.80
		bytes[k * 4] = lum
		bytes[k * 4 + 1] = lum
		bytes[k * 4 + 2] = lum
		bytes[k * 4 + 3] = int(clampf(a, 0.0, 1.0) * 255.0)
	var img: Image = Image.create_from_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8, bytes)
	return ImageTexture.create_from_image(img)


## 완주 줌아웃(어두운 배경의 지도)에서 쓰는 능선 마스크. 흰색 + 높이 알파.
static func _build_crest_texture(hgt: PackedFloat32Array) -> ImageTexture:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(TEX_SIZE * TEX_SIZE * 4)
	for k in range(TEX_SIZE * TEX_SIZE):
		bytes[k * 4] = 255
		bytes[k * 4 + 1] = 255
		bytes[k * 4 + 2] = 255
		bytes[k * 4 + 3] = int(smoothstep(0.08, 0.55, hgt[k]) * 255.0)
	var img: Image = Image.create_from_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8, bytes)
	return ImageTexture.create_from_image(img)


## 패치의 정규화 높이 진행(0..1). 생성 후 RISE 동안 솟고, relax 시각부터 RELAX 동안 RESIDUE까지
## 낮아진 뒤 RESIDUE_FADE 동안 0이 된다. 솟음은 relax 시각에서 멈춘다: RISE 전에 드리프트가 끝나면
## 그때 도달한 높이에서 낮아지기만 한다(손을 뗀 뒤 다시 부풀지 않음). now·born·relax는 표현 시계 값이다.
## drift_fold.gdshader의 fold_amp01과 같은 식이어야 한다.
static func amp01(born: float, relax: float, now: float) -> float:
	var age: float = now - born
	if age <= 0.0:
		return 0.0
	var rise: float = smoothstep(0.0, RISE, minf(age, maxf(relax - born, 0.0)))
	var since: float = now - relax
	if since <= 0.0:
		return rise
	if since <= RELAX:
		return rise * lerpf(1.0, RESIDUE, smoothstep(0.0, RELAX, since))
	return rise * RESIDUE * (1.0 - smoothstep(0.0, RESIDUE_FADE, since - RELAX))


## 패치 높이가 완전히 0이 되는 시각(이후에는 메시 후보에서 빠진다).
static func amp_end_time(relax: float) -> float:
	return relax + RELAX + RESIDUE_FADE


## (cols+1)×(rows+1) 정점 격자의 삼각형 인덱스. order 비트: 1=i 역순, 2=j 역순, 4=j가 바깥 루프.
## 그리는 쪽이 카메라에서 먼 셀부터 그리도록 순서를 고른다(캔버스에는 깊이 버퍼가 없다).
static func grid_indices(cols: int, rows: int, order: int) -> PackedInt32Array:
	var key: int = (cols * 1000 + rows) * 8 + order
	if _index_cache.has(key):
		return _index_cache[key]
	var w: int = cols + 1
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(cols * rows * 6)
	var p: int = 0
	var outer_n: int = rows if (order & 4) != 0 else cols
	var inner_n: int = cols if (order & 4) != 0 else rows
	for a in range(outer_n):
		for b in range(inner_n):
			var i: int = b if (order & 4) != 0 else a
			var j: int = a if (order & 4) != 0 else b
			if (order & 1) != 0:
				i = cols - 1 - i
			if (order & 2) != 0:
				j = rows - 1 - j
			var k: int = j * w + i
			out[p] = k
			out[p + 1] = k + 1
			out[p + 2] = k + w
			out[p + 3] = k + 1
			out[p + 4] = k + w + 1
			out[p + 5] = k + w
			p += 6
	_index_cache[key] = out
	return out
