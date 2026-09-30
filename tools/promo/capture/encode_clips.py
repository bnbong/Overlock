#!/usr/bin/env python3
"""Movie Maker 원본(AVI, MJPEG)에서 클립을 잘라 편집용 H.264로 인코딩하고 footage.json을 만든다.

usage: encode_clips.py <runs 디렉터리> <footage 출력 디렉터리> [--crf 12] [--only 04_,07_,09_injury]

<runs>/m_heart, m_tee, m_star 에 run_capture.sh ... movie 결과(movie/f.avi, events.jsonl)가 있어야 한다.
클립 구간은 아래 CLIPS 표의 Movie Maker 프레임 번호(= events.jsonl 의 mf)로 정한다. 같은 입력이면
같은 프레임이 나오므로(결정론) 재촬영해도 번호가 그대로 맞는다. 이벤트 시각은 events.jsonl 에서
자동으로 가져오고, 로그에 없는 연출 시각(말풍선 페이드, 얼굴 전환)은 프레임 분석값을 EXTRA 로 둔다.
"""
import argparse
import json
import os
import subprocess

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
FPS = 60

# 화면 좌표는 1920x1080 기준. focus = 편집 줌 기준점(시선이 가는 곳).
FOOT = {"x": 960, "y": 330, "what": "노루발·바늘(화면 중앙 상단), 그 아래로 스티치가 찍힌다"}
FACE = {"x": 960, "y": 170, "what": "상단 얼굴(표정·기울기)"}

# 부상 클립은 사전 연출·부상·말풍선 시각을 인코딩된 클립 프레임에서 직접 측정한 값(markers)으로 적는다.
# events.jsonl 의 같은 사건(mf)도 같은 프레임을 가리키지만(측정값과 일치 확인), 중복을 피하려고 뺀다.
INJURY_SKIP = ["cut_pending_start", "stun_start", "toast_show", "toast_full", "toast_fade", "toast_hidden"]

