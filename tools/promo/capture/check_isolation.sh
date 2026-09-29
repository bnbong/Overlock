#!/usr/bin/env bash
# Godot 사본을 실행하기 전에 매번 부른다. 사본 project.godot에 격리 user dir 설정이 없으면
# 실행을 막는다(실제 사용자 기록 ~/Library/Application Support/Godot/app_userdata/Overlock 보호).
# usage: check_isolation.sh <사본 game 디렉터리>
set -euo pipefail
PROJ="${1:?사본 game 디렉터리}"
UD_NAME="${PROMO_USER_DIR:-overlock_promo_capture_v1}"
PG="$PROJ/project.godot"
if ! tr -d '\r' < "$PG" | grep -qx 'config/use_custom_user_dir=true'; then
	echo "격리 설정 없음: $PG (use_custom_user_dir)" >&2
	exit 3
fi
if ! tr -d '\r' < "$PG" | grep -qx "config/custom_user_dir_name=\"$UD_NAME\""; then
	echo "격리 설정 없음: $PG (custom_user_dir_name=$UD_NAME)" >&2
	exit 3
fi
ABS="$(cd "$PROJ" && pwd)"
case "$ABS" in
	*/.claude/worktrees/*/game | */programming/overlock/game)
		echo "저장소 game/ 에서 직접 실행 금지: $ABS" >&2
		exit 3
		;;
esac
echo "isolation ok: $PG -> $UD_NAME"
