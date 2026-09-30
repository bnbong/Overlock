extends Node
## 오디오 매니저 (presentation.md §7). autoload "AudioManager".
##
## 훅은 UI/프레젠테이션 계층(Countdown / SpeedGauge / HUD / PresentationController /
## ResultScreen)에 심어 물리 루프(RaceDirector)와 완전히 분리한다. 호출부는
## /root/AudioManager를 런타임 조회 + has_method 가드로 부르므로, 이 오토로드가 없어도
## 안전하게 무시된다. 여기의 어떤 메서드도 시뮬레이션 상태를 조회하거나 변경하지 않는다.
##
## 버스: Master 아래 BGM/SFX 버스를 코드로 생성한다. BGM은 loop_id→스트림 매핑으로 메뉴 곡
## (Sewed)과 인게임 곡(Locking_In)을 전환하며, 같은 곡이 이미 울리고 있으면 재시작하지 않는다
## (MP3 루프는 .import loop=true가 1차 소스, 런타임에서도 방어적으로 켠다). SFX는 라운드로빈
## 폴리포니 풀로 재생한다. 재봉틀 틱은 속도(0..1)에 비례해 재생 간격/피치를 바꾸는 표현 전용 루프다.

const BUS_MASTER: String = "Master"
const BUS_BGM: String = "BGM"
const BUS_SFX: String = "SFX"

const AUDIO_DIR: String = "res://assets/audio/"
# BGM: loop_id → 파일. 메뉴 계열은 Sewed, 인게임은 Locking_In. 미지의 loop_id는 메뉴 곡 폴백.
const BGM_FILES: Dictionary = {
	"menu": "Sewed.mp3",
	"gameplay": "Locking_In.mp3",
}
const BGM_FALLBACK_ID: String = "menu"
const SFX_FILES: Dictionary = {
	"tick": "sfx_tick.wav",
	"countdown": "sfx_countdown.wav",
	"go": "sfx_go.wav",
	"cut": "sfx_cut.wav",
	"offseam": "sfx_offseam.wav",
	"speed_up": "sfx_speed_up.wav",
	"speed_down": "sfx_speed_down.wav",
	"finish": "sfx_finish.wav",
	"record": "sfx_record.wav",
}

const SFX_VOICES: int = 8  # 라운드로빈 폴리포니 보이스 수
const DEFAULT_BGM_DB: float = -6.0

# 재봉틀 틱 루프 튜닝(표현 전용). norm 0=정지(무음) → 1=최고속.
const TICK_INTERVAL_SLOW: float = 0.32
const TICK_INTERVAL_FAST: float = 0.055
const TICK_PITCH_LOW: float = 0.85
const TICK_PITCH_HIGH: float = 1.55
const TICK_LOG_STEP: float = 0.15  # 이만큼 rate가 바뀌면 디버그 로그
# rate가 0으로 떨어져도 이 시간만큼은 tick accum을 유지한다. 고주사율(90/120Hz)
# 디스플레이에서 물리 틱 없는 렌더 프레임이 순간적으로 rate 0을 넣어도 틱 스케줄이
# 살아남게 하는 방어(호출부의 이동 판정 히스테리시스와 이중 안전).
const TICK_ZERO_GRACE: float = 0.12
# set_machine_rate가 이 시간(처리 시간 기준) 넘게 오지 않으면 구동자(주행 씬의 프레젠테이션)가
# 사라진 것으로 보고 틱 루프를 끈다. 일시정지 중에는 이 오토로드도 멈춰 경과가 쌓이지 않는다.
# 씬 전환 시 stop_run_audio가 1차 정리이고, 이것은 호출이 누락돼도 메뉴에서 틱이 새지 않게 하는 방어.
const TICK_STALE_TIME: float = 0.5

var _bgm_streams: Dictionary = {}  # loop_id(String) → AudioStream
var _sfx_streams: Dictionary = {}
var _bgm_player: AudioStreamPlayer = null
var _current_bgm_id: String = ""  # 현재 재생 중(또는 마지막으로 설정된) BGM loop_id
var _tick_player: AudioStreamPlayer = null
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_next: int = 0

var _prev_stage: int = 1
var _tick_norm: float = 0.0
var _tick_accum: float = 0.0
var _tick_zero_t: float = 0.0
var _tick_rate_age: float = 0.0  # 마지막 set_machine_rate 이후 경과(처리 시간)
var _last_logged_norm: float = -1.0
var _debug: bool = false

