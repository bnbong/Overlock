extends Node
## 온라인 리더보드 클라이언트 오토로드 (기획서 §13/§14, 아키텍처 §11 확장 지점).
##
## HTTPRequest 기반 비동기 통신으로 기록 제출·리더보드 조회·헬스체크를 수행한다.
## 결과는 항상 시그널로만 통지하고, 오프라인/서버 없음/타임아웃은 조용히 실패한다
## (크래시·행 없음). 물리 루프·시뮬레이션과 완전히 분리되어 있으며 게임 값·판정에
## 관여하지 않는다.
##
## 설정은 user://settings.json에서 로드/저장한다(SettingsStore 역할 내장). 닉네임만 UI에서
## 관리하고, 서버 URL은 UI에서 제거했다 — 데스크톱 기본값은 DEFAULT_BASE_URL(디버그는
## DEV_BASE_URL)이며, 셀프호스팅/개발은 settings.json에 base_url을 수동으로 적어 우선시킨다.
## 웹 export에서는 사용자가 URL을 지정하지 않았으면(기본값 그대로/빈 값) 현재 페이지
## origin(window.location.origin)이 신뢰 오리진(*.bnbong.com·localhost·127.0.0.1)일 때만
## 자동으로 base URL로 사용한다(게임·API 동일 도메인 배포 전제). itch.io(*.itch.zone) 등
## 그 외 오리진에서는 same-origin 호출이 게임 호스트로 가서 실패하므로 DEFAULT_BASE_URL로
## 폴백한다. 데스크톱 경로와 사용자가 명시한 URL은 이 분기의 영향을 받지 않는다.
##
## 서버 계약(POST /api/runs, GET /api/leaderboard, GET /api/health)은 §13.3 스키마를
## 따른다. RunStats.finalize 결과 dict는 이미 대부분 필드가 정합하며, 여기서
## player_name·game_version·track_checksum만 보강해 매핑한다.
##
## 호출 규약: 결과 시그널에 먼저 connect한 뒤 메서드를 호출한다. 오프라인·닉네임 없음
## 같은 가드 실패는 메서드 호출 중 동기적으로 시그널을 방출하므로, "호출 후 await" 패턴은
## 그 경우를 놓친다(UI는 모두 connect-먼저-후-호출로 안전하다).

signal submit_completed(success: bool, rank: int, status: String, message: String)
signal leaderboard_fetched(success: bool, entries: Array, message: String)
signal health_checked(ok: bool, message: String)

const GAME_VERSION: String = "1.0.1"  # §13.3 game_version. 시뮬 수학 변경(조향 expo) 반영 범프.
# 릴리스 기본 서버(프로덕션). UI에서 서버 URL 입력을 제거했으므로 이 상수가 데스크톱 기본값.
# 웹 export는 _resolve_base_url이 이 값을 "기본값(미지정)" 신호로 보고, origin이 신뢰 오리진이면
# 현재 페이지 origin으로 대체한다(그 외 오리진은 이 값으로 폴백 — _resolve_base_url 주석 참고).
const DEFAULT_BASE_URL: String = "https://overlock.bnbong.com"
# 디버그 빌드(에디터/디버그 데스크톱) 전용 기본값. 개발자가 settings.json을 만지지 않고 로컬
# 서버로 붙게 한다. 웹 빌드는 디버그여도 DEFAULT_BASE_URL을 써서 same-origin 대체가 항상 동작한다.
const DEV_BASE_URL: String = "http://localhost:8000"
const SETTINGS_PATH: String = "user://settings.json"
const REQUEST_TIMEOUT: float = 5.0  # 초. 오프라인/무응답 서버에서 조용히 실패시키는 상한.
const NICKNAME_MAX: int = 16
const OFFICIAL_DIR: String = "res://tracks/official/"
const CUSTOM_PREFIX: String = "custom_"  # TrackLoader와 동일 네임스페이스. 제출/조회 제외 판별용.

