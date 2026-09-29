#!/usr/bin/env bash
# 홍보 촬영 실행기. prepare_copy.sh 로 만든 사본에서 PromoDriver 시나리오를 실행한다.
# 실행 전마다 사본의 격리 설정을 확인하고, 격리 user dir 의 settings.json/records.json 을 초기화한다.
#
# usage: run_capture.sh <heart|tee|star> <movie|stills|headless> <출력 디렉터리> [WxH] [사본 상위]
#   movie    : Godot Movie Maker(--write-movie <출력>/movie/f.avi, MJPEG 화질 1.0, 60fps 고정)로 녹화
#              (MOVIE_EXT=png 이면 PNG 시퀀스지만 1080p에서 초당 1프레임 정도로 매우 느리다)
#   stills   : --stills 로 HUD 있는/없는 스틸 PNG만 저장(--fixed-fps 60, 녹화 없음)
#   headless : 렌더 없이 빠르게 주행만(자동 조향 품질·등급 점검용)
# 창이 다른 창에 가려지면 macOS 가 그리기를 멈추므로 항상 위에 띄우고 화면 잠자기를 막는다.
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN="${1:?scenario}"
MODE="${2:?mode}"
OUT="${3:?out dir}"
RES="${4:-1920x1080}"
BASE="${5:-/Users/bnbong/.claude/jobs/1a61bd74/tmp/worker-v1}"
PROJ="$BASE/game"
UD_NAME="${PROMO_USER_DIR:-overlock_promo_capture_v1}"
UDIR="$HOME/Library/Application Support/$UD_NAME"

"$HERE/check_isolation.sh" "$PROJ"
# 창 크기 오버라이드(촬영 해상도). Movie Maker 는 시작 시점의 창 크기로 녹화하므로 --resolution 대신
# 사본 project.godot [display] 의 window_width/height_override 로 처음부터 그 크기로 띄운다.
W="${RES%x*}"
H="${RES#*x}"
awk -v w="$W" -v h="$H" '
	{
		line = $0
		cr = ""
		if (sub(/\r$/, "", line)) cr = "\r"
	}
	line ~ /^window\/size\/window_(width|height)_override=/ { next }
	line == "[editor]" || line ~ /^movie_writer\/video_quality=/ { next }
	{ print; last_cr = cr }
	line == "[display]" {
		print "window/size/window_width_override=" w cr
		print "window/size/window_height_override=" h cr
	}
	END {
		# Movie Maker AVI(MJPEG) 화질을 최대로(기본 0.75).
		print "[editor]" last_cr
		print "movie_writer/video_quality=1.0" last_cr
	}
' "$PROJ/project.godot" > "$PROJ/project.godot.new"
mv "$PROJ/project.godot.new" "$PROJ/project.godot"
"$HERE/check_isolation.sh" "$PROJ"
cp "$HERE/PromoDriver.gd" "$HERE/PromoRead.gd" "$HERE/TrackProbe.gd" "$PROJ/promo_driver/"
mkdir -p "$OUT" "$UDIR"
rm -f "$UDIR/records.json"
printf '%s\n' \
	'{"base_url":"http://127.0.0.1:9","nickname":"Stitcher","tutorial_seen":true,"last_track_id":"cotton_01","volume_master":0.0}' \
	> "$UDIR/settings.json"

set +e
case "$MODE" in
	movie)
		mkdir -p "$OUT/movie"
		caffeinate -d -i "$GODOT" --path "$PROJ" --resolution "$RES" --position 0,0 --always-on-top \
			--write-movie "$OUT/movie/f.${MOVIE_EXT:-avi}" --fixed-fps 60 \
			-- --out="$OUT" --scenario="$SCEN" > "$OUT/console.log" 2>&1
		;;
	stills)
		rm -rf "$OUT/stills"
		caffeinate -d -i "$GODOT" --path "$PROJ" --resolution "$RES" --position 0,0 --always-on-top \
			--fixed-fps 60 -- --out="$OUT" --scenario="$SCEN" --stills > "$OUT/console.log" 2>&1
		;;
	headless)
		"$GODOT" --headless --path "$PROJ" --fixed-fps 60 \
			-- --out="$OUT" --scenario="$SCEN" > "$OUT/console.log" 2>&1
		;;
	*)
		echo "unknown mode $MODE" >&2
		exit 2
		;;
esac
code=$?
set -e
echo "godot exit=$code"
grep -E '"ev":"(finish|timeout|done|unknown_scenario)"' "$OUT/events.jsonl" || true
exit $code
