#!/bin/bash
set -euo pipefail

# ---- Config ----
MC_DIR="$HOME/mc-server"
JAVA_MIN=1024M
JAVA_MAX=1536M
MC_PORT=25565
BEDROCK_PORT=19132
RCON_PORT=25575
WEB_BIND="0.0.0.0"
WEB_PORT=8080
# ----------------

echo "Bắt đầu thiết lập Minecraft server + Web UI (không dùng psutil)..."

termux-setup-storage || true

pkg update -y && pkg upgrade -y
pkg install -y wget openjdk-25 curl python

mkdir -p "$MC_DIR"
cd "$MC_DIR"

# run.sh
cat > run.sh <<'SH'
#!/bin/bash
set -e
JAVA_MIN="${JAVA_MIN:-1024M}"
JAVA_MAX="${JAVA_MAX:-1536M}"
cd "$(dirname "$0")"
mkdir -p logs
exec java -Xmx${JAVA_MAX} -Xms${JAVA_MIN} -jar server.jar nogui >> logs/latest.log 2>&1
SH
chmod +x run.sh

echo "Tải server.jar..."
wget -O server.jar https://api.purpurmc.org/v2/purpur/26.2/latest/download

mkdir -p plugins

echo "Tải plugins..."
wget -q -O plugins/Geyser-Spigot.jar https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot || true
wget -q -O plugins/Floodgate-Spigot.jar https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot || true