CLIPS = [
    {
        "file": "01_title.mp4", "run": "m_heart", "start": 300, "end": 668,
        "track": None, "scene": "메인 메뉴. 타이틀 로고, 좌상단 닉네임 태그(Stitcher), 버튼 4개.",
        "focus": {"x": 960, "y": 200, "what": "타이틀 로고"},
        "use": [0.5, 5.9],
        "note": "정지 화면이다. 좌상단 '오프라인' 점은 리더보드 서버를 막아 둔 촬영 환경 탓이다. "
                "오프라인 안내 토스트는 이 구간 전에 사라진다.",
    },
    {
        "file": "02_trackselect.mp4", "run": "m_heart", "start": 690, "end": 1235,
        "track": "cotton_01 → heart_01 (캐러셀)",
        "scene": "트랙 선택. 다음 버튼 4번(cotton→heart→cat→tee→button), 이전 버튼 3번(→heart). "
                 "미리보기 윤곽·원단 스와치·트랙명이 바뀐다.",
        "focus": {"x": 960, "y": 170, "what": "트랙 미리보기 윤곽"},
        "use": [0.8, 8.9],
    },
    {
        "file": "03_countdown_go.mp4", "run": "m_heart", "start": 1307, "end": 1607,
        "track": "heart_01 (Sweetheart Seam, cotton)",
        "scene": "카운트다운 3-2-1과 GO. 카운트다운 동안 바늘이 상승점에 멈춰 있다가 출발과 함께 왕복한다.",
        "focus": FOOT, "use": [0.0, 5.0],
        "note": "첫 프레임부터 게임 화면이다(앞 1초 여유 대신 숫자 3이 1초 떠 있다).",
    },
    {
        "file": "04_straight_speedup.mp4", "run": "m_tee", "start": 653, "end": 905,
        "track": "tee_01 (Tailor's Tee, cotton)",
        "scene": "긴 직선에서 W 탭으로 1단→5단 가속. 우측 속도 게이지가 차고 바늘 왕복·스티치 간격이 빨라진다.",
        "focus": FOOT, "use": [0.8, 4.2],
        "note": "끝(4.2초 이후)에 곧바로 엄마 찬스 아이템에 닿는다(08 클립 시작과 겹친다).",
    },
    {
        "file": "05_curves_clean.mp4", "run": "m_heart", "start": 1547, "end": 2407,
        "track": "heart_01 (Sweetheart Seam, cotton)",
        "scene": "하트 트랙 윤곽을 자동 조향으로 재봉선에 맞춰 주행(PERFECT 100%, 최대 오차 약 10px). "
                 "좌우 조향에 따라 얼굴이 기울고 누르는 쪽 손이 커진다. 자동 변속으로 2~4단을 오간다.",
        "focus": FOOT, "use": [0.5, 14.0],
    },
    {
        "file": "06_drift.mp4", "run": "m_star", "start": 442, "end": 993,
        "track": "star_01 (Five-Point Finish, silk)",
        "scene": "별 트랙 꼭짓점을 4단 + Shift 드리프트로 돈다(드리프트 3회 + 짧은 보정 1회). "
                 "드리프트 쪽 손이 크게 눌리고 스키드 자국이 남는다.",
        "focus": FOOT, "use": [0.5, 8.7],
        "note": "실크 원단이라 재봉 띠와 원단 명도 차가 작다. 스키드 자국은 은은하다.",
    },
    {
        "file": "07_thimble.mp4", "run": "m_tee", "start": 1440, "end": 1780,
        "track": "tee_01 (Tailor's Tee, cotton)",
        "scene": "골무 아이템 획득 → 양손 검지에 골무, 좌측 HUD에 골무 잔여시간 배지, '골무! 4.5초 동안 부상 면역' 토스트.",
        "focus": {"x": 960, "y": 560, "what": "골무 낀 손가락(좌우 손 끝)"},
        "use": [0.5, 5.5],
        "note": "시작 부분에 앞선 꾸중 말풍선이 페이드아웃 중이다(약 1.6초까지). 4.5초부터는 부상 A를 내기 위한 "
                "좌우 급반전 입력이 시작되어 RISK 게이지가 오른다(골무 중이라 부상은 없다).",
    },
    {
        "file": "08_mom_chance.mp4", "run": "m_tee", "start": 854, "end": 1170,
        "track": "tee_01 (Tailor's Tee, cotton)",
        "scene": "5단 주행 중 엄마 찬스 획득 → 얼굴이 엄마로 바뀌고 손이 양옆으로 빠졌다가 엄마 손이 들어와 "
                 "자동 주행 → 끝나면 원래 얼굴·손으로 복귀.",
        "focus": FACE, "use": [0.6, 5.0],
        "extra": [
            {"t_mf": 914, "event": "얼굴·손 전환 시작(엄마 진입)"},
            {"t_mf": 934, "event": "엄마 얼굴 전환 완료"},
            {"t_mf": 1084, "event": "복귀 전환 시작"},
            {"t_mf": 1104, "event": "원래 얼굴 복귀 완료"},
        ],
    },
    {
        "file": "09_injury_A.mp4", "run": "m_tee", "start": 1714, "end": 2070,
        "track": "tee_01 (Tailor's Tee, cotton)",
        "scene": "5단 좌우 급반전으로 RISK 게이지가 가득 참 → 놀란 눈과 함께 오른손이 노루발 쪽으로 미끄러짐(0.20초) → "
                 "부상(FINGER CUT): 오른손 검지에 밴드, 표정이 > <로 바뀌고 화면이 흔들리며, 눈물 맺힌 초상화 말풍선 "
                 "'아파!'가 하단 중앙에 뜬다 → 손이 움찔 물러났다 제자리로. 1단으로 떨어지고 2초 조작 잠금.",
        "focus": {"x": 1120, "y": 760, "what": "부상 대사 말풍선(하단 중앙)과 밴드가 붙는 우측 손가락"},
        "use": [0.3, 5.5],
        "dialogue": "아파!",
        "markers_from": "A",
        "skip_events": INJURY_SKIP,
        "note": "런의 첫 부상이다. 시작 직후(약 1.2초까지) 앞선 골무 안내 토스트가 페이드아웃 중이고 양손에 골무가 "
                "남아 있다가 0.95초 무렵 골무 효과가 끝난다. 부상 뒤 강제 복귀 없이 재봉선 근처를 계속 달린다.",
    },
    {
        "file": "09_injury_B.mp4", "run": "m_tee", "start": 2440, "end": 2795,
        "track": "tee_01 (Tailor's Tee, cotton)",
        "scene": "긴 직선에서 5단 좌우 급반전 → 놀란 눈과 함께 왼손이 노루발 쪽으로 미끄러짐(0.20초) → 부상(FINGER CUT): "
                 "왼손 손가락에 밴드, > < 표정과 흔들림, 눈물 맺힌 초상화 말풍선 '아얏!' → 손이 움찔 복귀.",
        "focus": {"x": 1120, "y": 760, "what": "부상 대사 말풍선(하단 중앙)과 밴드가 붙는 좌측 손가락"},
        "use": [0.3, 5.5],
        "dialogue": "아얏!",
        "markers_from": "B",
        "skip_events": INJURY_SKIP,
        "note": "런의 두 번째 부상이라 오른손 검지에는 첫 부상의 밴드가 이미 붙어 있다. 시작 전에 다른 알림은 모두 "
                "사라진 상태다. 부상 뒤 강제 복귀는 없다.",
    },
    {
        "file": "10_bonk_scold.mp4", "run": "m_tee", "start": 1165, "end": 1600,
        "track": "tee_01 (Tailor's Tee, cotton)",
        "scene": "사선 직선에서 조향으로 heading을 틀고 직진해 재봉선을 300px 이상 벗어남 → 트랙 이탈 강제 복귀. "
                 "꿀밤(> < 표정, 별, 바운스)과 엄마 꾸중 말풍선 '이녀석, 제대로 해야지!'가 함께 나온다.",
        "focus": {"x": 760, "y": 900, "what": "엄마 꾸중 말풍선(하단 중앙 왼쪽), 동시에 상단 얼굴"},
        "use": [0.0, 7.0],
        "extra": [
            {"t_mf": 1302, "event": "말풍선 완전 표시"},
            {"t_mf": 1520, "event": "말풍선 페이드아웃 시작"},
            {"t_mf": 1540, "event": "말풍선 사라짐"},
        ],
        "skip_events": ["toast_full", "toast_fade", "toast_hidden"],
        "note": "5.6초에 골무를 먹고, 꾸중 말풍선이 사라진 뒤(6.2초) 골무 토스트가 이어서 뜬다. "
                "이 장면은 런의 첫 부상보다 앞이라 부상 대사 말풍선이 섞이지 않는다.",
    },
    {
        "file": "11_finish_reveal.mp4", "run": "m_heart", "start": 2363, "end": 2700,
        "track": "heart_01 (Sweetheart Seam, cotton)",
        "scene": "완주 → 노루발 근접에서 줌아웃해 하트 모양 트랙과 재봉 자국이 드러남 → TRACK COMPLETE·SEAM GRADE S·FINAL 00:15.600.",
        "focus": {"x": 960, "y": 560, "what": "하트 윤곽(화면 중앙), 좌상단 등급 S"},
        "use": [0.0, 5.3],
        "extra": [
            {"t_mf": 2483, "event": "줌아웃 끝(전체 트랙)"},
            {"t_mf": 2468, "event": "완주 문구·등급 페이드인 시작"},
            {"t_mf": 2498, "event": "등급 S 완전 표시"},
        ],
        "note": "5.3초(Result 전환) 이후는 결과 화면이다. 줌아웃 뒤 화면 하단에 'Press any key to continue' 안내가 있다.",
    },
    {
        "file": "11b_finish_reveal_star.mp4", "run": "m_star", "start": 1265, "end": 1600,
        "track": "star_01 (Five-Point Finish, silk)",
        "scene": "보너스: 별 트랙 완주 줌아웃. 별 모양 윤곽과 재봉 자국, 드리프트 스키드, SEAM GRADE S·FINAL 00:16.166.",
        "focus": {"x": 960, "y": 560, "what": "별 윤곽(화면 중앙), 좌상단 등급 S"},
        "use": [0.0, 4.5],
        "extra": [
            {"t_mf": 1385, "event": "줌아웃 끝(전체 트랙)"},
            {"t_mf": 1370, "event": "완주 문구·등급 페이드인 시작"},
            {"t_mf": 1400, "event": "등급 S 완전 표시"},
        ],
        "note": "4.53초(Result 전환) 이후는 결과 화면이다.",
    },
    {
        "file": "12_result.mp4", "run": "m_heart", "start": 2635, "end": 2985,
        "track": "heart_01 (Sweetheart Seam, cotton)",
        "scene": "결과 화면: 등급 S 일러스트(엄마와 원단), 최종 시간 00:15.600, NEW RECORD!, 정확도 94.8%·Perfect 100%·Cuts 0. "
             "오프라인 환경이라 제출 버튼은 표시되지 않는다(누르지도 않음).",
        "focus": {"x": 960, "y": 380, "what": "결과 카드(좌측 일러스트, 우측 등급 S)"},
        "use": [0.3, 5.8],
    },
]