# 볼륨 상태(선형 0..1). get_*가 돌려주는 권위값이며 버스 dB는 항상 여기서 파생한다(0=뮤트).
# 버스 dB→선형 역변환은 뮤트 경계에서 정보를 잃으므로 선형 캐시를 권위값으로 둔다. 시작 시
# _apply_saved_volumes가 저장값(LeaderboardClient.settings.json)으로 덮어쓴다. BGM 프리적용
# 기본은 버스 기본 -6dB(DEFAULT_BGM_DB)에서 파생 — 볼륨 API 도입 전후 체감을 동일하게 유지.
var _vol_master: float = 1.0
var _vol_bgm: float = db_to_linear(DEFAULT_BGM_DB)
var _vol_sfx: float = 1.0


func _ready() -> void:
	_debug = (
		OS.get_environment("OVERLOCK_AUDIO_LOG") != ""
		or "--audio-log" in OS.get_cmdline_user_args()
	)
	_ensure_buses()
	_load_streams()
	_build_players()
	# 저장 볼륨은 LeaderboardClient가 이 시점 이후(오토로드 순서상 뒤)에 로드하므로, 모든
	# 오토로드 _ready가 끝난 프레임 처음으로 적용을 미룬다.
	_apply_saved_volumes.call_deferred()
	_log("ready (buses+players initialised)")


func _exit_tree() -> void:
	# 트리 이탈(앱 종료 등) 시 재생 중인 보이스를 정리해 AudioServer 재생 핸들을 해제한다.
	_stop_all_voices()


func _process(delta: float) -> void:
	# 재봉틀 틱 루프: 매 프레임 rate만 반영, 재생 자체는 여기서 스케줄한다.
	_tick_rate_age += delta
	if _tick_rate_age > TICK_STALE_TIME and _tick_norm > 0.0:
		_log("machine rate stale -> tick off")
		_tick_norm = 0.0
		_last_logged_norm = -1.0
	if _tick_player == null or _tick_norm <= 0.001:
		# rate 0으로 떨어져도 짧은 유예 동안은 accum을 유지한다(고주사율에서 물리 틱
		# 공백 프레임이 넣는 순간적 rate 0로 틱 스케줄이 리셋되는 것을 막는다).
		_tick_zero_t += delta
		if _tick_zero_t >= TICK_ZERO_GRACE:
			_tick_accum = 0.0
		return
	_tick_zero_t = 0.0
	var interval: float = lerpf(TICK_INTERVAL_SLOW, TICK_INTERVAL_FAST, _tick_norm)
	_tick_accum += delta
	if _tick_accum >= interval:
		_tick_accum = 0.0
		_tick_player.pitch_scale = lerpf(TICK_PITCH_LOW, TICK_PITCH_HIGH, _tick_norm)
		_tick_player.play()


# --- 훅 API (presentation.md §7.1 표면과 호출부 시그니처에 정합) ---


## 런 시작 시 런 스코프 오디오 상태를 초기화한다. 이 오토로드는 씬 리로드에도
## 살아남으므로, 재시작 시 직전 런의 _prev_stage가 남아 속도 사운드 방향을 오판하는
## 것(예: 5단으로 끝낸 뒤 1→2단 가속이 하강음으로)을 막는다.
func reset_run_state() -> void:
	_prev_stage = 1
	_tick_norm = 0.0
	_tick_accum = 0.0
	_tick_zero_t = 0.0
	_last_logged_norm = -1.0
	if _tick_player != null:
		_tick_player.stop()
	_log("reset_run_state")


## loop_id에 맞는 곡으로 BGM을 전환한다. 메뉴 계열("menu" 등)은 Sewed, 인게임("gameplay")은
## Locking_In. 미지의 loop_id는 메뉴 곡으로 폴백한다. 같은 곡이 이미 재생 중이면 재시작하지
## 않아(메뉴 화면 간 이동에서 곡이 끊기지 않게) 곡이 다를 때만 스트림을 교체한다.
func play_bgm(loop_id: String) -> void:
	if _bgm_player == null:
		return
	var id: String = loop_id if _bgm_streams.has(loop_id) else BGM_FALLBACK_ID
	var stream: AudioStream = _bgm_streams.get(id, null)
	if stream == null:
		return
	if _current_bgm_id == id and _bgm_player.playing:
		return
	_current_bgm_id = id
	_bgm_player.stream = stream
	_bgm_player.play()
	_log("play_bgm(%s -> %s)" % [loop_id, id])


func stop_bgm() -> void:
	if _bgm_player != null:
		_bgm_player.stop()
	_log("stop_bgm")


func play_countdown_beep(n: int) -> void:
	# 3→2→1로 갈수록 살짝 높아지는 비프(GO에 다가가는 상승감).
	var pitch: float = 1.0 + (3 - clampi(n, 1, 3)) * 0.06
	_play_sfx("countdown", pitch)
	_log("play_countdown_beep(%d)" % n)


func play_go() -> void:
	_play_sfx("go")
	_log("play_go")