# 볼륨 기본값(선형 0..1, 하위 호환: settings.json에 키 없으면 이 값). 마스터/효과음은 최대.
const DEFAULT_VOLUME_MASTER: float = 1.0
const DEFAULT_VOLUME_SFX: float = 1.0
# BGM 기본은 AudioManager 버스 기본(-6dB = AudioManager.DEFAULT_BGM_DB)에 상응하는 선형값으로
# 맞춰, 볼륨 API 도입 전후 BGM 체감을 동일하게 유지한다. const에서 db_to_linear() 호출이 불가하여
# 환산값(10^(-6/20) ≈ 0.5012)을 고정한다 — AudioManager.DEFAULT_BGM_DB를 바꾸면 함께 갱신할 것.
const DEFAULT_VOLUME_BGM: float = 0.5011872336272722

# 조향 감도(부드러움) = Tuning.steer_expo. 슬라이더가 이 범위로 구동하고 settings.json에 영속한다.
# 볼륨과 동형으로 취급: 여기가 영속·클램프 소유자이고, 시작 시/변경 시 Tuning.steer_expo에 주입한다.
const STEER_EXPO_MIN: float = 0.25
const STEER_EXPO_MAX: float = 0.65
const DEFAULT_STEER_EXPO: float = 0.55  # v1.0.1 국소화 곡선 기본값(Tuning.gd·tuning.json과 정합).

# 설정(user://settings.json 미러). 비어 있는 base_url = 온라인 비활성.
var base_url: String = DEFAULT_BASE_URL
var nickname: String = ""
# 제출 성공 시 서버가 돌려준 트랙별 순위 캐시("track|difficulty" -> rank). "제출 시점 순위"라
# 리더보드 하단 "내 기록" 행에 참고 표기한다. settings.json에 함께 영속(하위 호환: 키 없으면 빈 dict).
var submitted_ranks: Dictionary = {}
# 세션 내 서버 연결 상태(health_check 결과). health_known=false면 아직 확인 전(낙관적 허용).
var server_reachable: bool = false
var health_known: bool = false
# 오프라인 안내 토스트를 세션당 1회만 띄우기 위한 플래그(메뉴 재방문마다 반복 금지).
var offline_notice_shown: bool = false

# 리더보드 조회 화면으로 넘길 대상(메인 메뉴 선택 → Leaderboard 씬). 오토로드가 영속이라
# 씬 전환 사이 상태 버스로 쓴다(GameState.track_id는 런 전용이라 여기서 분리 보관).
var view_track_id: String = ""
var view_difficulty: String = "normal"
var view_track_name: String = ""

# 맵 선택 화면 재진입 시 복원할 마지막 선택 트랙 id(user://settings.json에 함께 저장).
var last_track_id: String = ""

# 볼륨 설정(선형 0..1) — settings.json 미러. AudioManager가 시작 시 읽어 버스에 적용하고,
# 설정 화면이 변경 시 save_volumes로 영속한다(버스 적용은 AudioManager 담당).
var volume_master: float = DEFAULT_VOLUME_MASTER
var volume_bgm: float = DEFAULT_VOLUME_BGM
var volume_sfx: float = DEFAULT_VOLUME_SFX

# 조향 감도(부드러움) 미러(= Tuning.steer_expo). 시작 시 Tuning에 주입하고, 설정 화면이
# save_steer_expo로 영속한다(볼륨과 동형 — 클램프·저장 소유자).
var steer_expo: float = DEFAULT_STEER_EXPO

# settings.json에 사용자가 수동으로 적은 셀프호스팅/개발용 base_url이 있으면 true. 이 경우에만
# base_url을 다시 settings.json에 기록해 보존한다(기본값은 코드에서 결정 — 향후 기본 변경 자동 반영).
var _base_url_manual: bool = false

# 웹 export의 현재 페이지 origin 캐시(예: https://overlock.bnbong.com). 세션 내 불변이라
# 첫 조회 후 재사용한다. 데스크톱에서는 항상 빈 문자열이며 JavaScriptBridge를 건드리지 않는다.
var _web_origin_cache: String = ""
var _web_origin_resolved: bool = false


