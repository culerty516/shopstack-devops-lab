import os

from flask import Flask

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "0.2.0")


@app.get("/")
def index():
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ShopStack Frontend</title>
</head>
<body>
  <h1>Hello from ShopStack!</h1>
  <p>Version: {APP_VERSION}</p>
  <p>Release: Kubernetes-ready frontend</p>
</body>
</html>
"""


@app.get("/healthz")
def healthz():
    return "ok\n", 200