EVENT_LABEL = {
    "countdown": lambda e: "카운트다운 %d" % e["value"],
    "go": lambda e: "출발(GO)",
    "gear": lambda e: "%d단" % e["value"],
    "autopilot_start": lambda e: "엄마 찬스 획득(자동 주행 시작)",
    "autopilot_end": lambda e: "자동 주행 끝",
    "thimble_start": lambda e: "골무 획득",
    "thimble_end": lambda e: "골무 효과 끝",
    "stun_start": lambda e: "부상 발생(FINGER CUT)",
    "stun_end": lambda e: "부상 조작 잠금 해제",
    "offfabric_start": lambda e: "트랙 이탈 강제 복귀 발동(꿀밤 + 꾸중 말풍선)",
    "offfabric_end": lambda e: "강제 복귀 잠금 해제",
    "drift_start": lambda e: "드리프트 시작",
    "drift_end": lambda e: "드리프트 끝",
    "finish": lambda e: "완주(줌아웃 시작, 등급 %s)" % e["grade"],
    "result_screen": lambda e: "결과 화면 전환",
    "carousel": lambda e: "캐러셀 %s → %s" % ("다음" if e["dir"] > 0 else "이전", e["track"]),
    "bonk_steer_begin": lambda e: "이탈 유도 조향 시작",
    "bonk_steer_release": lambda e: "조향 키 뗌(직진)",
    "speedup_begin": lambda e: "가속 입력 시작",
    "induce_injury_begin": lambda e: "급반전 입력 시작",
    "cut_pending_start": lambda e: "RISK 최대: 놀란 눈·손 미끄러짐 시작(0.20초 사전 연출)",
    "toast_show": lambda e: ("부상 대사 말풍선 '%s' 등장" % e["text"]) if e.get("immediate")
    else ("알림 등장: %s" % e["text"]),
    "toast_full": lambda e: "알림 완전 표시: %s" % e["text"],
    "toast_fade": lambda e: "알림 페이드아웃 시작: %s" % e["text"],
    "toast_hidden": lambda e: "알림 사라짐",
}


