FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

COPY pyproject.toml uv.lock README.md LICENSE server.py ./
COPY src ./src
COPY mod ./mod

RUN uv sync --frozen --no-dev

ENV PZ_ZOMBOID_DIR=/tmp/Zomboid

ENTRYPOINT ["uv", "run", "--no-dev", "pz-ai-director"]