## 속도 단계 변경 시 상승/하강 휘프. 방향은 직전 단계와 비교해 판정.
func on_speed_stage(stage: int) -> void:
	var clamped: int = clampi(stage, 1, 5)
	if clamped > _prev_stage:
		_play_sfx("speed_up")
		_log("on_speed_stage(%d) up" % clamped)
	elif clamped < _prev_stage:
		_play_sfx("speed_down")
		_log("on_speed_stage(%d) down" % clamped)
	_prev_stage = clamped


## 재봉틀 틱 루프 속도(0..1). 매 프레임 rate만 갱신, 재생은 _process가 스케줄.
func set_machine_rate(speed_norm: float) -> void:
	_tick_norm = clampf(speed_norm, 0.0, 1.0)
	_tick_rate_age = 0.0
	if absf(_tick_norm - _last_logged_norm) >= TICK_LOG_STEP:
		_last_logged_norm = _tick_norm
		_log("set_machine_rate(%.2f)" % _tick_norm)


## 손가락 부상.
func play_injury() -> void:
	_play_sfx("cut")
	_log("play_injury")


## Off-Seam / Tear 진입 등 밴드 전이.
func on_band_enter(band: int) -> void:
	_play_sfx("offseam")
	_log("on_band_enter(%d)" % band)


## 아이템 슬롯이 가득 차 필드 아이템을 못 먹음(v2.2.1). 새 에셋 없이 짧은 재봉틀 틱을 낮은 음으로 낸다.
func on_item_slots_full() -> void:
	_play_sfx("tick", 0.6)
	_log("on_item_slots_full")


func play_finish() -> void:
	_end_run_audio()
	_play_sfx("finish")
	_log("play_finish")


## 신기록 팡파레(피니시 시 신기록일 때 finish 대신 재생).
func play_record() -> void:
	_end_run_audio()
	_play_sfx("record")
	_log("play_record")


## 주행 종료 공통 정리: BGM과 재봉틀 틱 루프를 멈춘다(결과 화면에서 계속 울리지 않도록).
func _end_run_audio() -> void:
	stop_bgm()
	_tick_norm = 0.0
	_last_logged_norm = -1.0
	if _tick_player != null:
		_tick_player.stop()


## 주행 씬 이탈(일시정지 후 메뉴·재시작, 에디터 복귀, 결과 전환 등 모든 트리 이탈) 시 주행 전용
## 소리를 멈춘다: 재봉틀 틱 루프와 그 상태, 남은 SFX 보이스. 틱 rate는 주행 씬의 프레젠테이션만
## 갱신하는데, 일시정지 중엔 그 갱신도 이 오토로드의 _process도 멈춰 있다가 씬 전환 후 마지막
## rate로 되살아나 메뉴에서 틱이 계속 울렸다(Esc→M 버그). BGM은 건드리지 않는다(재시작은 곡을
## 이어 가고, 메뉴·에디터 화면은 각자 play_bgm으로 곡을 맞추며, 완주는 play_finish가 멈춘다).
func stop_run_audio() -> void:
	_tick_norm = 0.0
	_tick_accum = 0.0
	_tick_zero_t = 0.0
	_last_logged_norm = -1.0
	if _tick_player != null:
		_tick_player.stop()
	for voice in _sfx_pool:
		if voice != null:
			voice.stop()
	_log("stop_run_audio")


# --- 볼륨 API (선형 0..1 → 버스 dB, 0=뮤트) ---
#
# 설정 화면(SettingsScreen)이 슬라이더로 구동한다. set_*는 버스에 즉시 반영만 하고(디스크
# 미접촉), 영속은 LeaderboardClient.save_volumes가 담당한다(settings.json 소유자). get_*는
# 마지막으로 설정한 선형값을 그대로 돌려준다.


func set_master_volume(linear: float) -> void:
	_vol_master = _apply_bus_volume(BUS_MASTER, linear)


func set_bgm_volume(linear: float) -> void:
	_vol_bgm = _apply_bus_volume(BUS_BGM, linear)


func set_sfx_volume(linear: float) -> void:
	_vol_sfx = _apply_bus_volume(BUS_SFX, linear)


func get_master_volume() -> float:
	return _vol_master


func get_bgm_volume() -> float:
	return _vol_bgm


func get_sfx_volume() -> float:
	return _vol_sfx


## 설정 화면 볼륨 프리뷰용 단발 효과음(마스터/효과음 슬라이더 조작 종료 시 체감 확인).
func preview_sfx() -> void:
	_play_sfx("go")
	_log("preview_sfx")


# --- 내부 구현 ---


