extends SceneTree
## 실제 입력 플레이 캡처 합성(JPG): 대표 장면 축소 복사, 확대 크롭, 연속 프레임 시트.
## 인자(-- 뒤): <full 실행 출력> <모바일 844 출력> <모바일 932 출력> <합성 출력 디렉터리>
## 없는 파일은 건너뛴다(캡처 이름은 s 값 등 실행마다 달라질 수 있어 접두사로 찾는다).

const SINGLE_W: int = 960
const SINGLE_H: int = 540

var _full: String = ""
var _m844: String = ""
var _m932: String = ""
var _out_dir: String = ""


func _init() -> void:
	var a: PackedStringArray = OS.get_cmdline_user_args()
	_full = a[0].trim_suffix("/") + "/"
	_m844 = a[1].trim_suffix("/") + "/"
	_m932 = a[2].trim_suffix("/") + "/"
	_out_dir = a[3]
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_singles()
	_crops()
	_sheets()
	quit()


func _load(p: String) -> Image:
	if not FileAccess.file_exists(p):
		push_warning("missing " + p)
		return null
	var img: Image = Image.load_from_file(p)
	if img == null or img.is_empty():
		return null
	img.convert(Image.FORMAT_RGB8)
	return img


## dir 안에서 prefix로 시작하는 첫 PNG 경로(정렬 기준). 없으면 "".
func _find(dir: String, prefix: String) -> String:
	var files: Array = Array(DirAccess.get_files_at(dir))
	files.sort()
	for f in files:
		if f.begins_with(prefix) and f.ends_with(".png"):
			return dir + f
	return ""


func _save(img: Image, name: String) -> void:
	img.save_jpg(_out_dir + "/" + name + ".jpg", 0.86)
	print("wrote ", name, " ", img.get_size())


## 대표 장면(1280×720 → 960×540). [실행 디렉터리, 파일 접두사, 출력 이름]
func _singles() -> void:
	var specs: Array = [
		[_full, "play_01_nickname_modal", "play_01_nickname_modal"],
		[_full, "play_03_track_select", "play_03_track_select"],
		[_full, "play_04_tutorial_coachmarks", "play_04_tutorial_coachmarks"],
		[_full, "play_05_countdown", "play_05_countdown"],
		[_full, "play_07_gear5", "play_07_gear5"],
		[_full, "play_08_gear_down2", "play_08_gear_down2"],
		[_full, "play_12_steer_right_max", "play_12_steer_right_max"],
		[_full, "play_14_steer_left_max", "play_14_steer_left_max"],
		[_full, "play_15_curve_right_approach", "play_15_curve_right_approach"],
		[_full, "play_16_curve_left_entry", "play_16_curve_left_entry"],
		[_full, "play_17_drift_a", "play_17_drift_a"],
		[_full, "play_18_drift_b", "play_18_drift_b"],
		[_full, "play_19_paused_t0", "play_19_paused"],
		[_full, "play_r1_bonk_1_t3", "play_r1_bonk_t3"],
		[_full, "play_r1_bonk_2_t12", "play_r1_bonk_t12"],
		[_full, "play_22_restart_t3", "play_22_restart_t3"],
		[_full, "play_r1_mom_hold", "play_r1_mom_hold"],
		[_full, "play_r1_mom_exit_done", "play_r1_mom_exit_done"],
		[_full, "play_r2_injury1_t0", "play_r2_injury1"],
		[_full, "play_r2_mom_paused_mid", "play_r2_mom_paused_mid"],
		[_full, "play_r2_mom_exit_done", "play_r2_mom_exit_done_band"],
		[_full, "play_r2_thimble_s", "play_r2_thimble"],
		[_full, "play_r2_injury2_t0", "play_r2_injury2"],
		[_full, "play_r2_bonk_2_paused_mid", "play_r2_bonk_paused_mid"],
		[_full, "play_r2_bonk_3_after", "play_r2_bonk_after"],
		[_full, "play_r2_straight_late", "play_r2_straight_late"],
		[_full, "play_31_finish_view_t60", "play_31_finish_view"],
		[_full, "play_33_result", "play_33_result"],
	]
	for sp in specs:
		var p: String = _find(sp[0], sp[1])
		var img: Image = _load(p) if p != "" else null
		if img == null:
			push_warning("single missing " + sp[1])
			continue
		img.resize(SINGLE_W, SINGLE_H, Image.INTERPOLATE_LANCZOS)
		_save(img, sp[2])
	for m in [[_m844, "844"], [_m932, "932"]]:
		for n in [
			"play_m_04_tutorial_coachmarks",
			"play_m_08_steer_left_max",
			"play_m_09_steer_right_max",
			"play_m_10_drift",
			"play_m_bonk_1_t3",
			"play_m_bonk_2_paused_mid",
			"play_m_r1_mom_enter_b",
		]:
			var src: String = n.replace("play_m_r1_", "play_r1_")
			var img: Image = _load(m[0] + src + ".png")
			if img != null:
				_save(img, n.replace("play_m_", "play_m%s_" % m[1]))


func _crop(img: Image, r: Rect2i, scale: float) -> Image:
	var c: Image = img.get_region(r)
	c.resize(int(r.size.x * scale), int(r.size.y * scale), Image.INTERPOLATE_LANCZOS)
	return c