func _ready() -> void:
	_load_settings()
	# 저장된 조향 감도(부드러움)를 Tuning에 주입한다(볼륨 주입과 동일 타이밍 패턴). Tuning은
	# 앞선 오토로드라 이 시점에 준비돼 있다 — 설정 화면·게임플레이가 이후 이 값을 그대로 쓴다.
	if is_instance_valid(Tuning):
		Tuning.steer_expo = steer_expo


# --- 설정(SettingsStore) API ---


## 실질 base URL(웹 origin 폴백 포함)이 비어 있지 않으면 온라인 기능 활성(true).
func is_online_enabled() -> bool:
	return not _effective_base_url().is_empty()


## 닉네임이 1~16자로 설정돼 있으면 true(제출 가능 조건).
func has_nickname() -> bool:
	var trimmed: String = nickname.strip_edges()
	return trimmed.length() >= 1 and trimmed.length() <= NICKNAME_MAX


## 닉네임을 갱신하고 user://settings.json에 저장한다(서버 URL은 UI에서 제거됨 — 건드리지
## 않는다). 저장 성공 시 true. 최초 실행 모달·타이틀 태그·설정 화면이 공유한다.
func save_nickname(new_nickname: String) -> bool:
	nickname = new_nickname.strip_edges()
	return _write_settings()


## 볼륨 설정(선형 0..1)을 갱신하고 settings.json에 영속한다(0..1로 클램프). 저장 성공 시 true.
## 설정 화면의 슬라이더 조작 종료/저장에서 호출한다. 버스 적용은 AudioManager가 담당한다.
func save_volumes(master: float, bgm: float, sfx: float) -> bool:
	volume_master = clampf(master, 0.0, 1.0)
	volume_bgm = clampf(bgm, 0.0, 1.0)
	volume_sfx = clampf(sfx, 0.0, 1.0)
	return _write_settings()


## 조향 감도(부드러움) = Tuning.steer_expo를 갱신하고 settings.json에 영속한다([0.25,0.65]로
## 클램프). Tuning에도 즉시 반영해 저장 직후부터 새 값이 적용되게 한다. 저장 성공 시 true.
func save_steer_expo(expo: float) -> bool:
	steer_expo = clampf(expo, STEER_EXPO_MIN, STEER_EXPO_MAX)
	if is_instance_valid(Tuning):
		Tuning.steer_expo = steer_expo
	return _write_settings()


## 맵 선택 화면에서 마지막으로 고른 트랙 id를 settings.json에 기록한다(재진입 복원용).
func remember_last_track(track_id: String) -> void:
	last_track_id = track_id
	_write_settings()


## 제출 성공 시 서버가 돌려준 순위를 트랙·난이도별로 캐시하고 영속한다("제출 시점 순위").
func _cache_submitted_rank(track_id: String, difficulty: String, rank: int) -> void:
	if rank <= 0:
		return
	submitted_ranks[track_id + "|" + difficulty] = rank
	_write_settings()


## 캐시된 "제출 시점 순위"(없으면 -1).
func submitted_rank(track_id: String, difficulty: String) -> int:
	return int(submitted_ranks.get(track_id + "|" + difficulty, -1))


## settings.json 직렬화 dict. base_url은 사용자가 수동 지정했을 때만 포함(기본값은 코드가
## 결정). submitted_ranks는 비어 있지 않을 때만 포함(하위 호환).
func _settings_dict() -> Dictionary:
	var d: Dictionary = {
		"nickname": nickname,
		"last_track_id": last_track_id,
		"volume_master": volume_master,
		"volume_bgm": volume_bgm,
		"volume_sfx": volume_sfx,
		"steer_expo": steer_expo,
	}
	if _base_url_manual:
		d["base_url"] = base_url
	if not submitted_ranks.is_empty():
		d["submitted_ranks"] = submitted_ranks
	return d