VV_URL=$(curl -s https://api.github.com/repos/ViaVersion/ViaVersion/releases/latest | grep "browser_download_url" | grep -v "fabric\|sources\|javadoc" | grep '\.jar"' | cut -d '"' -f4 | head -n1 || true)
[ -n "$VV_URL" ] && wget -q -O plugins/ViaVersion.jar "$VV_URL" || true

VB_URL=$(curl -s https://api.github.com/repos/ViaVersion/ViaBackwards/releases/latest | grep "browser_download_url" | grep -v "fabric\|sources\|javadoc" | grep '\.jar"' | cut -d '"' -f4 | head -n1 || true)
[ -n "$VB_URL" ] && wget -q -O plugins/ViaBackwards.jar "$VB_URL" || true

echo "eula=true" > eula.txt

generate_pass() {
  tr -dc 'A-Za-z0-9_!@#%&' < /dev/urandom | head -c 20 || echo "changeme12345"
}
RCON_PASS=$(generate_pass)
ADMIN_USER="admin"
ADMIN_PASS=$(generate_pass)

cat > server.properties <<EOF
online-mode=false
server-port=${MC_PORT}
gamemode=survival
difficulty=normal
max-players=20
motd=Welcome to Minecraft Server
allow-flight=false
pvp=true
generate-structures=true
spawn-protection=16
enable-rcon=true
rcon.port=${RCON_PORT}
rcon.password=${RCON_PASS}
EOF

mkdir -p plugins/Geyser-Spigot plugins/floodgate
cat > plugins/Geyser-Spigot/config.yml <<'YML'
bedrock:
  port: 19132
  address: "0.0.0.0"
java:
  address: localhost
  port: 25565
auth-type: floodgate
YML

cat > plugins/floodgate/config.yml <<'YML'
username-prefix: "."
YML

mkdir -p logs templates static

# requirements (KHÔNG còn psutil)
cat > requirements.txt <<'REQ'
flask
mcrcon
REQ

# ==================== webui.py (đã sửa) ====================
cat > webui.py <<'PY'
#!/usr/bin/env python3
import os
import subprocess
import time
import signal
from datetime import datetime
from flask import Flask, render_template, request, jsonify
from functools import wraps

try:
    from mcrcon import MCRcon
except Exception:
    raise SystemExit("Chạy: pip3 install -r requirements.txt")

app = Flask(__name__, static_folder="static", template_folder="templates")

MC_DIR = os.getcwd()
RCON_HOST = os.environ.get("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("RCON_PORT", 25575))
RCON_PASS = os.environ.get("RCON_PASS", "")
LOG_PATH = os.path.join(MC_DIR, "logs", "latest.log")
PID_FILE = os.path.join(MC_DIR, "mcserver.pid")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "")
WEB_BIND = os.environ.get("WEB_BIND", "0.0.0.0")
WEB_PORT = int(os.environ.get("WEB_PORT", 8080))
MC_PORT = int(os.environ.get("MC_PORT", 25565))
BEDROCK_PORT = int(os.environ.get("BEDROCK_PORT", 19132))

def check_auth():
    if not ADMIN_USER or not ADMIN_PASS:
        return True
    auth = request.authorization
    return auth and auth.username == ADMIN_USER and auth.password == ADMIN_PASS

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not check_auth():
            return jsonify({"error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

def get_local_ip():
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        try:
            out = subprocess.check_output(["hostname", "-I"], text=True).strip()
            return out.split()[0] if out else "127.0.0.1"
        except Exception:
            return "127.0.0.1"

def is_server_running():
    if not os.path.exists(PID_FILE):
        return False, None
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        # Kiểm tra process còn sống không
        os.kill(pid, 0)
        return True, pid
    except (OSError, ValueError):
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)
        return False, None

def start_server():
    running, _ = is_server_running()
    if running:
        return False, "Server đang chạy rồi"
    try:
        proc = subprocess.Popen(
            ["bash", "run.sh"],
            cwd=MC_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )
        with open(PID_FILE, "w") as f:
            f.write(str(proc.pid))
        time.sleep(1.5)
        return True, f"Đã khởi động (PID {proc.pid})"
    except Exception as e:
        return False, str(e)

def stop_server():
    running, pid = is_server_running()
    if not running:
        return False, "Server không chạy"
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(2)
        try:
            os.kill(pid, 0)  # còn sống?
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)
        return True, "Đã tắt server"
    except Exception as e:
        return False, str(e)

def get_system_stats():
    """Lấy CPU / RAM / Disk bằng lệnh hệ thống (tương thích Termux)"""
    stats = {
        "cpu": 0.0,
        "ram_used": 0.0,
        "ram_total": 0.0,
        "ram_percent": 0.0,
        "disk_used": 0.0,
        "disk_total": 0.0,
        "disk_percent": 0.0,
    }
    try:
        # RAM
        out = subprocess.check_output(["free", "-m"], text=True)
        for line in out.splitlines():
            if line.startswith("Mem:"):
                parts = line.split()
                total = float(parts[1])
                used = float(parts[2])
                stats["ram_total"] = round(total / 1024, 2)
                stats["ram_used"] = round(used / 1024, 2)
                stats["ram_percent"] = round((used / total) * 100, 1) if total > 0 else 0
                break
    except Exception:
        pass

    try:
        # Disk
        out = subprocess.check_output(["df", "-B1", "."], text=True)
        lines = out.strip().splitlines()
        if len(lines) >= 2:
            parts = lines[1].split()
            total = float(parts[1])
            used = float(parts[2])
            stats["disk_total"] = round(total / (1024**3), 2)
            stats["disk_used"] = round(used / (1024**3), 2)
            stats["disk_percent"] = round((used / total) * 100, 1) if total > 0 else 0
    except Exception:
        pass

    try:
        # CPU (dùng load average 1 phút * số core gần đúng)
        with open("/proc/loadavg") as f:
            load1 = float(f.read().split()[0])
        # Ước lượng % (load1 / số core * 100), giới hạn 100
        cores = os.cpu_count() or 4
        cpu = min(100.0, round((load1 / cores) * 100, 1))
        stats["cpu"] = cpu
    except Exception:
        stats["cpu"] = 0.0

    return stats

@app.route("/")
def index():
    if not check_auth():
        return ("Unauthorized", 401, {"WWW-Authenticate": 'Basic realm="MC Web Control"'})
    return render_template("index.html")

@app.route("/api/status")
@require_auth
def api_status():
    running, pid = is_server_running()
    stats = get_system_stats()
    ip = get_local_ip()
    return jsonify({
        "running": running,
        "pid": pid,
        "stats": stats,
        "ip": ip,
        "java_port": MC_PORT,
        "bedrock_port": BEDROCK_PORT,
        "java_address": f"{ip}:{MC_PORT}",
        "bedrock_address": f"{ip}:{BEDROCK_PORT}",
        "time": datetime.now().strftime("%H:%M:%S %d/%m/%Y")
    })

@app.route("/api/start", methods=["POST"])
@require_auth
def api_start():
    ok, msg = start_server()
    return jsonify({"success": ok, "message": msg})

@app.route("/api/stop", methods=["POST"])
@require_auth
def api_stop():
    ok, msg = stop_server()
    return jsonify({"success": ok, "message": msg})

@app.route("/api/restart", methods=["POST"])
@require_auth
def api_restart():
    stop_server()
    time.sleep(2)
    ok, msg = start_server()
    return jsonify({"success": ok, "message": "Restart: " + msg})

@app.route("/api/reset", methods=["POST"])
@require_auth
def api_reset():
    stop_server()
    time.sleep(1.5)
    try:
        import shutil
        for name in ["world", "world_nether", "world_the_end"]:
            path = os.path.join(MC_DIR, name)
            if os.path.exists(path):
                shutil.rmtree(path)
        ok, msg = start_server()
        return jsonify({"success": ok, "message": "Đã reset world + " + msg})
    except Exception as e:
        return jsonify({"success": False, "message": str(e)})

@app.route("/api/cmd", methods=["POST"])
@require_auth
def api_cmd():
    data = request.get_json() or {}
    command = data.get("command", "").strip()
    if not command:
        return jsonify({"error": "empty command"}), 400
    try:
        with MCRcon(RCON_HOST, RCON_PASS, port=RCON_PORT) as m:
            resp = m.command(command)
        return jsonify({"response": resp or "(không có phản hồi)"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

def tail_file(path, lines=250):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            block = 1024
            data = b""
            while len(data.splitlines()) <= lines and size > 0:
                read_size = min(block, size)
                f.seek(size - read_size)
                data = f.read(read_size) + data
                size -= read_size
            text = data.decode("utf-8", errors="ignore")
            return "\n".join(text.splitlines()[-lines:])
    except FileNotFoundError:
        return "Chưa có log (server chưa chạy hoặc chưa tạo log)."
    except Exception as e:
        return f"Lỗi đọc log: {e}"

@app.route("/api/logs")
@require_auth
def api_logs():
    lines = int(request.args.get("lines", 250))
    return jsonify({"logs": tail_file(LOG_PATH, lines)})

if __name__ == "__main__":
    print(f"Web UI đang chạy tại http://{WEB_BIND}:{WEB_PORT}")
    app.run(host=WEB_BIND, port=WEB_PORT, debug=False)
PY

# ==================== templates/index.html ====================
cat > templates/index.html <<'HTML'
<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0"/>
  <title>MC Server Control</title>
  <style>
    :root {
      --bg: #0c0c0f;
      --card: #16161a;
      --border: #2a2a32;
      --text: #e4e4e7;
      --muted: #a1a1aa;
      --accent: #4ade80;
      --accent-dim: #22c55e;
      --danger: #f87171;
      --warning: #fbbf24;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
      min-height: 100vh;
      padding: 12px;
    }
    .container { max-width: 1100px; margin: 0 auto; }
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 20px;
      flex-wrap: wrap;
      gap: 12px;
    }
    h1 { font-size: 1.5rem; font-weight: 700; display: flex; align-items: center; gap: 10px; }
    .status-badge {
      font-size: 0.85rem;
      padding: 4px 12px;
      border-radius: 999px;
      font-weight: 600;
    }
    .online { background: rgba(74, 222, 128, 0.15); color: var(--accent); }
    .offline { background: rgba(248, 113, 113, 0.15); color: var(--danger); }

    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 16px;
      margin-bottom: 20px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 18px;
    }
    .card h3 {
      font-size: 0.95rem;
      color: var(--muted);
      margin-bottom: 14px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }

    .btn-group { display: flex; flex-wrap: wrap; gap: 8px; }
    button {
      border: none;
      border-radius: 10px;
      padding: 10px 16px;
      font-weight: 600;
      font-size: 0.9rem;
      cursor: pointer;
      transition: all 0.15s;
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    button:active { transform: scale(0.97); }
    .btn-start { background: var(--accent); color: #052e16; }
    .btn-start:hover { background: var(--accent-dim); }
    .btn-stop { background: var(--danger); color: #450a0a; }
    .btn-restart { background: var(--warning); color: #422006; }
    .btn-reset { background: #a78bfa; color: #2e1065; }
    .btn-secondary { background: #27272a; color: var(--text); border: 1px solid var(--border); }

    .stat-row {
      display: flex;
      justify-content: space-between;
      margin-bottom: 6px;
      font-size: 0.9rem;
    }
    .progress {
      height: 8px;
      background: #27272a;
      border-radius: 99px;
      overflow: hidden;
      margin-bottom: 14px;
    }
    .progress-bar {
      height: 100%;
      border-radius: 99px;
      transition: width 0.4s ease;
    }
    .bar-cpu { background: linear-gradient(90deg, #60a5fa, #3b82f6); }
    .bar-ram { background: linear-gradient(90deg, #4ade80, #22c55e); }
    .bar-disk { background: linear-gradient(90deg, #fbbf24, #f59e0b); }

    .addr-box {
      background: #0f0f12;
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px;
      margin-bottom: 10px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 10px;
    }
    .addr-box code {
      font-family: ui-monospace, monospace;
      font-size: 0.95rem;
      word-break: break-all;
    }
    .copy-btn {
      background: #27272a;
      color: var(--accent);
      padding: 6px 12px;
      font-size: 0.8rem;
      white-space: nowrap;
    }

    .console-card { grid-column: 1 / -1; }
    #log {
      background: #0a0a0c;
      border: 1px solid var(--border);
      border-radius: 10px;
      height: 320px;
      overflow-y: auto;
      padding: 12px;
      font-family: ui-monospace, monospace;
      font-size: 0.82rem;
      line-height: 1.45;
      white-space: pre-wrap;
      color: #d4d4d8;
    }
    .cmd-form {
      display: flex;
      gap: 8px;
      margin-top: 12px;
    }
    .cmd-form input {
      flex: 1;
      background: #0f0f12;
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px 14px;
      color: var(--text);
      font-size: 0.95rem;
      outline: none;
    }
    .cmd-form input:focus { border-color: var(--accent); }
    .cmd-form button {
      background: var(--accent);
      color: #052e16;
      padding: 0 20px;
    }

    .toast {
      position: fixed;
      bottom: 24px;
      left: 50%;
      transform: translateX(-50%);
      background: #27272a;
      border: 1px solid var(--border);
      color: var(--text);
      padding: 12px 20px;
      border-radius: 12px;
      font-size: 0.9rem;
      z-index: 999;
      opacity: 0;
      transition: opacity 0.3s;
      pointer-events: none;
    }
    .toast.show { opacity: 1; }

    footer {
      text-align: center;
      color: var(--muted);
      font-size: 0.8rem;
      margin-top: 24px;
      padding-bottom: 20px;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>⛏ MC Server Control</h1>
      <div id="statusBadge" class="status-badge offline">● Offline</div>
    </header>

    <div class="grid">
      <div class="card">
        <h3>Điều khiển Server</h3>
        <div class="btn-group">
          <button class="btn-start" onclick="action('start')">▶ Bật</button>
          <button class="btn-stop" onclick="action('stop')">⏹ Tắt</button>
          <button class="btn-restart" onclick="action('restart')">🔄 Restart</button>
          <button class="btn-reset" onclick="confirmReset()">💣 Reset World</button>
        </div>
        <p style="margin-top:14px;font-size:0.85rem;color:var(--muted)" id="pidInfo">PID: —</p>
      </div>

      <div class="card">
        <h3>Tài nguyên hệ thống</h3>
        <div class="stat-row"><span>CPU</span><span id="cpuText">—%</span></div>
        <div class="progress"><div class="progress-bar bar-cpu" id="cpuBar" style="width:0%"></div></div>

        <div class="stat-row"><span>RAM</span><span id="ramText">— / — GB</span></div>
        <div class="progress"><div class="progress-bar bar-ram" id="ramBar" style="width:0%"></div></div>

        <div class="stat-row"><span>Disk (ROM)</span><span id="diskText">— / — GB</span></div>
        <div class="progress"><div class="progress-bar bar-disk" id="diskBar" style="width:0%"></div></div>
      </div>

      <div class="card">
        <h3>Địa chỉ kết nối</h3>
        <div class="addr-box">
          <div>
            <div style="font-size:0.75rem;color:var(--muted);margin-bottom:2px">Java (PC)</div>
            <code id="javaAddr">—</code>
          </div>
          <button class="copy-btn" onclick="copyText('javaAddr')">Copy</button>
        </div>
        <div class="addr-box">
          <div>
            <div style="font-size:0.75rem;color:var(--muted);margin-bottom:2px">Bedrock (PE / Mobile)</div>
            <code id="bedrockAddr">—</code>
          </div>
          <button class="copy-btn" onclick="copyText('bedrockAddr')">Copy</button>
        </div>
      </div>
    </div>

    <div class="card console-card">
      <h3>Console / Log</h3>
      <div id="log">Đang tải log...</div>
      <form class="cmd-form" onsubmit="return sendCmd(event)">
        <input id="cmdInput" type="text" placeholder="Nhập lệnh (vd: say xin chào, list, op Steve...)" autocomplete="off" />
        <button type="submit">Gửi</button>
      </form>
    </div>

    <footer>
      Cập nhật lúc <span id="updateTime">—</span> · Web UI Minecraft Server
    </footer>
  </div>

  <div class="toast" id="toast"></div>

  <script>
    function toast(msg) {
      const el = document.getElementById('toast');
      el.textContent = msg;
      el.classList.add('show');
      setTimeout(() => el.classList.remove('show'), 2800);
    }

    async function action(type) {
      try {
        const res = await fetch(`/api/${type}`, { method: 'POST' });
        const j = await res.json();
        toast(j.message || (j.success ? 'OK' : 'Lỗi'));
        setTimeout(refreshStatus, 800);
      } catch (e) {
        toast('Lỗi kết nối: ' + e.message);
      }
    }

    function confirmReset() {
      if (confirm('Bạn chắc chắn muốn XÓA TOÀN BỘ WORLD và khởi động lại server?\nHành động này không thể hoàn tác!')) {
        action('reset');
      }
    }

    async function sendCmd(e) {
      e.preventDefault();
      const input = document.getElementById('cmdInput');
      const cmd = input.value.trim();
      if (!cmd) return false;
      try {
        const res = await fetch('/api/cmd', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ command: cmd })
        });
        const j = await res.json();
        toast(j.response || j.error || 'Đã gửi');
        input.value = '';
        setTimeout(loadLogs, 400);
      } catch (err) {
        toast('Lỗi: ' + err.message);
      }
      return false;
    }

    function copyText(id) {
      const text = document.getElementById(id).textContent;
      navigator.clipboard.writeText(text).then(() => toast('Đã copy: ' + text));
    }

    async function refreshStatus() {
      try {
        const res = await fetch('/api/status');
        const j = await res.json();

        const badge = document.getElementById('statusBadge');
        if (j.running) {
          badge.textContent = '● Online';
          badge.className = 'status-badge online';
        } else {
          badge.textContent = '● Offline';
          badge.className = 'status-badge offline';
        }

        document.getElementById('pidInfo').textContent = j.pid ? `PID: ${j.pid}` : 'PID: —';

        document.getElementById('cpuText').textContent = j.stats.cpu + '%';
        document.getElementById('cpuBar').style.width = j.stats.cpu + '%';

        document.getElementById('ramText').textContent = `${j.stats.ram_used} / ${j.stats.ram_total} GB`;
        document.getElementById('ramBar').style.width = j.stats.ram_percent + '%';

        document.getElementById('diskText').textContent = `${j.stats.disk_used} / ${j.stats.disk_total} GB`;
        document.getElementById('diskBar').style.width = j.stats.disk_percent + '%';

        document.getElementById('javaAddr').textContent = j.java_address;
        document.getElementById('bedrockAddr').textContent = j.bedrock_address;
        document.getElementById('updateTime').textContent = j.time;
      } catch (e) {
        console.error(e);
      }
    }

    async function loadLogs() {
      try {
        const res = await fetch('/api/logs?lines=300');
        const j = await res.json();
        const el = document.getElementById('log');
        el.textContent = j.logs || '';
        el.scrollTop = el.scrollHeight;
      } catch (e) {}
    }

    refreshStatus();
    loadLogs();
    setInterval(refreshStatus, 4000);
    setInterval(loadLogs, 3500);
  </script>
</body>
</html>
HTML

# Cài package
echo "Cài Python packages..."
pip3 install --upgrade pip >/dev/null 2>&1 || true
pip3 install -r requirements.txt --no-cache-dir

# Biến môi trường
export RCON_PASS="${RCON_PASS}"
export RCON_HOST="127.0.0.1"
export RCON_PORT="${RCON_PORT}"
export ADMIN_USER="${ADMIN_USER}"
export ADMIN_PASS="${ADMIN_PASS}"
export WEB_BIND="${WEB_BIND}"
export WEB_PORT="${WEB_PORT}"
export MC_PORT="${MC_PORT}"
export BEDROCK_PORT="${BEDROCK_PORT}"

echo "Khởi động Minecraft server..."
nohup bash ./run.sh > /dev/null 2>&1 &
echo $! > mcserver.pid
sleep 2

echo "Khởi động Web UI..."
nohup python3 webui.py > webui.log 2>&1 &
echo $! > webui.pid

IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

echo ""
echo "=============================================="
echo "  HOÀN TẤT THIẾT LẬP (không dùng psutil)"
echo "=============================================="
echo "Minecraft Java   : ${IP_ADDR}:${MC_PORT}"
echo "Minecraft Bedrock: ${IP_ADDR}:${BEDROCK_PORT}"
echo ""
echo "Web UI           : http://${IP_ADDR}:${WEB_PORT}"
echo "Tài khoản Web    : ${ADMIN_USER}"
echo "Mật khẩu Web     : ${ADMIN_PASS}"
echo ""
echo "RCON Password    : ${RCON_PASS}"
echo "=============================================="
echo "Logs server : $MC_DIR/logs/latest.log"
echo "Logs webui  : $MC_DIR/webui.log"
echo "=============================================="