func _row(imgs: Array) -> Image:
	var w: int = 0
	var h: int = 0
	for i in imgs:
		w += i.get_width() + 6
		h = maxi(h, i.get_height())
	var out: Image = Image.create(w - 6, h, false, Image.FORMAT_RGB8)
	out.fill(Color(1, 1, 1))
	var x: int = 0
	for i in imgs:
		out.blit_rect(i, Rect2i(Vector2i.ZERO, i.get_size()), Vector2i(x, 0))
		x += i.get_width() + 6
	return out


## 확대 크롭: [[접두사, 영역], ...] 을 한 줄로 이어 붙인다.
func _crops() -> void:
	var specs: Array = [
		[
			"crop_needle_top_countdown_gear1",
			[
				["play_05_countdown", Rect2i(540, 150, 200, 340)],
				["play_06_straight_gear1", Rect2i(540, 150, 200, 340)]
			],
			1.6
		],
		[
			"crop_right_pinky_speedpanel",
			[
				["play_07_gear5", Rect2i(1000, 380, 280, 240)],
				["play_12_steer_right_max", Rect2i(1000, 380, 280, 240)],
				["play_18_drift_b", Rect2i(1000, 380, 280, 240)],
				["play_r1_mom_hold", Rect2i(1000, 380, 280, 240)]
			],
			1.3
		],
		[
			"crop_sweat_cheek",
			[
				["play_07_gear5", Rect2i(420, 170, 480, 150)],
				["play_12_steer_right_max", Rect2i(420, 170, 480, 150)]
			],
			1.3
		],
		[
			"crop_bonk_stars_hud",
			[
				["play_r1_bonk_1_t3", Rect2i(380, 0, 900, 320)],
				["play_r1_bonk_2_t12", Rect2i(380, 0, 900, 320)]
			],
			0.8
		],
	]
	for sp in specs:
		var parts: Array = []
		for c in sp[1]:
			var p: String = _find(_full, c[0])
			var img: Image = _load(p) if p != "" else null
			if img != null:
				parts.append(_crop(img, c[1], sp[2]))
		if not parts.is_empty():
			_save(_row(parts), sp[0])


## 연속 프레임 시트. [실행, seq 접두사, 몇 장마다, 최대 장수, 스케일, 열, 크롭 또는 null, 이름, 시작 오프셋]
func _sheets() -> void:
	var band: Rect2i = Rect2i(0, 120, 1280, 230)
	var specs: Array = [
		[_full, "r1_steer", 3, 56, 0.5, 2, band, "play_seq_steer_face_band", 0],
		[_full, "r1_steer", 6, 28, 0.25, 7, null, "play_seq_steer_full", 0],
		[_full, "r1_gears", 2, 24, 0.25, 6, null, "play_seq_gears", 0],
		[_full, "r1_drift", 2, 25, 0.25, 5, null, "play_seq_drift", 0],
		[_full, "r1_bonk", 2, 50, 0.25, 5, null, "play_seq_bonk_run1_full", 0],
		[_full, "r1_bonk", 2, 40, 0.5, 4, Rect2i(240, 0, 800, 330), "play_seq_bonk_run1_face", 0],
		[_full, "r2_bonk", 2, 50, 0.25, 5, null, "play_seq_bonk_run2_injured_pause", 0],
		[_full, "r1_mom", 2, 33, 0.25, 6, null, "play_seq_mom_run1", 0],
		[_full, "r2_mom", 2, 33, 0.25, 6, null, "play_seq_mom_run2_after_injury", 0],
		[_full, "r2a_reversal", 2, 25, 0.25, 5, null, "play_seq_reversal_injury1", 0],
		[_full, "r2_finish", 2, 19, 0.25, 5, null, "play_seq_finish", 0],
		[_m844, "m_bonk", 3, 30, 0.5, 5, null, "play_m844_seq_bonk", 0],
		[_m932, "m_bonk", 3, 30, 0.5, 5, null, "play_m932_seq_bonk", 0],
	]
	for sp in specs:
		var dir: String = sp[0] + "seq/"
		var files: Array = []
		for f in DirAccess.get_files_at(dir):
			if f.begins_with(sp[1] + "_") and f.ends_with(".png"):
				files.append(f)
		files.sort()
		var picked: Array = []
		for i in range(int(sp[8]), files.size(), sp[2]):
			picked.append(files[i])
			if picked.size() >= sp[3]:
				break
		if picked.is_empty():
			push_warning("sheet empty " + sp[7])
			continue
		var cols: int = sp[5]
		var tiles: Array = []
		for f in picked:
			var img: Image = _load(dir + f)
			if sp[6] != null:
				img = img.get_region(sp[6])
			img.resize(
				int(img.get_width() * sp[4]),
				int(img.get_height() * sp[4]),
				Image.INTERPOLATE_BILINEAR
			)
			tiles.append(img)
		var tw: int = tiles[0].get_width()
		var th: int = tiles[0].get_height()
		var rows: int = int(ceil(tiles.size() / float(cols)))
		var sheet: Image = Image.create(cols * (tw + 2), rows * (th + 2), false, Image.FORMAT_RGB8)
		sheet.fill(Color(1, 1, 1))
		for i in range(tiles.size()):
			sheet.blit_rect(
				tiles[i],
				Rect2i(0, 0, tw, th),
				Vector2i((i % cols) * (tw + 2), (i / cols) * (th + 2))
			)
		_save(sheet, sp[7])
		print("  ", sp[7], " frames: ", picked[0], " .. ", picked[picked.size() - 1])
