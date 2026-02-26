"""
veljko-demo-app — Flask application
"""

import os
import time
import logging
import threading

from flask import Flask, jsonify, request, Response
from sqlalchemy import create_engine, text, Column, Integer, String, DateTime
from sqlalchemy.orm import declarative_base, sessionmaker
from sqlalchemy.sql import func
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST,
)

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
)
log = logging.getLogger(__name__)

app = Flask(__name__)

# ── Database ───────────────────────────────────────────────────────────────────
DB_HOST     = os.environ["DB_HOST"]
DB_PORT     = os.environ.get("DB_PORT", "5432")
DB_NAME     = os.environ["DB_NAME"]
DB_USER     = os.environ["DB_USER"]
DB_PASSWORD = os.environ["password"]

DATABASE_URL = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
engine       = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    pool_size=5,
    connect_args={"connect_timeout": 5},
)
SessionLocal = sessionmaker(bind=engine)
Base         = declarative_base()

_db_ready = False


class Item(Base):
    __tablename__ = "items"
    id         = Column(Integer, primary_key=True)
    name       = Column(String(255), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())


def init_db_background():
    """Connect to DB in a background thread — never blocks gunicorn workers."""
    global _db_ready
    for attempt in range(30):
        try:
            Base.metadata.create_all(bind=engine)
            _db_ready = True
            log.info("DB tables ready")
            return
        except Exception as e:
            log.warning(f"DB not ready ({attempt + 1}/30): {e}")
            time.sleep(5)
    log.error("Could not connect to DB after 30 attempts")


# Start DB init in background immediately on startup
threading.Thread(target=init_db_background, daemon=True).start()


# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total", "HTTP request count",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP latency",
    ["method", "endpoint"],
    buckets=[0.01, 0.05, 0.1, 0.5, 1.0, 5.0],
)
DB_QUERY_LATENCY = Histogram(
    "db_query_duration_seconds", "DB query latency", ["operation"],
)
DB_ERRORS   = Counter("db_connection_errors_total", "DB error count")
ITEMS_GAUGE = Gauge("app_items_total", "Total items in DB")


# ── Routes ─────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    return jsonify({
        "app":       "veljko-demo",
        "version":   os.environ.get("APP_VERSION", "dev"),
        "db_ready":  _db_ready,
        "endpoints": ["/health", "/metrics", "/items"],
    })


@app.route("/health")
def health():
    """
    Always returns 200 so the pod stays alive.
    Reports db status but never fails because of DB — the pod should not
    restart just because RDS is slow to accept connections.
    """
    start = time.time()
    REQUEST_COUNT.labels("GET", "/health", "200").inc()
    REQUEST_LATENCY.labels("GET", "/health").observe(time.time() - start)
    return jsonify({
        "status":   "ok",
        "db_ready": _db_ready,
    }), 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.route("/items", methods=["GET"])
def list_items():
    if not _db_ready:
        return jsonify({"error": "db not ready yet, please retry"}), 503
    start = time.time()
    db = SessionLocal()
    try:
        with DB_QUERY_LATENCY.labels("select").time():
            items = db.query(Item).all()
        ITEMS_GAUGE.set(len(items))
        REQUEST_COUNT.labels("GET", "/items", "200").inc()
        REQUEST_LATENCY.labels("GET", "/items").observe(time.time() - start)
        return jsonify([
            {"id": i.id, "name": i.name, "created_at": str(i.created_at)}
            for i in items
        ])
    except Exception as e:
        DB_ERRORS.inc()
        log.error(f"GET /items error: {e}")
        REQUEST_COUNT.labels("GET", "/items", "503").inc()
        return jsonify({"error": "database error"}), 503
    finally:
        db.close()


@app.route("/items", methods=["POST"])
def create_item():
    if not _db_ready:
        return jsonify({"error": "db not ready yet, please retry"}), 503
    start = time.time()
    data = request.get_json()
    if not data or "name" not in data:
        return jsonify({"error": "name is required"}), 400
    db = SessionLocal()
    try:
        with DB_QUERY_LATENCY.labels("insert").time():
            item = Item(name=data["name"])
            db.add(item)
            db.commit()
            db.refresh(item)
        log.info(f"Created item id={item.id} name={item.name}")
        REQUEST_COUNT.labels("POST", "/items", "201").inc()
        REQUEST_LATENCY.labels("POST", "/items").observe(time.time() - start)
        return jsonify({"id": item.id, "name": item.name}), 201
    except Exception as e:
        DB_ERRORS.inc()
        db.rollback()
        log.error(f"POST /items error: {e}")
        REQUEST_COUNT.labels("POST", "/items", "503").inc()
        return jsonify({"error": "database error"}), 503
    finally:
        db.close()


@app.route("/items/<int:item_id>", methods=["DELETE"])
def delete_item(item_id):
    if not _db_ready:
        return jsonify({"error": "db not ready yet, please retry"}), 503
    start = time.time()
    db = SessionLocal()
    try:
        with DB_QUERY_LATENCY.labels("delete").time():
            item = db.query(Item).filter(Item.id == item_id).first()
            if not item:
                return jsonify({"error": "not found"}), 404
            db.delete(item)
            db.commit()
        log.info(f"Deleted item id={item_id}")
        REQUEST_COUNT.labels("DELETE", "/items", "200").inc()
        REQUEST_LATENCY.labels("DELETE", "/items").observe(time.time() - start)
        return jsonify({"deleted": item_id}), 200
    except Exception as e:
        DB_ERRORS.inc()
        db.rollback()
        log.error(f"DELETE /items/{item_id} error: {e}")
        REQUEST_COUNT.labels("DELETE", "/items", "503").inc()
        return jsonify({"error": "database error"}), 503
    finally:
        db.close()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
