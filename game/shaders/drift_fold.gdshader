shader_type canvas_item;
render_mode blend_mix;

// 드리프트 원단 주름 2.5D 투영 (presentation.md §15). DriftFoldLayer가 패치마다 캔버스 아이템 두 개
// (접지 그림자 패스 + 표면 패스)를 만들고, 정점에는 바닥 월드 좌표와 형태 데이터만 한 번 올린다.
// 카메라(플레이어 위치·진행각)와 표현 시각은 프레임마다 한 번 바꾸는 전역 uniform으로 받고, 높이 진행은
// 패치 상수(생성·완화 시각, 최대 높이)와 표현 시각으로 셰이더가 계산한다.
//
// 투영은 fabric_mode7.gdshader의 화면→월드 수식을 역으로 푼 것과 같다(DriftFoldLayer.project와 동일):
//   d = P - player;  depth = d·fwd + cam_back;  x = (0.5 + (d·rgt)/(depth*spread)) * W
//   y = (horizon + depth_scale * (1 - z/cam_height) / depth) * H
// z=0이면 바닥 셰이더가 같은 화면 점에서 샘플하는 월드 점이 정확히 P다. 표면 색은 바닥 SubViewport
// 텍스처를 P의 원래 월드 UV(0.5 + d/coverage)로 원근 보정해 샘플한다(색 데이터 그대로, 피드백 없음).
//
// 정점 데이터: VERTEX = 바닥 월드 좌표, UV = (정규화 높이 h, 골짜기 차폐 ao),
// COLOR = (월드 기울기 x, y를 GRAD_RANGE로 [0,1]에 인코딩, 표면 알파, 접지 그림자 가중치).

const float GRAD_RANGE = 1.5;

uniform sampler2D source_tex : filter_linear, repeat_disable;
uniform bool shadow_pass = false;
// 모든 슬롯이 같은 값이라 프레임마다 한 번만 바꾸는 전역 uniform(DriftFoldLayer.setup이 런타임에 등록).
global uniform vec2 fold_player_pos;
global uniform float fold_heading;
global uniform float fold_now;
// 재질 생성 때 한 번 정하는 상수.
uniform vec2 screen_size = vec2(1280.0, 720.0);
uniform float horizon = 0.42;
uniform float depth_scale = 28.0;
uniform float cam_back = 140.0;
uniform float spread = 0.9;
uniform float coverage = 600.0;
uniform float cam_height = 14.175;
uniform float near_clip = 30.0;
// 시간 모델(DriftFoldShape와 같은 값).
uniform float t_rise = 0.12;
uniform float t_relax = 0.6;
uniform float residue = 0.15;
uniform float t_residue_fade = 2.5;
uniform float relax_spread_max = 0.45;
// 광원(카메라 기준: 오른쪽, 앞쪽, 위). 좌우 반전된 패치에도 같은 방향이라 그림자가 뒤집히지 않는다.
uniform vec3 light = vec3(-0.5, 0.45, 0.74);
uniform float light_gain = 1.25;
uniform float ao_gain = 0.3;
uniform float crest_gain = 0.12;
uniform float lum_min = 0.62;
uniform float lum_max = 1.38;
uniform float shadow_alpha = 0.3;
uniform float shadow_len = 0.5;
// 화면에서 솟는 최대 픽셀(캔버스 기준). 카메라 바로 앞에서 원근 때문에 주름이 지나치게 높아지지 않도록
// 정점 깊이에서 이 픽셀을 넘는 만큼 패치 높이 전체를 비례로 낮춘다(모양은 유지).
uniform float max_lift_px = 26.0;
// 카메라 바로 앞 감쇠: 정점 깊이가 near_fade_lo 이하면 높이·명암·표면 알파 0, near_fade_hi 이상이면 그대로.
// 근경에서 능선이 원근으로 부채꼴처럼 뻗지 않게 하고, near_clip으로 눌린 정점을 보이지 않게 한다.
uniform float near_fade_lo = 52.0;
uniform float near_fade_hi = 84.0;
// 패치 상수(슬롯에 패치를 올릴 때, relax가 바뀔 때만 설정). 측방 중심선은 patch_base + patch_n * patch_mid.
uniform vec2 patch_base = vec2(0.0);
uniform vec2 patch_n = vec2(0.0, 1.0);
uniform float patch_mid = 0.0;
uniform float patch_born = 0.0;
uniform float patch_relax = 0.0;
uniform float patch_amp = 0.0;
// 검증용: true면 높이 0·표면 알파 1로 그린다(높이 0 패치가 바닥과 같은 픽셀인지 화면 비교할 때만 사용).
uniform bool force_flat = false;

