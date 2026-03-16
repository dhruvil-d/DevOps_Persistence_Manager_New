# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile – Persistent Volume Demo Application
# ─────────────────────────────────────────────────────────────────────────────
# Build:    docker build -t pv-demo-app:latest ./app
# Run:      docker run -v /tmp/pv-data:/data pv-demo-app:latest
# ─────────────────────────────────────────────────────────────────────────────

FROM python:3.11-slim

# ── Metadata ──────────────────────────────────────────────────────────────────
LABEL maintainer="DevOps Team"
LABEL description="Demo app that persists timestamped data to a mounted volume"
LABEL version="1.0.0"

# ── Non-root user for security ────────────────────────────────────────────────
RUN groupadd --gid 1001 appgroup && \
    useradd  --uid 1001 --gid appgroup --shell /bin/sh --create-home appuser

# ── App directory ─────────────────────────────────────────────────────────────
WORKDIR /app

# ── Dependencies (none in this project; copy for consistency) ─────────────────
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Application source ────────────────────────────────────────────────────────
COPY app.py .
COPY static/ ./static/

# ── Persistent data directory (overridden by volume mount at runtime) ─────────
RUN mkdir -p /data && chown appuser:appgroup /data

# ── Expose UI Port ────────────────────────────────────────────────────────────
EXPOSE 5000

# ── Switch to non-root user ───────────────────────────────────────────────────
USER appuser

# ── Health check – test web server ────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:5000/ || exit 1

# ── Entry point ───────────────────────────────────────────────────────────────
CMD ["python", "-u", "app.py"]
