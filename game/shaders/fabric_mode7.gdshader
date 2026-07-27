shader_type canvas_item;
render_mode blend_mix;

// Mode 7 바닥 원근 셰이더 (presentation.md §1.4/§1.5).
// SubViewport(플레이어 중심·월드 정렬 탑다운)를 source_tex로 받아
// 수평선 아래를 원근 워프한다. heading 회전은 프래그먼트에서 처리하므로
// SubViewport 카메라는 회전하지 않는다(translate-only). 수평선 위는 투명.

uniform sampler2D source_tex : filter_linear, repeat_disable;
uniform float heading = 0.0; // 플레이어 진행각(rad)
uniform float horizon = 0.40; // 수평선 스크린 행
uniform float depth_scale = 28.0; // cam_height*focal 통합 상수(px). 클수록 멀리 봄
uniform float spread = 0.9; // 가로 원근 확산
uniform float cam_back = 140.0; // 카메라가 플레이어 뒤로 물러난 거리(px)
uniform float coverage = 600.0; // 소스가 담는 월드 정사각 한 변(px)
uniform vec4 fabric_color : source_color = vec4(0.72, 0.78, 0.34, 1.0);

void fragment() {
	if (UV.y <= horizon) {
		COLOR = vec4(0.0); // 수평선 위 → 투명(배경 얼굴이 비침)
	} else {
		// mediump 강제 GPU(웹)에서 UV.y-horizon이 반올림으로 0이 되면 depth가
		// Inf/NaN으로 전파될 수 있어 하한을 건다. 데스크톱(highp)에선 이 구간이
		// 이미 수평선 바로 아래 서브픽셀이라 OOB→원단색이므로 시각 변화 없음.
		float dy = max(UV.y - horizon, 1e-3);
		float depth = depth_scale / dy;
		float lateral = (UV.x - 0.5) * depth * spread;
		float forward = depth - cam_back;
		vec2 fwd = vec2(cos(heading), sin(heading));
		vec2 rgt = vec2(-fwd.y, fwd.x); // 부호는 하네스에서 좌/우 검증
		vec2 world_off = fwd * forward + rgt * lateral;
		vec2 src_uv = vec2(0.5) + world_off / coverage;

		bool oob = src_uv.x < 0.0 || src_uv.x > 1.0 || src_uv.y < 0.0 || src_uv.y > 1.0;
		COLOR = oob ? fabric_color : texture(source_tex, src_uv);

		float fade = smoothstep(0.0, 0.06, dy); // 원경 앨리어싱 완화
		COLOR.rgb = mix(fabric_color.rgb, COLOR.rgb, fade);
		COLOR.a = 1.0;
	}
}
