import os
import time
import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "localhost"),
    "dbname": os.getenv("DB_NAME", "visitsdb"),
    "user": os.getenv("DB_USER", "appuser"),
    "password": os.getenv("DB_PASSWORD", "changeme"),
}


def get_conn():
    return psycopg2.connect(**DB_CONFIG)


def init_db():
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS visits ("
            "id SERIAL PRIMARY KEY, ts TIMESTAMP DEFAULT NOW())"
        )
        conn.commit()


@app.route("/")
def index():
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO visits DEFAULT VALUES")
        cur.execute("SELECT COUNT(*) FROM visits")
        count = cur.fetchone()[0]
        conn.commit()
    return jsonify(message="Hello from Flask", visits=count)


@app.route("/health")
def health():
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return jsonify(status="healthy"), 200
    except Exception as e:
        return jsonify(status="unhealthy", error=str(e)), 503


def _startup():
    for attempt in range(10):
        try:
            init_db()
            app.logger.info("Database initialised")
            return
        except Exception as e:
            app.logger.warning("DB not ready (%s/10): %s", attempt + 1, e)
            time.sleep(2)
    raise RuntimeError("Database unreachable after 10 attempts")


_startup()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)