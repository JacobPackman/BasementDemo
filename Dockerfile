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

# Run uvicorn on port 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