## user://settings.json 저장(단일 경로). 성공 시 true.
func _write_settings() -> bool:
	var file: FileAccess = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		push_error("LeaderboardClient: 설정 저장 실패 " + SETTINGS_PATH)
		return false
	file.store_string(JSON.stringify(_settings_dict()))
	file.close()
	return true


## 리더보드 조회 대상(메인 메뉴에서 선택한 트랙)을 보관한다.
func set_view_target(track_id: String, difficulty: String, track_name: String) -> void:
	view_track_id = track_id
	view_difficulty = difficulty
	view_track_name = track_name


# --- 체크섬 (§13.3 track_checksum) ---


## 공식 트랙 JSON 파일 바이트의 SHA-256("sha256:" 접두). 커스텀 트랙은 제출 대상이
## 아니므로 공식 경로만 대상으로 한다. 서버는 동일 파일 바이트로 동일 값을 재현해야 한다.
func track_checksum(track_id: String) -> String:
	if track_id.begins_with(CUSTOM_PREFIX):
		return ""
	var path: String = OFFICIAL_DIR + track_id + ".json"
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return "sha256:" + ctx.finish().hex_encode()


# --- 비동기 API (결과는 시그널로 통지) ---


## 결과 dict를 §13.3 스키마로 매핑해 POST /api/runs. 결과는 submit_completed로 통지.
## 오프라인·닉네임 없음·연결 실패·서버 거부 모두 success=false로 조용히 통지한다.
func submit_run(result: Dictionary) -> void:
	if not is_online_enabled():
		submit_completed.emit(false, -1, "", "오프라인 (서버 URL 미설정)")
		return
	if not has_nickname():
		submit_completed.emit(false, -1, "", "닉네임을 먼저 설정하세요")
		return
	var body: String = JSON.stringify(_build_submit_body(result))
	var resp: Dictionary = await _request(HTTPClient.METHOD_POST, _base() + "/api/runs", body)
	if not bool(resp["ok"]):
		submit_completed.emit(false, -1, "", _friendly_reason(resp))
		return
	var code: int = int(resp["code"])
	if code < 200 or code >= 300:
		submit_completed.emit(false, -1, "", _submit_error_message(code))
		return
	var data: Variant = JSON.parse_string(str(resp["body"]))
	var rank: int = -1
	var status: String = ""
	if data is Dictionary:
		rank = int((data as Dictionary).get("rank", -1))
		status = str((data as Dictionary).get("verification_status", ""))
	_cache_submitted_rank(str(result.get("track_id", "")), str(result.get("difficulty", "")), rank)
	submit_completed.emit(true, rank, status, "")


## GET /api/leaderboard?track_id=&difficulty=&limit=. 결과는 leaderboard_fetched로 통지.
## 응답 최상위 구조가 달라도 관대하게 파싱한다(_extract_entries).
func fetch_leaderboard(track_id: String, difficulty: String, limit: int = 100) -> void:
	if not is_online_enabled():
		leaderboard_fetched.emit(false, [], "오프라인 (서버 URL 미설정)")
		return
	var url: String = (
		"%s/api/leaderboard?track_id=%s&difficulty=%s&limit=%d"
		% [_base(), track_id.uri_encode(), difficulty.uri_encode(), limit]
	)
	var resp: Dictionary = await _request(HTTPClient.METHOD_GET, url, "")
	if not bool(resp["ok"]):
		leaderboard_fetched.emit(false, [], _friendly_reason(resp))
		return
	var code: int = int(resp["code"])
	if code < 200 or code >= 300:
		var msg: String = "트랙을 찾을 수 없음" if code == 404 else "서버 오류 (HTTP %d)" % code
		leaderboard_fetched.emit(false, [], msg)
		return
	var data: Variant = JSON.parse_string(str(resp["body"]))
	leaderboard_fetched.emit(true, _extract_entries(data), "")