func _ensure_buses() -> void:
	_add_child_bus(BUS_BGM)
	_add_child_bus(BUS_SFX)
	var bgm_idx: int = AudioServer.get_bus_index(BUS_BGM)
	if bgm_idx != -1:
		AudioServer.set_bus_volume_db(bgm_idx, DEFAULT_BGM_DB)


func _add_child_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	var idx: int = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, BUS_MASTER)


## 저장된 볼륨(LeaderboardClient.settings.json)을 세 버스에 적용한다. 오토로드 순서상
## AudioManager._ready 시점엔 LeaderboardClient가 아직 로드 전이라 call_deferred로 미뤄 호출한다
## (그때는 모든 오토로드 _ready 완료 → 저장값 반영). LeaderboardClient가 없으면 조용히 무시.
func _apply_saved_volumes() -> void:
	if not is_instance_valid(LeaderboardClient):
		return
	set_master_volume(LeaderboardClient.volume_master)
	set_bgm_volume(LeaderboardClient.volume_bgm)
	set_sfx_volume(LeaderboardClient.volume_sfx)
	_log("apply_saved_volumes m=%.3f b=%.3f s=%.3f" % [_vol_master, _vol_bgm, _vol_sfx])


## 선형 볼륨(0..1)을 버스에 반영하고 클램프한 선형값을 돌려준다(캐시에 그대로 저장). 0 근사는
## dB로 -inf라 set_bus_mute로 처리한다. 버스가 없으면(초기화 전/헤드리스) 클램프값만 반환.
func _apply_bus_volume(bus_name: String, linear: float) -> float:
	var clamped: float = clampf(linear, 0.0, 1.0)
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return clamped
	if clamped <= 0.001:
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, linear_to_db(clamped))
	return clamped


func _load_streams() -> void:
	# BGM(MP3)은 loop_id별로 로드한다. 루프는 .import(loop=true)가 1차 소스지만, 임포트 설정이
	# 유실돼도 끊김 없이 반복되도록 런타임에서도 AudioStreamMP3.loop를 방어적으로 켠다.
	for id in BGM_FILES:
		var bgm_path: String = AUDIO_DIR + String(BGM_FILES[id])
		if ResourceLoader.exists(bgm_path):
			var stream: AudioStream = load(bgm_path)
			if stream is AudioStreamMP3:
				(stream as AudioStreamMP3).loop = true
			_bgm_streams[id] = stream
	for key in SFX_FILES:
		var path: String = AUDIO_DIR + String(SFX_FILES[key])
		if ResourceLoader.exists(path):
			_sfx_streams[key] = load(path)


func _build_players() -> void:
	# BGM 스트림은 play_bgm(loop_id)에서 곡별로 설정한다(빌드 시엔 미지정).
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.bus = BUS_BGM
	_apply_web_playback(_bgm_player)
	add_child(_bgm_player)

	_tick_player = AudioStreamPlayer.new()
	_tick_player.bus = BUS_SFX
	if _sfx_streams.has("tick"):
		_tick_player.stream = _sfx_streams["tick"]
	_apply_web_playback(_tick_player)
	add_child(_tick_player)

	for i in range(SFX_VOICES):
		var voice: AudioStreamPlayer = AudioStreamPlayer.new()
		voice.bus = BUS_SFX
		_apply_web_playback(voice)
		add_child(voice)
		_sfx_pool.append(voice)


## 웹(HTML5)에서는 기본 재생 타입이 Sample(Web Audio 샘플 노드 직결)이다. 이 경로는
## 런타임에 코드로 만든 커스텀 버스(BGM/SFX→Master) 라우팅을 통해 신호를 출력단까지
## 전달하지 못해 완전 무음이 된다(스레드 OFF 단일 스레드 빌드에서 재현). 재생 타입을
## Stream 으로 강제하면 Godot 자체 AudioServer 믹싱(드라이버 워클릿)을 거쳐 버스 라우팅이
## 정상 반영된다. 데스크톱은 원래 AudioServer 믹싱이라 영향 없음(웹에서만 분기).
func _apply_web_playback(player: AudioStreamPlayer) -> void:
	if OS.has_feature("web"):
		player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM


func _stop_all_voices() -> void:
	if _bgm_player != null:
		_bgm_player.stop()
	if _tick_player != null:
		_tick_player.stop()
	for voice in _sfx_pool:
		if voice != null:
			voice.stop()


func _play_sfx(key: String, pitch: float = 1.0) -> void:
	if not _sfx_streams.has(key) or _sfx_pool.is_empty():
		return
	var voice: AudioStreamPlayer = _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_pool.size()
	voice.stream = _sfx_streams[key]
	voice.pitch_scale = pitch
	voice.play()


func _log(msg: String) -> void:
	if _debug:
		print("[AudioManager] ", msg)
