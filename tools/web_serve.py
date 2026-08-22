#!/usr/bin/env python3
"""Overlock 웹(HTML5) 빌드 로컬 서빙 스크립트.

`build/web/`(Godot `--export-release "Web"` 산출물)를 정적으로 서빙하며,
브라우저에서 게임을 확인하거나 배포 전 점검할 때 쓴다. 표준 라이브러리만 사용한다.

사용법:
    # 기본: 레포의 build/web 을 8060 포트로 서빙
    python3 tools/web_serve.py

    # 포트 지정
    python3 tools/web_serve.py --port 9000

    # 다른 디렉토리 서빙
    python3 tools/web_serve.py --dir /path/to/build/web

    # COOP/COEP/CORP(교차 출처 격리) 헤더 부착
    #   Web 프리셋은 스레드 OFF라 이 헤더 없이도 동작한다. 이 옵션은
    #   추후 스레드 ON 빌드나 SharedArrayBuffer 실험을 로컬에서 재현할 때만 필요하다.
    python3 tools/web_serve.py --coi

종료: Ctrl-C.

주의:
- .wasm 은 반드시 `application/wasm` MIME 로 서빙해야 브라우저가 스트리밍 컴파일한다.
  이 스크립트는 확장자별 MIME 를 명시적으로 지정한다(구형 파이썬의 mimetypes 누락 방지).
- 이 스크립트는 로컬 확인용이다. 실제 배포는 `docs/deploy.md` 참고.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import socketserver
import sys
from pathlib import Path

# 확장자 → MIME. Godot 웹 산출물이 요구하는 타입을 명시적으로 고정한다.
_MIME_BY_EXT: dict[str, str] = {
    ".wasm": "application/wasm",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".pck": "application/octet-stream",
    ".html": "text/html; charset=utf-8",
    ".json": "application/json",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}

_REPO_ROOT = Path(__file__).resolve().parent.parent
_DEFAULT_DIR = _REPO_ROOT / "build" / "web"


class _Handler(http.server.SimpleHTTPRequestHandler):
    """정적 핸들러. .wasm 등 MIME 를 고정하고, 옵션으로 COOP/COEP/CORP 를 붙인다."""

    cross_origin_isolation: bool = False

    def guess_type(self, path: str) -> str:  # type: ignore[override]
        ext = os.path.splitext(path)[1].lower()
        if ext in _MIME_BY_EXT:
            return _MIME_BY_EXT[ext]
        return super().guess_type(path)

    def end_headers(self) -> None:
        # 캐시 무효화(로컬 확인 중 빌드를 바꿔도 즉시 반영되도록).
        self.send_header("Cache-Control", "no-store")
        if self.cross_origin_isolation:
            # SharedArrayBuffer/스레드 빌드를 로컬에서 재현할 때만 필요한 격리 헤더.
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("  %s - %s\n" % (self.address_string(), fmt % args))


def main() -> int:
    parser = argparse.ArgumentParser(description="Overlock 웹 빌드 로컬 서버")
    parser.add_argument("--port", type=int, default=8060, help="바인드 포트 (기본 8060)")
    parser.add_argument(
        "--dir",
        default=str(_DEFAULT_DIR),
        help="서빙할 디렉토리 (기본: <repo>/build/web)",
    )
    parser.add_argument(
        "--host", default="127.0.0.1", help="바인드 호스트 (기본 127.0.0.1)"
    )
    parser.add_argument(
        "--coi",
        "--cross-origin-isolation",
        dest="coi",
        action="store_true",
        help="COOP/COEP/CORP 헤더 부착(스레드 ON 빌드 재현용, 기본 OFF)",
    )
    args = parser.parse_args()

    serve_dir = Path(args.dir).resolve()
    if not serve_dir.is_dir():
        sys.stderr.write("오류: 디렉토리 없음 -> %s\n" % serve_dir)
        sys.stderr.write("먼저 웹 빌드를 만드세요: "
                         "godot --headless --export-release \"Web\" build/web/index.html\n")
        return 1
    if not (serve_dir / "index.html").is_file():
        sys.stderr.write("경고: %s 에 index.html 이 없습니다.\n" % serve_dir)

    _Handler.cross_origin_isolation = bool(args.coi)
    handler = functools.partial(_Handler, directory=str(serve_dir))

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((args.host, args.port), handler) as httpd:
        url = "http://%s:%d/" % (args.host, args.port)
        sys.stdout.write("Overlock 웹 서버\n")
        sys.stdout.write("  디렉토리 : %s\n" % serve_dir)
        sys.stdout.write("  주소     : %s\n" % url)
        sys.stdout.write("  격리헤더 : %s\n" % ("ON" if args.coi else "OFF"))
        sys.stdout.write("  (Ctrl-C 로 종료)\n")
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            sys.stdout.write("\n종료합니다.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
