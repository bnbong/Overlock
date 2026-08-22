extends Node
## 오디오 매니저 (presentation.md §7). autoload "AudioManager".
##
## 훅은 UI/프레젠테이션 계층(Countdown / SpeedGauge / HUD / PresentationController /
## ResultScreen)에 심어 물리 루프(RaceDirector)와 완전히 분리한다. 호출부는
## /root/AudioManager를 런타임 조회 + has_method 가드로 부르므로, 이 오토로드가 없어도
## 안전하게 무시된다. 여기의 어떤 메서드도 시뮬레이션 상태를 조회하거나 변경하지 않는다.
##
## 버스: Master 아래 BGM/SFX 버스를 코드로 생성한다. BGM은 AudioStreamWAV의 loop_mode를
## 런타임에 LOOP_FORWARD로 강제(import 메타데이터 비의존). SFX는 라운드로빈 폴리포니 풀로
## 재생한다. 재봉틀 틱은 속도(0..1)에 비례해 재생 간격/피치를 바꾸는 표현 전용 루프다.

const BUS_MASTER: String = "Master"
const BUS_BGM: String = "BGM"
const BUS_SFX: String = "SFX"

const AUDIO_DIR: String = "res://assets/audio/"
const BGM_FILE: String = "bgm_main.wav"
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

var _bgm_stream: AudioStream = null
var _sfx_streams: Dictionary = {}
var _bgm_player: AudioStreamPlayer = null
var _tick_player: AudioStreamPlayer = null
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_next: int = 0

var _prev_stage: int = 1
var _tick_norm: float = 0.0
var _tick_accum: float = 0.0
var _tick_zero_t: float = 0.0
var _last_logged_norm: float = -1.0
var _debug: bool = false


func _ready() -> void:
	_debug = (
		OS.get_environment("OVERLOCK_AUDIO_LOG") != ""
		or "--audio-log" in OS.get_cmdline_user_args()
	)
	_ensure_buses()
	_load_streams()
	_build_players()
	_log("ready (buses+players initialised)")


func _exit_tree() -> void:
	# 트리 이탈(앱 종료 등) 시 재생 중인 보이스를 정리해 AudioServer 재생 핸들을 해제한다.
	_stop_all_voices()


func _process(delta: float) -> void:
	# 재봉틀 틱 루프: 매 프레임 rate만 반영, 재생 자체는 여기서 스케줄한다.
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


func play_bgm(loop_id: String) -> void:
	if _bgm_player == null or _bgm_stream == null:
		return
	if not _bgm_player.playing:
		_bgm_player.play()
	_log("play_bgm(%s)" % loop_id)


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


func _load_streams() -> void:
	var bgm_path: String = AUDIO_DIR + BGM_FILE
	if ResourceLoader.exists(bgm_path):
		_bgm_stream = load(bgm_path)
		# 루프는 import 메타데이터가 아니라 런타임에서 강제한다(README/§7 지침).
		if _bgm_stream is AudioStreamWAV:
			var wav: AudioStreamWAV = _bgm_stream as AudioStreamWAV
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			# 루프 비활성으로 임포트된 리소스는 loop_end=0이라 loop_mode만 켜면 빈
			# 루프 구간이 되어 재생이 즉시 끝난다. 런타임 경로에선 전체 샘플을 명시한다.
			wav.loop_begin = 0
			wav.loop_end = int(round(wav.get_length() * wav.mix_rate))
	for key in SFX_FILES:
		var path: String = AUDIO_DIR + String(SFX_FILES[key])
		if ResourceLoader.exists(path):
			_sfx_streams[key] = load(path)


func _build_players() -> void:
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.bus = BUS_BGM
	_bgm_player.stream = _bgm_stream
	add_child(_bgm_player)

	_tick_player = AudioStreamPlayer.new()
	_tick_player.bus = BUS_SFX
	if _sfx_streams.has("tick"):
		_tick_player.stream = _sfx_streams["tick"]
	add_child(_tick_player)

	for i in range(SFX_VOICES):
		var voice: AudioStreamPlayer = AudioStreamPlayer.new()
		voice.bus = BUS_SFX
		add_child(voice)
		_sfx_pool.append(voice)


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
