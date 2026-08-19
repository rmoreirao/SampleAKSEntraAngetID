FROM ghcr.io/astral-sh/uv:0.8.11 AS uv

FROM python:3.12.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/app/.venv/bin:$PATH

RUN groupadd --gid 10001 app && \
    useradd --uid 10001 --gid app --create-home --home-dir /home/app app

WORKDIR /app
COPY --from=uv /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
COPY data ./data
RUN uv sync --frozen --no-dev && chown -R app:app /app

USER 10001:10001
EXPOSE 8000 8002 8003 8004
CMD ["web-api"]
