"""
veljko-demo-app — Flask application with UI
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


# ── UI ─────────────────────────────────────────────────────────────────────────
UI_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>veljko / items</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=DM+Sans:wght@300;400;500&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:      #0d0d0d;
      --panel:   #141414;
      --border:  #222;
      --accent:  #c8ff00;
      --red:     #ff4d4d;
      --text:    #f0f0f0;
      --muted:   #555;
      --mono:    'Space Mono', monospace;
      --sans:    'DM Sans', sans-serif;
    }

    body {
      background: var(--bg);
      color: var(--text);
      font-family: var(--sans);
      min-height: 100vh;
    }

    /* top bar */
    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 18px 32px;
      border-bottom: 1px solid var(--border);
    }

    .brand {
      font-family: var(--mono);
      font-size: 13px;
      letter-spacing: 0.05em;
      color: var(--text);
    }

    .brand span { color: var(--accent); }

    .db-status {
      display: flex;
      align-items: center;
      gap: 7px;
      font-family: var(--mono);
      font-size: 11px;
      color: var(--muted);
    }

    .dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: var(--muted);
    }
    .dot.ready { background: var(--accent); box-shadow: 0 0 8px var(--accent); }
    .dot.waiting { background: #ff9900; box-shadow: 0 0 8px #ff9900; animation: pulse 1.2s ease-in-out infinite; }

    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.4; } }

    /* main layout */
    .main {
      max-width: 720px;
      margin: 0 auto;
      padding: 48px 24px 80px;
    }

    h1 {
      font-family: var(--mono);
      font-size: clamp(32px, 6vw, 56px);
      font-weight: 700;
      letter-spacing: -0.03em;
      line-height: 1;
      margin-bottom: 8px;
    }

    h1 .accent { color: var(--accent); }

    .subtitle {
      font-size: 14px;
      color: var(--muted);
      margin-bottom: 48px;
      font-family: var(--mono);
    }

    /* add form */
    .form-label {
      font-family: var(--mono);
      font-size: 10px;
      letter-spacing: 0.2em;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 10px;
    }

    .input-group {
      display: flex;
      border: 1px solid var(--border);
      background: var(--panel);
      margin-bottom: 40px;
      transition: border-color 0.2s;
    }

    .input-group:focus-within { border-color: var(--accent); }

    input[type="text"] {
      flex: 1;
      background: transparent;
      border: none;
      outline: none;
      padding: 15px 20px;
      font-family: var(--mono);
      font-size: 14px;
      color: var(--text);
    }

    input::placeholder { color: var(--muted); }

    .btn-add {
      background: var(--accent);
      color: #000;
      border: none;
      padding: 15px 28px;
      font-family: var(--mono);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.1em;
      text-transform: uppercase;
      cursor: pointer;
      transition: opacity 0.15s, transform 0.1s;
      flex-shrink: 0;
    }

    .btn-add:hover { opacity: 0.85; }
    .btn-add:active { transform: scale(0.97); }
    .btn-add:disabled { opacity: 0.3; cursor: not-allowed; }

    /* list header */
    .list-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
    }

    .list-label {
      font-family: var(--mono);
      font-size: 10px;
      letter-spacing: 0.2em;
      text-transform: uppercase;
      color: var(--muted);
    }

    .count {
      font-family: var(--mono);
      font-size: 11px;
      color: var(--accent);
      background: rgba(200, 255, 0, 0.07);
      border: 1px solid rgba(200, 255, 0, 0.2);
      padding: 3px 10px;
    }

    /* items */
    .items { display: flex; flex-direction: column; gap: 2px; }

    .item {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 14px 20px;
      background: var(--panel);
      border: 1px solid var(--border);
      border-left: 2px solid transparent;
      transition: border-left-color 0.15s, background 0.15s;
      animation: fadeIn 0.25s ease both;
    }

    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(-6px); }
      to   { opacity: 1; transform: translateY(0); }
    }

    .item:hover { border-left-color: var(--accent); background: #181818; }

    .item-left { display: flex; align-items: center; gap: 16px; }

    .item-id {
      font-family: var(--mono);
      font-size: 11px;
      color: var(--muted);
      min-width: 28px;
    }

    .item-name {
      font-size: 14px;
      font-weight: 400;
    }

    .item-right { display: flex; align-items: center; gap: 16px; }

    .item-date {
      font-family: var(--mono);
      font-size: 11px;
      color: var(--muted);
    }

    .btn-del {
      background: transparent;
      border: 1px solid transparent;
      color: var(--muted);
      font-size: 18px;
      line-height: 1;
      width: 28px;
      height: 28px;
      display: flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      transition: all 0.15s;
    }

    .btn-del:hover {
      color: var(--red);
      border-color: var(--red);
      background: rgba(255,77,77,0.08);
    }

    .empty {
      text-align: center;
      padding: 60px 20px;
      font-family: var(--mono);
      font-size: 13px;
      color: var(--muted);
      border: 1px dashed var(--border);
      background: var(--panel);
    }

    .empty .hint { color: var(--accent); }

    /* toast */
    #toast {
      position: fixed;
      bottom: 28px;
      left: 50%;
      transform: translateX(-50%) translateY(20px);
      background: var(--panel);
      border: 1px solid var(--border);
      border-left: 3px solid var(--accent);
      font-family: var(--mono);
      font-size: 12px;
      padding: 11px 22px;
      opacity: 0;
      transition: all 0.2s;
      pointer-events: none;
      white-space: nowrap;
      z-index: 99;
    }

    #toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
    #toast.err  { border-left-color: var(--red); }

    /* footer links */
    .footer {
      margin-top: 56px;
      padding-top: 20px;
      border-top: 1px solid var(--border);
      display: flex;
      gap: 24px;
    }

    .footer a {
      font-family: var(--mono);
      font-size: 11px;
      letter-spacing: 0.1em;
      color: var(--muted);
      text-decoration: none;
      text-transform: uppercase;
      transition: color 0.15s;
    }

    .footer a:hover { color: var(--accent); }

    .spinner {
      display: inline-block;
      width: 12px; height: 12px;
      border: 2px solid rgba(0,0,0,0.3);
      border-top-color: #000;
      border-radius: 50%;
      animation: spin 0.5s linear infinite;
      vertical-align: middle;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div class="topbar">
    <div class="brand">veljko<span>/</span>demo</div>
    <div class="db-status">
      <div class="dot" id="dbDot"></div>
      <span id="dbText">checking db</span>
    </div>
  </div>

  <div class="main">
    <h1>item<span class="accent">_</span>store<span class="accent">.</span></h1>
    <div class="subtitle">// a simple crud demo running on eks + rds</div>

    <div class="form-label">// new item</div>
    <div class="input-group">
      <input type="text" id="nameInput" placeholder="enter item name..." maxlength="255" autocomplete="off"
             onkeydown="if(event.key==='Enter') addItem()">
      <button class="btn-add" id="addBtn" onclick="addItem()">+ add</button>
    </div>

    <div class="list-header">
      <div class="list-label">// items</div>
      <div class="count" id="countBadge">0</div>
    </div>

    <div class="items" id="itemsList">
      <div class="empty"><span class="hint">no items yet</span> — add one above</div>
    </div>

    <div class="footer">
      <a href="/health" target="_blank">→ health</a>
      <a href="/metrics" target="_blank">→ metrics</a>
      <a href="/items" target="_blank">→ api</a>
    </div>
  </div>

  <div id="toast"></div>

  <script>
    let items = [];

    function toast(msg, err = false) {
      const t = document.getElementById('toast');
      t.textContent = msg;
      t.className = 'show' + (err ? ' err' : '');
      clearTimeout(t._t);
      t._t = setTimeout(() => t.className = '', 2500);
    }

    function fmtDate(s) {
      if (!s) return '';
      try { return new Date(s).toLocaleDateString('en-GB', {day:'2-digit',month:'short',year:'numeric'}); }
      catch { return ''; }
    }

    function esc(s) {
      return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function render() {
      const list = document.getElementById('itemsList');
      const badge = document.getElementById('countBadge');
      badge.textContent = items.length + ' item' + (items.length !== 1 ? 's' : '');
      if (!items.length) {
        list.innerHTML = '<div class="empty"><span class="hint">no items yet</span> — add one above</div>';
        return;
      }
      list.innerHTML = items.map(it => `
        <div class="item" id="item-${it.id}">
          <div class="item-left">
            <span class="item-id">#${it.id}</span>
            <span class="item-name">${esc(it.name)}</span>
          </div>
          <div class="item-right">
            <span class="item-date">${fmtDate(it.created_at)}</span>
            <button class="btn-del" onclick="delItem(${it.id})" title="delete">×</button>
          </div>
        </div>`).join('');
    }

    async function checkDb() {
      try {
        const r = await fetch('/health');
        const d = await r.json();
        const dot  = document.getElementById('dbDot');
        const text = document.getElementById('dbText');
        if (d.db_ready) {
          dot.className = 'dot ready';
          text.textContent = 'db connected';
        } else {
          dot.className = 'dot waiting';
          text.textContent = 'db connecting...';
          setTimeout(checkDb, 3000);
        }
      } catch { setTimeout(checkDb, 3000); }
    }

    async function loadItems() {
      try {
        const r = await fetch('/items');
        if (r.status === 503) { setTimeout(loadItems, 3000); return; }
        items = await r.json();
        render();
      } catch { setTimeout(loadItems, 3000); }
    }

    async function addItem() {
      const input = document.getElementById('nameInput');
      const btn   = document.getElementById('addBtn');
      const name  = input.value.trim();
      if (!name) { input.focus(); return; }

      btn.disabled = true;
      btn.innerHTML = '<span class="spinner"></span>';

      try {
        const r = await fetch('/items', {
          method: 'POST',
          headers: {'Content-Type':'application/json'},
          body: JSON.stringify({name})
        });
        if (!r.ok) throw new Error();
        const it = await r.json();
        items.unshift(it);
        render();
        input.value = '';
        toast('item added');
      } catch { toast('failed to add item', true); }
      finally {
        btn.disabled = false;
        btn.textContent = '+ add';
        input.focus();
      }
    }

    async function delItem(id) {
      const el = document.getElementById('item-' + id);
      if (el) el.style.opacity = '0.4';
      try {
        const r = await fetch('/items/' + id, {method:'DELETE'});
        if (!r.ok) throw new Error();
        items = items.filter(i => i.id !== id);
        render();
        toast('item deleted');
      } catch {
        if (el) el.style.opacity = '1';
        toast('failed to delete', true);
      }
    }

    checkDb();
    loadItems();
  </script>
</body>
</html>"""


# ── Routes ─────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    return Response(UI_HTML, mimetype="text/html")


@app.route("/health")
def health():
    start = time.time()
    REQUEST_COUNT.labels("GET", "/health", "200").inc()
    REQUEST_LATENCY.labels("GET", "/health").observe(time.time() - start)
    return jsonify({"status": "ok", "db_ready": _db_ready}), 200


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
