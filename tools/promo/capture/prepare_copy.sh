#!/usr/bin/env bash
# 홍보 촬영용 게임 사본을 만든다. 저장소 game/은 읽기만 하고, 사본 project.godot에만
# 격리 user dir(overlock_promo_capture_v1)과 PromoDriver autoload를 추가한다.
# 격리 user dir의 settings.json은 닿지 않는 base_url(127.0.0.1:9)·무음·닉네임 Stitcher·
# 튜토리얼 본 상태로 초기화하고 records.json은 지운다(리더보드 서버로 기록이 나가지 않는다).
#
# usage: prepare_copy.sh <사본 상위 디렉터리>
#   결과: <상위>/game (Godot 프로젝트 사본)
# 환경변수: GAME_DIR(기본: 저장소 game/), GODOT, PROMO_USER_DIR(기본 overlock_promo_capture_v1)
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GAME_DIR="${GAME_DIR:-$REPO/game}"
BASE="${1:?사본 상위 디렉터리}"
UD_NAME="${PROMO_USER_DIR:-overlock_promo_capture_v1}"
UDIR="$HOME/Library/Application Support/$UD_NAME"
PROJ="$BASE/game"

mkdir -p "$PROJ"
rsync -a --delete --exclude='.godot' --exclude='promo_driver' "$GAME_DIR/" "$PROJ/"

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
		print "PromoDriver=\"*res://promo_driver/PromoDriver.gd\"" cr
		ad = 1
	}
	END { if (!app || !ad) exit 1 }
' "$PROJ/project.godot" > "$PROJ/project.godot.new" || {
	echo "project.godot 수정 실패([application] 또는 OrientationGuard autoload 없음)" >&2
	exit 2
}
mv "$PROJ/project.godot.new" "$PROJ/project.godot"
mkdir -p "$PROJ/promo_driver"
cp "$HERE/PromoDriver.gd" "$HERE/PromoRead.gd" "$HERE/TrackProbe.gd" "$PROJ/promo_driver/"

"$HERE/check_isolation.sh" "$PROJ"

mkdir -p "$UDIR"
reset_user_dir() {
	rm -f "$UDIR/records.json"
	printf '%s\n' \
		'{"base_url":"http://127.0.0.1:9","nickname":"Stitcher","tutorial_seen":true,"last_track_id":"cotton_01","volume_master":0.0}' \
		> "$UDIR/settings.json"
}
reset_user_dir

"$GODOT" --headless --path "$PROJ" --import > "$BASE/import.log" 2>&1 || true
echo "prepared $PROJ (user dir: $UDIR)"