// 원근 보정 UV: 캔버스 varying은 화면 공간에서 선형 보간되므로 d/depth와 1/depth를 넘기고 fragment에서
// 나눠 월드 오프셋 d를 되살린다(높이 0 바닥 평면에서는 Mode 7과 정확히 같은 투영 매핑).
varying vec2 v_wd;
varying float v_id;
varying vec4 v_shade;

// DriftFoldShape.amp01과 같은 식. 솟음은 relax 시각에서 멈추고, 그때 높이에서 낮아지기만 한다.
float fold_amp01(float born, float relax, float now) {
	float age = now - born;
	if (age <= 0.0) {
		return 0.0;
	}
	float rise = smoothstep(0.0, t_rise, min(age, max(relax - born, 0.0)));
	float since = now - relax;
	if (since <= 0.0) {
		return rise;
	}
	if (since <= t_relax) {
		return rise * mix(1.0, residue, smoothstep(0.0, t_relax, since));
	}
	return rise * residue * (1.0 - smoothstep(0.0, t_residue_fade, since - t_relax));
}

void vertex() {
	vec2 fwd = vec2(cos(fold_heading), sin(fold_heading));
	vec2 rgt = vec2(-fwd.y, fwd.x);
	vec3 l = normalize(light);
	float a01 = force_flat ? 0.0 : fold_amp01(patch_born, patch_relax, fold_now);
	float amp = patch_amp * a01;
	// 완화 퍼짐: 완화가 진행될수록 측방 거리를 1 → 1+relax_spread_max배로 넓혀 능선이 넓어지며 낮아진다.
	float spread_k = force_flat ? 1.0 : 1.0 + relax_spread_max * smoothstep(0.0, t_relax, fold_now - patch_relax);
	float h = UV.x;
	float lat = dot(VERTEX - patch_base, patch_n);
	vec2 spread_pos = VERTEX + patch_n * ((lat - patch_mid) * (spread_k - 1.0));
	vec2 shadow_off = -normalize(rgt * l.x + fwd * l.y) * amp * shadow_len;
	vec2 world = shadow_pass ? spread_pos + shadow_off : spread_pos;
	vec2 d = world - fold_player_pos;
	float depth = dot(d, fwd) + cam_back;
	float inv = 1.0 / max(depth, near_clip);
	// 이 깊이에서 높이 1 단위가 솟는 픽셀 = depth_scale * H * inv / cam_height.
	float px_per_unit = depth_scale * screen_size.y * inv / cam_height;
	float near_k = smoothstep(near_fade_lo, near_fade_hi, depth);
	float a_eff = min(amp, max_lift_px / max(px_per_unit, 1e-4)) * near_k;
	float z = shadow_pass ? 0.0 : a_eff * h;
	v_wd = d * inv;
	v_id = inv;
	VERTEX = vec2(
		(0.5 + dot(d, rgt) * inv / spread) * screen_size.x,
		(horizon + depth_scale * (1.0 - z / cam_height) * inv) * screen_size.y
	);
	if (shadow_pass) {
		v_shade = vec4(0.0, 0.0, 0.0, force_flat ? 0.0 : shadow_alpha * a01 * near_k * COLOR.a);
	} else {
		vec2 g = (COLOR.rg * 2.0 - 1.0) * GRAD_RANGE * a_eff;
		float gr = dot(g, rgt);
		float gf = dot(g, fwd);
		float ndl = (-gr * l.x - gf * l.y + l.z) * inversesqrt(1.0 + gr * gr + gf * gf);
		float a01n = a01 * near_k;
		float lum = 1.0 + light_gain * (ndl - l.z) - ao_gain * a01n * UV.y + crest_gain * a01n * h;
		v_shade = vec4(vec3(clamp(lum, lum_min, lum_max)), force_flat ? 1.0 : COLOR.b * near_k);
	}
}

void fragment() {
	if (shadow_pass) {
		COLOR = v_shade;
	} else {
		vec4 t = texture(source_tex, vec2(0.5) + (v_wd / v_id) / coverage);
		COLOR = vec4(t.rgb * v_shade.rgb, v_shade.a);
	}
}