def load_events(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def probe(path):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0", "-count_frames",
         "-show_entries", "stream=codec_name,width,height,r_frame_rate,nb_read_frames,pix_fmt",
         "-show_entries", "format=duration,size", "-of", "json", path],
        capture_output=True, check=True, text=True).stdout
    return json.loads(out)


def _bubble_curve(path):
    """클립 전체 프레임에서 하단 말풍선 안쪽(1180~1420, 940~990) 밝기(RGB 평균, 편집 렌더러와 같은 BT.709 리미티드 변환) 평균과 표준편차를 구한다(정확한 프레임 번호).
    말풍선이 완전히 보이면 이 영역은 단색 원단(표준편차 약 0)이다."""
    import numpy as np
    raw = subprocess.run(
        [FFMPEG, "-v", "error", "-i", path, "-vf",
         "crop=240:50:1180:940,scale=in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgb24",
         "-fps_mode", "passthrough", "-f", "rawvideo", "-"],
        capture_output=True, check=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(-1, 50, 240, 3).astype(float).mean(axis=3)
    return a.mean(axis=(1, 2)), a.std(axis=(1, 2))


def _eyes_curve(path):
    """놀란 눈 판정용: 얼굴 눈 영역(700~1220, 250~420)의 연속 프레임 차이."""
    import numpy as np
    raw = subprocess.run(
        [FFMPEG, "-v", "error", "-i", path, "-vf",
         "crop=520:170:700:250,scale=130:42:in_color_matrix=bt709:in_range=tv:out_range=pc,format=gray",
         "-fps_mode", "passthrough", "-f", "rawvideo", "-"],
        capture_output=True, check=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(-1, 42, 130).astype(float)
    return np.r_[0.0, np.abs(np.diff(a, axis=0)).mean(axis=(1, 2))]


def markers(path):
    """부상 클립의 연출 시각(초)을 인코딩된 클립에서 직접 측정한다.
    cut = 말풍선이 처음 보이는 프레임(밴드·FINGER CUT·흔들림도 같은 프레임), slip_start = cut 12프레임 전
    (사전 연출 0.20초, 놀란 눈 전환 프레임으로 교차 확인), dialogue_full = 말풍선 알파 1 도달,
    dialogue_fade = 페이드아웃 시작, dialogue_gone = 완전히 사라짐."""
    import numpy as np
    b, sd = _bubble_curve(path)
    n = len(b)
    full = int(next(i for i in range(n - 60) if (sd[i:i + 60] < 0.2).all()))
    full_v = float(np.median(b[full:full + 60]))
    cut = full
    while cut > 1 and b[cut - 1] - b[cut - 2] > 12.0:
        cut -= 1
    fade = int(next(i for i in range(full, n) if b[i] < full_v - 0.5))
    gone = int(next(i for i in range(fade + 10, n - 1)
                    if abs(b[i] - b[i - 1]) < 1.0 and abs(b[i + 1] - b[i]) < 1.0))
    e = _eyes_curve(path)
    lo = max(1, cut - 20)
    eyes = int(lo + e[lo:cut - 3].argmax())
    r = lambda f: round(f / FPS, 3)
    return {"slip_start": r(cut - 12), "surprised_eyes_frame_check": r(eyes), "cut": r(cut),
            "dialogue_full": r(full), "dialogue_fade": r(fade), "dialogue_gone": r(gone),
            "frames": {"slip_start": cut - 12, "cut": cut, "dialogue_full": full, "dialogue_fade": fade,
                       "dialogue_gone": gone}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs")
    ap.add_argument("out")
    ap.add_argument("--crf", type=int, default=12)
    ap.add_argument("--only", default="")
    ap.add_argument("--skip-encode", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    meta = []
    for c in CLIPS:
        src = os.path.join(a.runs, c["run"], "movie", "f.avi")
        dst = os.path.join(a.out, c["file"])
        n = c["end"] - c["start"]
        if not a.skip_encode and (not a.only or any(k in c["file"] for k in a.only.split(","))):
            subprocess.run(
                [FFMPEG, "-v", "error", "-y", "-ss", "%.6f" % (c["start"] / FPS), "-i", src,
                 "-frames:v", str(n), "-an", "-c:v", "libx264", "-preset", "slow",
                 "-crf", str(a.crf),
                 # MJPEG(JFIF)는 풀 레인지다. 편집 호환을 위해 BT.709 리미티드 레인지 yuv420p로 바꾼다.
                 "-vf", "scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv420p",
                 "-color_range", "tv", "-r", str(FPS),
                 "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                 "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709:range=tv",
                 "-movflags", "+faststart", dst],
                check=True)
            print("encoded", c["file"])
        evs = []
        for e in load_events(os.path.join(a.runs, c["run"], "events.jsonl")):
            if e["ev"] in c.get("skip_events", []):
                continue
            if e["ev"] in EVENT_LABEL and c["start"] <= e["mf"] < c["end"]:
                evs.append({"t": round((e["mf"] - c["start"]) / FPS, 3),
                            "event": EVENT_LABEL[e["ev"]](e)})
        for x in c.get("extra", []):
            if c["start"] <= x["t_mf"] < c["end"]:
                evs.append({"t": round((x["t_mf"] - c["start"]) / FPS, 3), "event": x["event"]})
        mk = markers(dst) if "markers_from" in c else None
        if mk:
            line = c.get("dialogue", "")
            for k, label in (("slip_start", "놀란 눈·손 미끄러짐 시작(0.20초 사전 연출)"),
                             ("cut", "부상 프레임: 밴드·FINGER CUT!·흔들림, 대사 말풍선 '%s' 등장" % line),
                             ("dialogue_full", "대사 말풍선 완전 표시"),
                             ("dialogue_fade", "대사 말풍선 페이드아웃 시작"),
                             ("dialogue_gone", "대사 말풍선 사라짐")):
                evs.append({"t": mk[k], "event": label})
        evs.sort(key=lambda d: d["t"])
        p = probe(dst)
        st = p["streams"][0]
        meta.append({
            "file": c["file"],
            "duration_s": round(float(p["format"]["duration"]), 3),
            "frames": int(st["nb_read_frames"]),
            "resolution": "%dx%d" % (st["width"], st["height"]),
            "fps": st["r_frame_rate"],
            "codec": "%s %s CRF %d BT.709 limited" % (st["codec_name"], st["pix_fmt"], a.crf),
            "size_mb": round(int(p["format"]["size"]) / 1e6, 1),
            "track": c["track"],
            "scene": c["scene"],
            "source": {"run": c["run"], "movie_frames": [c["start"], c["end"]]},
            "events": evs,
            "focus_point_1080p": c["focus"],
            "recommended_use_s": c["use"],
            **({"dialogue": c["dialogue"]} if "dialogue" in c else {}),
            **({"markers_s": mk} if mk else {}),
            "note": c.get("note", ""),
        })
    doc = {
        "capture": {
            "method": "Godot 4.6.1 Movie Maker (--write-movie AVI MJPEG 화질 1.0, --fixed-fps 60) → ffmpeg H.264",
            "resolution": "1920x1080", "fps": 60, "audio": "없음(게임 무음으로 촬영)",
            "margins": "각 클립 앞뒤 약 1초 여유(예외는 note 참고)",
        },
        "clips": meta,
    }
    with open(os.path.join(a.out, "footage.json"), "w") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    print("total MB", round(sum(m["size_mb"] for m in meta), 1))


if __name__ == "__main__":
    main()
