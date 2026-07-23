FROM python:3.12-slim AS builder
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
RUN useradd -m -u 1000 appuser
COPY --from=builder --chown=appuser:appuser /opt/venv /opt/venv
WORKDIR /app
COPY --chown=appuser:appuser . .
USER appuser
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://localhost:8000/health')"
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "app:app"]