## GET /api/health → {status, version}. 결과는 health_checked로 통지(서버 연결 확인용).
## 성공 시 message에 서버 버전을 담아 UI가 표시할 수 있게 한다.
func health_check() -> void:
	if not is_online_enabled():
		_set_health(false)
		health_checked.emit(false, "오프라인 (서버 URL 미설정)")
		return
	var resp: Dictionary = await _request(HTTPClient.METHOD_GET, _base() + "/api/health", "")
	var ok: bool = bool(resp["ok"]) and int(resp["code"]) >= 200 and int(resp["code"]) < 300
	if not ok:
		_set_health(false)
		health_checked.emit(false, _friendly_reason(resp))
		return
	var version: String = ""
	var data: Variant = JSON.parse_string(str(resp["body"]))
	if data is Dictionary and (data as Dictionary).has("version"):
		version = str((data as Dictionary)["version"])
	_set_health(true)
	health_checked.emit(true, version)


## health_check 결과를 세션 상태로 반영한다(온라인 표시·오프라인 게이팅·토스트 판정용).
func _set_health(ok: bool) -> void:
	server_reachable = ok
	health_known = true


# --- 내부 구현 ---


## 요청마다 새 HTTPRequest 자식을 만들어 동시 요청 충돌을 피한다. await로 완료를
## 기다린 뒤 노드를 정리하고 {ok, code, result, body}를 반환한다.
func _request(method: int, url: String, body: String) -> Dictionary:
	var http: HTTPRequest = HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT
	# 웹 export 회피책: 브라우저는 gzip/deflate 응답을 이미 해제해 평문 본문을 넘기면서도
	# Content-Encoding 헤더는 그대로 노출한다. Godot HTTPRequest(accept_gzip 기본 true)는
	# 그 헤더를 보고 본문을 다시 해제하려다 실패해(RESULT_BODY_DECOMPRESS_FAILED) 200 OK를
	# 연결 실패로 처리한다. 웹에선 브라우저가 압축 해제를 전담하므로 재해제를 끈다
	# (요청 압축 협상은 브라우저 몫이라 대역폭 손해 없음). 데스크톱 네이티브 경로는 불변.
	if OS.has_feature("web"):
		http.accept_gzip = false
	add_child(http)
	var headers: PackedStringArray = PackedStringArray(
		["Content-Type: application/json", "Accept: application/json"]
	)
	var err: int = http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": 0, "result": -1, "body": ""}
	var res: Array = await http.request_completed
	http.queue_free()
	var result_code: int = int(res[0])
	var response_code: int = int(res[1])
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": response_code, "result": result_code, "body": ""}
	var body_bytes: PackedByteArray = res[3]
	return {
		"ok": true,
		"code": response_code,
		"result": result_code,
		"body": body_bytes.get_string_from_utf8(),
	}


## 결과 dict → §13.3 POST /api/runs 바디. replay_hash는 지금 생략(§14.2 Unverified 운영).
func _build_submit_body(result: Dictionary) -> Dictionary:
	var track_id: String = str(result.get("track_id", ""))
	return {
		"player_name": nickname.strip_edges(),
		"track_id": track_id,
		"difficulty": str(result.get("difficulty", "")),
		"time_ms": int(result.get("finish_ms", 0)),
		"penalty_ms": int(result.get("penalty_ms", 0)),
		"final_time_ms": int(result.get("final_time_ms", 0)),
		"accuracy": float(result.get("accuracy", 0.0)),
		"cuts": int(result.get("cuts", 0)),
		"off_seam_ms": int(result.get("off_seam_ms", 0)),
		"game_version": GAME_VERSION,
		"track_checksum": track_checksum(track_id),
	}


## 응답 최상위 구조가 달라도 entries 배열을 관대하게 추출한다.
func _extract_entries(data: Variant) -> Array:
	if data is Array:
		return data
	if data is Dictionary:
		var dict: Dictionary = data
		for key in ["entries", "leaderboard", "runs", "results", "data"]:
			if dict.has(key) and dict[key] is Array:
				return dict[key]
	return []


## 트레일링 슬래시를 제거한 정규화 base URL(실질 URL 기준 = 웹 origin 폴백 반영).
func _base() -> String:
	return _effective_base_url().trim_suffix("/")


