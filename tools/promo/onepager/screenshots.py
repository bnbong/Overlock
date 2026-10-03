#!/usr/bin/env python3
"""docs/promo/screenshots/ 의 인게임 스크린샷을 홍보 촬영 원본(Movie Maker AVI)에서 다시 뽑는다.

usage: screenshots.py <runs 디렉터리> [출력 디렉터리(기본 docs/promo/screenshots)]

<runs>/m_heart, m_tee, m_star, m_hub 는 tools/promo/capture/run_capture.sh ... movie 결과다.
같은 입력이면 같은 프레임이 나오므로(결정론) SHOTS 표의 Movie Maker 프레임 번호(events.jsonl 의 mf)로
장면을 고른다. 1920x1080 프레임을 Lanczos 로 1280x720 으로 줄여 RGB PNG 로 저장한다.
"""
import os
import subprocess
import sys

FFMPEG = "/opt/homebrew/bin/ffmpeg"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# (파일명, 런, 프레임, 설명)
SHOTS = [
    ("title.png", "m_heart", 600, "메인 메뉴"),
    ("track_kind.png", "m_heart", 760, "Start 뒤 트랙 종류 선택(공식/유저)"),
    ("track_select.png", "m_heart", 1000, "공식 트랙 선택(Cat's Cradle, 데님 견본과 주행 특성 문구)"),
    ("gameplay_fold.png", "m_heart", 3876, "긴 드리프트: 손끝 앞에서 면 원단이 접혀 올라온 주름, 앞에 고스트"),
    ("gameplay_ghost.png", "m_heart", 3480, "개인 고스트: 필드 위 반투명 노루발과 미니맵 마커"),
    ("gameplay_action.png", "m_star", 1100, "실크 원단 별 트랙 꼭짓점 드리프트 주름"),
    ("gameplay_bandage.png", "m_tee", 2530, "부상: 밴드, > < 표정, FINGER CUT!, 대사 말풍선"),
    ("gameplay_items.png", "m_tee", 1000, "엄마 찬스를 ITEM 슬롯에 담은 상태"),
    ("finish_zoomout.png", "m_heart", 2700, "완주 줌아웃과 SEAM GRADE S"),
    ("editor.png", "m_hub", 1420, "트랙 에디터 아이템 배치"),
    ("hub.png", "m_hub", 560, "공유 허브 게시물 상세"),
]


def main():
    runs = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "docs", "promo", "screenshots")
    os.makedirs(out, exist_ok=True)
    for name, run, frame, _ in SHOTS:
        src = os.path.join(runs, run, "movie", "f.avi")
        subprocess.run(
            [FFMPEG, "-v", "error", "-y", "-i", src, "-vf",
             "select=eq(n\\,%d),scale=1280:720:flags=lanczos:in_range=pc:out_range=pc,format=rgb24" % frame,
             "-fps_mode", "passthrough", "-frames:v", "1", os.path.join(out, name)],
            check=True)
        print("wrote", name)


if __name__ == "__main__":
    main()
