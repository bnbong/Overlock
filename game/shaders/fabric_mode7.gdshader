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
// 이음새 봉합(presentation.md §12/구도 결함 수정 3). PresentationController가 상수로 주입.
uniform float horizon_fade = 0.035; // 수평선 근처를 원단 대표색으로 흐리는 대역(앨리어싱 완화)
uniform float edge_width = 0.02; // 테이블 모서리 트림(어두운 라인) 폭(수평선 바로 아래)
uniform float edge_darkness = 0.58; // 트림 최저 밝기 배수(0=검정, 1=변화없음)

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

		// 원경 페이드: 수평선 근처 원단을 대표색으로 흐려 앨리어싱/시머를 줄인다.
		// fabric_color가 타일 평균색과 일치하므로(FabricSurface.FABRIC_BASE) 단색 띠로
		// 보이지 않고 원단 질감이 자연스럽게 수렴한다.
		float fade = smoothstep(0.0, horizon_fade, dy);
		COLOR.rgb = mix(fabric_color.rgb, COLOR.rgb, fade);

		// 테이블 모서리 트림: 수평선 바로 아래를 부드럽게 어둡게 해 원단이 테이블에
		// '놓여 있는' 느낌으로 봉합한다(원단이 떠 보이는 문제 해소, 참고작 구도).
		// dy=0(수평선)에서 최대, edge_width에서 소멸.
		float trim = 1.0 - smoothstep(0.0, edge_width, dy);
		COLOR.rgb *= mix(1.0, edge_darkness, trim);
		COLOR.a = 1.0;
	}
}