## 실제 요청에 사용할 base URL. 웹 export에서 사용자가 URL을 지정하지 않았으면(기본값/빈 값)
## 현재 페이지 origin이 신뢰 오리진일 때만 그것을 쓰고, 아니면 DEFAULT_BASE_URL로 폴백한다.
## 사용자가 명시한 URL은 그대로 우선한다. 데스크톱에서는 저장된 base_url을 그대로 반환한다(불변).
func _effective_base_url() -> String:
	return _resolve_base_url(base_url, OS.has_feature("web"), _web_origin())


## _effective_base_url의 순수 결정 로직. 플랫폼·JS 의존을 인자로 분리해 데스크톱에서도
## 웹 분기(is_web=true)를 강제로 태워 단위 검증할 수 있게 한다.
##
## 규칙:
##   1) 사용자가 명시한 URL(빈 값도 DEFAULT_BASE_URL도 아닌 값)은 웹·데스크톱 무관하게 그대로 우선.
##   2) 웹 + URL 미지정(빈 값/기본값): origin이 신뢰 오리진이면 same-origin(origin) 유지,
##      아니면(itch.zone 등) DEFAULT_BASE_URL로 폴백 — same-origin API 호출이 게임 호스트로
##      가서 실패하는 것을 막는다.
##   3) 데스크톱: 저장된 base_url을 그대로 반환(기존 동작 불변).
static func _resolve_base_url(raw: String, is_web: bool, origin: String) -> String:
	var url: String = raw.strip_edges()
	if is_web and (url.is_empty() or url == DEFAULT_BASE_URL):
		if _is_trusted_origin(origin):
			return origin.strip_edges()
		return DEFAULT_BASE_URL
	return url


## 웹 origin이 same-origin API 호출을 신뢰할 수 있는 배포처인지 판정한다(순수 함수).
## 신뢰 = *.bnbong.com 계열(프로덕션·서브도메인) + localhost/127.0.0.1(포트 무관 —
## 로컬 웹 테스트·mock 서버 워크플로우가 same-origin에 의존). 그 외(itch.zone 등)는 false.
static func _is_trusted_origin(origin: String) -> bool:
	var host: String = _origin_host(origin)
	if host.is_empty():
		return false
	if host == "localhost" or host == "127.0.0.1":
		return true
	return host == "bnbong.com" or host.ends_with(".bnbong.com")


## origin 문자열("scheme://host[:port][/path]")에서 호스트만 소문자로 추출한다(순수 함수).
## 판정에 스킴·포트·경로는 쓰지 않는다. 형식이 어긋나면 빈 문자열.
static func _origin_host(origin: String) -> String:
	var s: String = origin.strip_edges().to_lower()
	var scheme_end: int = s.find("://")
	if scheme_end >= 0:
		s = s.substr(scheme_end + 3)
	var slash: int = s.find("/")
	if slash >= 0:
		s = s.substr(0, slash)
	var colon: int = s.find(":")
	if colon >= 0:
		s = s.substr(0, colon)
	return s


## 웹 export의 현재 페이지 origin을 반환한다(데스크톱에서는 "" — JavaScriptBridge 미접촉).
## 세션 내 불변이므로 첫 조회 결과를 캐시한다.
func _web_origin() -> String:
	if not OS.has_feature("web"):
		return ""
	if _web_origin_resolved:
		return _web_origin_cache
	_web_origin_resolved = true
	var origin: Variant = JavaScriptBridge.eval("window.location.origin")
	if origin is String:
		_web_origin_cache = (origin as String).strip_edges()
	return _web_origin_cache


## POST /api/runs 비정상 응답 코드를 사용자 표시 문구로 구분한다(서버 계약: 422 거부,
## 429 레이트리밋, 404 미등록 트랙).
func _submit_error_message(code: int) -> String:
	match code:
		422:
			return "기록이 거부됨 (검증 실패)"
		429:
			return "요청이 너무 잦습니다 (잠시 후 재시도)"
		404:
			return "트랙을 찾을 수 없음"
	if code >= 500:
		return "서버 오류 (HTTP %d)" % code
	return "서버가 기록을 거부함 (HTTP %d)" % code


