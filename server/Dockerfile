# Overlock 리더보드 서버 컨테이너 이미지.
# 빌드:  docker build -t overlock-server ./server
# 실행:  docker run -d -p 8010:8000 -v overlock-data:/data overlock-server
#        (호스트 8010 → 컨테이너 8000. 배포 상세는 docs/deploy.md 참고.)
FROM python:3.13-slim

# 파이썬 런타임 기본값: .pyc 미기록 + 로그 즉시 플러시(컨테이너 로그 가시성).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# 의존성만 먼저 설치해 레이어 캐시를 살린다(app 코드 변경 시 재설치 방지).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 애플리케이션 코드(공식 트랙 스냅샷 app/tracks 포함).
COPY app ./app

# 비루트 실행 + DB 볼륨 마운트포인트 준비.
# /data 를 appuser 소유로 만든 뒤 VOLUME 선언 → 새 네임드 볼륨이 이 소유권을 물려받아
# SQLite 파일 생성/쓰기가 비루트로도 가능하다.
RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /data \
    && chown -R appuser:appuser /data

# SQLite DB 를 /data 볼륨에 둔다(sqlite:////data = 절대경로 /data/overlock.db).
ENV OVERLOCK_DB_URL=sqlite:////data/overlock.db
VOLUME /data

# 컨테이너 내부 포트는 8000 고정. 호스트 매핑에서 8010:8000 으로 노출한다.
EXPOSE 8000

USER appuser

# /api/health 를 주기적으로 확인(curl 미포함 slim 이미지라 파이썬 표준 라이브러리 사용).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health', timeout=4)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
