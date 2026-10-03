shader_type canvas_item;

// 바닥 원단 타일(FabricSurface) 셰이더. SubViewport(월드 정렬 탑다운) 안에서 원단 텍스처를
// 월드 좌표로 반복 샘플하고, Mode 7 화면에서 그 지점이 놓일 깊이에 맞춰 밉맵 레벨을 고른다.
// Mode 7 셰이더(fabric_mode7.gdshader)와 주름 셰이더는 이 SubViewport를 밉맵 없이 한 번만
// 샘플하므로, 중·원경에서 화면 1px이 덮는 월드 면적만큼 여기서 미리 걸러 두어야 모아레가 줄어든다.
// 두 셰이더가 같은 소스를 읽으므로 바닥과 주름(높이 0) 픽셀은 계속 일치한다.
// 깊이 식은 fabric_mode7.gdshader와 같다: depth = forward + cam_back, 화면 행 dy = depth_scale/depth.

uniform sampler2D fabric_tex : filter_linear_mipmap, repeat_enable;
uniform float tile_world = 512.0; // 타일 1장의 월드 한 변(px)
uniform float texels_per_world = 1.0; // 텍스처 한 변 / tile_world
uniform float vp_per_world = 0.853; // SubViewport px / 월드 px
uniform bool use_depth = false; // 플레이어가 없으면(게임 밖) 뷰포트 해상도 기준 밉맵만 쓴다
uniform vec2 player_pos = vec2(0.0);
uniform vec2 fwd = vec2(1.0, 0.0);
uniform float depth_scale = 28.0;
uniform float cam_back = 140.0;
uniform float spread = 0.9;
uniform vec2 screen_size = vec2(1280.0, 720.0);
uniform float near_clip = 30.0;
// 화면 1px의 월드 발자국은 세로(깊이 방향)가 가로보다 훨씬 길다. 세로 비중을 높일수록
// 원경 줄무늬 모아레가 줄고, 낮출수록 가로 결이 선명하다.
uniform float aniso_weight = 0.7;
uniform float lod_bias = 0.0;

varying vec2 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 uv = v_world / tile_world;
	// SubViewport 자체의 해상도 한계(텍스처를 뷰포트에 축소해 그릴 때의 일반 밉맵).
	float lod = log2(max(texels_per_world / vp_per_world, 1e-4));
	if (use_depth) {
		float depth = max(dot(v_world - player_pos, fwd) + cam_back, near_clip);
		float fy = depth * depth / (depth_scale * screen_size.y); // 세로 1px당 월드 px
		float fx = depth * spread / screen_size.x; // 가로 1px당 월드 px
		float f = pow(fx, 1.0 - aniso_weight) * pow(fy, aniso_weight);
		lod = max(lod, log2(max(f * texels_per_world, 1e-4)) + lod_bias);
	}
	COLOR = textureLod(fabric_tex, uv, max(lod, 0.0));
}
