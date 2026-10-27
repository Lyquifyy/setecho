# Setecho API. Stateless; the only secret is MODEL_API_KEY, set as a Fly secret, never baked in.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# ffmpeg converts non-WAV audio before transcription; libglib is what opencv-headless needs at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_NO_DEV=1

# Dependencies first so they cache separately from the app code.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev

COPY app ./app

EXPOSE 8000
# Start the venv's uvicorn directly: `uv run` re-syncs and byte-compiles at every boot, which
# is slower than the proxy's wait for a cold machine.
CMD ["/srv/.venv/bin/uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