## HTTPRequest 실패 결과를 한 줄 사유 문자열로 변환한다.
func _friendly_reason(resp: Dictionary) -> String:
	var result_code: int = int(resp.get("result", -1))
	match result_code:
		HTTPRequest.RESULT_TIMEOUT:
			return "서버 응답 없음 (타임아웃)"
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "서버에 연결할 수 없음"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "서버에 연결할 수 없음"
	var code: int = int(resp.get("code", 0))
	if code >= 400:
		return "서버 오류 (HTTP %d)" % code
	return "연결 실패"


func _load_settings() -> void:
	base_url = _default_base_url()
	_base_url_manual = false
	nickname = ""
	last_track_id = ""
	submitted_ranks = {}
	volume_master = DEFAULT_VOLUME_MASTER
	volume_bgm = DEFAULT_VOLUME_BGM
	volume_sfx = DEFAULT_VOLUME_SFX
	steer_expo = DEFAULT_STEER_EXPO
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var file: FileAccess = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	var dict: Dictionary = parsed
	# 서버 URL은 UI에서 제거됐다. settings.json에 사용자가 "수동으로" 적은 셀프호스팅/개발용
	# URL만 우선한다. 과거 프리필로 저장된 기본값(localhost/프로덕션)·빈 값은 무시하고 코드
	# 기본값(_default_base_url)을 써서, 기본 서버가 바뀌어도 자동 반영되게 한다.
	if dict.has("base_url"):
		var stored: String = str(dict["base_url"]).strip_edges()
		if not stored.is_empty() and stored != DEV_BASE_URL and stored != DEFAULT_BASE_URL:
			base_url = stored
			_base_url_manual = true
	if dict.has("nickname"):
		nickname = str(dict["nickname"])
	if dict.has("last_track_id"):
		last_track_id = str(dict["last_track_id"])
	if dict.has("submitted_ranks") and dict["submitted_ranks"] is Dictionary:
		var raw: Dictionary = dict["submitted_ranks"]
		for k in raw:
			submitted_ranks[str(k)] = int(raw[k])
	volume_master = _read_volume(dict, "volume_master", DEFAULT_VOLUME_MASTER)
	volume_bgm = _read_volume(dict, "volume_bgm", DEFAULT_VOLUME_BGM)
	volume_sfx = _read_volume(dict, "volume_sfx", DEFAULT_VOLUME_SFX)
	steer_expo = _read_steer_expo(dict)


## settings.json에서 선형 볼륨 키를 읽어 0..1로 클램프한다(키 없음/비수치 → 기본값 유지).
func _read_volume(dict: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = dict.get(key, fallback)
	if v is float or v is int:
		return clampf(float(v), 0.0, 1.0)
	return fallback


## settings.json에서 조향 감도(부드러움)를 읽어 [STEER_EXPO_MIN,MAX]로 클램프한다(키 없음/비수치
## → 기본값). 하위 호환: 이 키가 없던 저장본은 기본값(DEFAULT_STEER_EXPO)을 쓴다.
func _read_steer_expo(dict: Dictionary) -> float:
	var v: Variant = dict.get("steer_expo", DEFAULT_STEER_EXPO)
	if v is float or v is int:
		return clampf(float(v), STEER_EXPO_MIN, STEER_EXPO_MAX)
	return DEFAULT_STEER_EXPO


## 플랫폼별 기본 base URL. 디버그 데스크톱은 로컬 서버, 그 외(릴리스·웹)는 프로덕션.
## 웹은 디버그여도 프로덕션 기본을 써야 _resolve_base_url의 same-origin 대체가 동작한다.
func _default_base_url() -> String:
	if OS.is_debug_build() and not OS.has_feature("web"):
		return DEV_BASE_URL
	return DEFAULT_BASE_URL
