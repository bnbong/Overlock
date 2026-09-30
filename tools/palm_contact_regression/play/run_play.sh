#!/usr/bin/env bash
# 실제 입력 플레이 검증 실행기(비-headless 렌더 창).
# 저장소 game/(또는 GAME_DIR)을 임시 사본으로 복사하고, 사본 project.godot 에만 격리 user dir 과
# PlayDriver autoload 를 추가해 실행한다. 저장소와 실제 사용자 기록
# (~/Library/Application Support/Godot/app_userdata/Overlock/)은 건드리지 않는다.
# 격리 user dir 의 settings.json 은 닿지 않는 base_url(127.0.0.1:9)과 무음으로 초기화해
# 리더보드 서버로 기록이 나가지 않게 한다(드라이버는 결과 화면의 제출 버튼을 누르지 않는다).
#
# usage: run_play.sh <full|mobile|scold|cutdlg|cutdlg_mobile|cutdlg_lowfps|cutdlg_band|cutdlg_finish|
#        inject|inject_cut> <새 출력 디렉터리>
#        [WxH] [--touch-controls]
# 실행 중 게임 창이 가려지거나 최소화되면 그리기가 멈춰 캡처가 늦게 찍힌다. events.txt 의
# "WARNING capture ... delayed" 줄이 있으면 그 캡처는 무효이므로 창을 보이게 두고 다시 실행한다.
#   full   : 메뉴 → 트랙 선택(tee_01) → 튜토리얼 → 카운트다운 → 가감속 → 좌우 조향 → 드리프트
#            → 일시정지/복귀 → 재시작 → 2회차 완주 → 결과 (키·마우스 이벤트 주입)
#   mobile : --touch-controls 와 함께. 터치(InputEventScreenTouch)로 출발·조향·드리프트·일시정지
#   scold  : 엄마 찬스(일반 토스트) → 트랙 이탈 강제 복귀 2회 연속(엄마 꾸중 말풍선) → 골무(일반 토스트).
#            --touch-controls 를 주면 터치로 조작한다(ScoldPlay.gd, 결과 화면·기록 제출 없음)
#   cutdlg : 부상 대사 말풍선 통합 플레이(CutDialoguePlay.gd). 급반전 부상 여러 번(연속 프레임), 엄마 찬스·
#            엄마 꾸중 표시 중 부상(선점), 골무 중 급반전, 사전 연출 중 일시정지, 연속 부상, pending 중 재시작,
#            2회차 완주 직전 부상 시도 → 결과. cutdlg_mobile 은 --touch-controls 와 함께 터치로 부상·강제 복귀,
#            cutdlg_lowfps 는 LOW_FPS=15 로 렌더 15fps(물리 4틱당 렌더 1회)에서 부상 1회. cutdlg_band 는 부상
#            6회 연속, cutdlg_finish 는 완주 직전 급반전(--finish-back=N).
#   inject_cut : 부상 대사 상태 주입 보조 캡처(CutDialogueInject.gd, 실제 플레이 아님, inject_ 캡처)
#   inject : 상태 주입 보조 검사(실제 플레이 아님, inject_ 캡처)
#   full 은 1회차 사선 직선(s≈2260)과 2회차 긴 직선(s≈4660)에서 실제 조향 입력으로 트랙 이탈
#   강제 복귀(꿀밤)를 발동한다(조향으로 heading 을 틀고 키를 뗀 채 직진). mobile 도 터치로 1회 발동.
# 환경변수: GODOT, GAME_DIR(기본: 저장소 game/), PALM_REGRESSION_TMP(임시 상위 경로),
#   PALM_PLAY_USER_DIR(격리 user dir 이름, 기본 overlock_palm_play_check),
#   PALM_PLAY_WORK(사본 위치를 고정하고 실행 후 지우지 않음. 비우면 mktemp 후 삭제),
#   LOW_FPS(렌더 고정 FPS, 기본 60. 물리는 항상 60Hz)
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GAME_DIR="${GAME_DIR:-$REPO/game}"
TMP_BASE="${PALM_REGRESSION_TMP:-${TMPDIR:-/tmp}}"
SCEN="${1:?scenario}"
OUT="${2:?out dir}"
RES="${3:-1280x720}"
shift $(($# >= 3 ? 3 : $#))
UD_NAME="${PALM_PLAY_USER_DIR:-overlock_palm_play_check}"
UDIR="$HOME/Library/Application Support/$UD_NAME"

mkdir -p "$TMP_BASE" "$OUT"
if [ -n "${PALM_PLAY_WORK:-}" ]; then
	WORK="$PALM_PLAY_WORK"
	mkdir -p "$WORK"
	rm -rf "$WORK/game"
else
	WORK="$(mktemp -d "$TMP_BASE/palm_play.XXXXXX")"
	trap 'rm -rf "$WORK"' EXIT
fi
PROJ="$WORK/game"
mkdir -p "$PROJ"
(cd "$GAME_DIR" && tar --exclude='./.godot' -cf - .) | (cd "$PROJ" && tar -xf -)

awk -v ud="$UD_NAME" '
	{
		line = $0
		cr = ""
		if (sub(/\r$/, "", line)) cr = "\r"
		print
	}
	line == "[application]" && !app {
		print "config/use_custom_user_dir=true" cr
		print "config/custom_user_dir_name=\"" ud "\"" cr
		app = 1
	}
	line ~ /^OrientationGuard=/ && !ad {
		print "PlayDriver=\"*res://play_driver/PlayDriver.gd\"" cr
		ad = 1
	}
	END { if (!app || !ad) exit 1 }
' "$PROJ/project.godot" > "$PROJ/project.godot.new" || {
	echo "project.godot 수정 실패([application] 또는 OrientationGuard autoload 없음)" >&2
	exit 2
}
mv "$PROJ/project.godot.new" "$PROJ/project.godot"
mkdir -p "$PROJ/play_driver"
cp "$HERE/PlayDriver.gd" "$HERE/PlayRead.gd" "$HERE/ScoldPlay.gd" "$HERE/CutDialoguePlay.gd" \
	"$HERE/CutDialogueInject.gd" "$HERE/CutDialogueInject.tscn" \
	"$HERE/Inject.gd" "$HERE/Inject.tscn" "$PROJ/play_driver/"
# 실행 전 격리 설정 재확인(없으면 실행하지 않는다).
grep -q '^config/use_custom_user_dir=true' "$PROJ/project.godot" &&
	grep -q "^config/custom_user_dir_name=\"$UD_NAME\"" "$PROJ/project.godot" || {
	echo "사본 project.godot 에 격리 user dir 설정이 없습니다" >&2
	exit 2
}

mkdir -p "$UDIR"
rm -f "$UDIR/settings.json" "$UDIR/records.json"
printf '{"base_url":"http://127.0.0.1:9","volume_master":0.0}\n' > "$UDIR/settings.json"

"$GODOT" --headless --path "$PROJ" --import > "$OUT/import.log" 2>&1 || true
set +e
if [ "$SCEN" = "inject_cut" ]; then
	"$GODOT" --path "$PROJ" --resolution "$RES" --fixed-fps 60 res://play_driver/CutDialogueInject.tscn \
		-- --inject-out="$OUT" > "$OUT/console.log" 2>&1
elif [ "$SCEN" = "inject" ]; then
	"$GODOT" --path "$PROJ" --resolution "$RES" --fixed-fps 60 res://play_driver/Inject.tscn \
		-- --inject-out="$OUT" > "$OUT/console.log" 2>&1
else
	# 창이 다른 창에 가려지면 macOS가 그리기를 멈춰 캡처가 빠지므로 항상 위에 띄우고 화면 잠자기를 막는다.
	caffeinate -d -i "$GODOT" --path "$PROJ" --resolution "$RES" --fixed-fps "${LOW_FPS:-60}" --always-on-top \
		-- --out="$OUT" --scenario="$SCEN" "$@" > "$OUT/console.log" 2>&1
fi
code=$?
set -e
grep -E "PLAYDRIVER .*(TIMEOUT|EVENT|DONE|face cut|CUTDLG)|INJECT |INJECTCUT |ERROR" "$OUT/console.log" || true
exit "$code"
