extends "res://menu_ux_regression/check_base.gd"
## 비-headless 캡처(run.sh 의 CAPTURE_OUT). 창 크기(--resolution)와 --touch-controls 조합으로 메뉴 화면을
## 차례로 열어 PNG 를 남기고, 보이는 버튼의 논리 높이와 창 기준 실제 높이를 "PX" 줄로 출력한다.
## 창 크기 모사일 뿐 실기 검증이 아니다. 인자: --stub=<URL> --out=<dir> --prefix=<파일 접두>

const STATES: Array[String] = [
	"main",
	"nick_first",
	"nick_edit",
	"profile",
	"kind",
	"select_official",
	"select_empty",
	"select_user",
	"settings",
	"leaderboard",
	"leaderboard_fail",
	"hub_list_fail",
	"hub_list",
	"hub_detail",
	"hub_form",
	"hub_done",
	"hub_confirm",
	"result",
	"result_test",
]

var _driver: bool = false


func _ready() -> void:
	if not _driver:
		var d: Node = get_script().new()
		d.set("_driver", true)
		d.name = "MenuUxCaptureDriver"
		get_tree().root.add_child.call_deferred(d)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_args()
	LeaderboardClient.tutorial_seen = true
	await _frames(10)
	var out: String = str(_args.get("out", "."))
	var prefix: String = str(_args.get("prefix", "cap"))
	# 창 크기(논리 점)와 캔버스 배율: 16:9 캔버스가 창 안에 keep 으로 들어가는 배율.
	var win: Vector2 = Vector2(DisplayServer.window_get_size())
	var dpi: float = DisplayServer.screen_get_scale()
	var css: Vector2 = win / maxf(dpi, 1.0)
	var scale: float = minf(css.x / 1280.0, css.y / 720.0)
	print("CAPTURE %s window=%s css=%s scale=%.4f" % [prefix, str(win), str(css), scale])
	for st in STATES:
		if not await _state(st):
			print("CAPTURE %s %s: state failed" % [prefix, st])
			continue
		await _frames(12)
		var img: Image = get_viewport().get_texture().get_image()
		var path: String = "%s/%s_%s.png" % [out, prefix, st]
		img.save_png(path)
		print("CAPTURE %s" % path)
		for b in _visible_of(_scene(), "Button"):
			var h: float = (b as Control).get_global_rect().size.y
			print("PX %s %s %s logical=%.0f px=%.1f" % [prefix, st, _key_of(b), h, h * scale])
	get_tree().quit(0)
