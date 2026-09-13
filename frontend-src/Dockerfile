FROM python:3.13-alpine3.22

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=0.1.0

WORKDIR /app

RUN addgroup \
      -S \
      -g 10001 \
      shopstack \
    && adduser \
      -S \
      -D \
      -H \
      -u 10001 \
      -G shopstack \
      shopstack

COPY requirements.txt .

RUN pip install \
    --no-cache-dir \
    --disable-pip-version-check \
    -r requirements.txt

COPY app.py .

RUN chown -R shopstack:shopstack /app

USER 10001:10001

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "2", "app:app"]
