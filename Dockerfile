# Multi-stage production Dockerfile
FROM python:3.11-slim as base

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000 \
    DATABASE_URL=sqlite+aiosqlite:////data/wetbasement.db

WORKDIR /app

# Install dependencies in a single layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY models.py admin.py main.py ./
COPY templates/ ./templates/

# Ensure SQLite storage directory exists
RUN mkdir -p /data

EXPOSE 8000

# --proxy-headers + --forwarded-allow-ips: trust X-Forwarded-Proto from the
# Azure Container Apps ingress (which terminates TLS) so the app generates
# https:// URLs. Without this, the admin login form posts to http:// and
# browsers block it as mixed content.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
