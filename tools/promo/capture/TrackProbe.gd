extends SceneTree
## 트랙 곡률 프로파일 출력(촬영 구간 선정용, 읽기 전용). 격리 사본에서 실행한다.
## usage: Godot --headless --path <사본> -s res://promo_driver/TrackProbe.gd -- heart_01 cat_01
## 출력: 50px 간격으로 s, 부호 있는 곡률 반경(+=우회전), 접선 각도. 아이템 위치도 함께 찍는다.

const STEP: float = 50.0


func _initialize() -> void:
	var loader: Node = root.get_node("TrackLoader")
	for id in OS.get_cmdline_user_args():
		var tr: Object = loader.call("load_track", id)
		if tr == null:
			print("TRACK %s load failed" % id)
			continue
		var length: float = float(tr.get("length"))
		print("TRACK %s length=%.0f" % [id, length])
		var s: float = 0.0
		while s <= length:
			var t0: Vector2 = tr.call("tangent_at_s", s - 12.0)
			var t1: Vector2 = tr.call("tangent_at_s", s + 12.0)
			var k: float = t0.angle_to(t1) / 24.0
			var r: float = 1.0 / k if absf(k) > 1e-5 else 99999.0
			var t: Vector2 = tr.call("tangent_at_s", s)
			var p: Vector2 = tr.call("point_at_s", s)
			print(
				(
					"  s=%5.0f R=%8.0f ang=%6.1f pos=(%.0f,%.0f)"
					% [s, r, rad_to_deg(t.angle()), p.x, p.y]
				)
			)
			s += STEP
	quit(0)
