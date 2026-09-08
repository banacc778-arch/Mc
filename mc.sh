#!/bin/bash
set -euo pipefail

MC_DIR="$HOME/mc-server"
JAVA_MIN=1024M
JAVA_MAX=1536M
MC_PORT=25565
BEDROCK_PORT=19132
RCON_PORT=25575
WEB_BIND="0.0.0.0"
WEB_PORT=8080

echo "==> Đang cài Minecraft Server + Web UI (Không cần đăng nhập)..."

termux-setup-storage || true
pkg update -y && pkg upgrade -y
pkg install -y wget openjdk-25 curl python

mkdir -p "$MC_DIR"
cd "$MC_DIR"

# run.sh
cat > run.sh << 'SH'
#!/bin/bash
set -e
JAVA_MIN="${JAVA_MIN:-1024M}"
JAVA_MAX="${JAVA_MAX:-1536M}"
cd "$(dirname "$0")"
mkdir -p logs
exec java -Xmx${JAVA_MAX} -Xms${JAVA_MIN} -jar server.jar nogui >> logs/latest.log 2>&1
SH
chmod +x run.sh

echo "==> Tải server.jar..."
wget -q -O server.jar https://api.purpurmc.org/v2/purpur/26.2/latest/download

mkdir -p plugins
wget -q -O plugins/Geyser-Spigot.jar https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot || true
wget -q -O plugins/Floodgate-Spigot.jar https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot || true

VV_URL=$(curl -s https://api.github.com/repos/ViaVersion/ViaVersion/releases/latest | grep "browser_download_url" | grep -v "fabric\|sources\|javadoc" | grep '\.jar"' | cut -d '"' -f4 | head -n1 || true)
[ -n "$VV_URL" ] && wget -q -O plugins/ViaVersion.jar "$VV_URL" || true
VB_URL=$(curl -s https://api.github.com/repos/ViaVersion/ViaBackwards/releases/latest | grep "browser_download_url" | grep -v "fabric\|sources\|javadoc" | grep '\.jar"' | cut -d '"' -f4 | head -n1 || true)
[ -n "$VB_URL" ] && wget -q -O plugins/ViaBackwards.jar "$VB_URL" || true

echo "eula=true" > eula.txt

generate_pass() {
  tr -dc 'A-Za-z0-9_!@#%&' < /dev/urandom | head -c 16 || echo "McRcon2026"
}
RCON_PASS=$(generate_pass)

cat > server.properties << EOF
online-mode=false
server-port=${MC_PORT}
gamemode=survival
difficulty=normal
max-players=20
motd=Minecraft Server
allow-flight=false
pvp=true
generate-structures=true
spawn-protection=16
enable-rcon=true
rcon.port=${RCON_PORT}
rcon.password=${RCON_PASS}
EOF

mkdir -p plugins/Geyser-Spigot plugins/floodgate logs templates
cat > plugins/Geyser-Spigot/config.yml << 'YML'
bedrock:
  port: 19132
  address: "0.0.0.0"
java:
  address: localhost
  port: 25565
auth-type: floodgate
YML
cat > plugins/floodgate/config.yml << 'YML'
username-prefix: "."
YML

cat > requirements.txt << 'REQ'
flask
mcrcon
REQ

# ====================== webui.py (KHÔNG CÓ LOGIN) ======================
cat > webui.py << 'PY'
#!/usr/bin/env python3
import os, subprocess, time, signal, shutil
from datetime import datetime
from flask import Flask, render_template, request, jsonify
from werkzeug.utils import secure_filename

try:
    from mcrcon import MCRcon
except:
    raise SystemExit("pip3 install -r requirements.txt")

app = Flask(__name__, template_folder="templates")

MC_DIR = os.getcwd()
RCON_HOST = "127.0.0.1"
RCON_PORT = int(os.environ.get("RCON_PORT", 25575))
RCON_PASS = os.environ.get("RCON_PASS", "")
LOG_PATH = os.path.join(MC_DIR, "logs", "latest.log")
PID_FILE = os.path.join(MC_DIR, "mcserver.pid")
WEB_BIND = os.environ.get("WEB_BIND", "0.0.0.0")
WEB_PORT = int(os.environ.get("WEB_PORT", 8080))
MC_PORT = int(os.environ.get("MC_PORT", 25565))
BEDROCK_PORT = int(os.environ.get("BEDROCK_PORT", 19132))

def get_local_ip():
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        try:
            return subprocess.check_output(["hostname", "-I"], text=True).split()[0]
        except:
            return "127.0.0.1"

def is_running():
    if not os.path.exists(PID_FILE):
        return False, None
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True, pid
    except:
        if os.path.exists(PID_FILE):
            try: os.remove(PID_FILE)
            except: pass
        return False, None

def start_server():
    if is_running()[0]:
        return False, "Server đang chạy"
    try:
        proc = subprocess.Popen(["bash", "run.sh"], cwd=MC_DIR,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        with open(PID_FILE, "w") as f:
            f.write(str(proc.pid))
        time.sleep(2)
        return True, f"Đã bật (PID {proc.pid})"
    except Exception as e:
        return False, str(e)

def stop_server():
    running, pid = is_running()
    if not running:
        return False, "Server không chạy"
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(2)
        try:
            os.kill(pid, 0)
            os.kill(pid, signal.SIGKILL)
        except: pass
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)
        return True, "Đã tắt server"
    except Exception as e:
        return False, str(e)

def get_stats():
    stats = {"cpu": 0, "ram_used": 0, "ram_total": 0, "ram_percent": 0,
             "disk_used": 0, "disk_total": 0, "disk_percent": 0}
    try:
        out = subprocess.check_output(["free", "-m"], text=True)
        for line in out.splitlines():
            if line.startswith("Mem:"):
                p = line.split()
                total, used = float(p[1]), float(p[2])
                stats["ram_total"] = round(total/1024, 2)
                stats["ram_used"] = round(used/1024, 2)
                stats["ram_percent"] = round(used/total*100, 1)
                break
    except: pass
    try:
        out = subprocess.check_output(["df", "-B1", "."], text=True).splitlines()
        if len(out) >= 2:
            p = out[1].split()
            total, used = float(p[1]), float(p[2])
            stats["disk_total"] = round(total/(1024**3), 2)
            stats["disk_used"] = round(used/(1024**3), 2)
            stats["disk_percent"] = round(used/total*100, 1)
    except: pass
    try:
        with open("/proc/loadavg") as f:
            load = float(f.read().split()[0])
        cores = os.cpu_count() or 4
        stats["cpu"] = min(100.0, round(load / cores * 100, 1))
    except: pass
    return stats

def rcon_cmd(cmd):
    try:
        with MCRcon(RCON_HOST, RCON_PASS, port=RCON_PORT) as m:
            return m.command(cmd) or ""
    except Exception as e:
        return f"Lỗi RCON: {e}"

def safe_path(path):
    full = os.path.abspath(os.path.join(MC_DIR, path))
    if not full.startswith(os.path.abspath(MC_DIR)):
        return None
    return full

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/status")
def api_status():
    running, pid = is_running()
    ip = get_local_ip()
    return jsonify({
        "running": running, "pid": pid,
        "stats": get_stats(),
        "java_address": f"{ip}:{MC_PORT}",
        "bedrock_address": f"{ip}:{BEDROCK_PORT}",
        "time": datetime.now().strftime("%H:%M:%S %d/%m/%Y")
    })

@app.route("/api/start", methods=["POST"])
def api_start():
    ok, msg = start_server()
    return jsonify({"success": ok, "message": msg})

@app.route("/api/stop", methods=["POST"])
def api_stop():
    ok, msg = stop_server()
    return jsonify({"success": ok, "message": msg})

@app.route("/api/restart", methods=["POST"])
def api_restart():
    stop_server()
    time.sleep(2)
    ok, msg = start_server()
    return jsonify({"success": ok, "message": "Restart: " + msg})

@app.route("/api/reset", methods=["POST"])
def api_reset():
    stop_server()
    time.sleep(1)
    try:
        for name in ["world", "world_nether", "world_the_end"]:
            p = os.path.join(MC_DIR, name)
            if os.path.exists(p):
                shutil.rmtree(p)
        ok, msg = start_server()
        return jsonify({"success": ok, "message": "Reset xong + " + msg})
    except Exception as e:
        return jsonify({"success": False, "message": str(e)})

@app.route("/api/cmd", methods=["POST"])
def api_cmd():
    data = request.get_json() or {}
    cmd = data.get("command", "").strip()
    if not cmd:
        return jsonify({"error": "empty"}), 400
    return jsonify({"response": rcon_cmd(cmd)})

@app.route("/api/players")
def api_players():
    resp = rcon_cmd("list")
    players = []
    count = 0
    try:
        if ":" in resp:
            names = resp.split(":")[-1].strip()
            if names and names.lower() not in ["", "none"]:
                players = [n.strip() for n in names.split(",") if n.strip()]
                count = len(players)
    except: pass
    return jsonify({"count": count, "players": players, "raw": resp})

@app.route("/api/op", methods=["POST"])
def api_op():
    data = request.get_json() or {}
    name = data.get("player", "").strip()
    if not name: return jsonify({"error": "Thiếu tên"}), 400
    return jsonify({"response": rcon_cmd(f"op {name}")})

@app.route("/api/deop", methods=["POST"])
def api_deop():
    data = request.get_json() or {}
    name = data.get("player", "").strip()
    if not name: return jsonify({"error": "Thiếu tên"}), 400
    return jsonify({"response": rcon_cmd(f"deop {name}")})

@app.route("/api/maxplayers", methods=["POST"])
def api_maxplayers():
    data = request.get_json() or {}
    try:
        num = int(data.get("max", 20))
        if num < 1 or num > 200:
            return jsonify({"error": "1-200 thôi"}), 400
    except:
        return jsonify({"error": "Số không hợp lệ"}), 400

    props = os.path.join(MC_DIR, "server.properties")
    lines = []
    if os.path.exists(props):
        with open(props) as f: lines = f.readlines()
    new_lines, found = [], False
    for line in lines:
        if line.startswith("max-players="):
            new_lines.append(f"max-players={num}\n")
            found = True
        else:
            new_lines.append(line)
    if not found:
        new_lines.append(f"max-players={num}\n")
    with open(props, "w") as f: f.writelines(new_lines)

    stop_server()
    time.sleep(1.5)
    ok, msg = start_server()
    return jsonify({"success": True, "message": f"Đã đặt max-players={num} và restart"})

@app.route("/api/logs")
def api_logs():
    lines = int(request.args.get("lines", 250))
    try:
        with open(LOG_PATH, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            data = b""
            while len(data.splitlines()) <= lines and size > 0:
                read = min(1024, size)
                f.seek(size - read)
                data = f.read(read) + data
                size -= read
            text = data.decode("utf-8", errors="ignore")
            return jsonify({"logs": "\n".join(text.splitlines()[-lines:])})
    except FileNotFoundError:
        return jsonify({"logs": "Chưa có log"})
    except Exception as e:
        return jsonify({"logs": str(e)})

# ========== FILE MANAGER ==========
@app.route("/api/files")
def api_files():
    rel = request.args.get("path", "").strip("/")
    full = safe_path(rel)
    if full is None or not os.path.isdir(full):
        return jsonify({"error": "Đường dẫn không hợp lệ"}), 400
    items = []
    try:
        for name in sorted(os.listdir(full)):
            p = os.path.join(full, name)
            items.append({
                "name": name,
                "is_dir": os.path.isdir(p),
                "size": os.path.getsize(p) if os.path.isfile(p) else 0,
                "path": os.path.join(rel, name).replace("\\", "/").strip("/")
            })
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return jsonify({"path": rel, "items": items})

@app.route("/api/file/read")
def api_file_read():
    rel = request.args.get("path", "").strip("/")
    full = safe_path(rel)
    if full is None or not os.path.isfile(full):
        return jsonify({"error": "File không tồn tại"}), 400
    try:
        if os.path.getsize(full) > 2*1024*1024:
            return jsonify({"error": "File quá lớn (>2MB)"}), 400
        with open(full, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        return jsonify({"path": rel, "content": content})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/file/save", methods=["POST"])
def api_file_save():
    data = request.get_json() or {}
    rel = data.get("path", "").strip("/")
    content = data.get("content", "")
    full = safe_path(rel)
    if full is None:
        return jsonify({"error": "Đường dẫn không hợp lệ"}), 400
    try:
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(content)
        return jsonify({"success": True, "message": "Đã lưu"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/file/delete", methods=["POST"])
def api_file_delete():
    data = request.get_json() or {}
    rel = data.get("path", "").strip("/")
    full = safe_path(rel)
    if full is None or full == os.path.abspath(MC_DIR):
        return jsonify({"error": "Không được xóa thư mục gốc"}), 400
    try:
        if os.path.isdir(full):
            shutil.rmtree(full)
        else:
            os.remove(full)
        return jsonify({"success": True, "message": "Đã xóa"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/file/upload", methods=["POST"])
def api_file_upload():
    if "file" not in request.files:
        return jsonify({"error": "Không có file"}), 400
    f = request.files["file"]
    rel_dir = request.form.get("path", "").strip("/")
    full_dir = safe_path(rel_dir) if rel_dir else MC_DIR
    if full_dir is None or not os.path.isdir(full_dir):
        return jsonify({"error": "Thư mục không hợp lệ"}), 400
    filename = secure_filename(f.filename)
    if not filename:
        return jsonify({"error": "Tên file không hợp lệ"}), 400
    try:
        f.save(os.path.join(full_dir, filename))
        return jsonify({"success": True, "message": f"Đã upload {filename}"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/file/new", methods=["POST"])
def api_file_new():
    data = request.get_json() or {}
    rel = data.get("path", "").strip("/")
    name = data.get("name", "").strip()
    is_dir = data.get("is_dir", False)
    if not name:
        return jsonify({"error": "Thiếu tên"}), 400
    full = safe_path(os.path.join(rel, name))
    if full is None:
        return jsonify({"error": "Đường dẫn không hợp lệ"}), 400
    try:
        if is_dir:
            os.makedirs(full, exist_ok=True)
        else:
            os.makedirs(os.path.dirname(full), exist_ok=True)
            open(full, "a").close()
        return jsonify({"success": True, "message": "Đã tạo"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    print(f"Web UI: http://{WEB_BIND}:{WEB_PORT}")
    app.run(host=WEB_BIND, port=WEB_PORT, debug=False)
PY

# ====================== index.html ======================
cat > templates/index.html << 'HTML'
<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MC Server Control</title>
<style>
:root{--bg:#0c0c0f;--card:#16161a;--border:#2a2a32;--text:#e4e4e7;--muted:#a1a1aa;--accent:#4ade80;--danger:#f87171;--warning:#fbbf24;--purple:#a78bfa}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--text);padding:12px;min-height:100vh}
.container{max-width:1200px;margin:0 auto}
header{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;flex-wrap:wrap;gap:10px}
h1{font-size:1.4rem}
.badge{padding:4px 12px;border-radius:99px;font-size:.85rem;font-weight:600}
.online{background:rgba(74,222,128,.15);color:var(--accent)}
.offline{background:rgba(248,113,113,.15);color:var(--danger)}
.tabs{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
.tab{padding:8px 14px;border-radius:10px;background:#27272a;border:none;color:var(--text);cursor:pointer;font-weight:600}
.tab.active{background:var(--accent);color:#052e16}
.panel{display:none}
.panel.active{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px;margin-bottom:16px}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:16px}
.card h3{font-size:.9rem;color:var(--muted);margin-bottom:12px;text-transform:uppercase}
.btn-group{display:flex;flex-wrap:wrap;gap:8px}
button{border:none;border-radius:10px;padding:9px 14px;font-weight:600;cursor:pointer;font-size:.9rem}
.btn-start{background:var(--accent);color:#052e16}
.btn-stop{background:var(--danger);color:#450a0a}
.btn-restart{background:var(--warning);color:#422006}
.btn-reset{background:var(--purple);color:#2e1065}
.btn-sm{padding:5px 10px;font-size:.8rem;background:#27272a;color:var(--text);border:1px solid var(--border)}
.stat-row{display:flex;justify-content:space-between;margin-bottom:4px;font-size:.9rem}
.progress{height:8px;background:#27272a;border-radius:99px;overflow:hidden;margin-bottom:12px}
.bar{height:100%;border-radius:99px;transition:width .3s}
.bar-cpu{background:#3b82f6}.bar-ram{background:#22c55e}.bar-disk{background:#f59e0b}
.addr{background:#0f0f12;border:1px solid var(--border);border-radius:10px;padding:10px;margin-bottom:8px;display:flex;justify-content:space-between;align-items:center;gap:8px}
.addr code{font-family:monospace;font-size:.9rem;word-break:break-all}
#log{background:#0a0a0c;border:1px solid var(--border);border-radius:10px;height:280px;overflow:auto;padding:10px;font-family:monospace;font-size:.8rem;white-space:pre-wrap;color:#d4d4d8}
.cmd-form{display:flex;gap:8px;margin-top:10px}
.cmd-form input{flex:1;background:#0f0f12;border:1px solid var(--border);border-radius:10px;padding:11px;color:var(--text);outline:none}
.cmd-form button{background:var(--accent);color:#052e16;padding:0 18px}
.player-item{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid var(--border)}
.file-list{max-height:320px;overflow:auto}
.file-item{display:flex;justify-content:space-between;align-items:center;padding:8px;border-radius:8px;cursor:pointer}
.file-item:hover{background:#1f1f24}
.file-actions{display:flex;gap:6px}
#editor{width:100%;height:340px;background:#0a0a0c;border:1px solid var(--border);border-radius:10px;color:#e4e4e7;padding:12px;font-family:monospace;font-size:.85rem;resize:vertical}
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#27272a;border:1px solid var(--border);padding:12px 18px;border-radius:12px;opacity:0;transition:.3s;z-index:99;pointer-events:none}
.toast.show{opacity:1}
.hidden{display:none}
footer{text-align:center;color:var(--muted);font-size:.8rem;margin-top:20px}
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>⛏ MC Server Control</h1>
    <div id="badge" class="badge offline">● Offline</div>
  </header>

  <div class="tabs">
    <button class="tab active" onclick="showTab('dash')">Dashboard</button>
    <button class="tab" onclick="showTab('players')">Người chơi</button>
    <button class="tab" onclick="showTab('console')">Console</button>
    <button class="tab" onclick="showTab('files')">Files</button>
    <button class="tab" onclick="showTab('settings')">Cài đặt</button>
  </div>

  <div id="dash" class="panel active">
    <div class="grid">
      <div class="card">
        <h3>Điều khiển</h3>
        <div class="btn-group">
          <button class="btn-start" onclick="act('start')">▶ Bật</button>
          <button class="btn-stop" onclick="act('stop')">⏹ Tắt</button>
          <button class="btn-restart" onclick="act('restart')">🔄 Restart</button>
          <button class="btn-reset" onclick="if(confirm('Xóa toàn bộ world?'))act('reset')">💣 Reset</button>
        </div>
        <p style="margin-top:12px;font-size:.85rem;color:var(--muted)" id="pid">PID: —</p>
      </div>
      <div class="card">
        <h3>Tài nguyên</h3>
        <div class="stat-row"><span>CPU</span><span id="cpuT">—%</span></div>
        <div class="progress"><div class="bar bar-cpu" id="cpuB" style="width:0%"></div></div>
        <div class="stat-row"><span>RAM</span><span id="ramT">—</span></div>
        <div class="progress"><div class="bar bar-ram" id="ramB" style="width:0%"></div></div>
        <div class="stat-row"><span>Disk</span><span id="diskT">—</span></div>
        <div class="progress"><div class="bar bar-disk" id="diskB" style="width:0%"></div></div>
      </div>
      <div class="card">
        <h3>Địa chỉ kết nối</h3>
        <div class="addr"><div><small style="color:var(--muted)">Java (PC)</small><br><code id="javaA">—</code></div>
          <button class="btn-sm" onclick="copy('javaA')">Copy</button></div>
        <div class="addr"><div><small style="color:var(--muted)">Bedrock (PE)</small><br><code id="bedA">—</code></div>
          <button class="btn-sm" onclick="copy('bedA')">Copy</button></div>
      </div>
    </div>
  </div>

  <div id="players" class="panel">
    <div class="card">
      <h3>Người chơi online: <span id="pCount">0</span></h3>
      <div id="playerList"></div>
      <div style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap">
        <input id="opName" placeholder="Tên người chơi" style="flex:1;min-width:140px;background:#0f0f12;border:1px solid var(--border);border-radius:10px;padding:10px;color:var(--text)">
        <button class="btn-start" onclick="doOp()">OP</button>
        <button class="btn-stop" onclick="doDeop()">DeOP</button>
      </div>
    </div>
  </div>

  <div id="console" class="panel">
    <div class="card">
      <h3>Console / Log</h3>
      <div id="log">Đang tải...</div>
      <form class="cmd-form" onsubmit="return sendCmd(event)">
        <input id="cmd" placeholder="Nhập lệnh (list, say hello, op Steve...)" autocomplete="off">
        <button type="submit">Gửi</button>
      </form>
    </div>
  </div>

  <div id="files" class="panel">
    <div class="card">
      <h3>Quản lý File — <span id="curPath">/</span></h3>
      <div style="margin-bottom:10px;display:flex;gap:8px;flex-wrap:wrap">
        <button class="btn-sm" onclick="loadFiles('')">Root</button>
        <button class="btn-sm" onclick="goUp()">↑ Lên</button>
        <button class="btn-sm" onclick="newFile(false)">+ File</button>
        <button class="btn-sm" onclick="newFile(true)">+ Folder</button>
        <label class="btn-sm" style="cursor:pointer">Upload
          <input type="file" id="upFile" class="hidden" onchange="uploadFile()">
        </label>
      </div>
      <div class="file-list" id="fileList"></div>
    </div>
    <div class="card" style="margin-top:14px">
      <h3>Editor — <span id="editPath">Chưa chọn file</span></h3>
      <textarea id="editor" placeholder="Chọn file để xem / sửa..."></textarea>
      <div style="margin-top:10px">
        <button class="btn-start" onclick="saveFile()">💾 Lưu</button>
      </div>
    </div>
  </div>

  <div id="settings" class="panel">
    <div class="card">
      <h3>Cài đặt Server</h3>
      <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
        <label>Max Players:</label>
        <input id="maxP" type="number" min="1" max="200" value="20" style="width:90px;background:#0f0f12;border:1px solid var(--border);border-radius:10px;padding:10px;color:var(--text)">
        <button class="btn-start" onclick="setMax()">Lưu & Restart</button>
      </div>
    </div>
  </div>

  <footer>Cập nhật: <span id="time">—</span></footer>
</div>
<div class="toast" id="toast"></div>

<script>
let currentPath = "";
let editingPath = "";

function toast(m){const t=document.getElementById('toast');t.textContent=m;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2800)}
function showTab(id){
  document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  event.target.classList.add('active');
  if(id==='players') loadPlayers();
  if(id==='files') loadFiles(currentPath);
  if(id==='console') loadLogs();
}
async function act(type){
  const r=await fetch('/api/'+type,{method:'POST'});
  const j=await r.json();
  toast(j.message||'OK');
  setTimeout(refresh,800);
}
function copy(id){navigator.clipboard.writeText(document.getElementById(id).textContent).then(()=>toast('Đã copy'))}

async function refresh(){
  try{
    const r=await fetch('/api/status');const j=await r.json();
    const b=document.getElementById('badge');
    b.textContent=j.running?'● Online':'● Offline';
    b.className='badge '+(j.running?'online':'offline');
    document.getElementById('pid').textContent=j.pid?`PID: ${j.pid}`:'PID: —';
    document.getElementById('cpuT').textContent=j.stats.cpu+'%';
    document.getElementById('cpuB').style.width=j.stats.cpu+'%';
    document.getElementById('ramT').textContent=`${j.stats.ram_used} / ${j.stats.ram_total} GB`;
    document.getElementById('ramB').style.width=j.stats.ram_percent+'%';
    document.getElementById('diskT').textContent=`${j.stats.disk_used} / ${j.stats.disk_total} GB`;
    document.getElementById('diskB').style.width=j.stats.disk_percent+'%';
    document.getElementById('javaA').textContent=j.java_address;
    document.getElementById('bedA').textContent=j.bedrock_address;
    document.getElementById('time').textContent=j.time;
  }catch(e){}
}

async function loadPlayers(){
  const r=await fetch('/api/players');const j=await r.json();
  document.getElementById('pCount').textContent=j.count;
  const box=document.getElementById('playerList');
  if(!j.players.length){box.innerHTML='<p style="color:var(--muted)">Không có ai online</p>';return}
  box.innerHTML=j.players.map(p=>`<div class="player-item"><span>${p}</span>
    <div><button class="btn-sm" onclick="opPlayer('${p}')">OP</button>
    <button class="btn-sm" onclick="deopPlayer('${p}')">DeOP</button></div></div>`).join('');
}
async function opPlayer(n){const r=await fetch('/api/op',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({player:n})});const j=await r.json();toast(j.response||j.error);loadPlayers()}
async function deopPlayer(n){const r=await fetch('/api/deop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({player:n})});const j=await r.json();toast(j.response||j.error);loadPlayers()}
async function doOp(){const n=document.getElementById('opName').value.trim();if(n)opPlayer(n)}
async function doDeop(){const n=document.getElementById('opName').value.trim();if(n)deopPlayer(n)}

async function sendCmd(e){
  e.preventDefault();
  const cmd=document.getElementById('cmd').value.trim();
  if(!cmd)return false;
  const r=await fetch('/api/cmd',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({command:cmd})});
  const j=await r.json();
  toast(j.response||j.error||'Đã gửi');
  document.getElementById('cmd').value='';
  setTimeout(loadLogs,500);
  return false;
}
async function loadLogs(){
  try{
    const r=await fetch('/api/logs?lines=300');const j=await r.json();
    const el=document.getElementById('log');el.textContent=j.logs||'';el.scrollTop=el.scrollHeight;
  }catch(e){}
}

async function setMax(){
  const num=document.getElementById('maxP').value;
  const r=await fetch('/api/maxplayers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({max:num})});
  const j=await r.json();
  toast(j.message||j.error);
}

async function loadFiles(path){
  currentPath=path||'';
  document.getElementById('curPath').textContent='/'+(currentPath||'');
  const r=await fetch('/api/files?path='+encodeURIComponent(currentPath));
  const j=await r.json();
  if(j.error){toast(j.error);return}
  const box=document.getElementById('fileList');
  if(!j.items.length){box.innerHTML='<p style="color:var(--muted)">Thư mục trống</p>';return}
  box.innerHTML=j.items.map(it=>{
    const icon=it.is_dir?'📁':'📄';
    const size=it.is_dir?'':` (${(it.size/1024).toFixed(1)} KB)`;
    return `<div class="file-item">
      <span onclick="${it.is_dir?`loadFiles('${it.path}')`:`openFile('${it.path}')`}">${icon} ${it.name}${size}</span>
      <div class="file-actions">
        ${!it.is_dir?`<button class="btn-sm" onclick="openFile('${it.path}')">Sửa</button>`:''}
        <button class="btn-sm" style="color:var(--danger)" onclick="delFile('${it.path}')">Xóa</button>
      </div></div>`;
  }).join('');
}
function goUp(){
  if(!currentPath)return;
  const p=currentPath.split('/').slice(0,-1).join('/');
  loadFiles(p);
}
async function openFile(path){
  const r=await fetch('/api/file/read?path='+encodeURIComponent(path));
  const j=await r.json();
  if(j.error){toast(j.error);return}
  editingPath=path;
  document.getElementById('editPath').textContent=path;
  document.getElementById('editor').value=j.content;
  toast('Đã mở file');
}
async function saveFile(){
  if(!editingPath){toast('Chưa chọn file');return}
  const r=await fetch('/api/file/save',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({path:editingPath,content:document.getElementById('editor').value})});
  const j=await r.json();
  toast(j.message||j.error);
}
async function delFile(path){
  if(!confirm('Xóa '+path+'?'))return;
  const r=await fetch('/api/file/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path})});
  const j=await r.json();
  toast(j.message||j.error);
  loadFiles(currentPath);
}
async function newFile(isDir){
  const name=prompt(isDir?'Tên thư mục:':'Tên file:');
  if(!name)return;
  const r=await fetch('/api/file/new',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({path:currentPath,name,is_dir:isDir})});
  const j=await r.json();
  toast(j.message||j.error);
  loadFiles(currentPath);
}
async function uploadFile(){
  const f=document.getElementById('upFile').files[0];
  if(!f)return;
  const fd=new FormData();
  fd.append('file',f);
  fd.append('path',currentPath);
  const r=await fetch('/api/file/upload',{method:'POST',body:fd});
  const j=await r.json();
  toast(j.message||j.error);
  document.getElementById('upFile').value='';
  loadFiles(currentPath);
}

refresh();
setInterval(refresh,5000);
setInterval(()=>{if(document.getElementById('console').classList.contains('active'))loadLogs()},4000);
setInterval(()=>{if(document.getElementById('players').classList.contains('active'))loadPlayers()},6000);
</script>
</body>
</html>
HTML

# Cài package + chạy
echo "==> Cài Python packages..."
pip3 install --upgrade pip >/dev/null 2>&1 || true
pip3 install -r requirements.txt --no-cache-dir

export RCON_PASS="$RCON_PASS"
export RCON_PORT="$RCON_PORT"
export WEB_BIND="$WEB_BIND"
export WEB_PORT="$WEB_PORT"
export MC_PORT="$MC_PORT"
export BEDROCK_PORT="$BEDROCK_PORT"

echo "==> Khởi động Minecraft server..."
nohup bash ./run.sh >/dev/null 2>&1 &
echo $! > mcserver.pid
sleep 2

echo "==> Khởi động Web UI..."
nohup python3 webui.py > webui.log 2>&1 &
echo $! > webui.pid

IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
echo ""
echo "=============================================="
echo "  CÀI ĐẶT HOÀN TẤT (KHÔNG CẦN ĐĂNG NHẬP)"
echo "=============================================="
echo "Java      : ${IP}:${MC_PORT}"
echo "Bedrock   : ${IP}:${BEDROCK_PORT}"
echo "Web UI    : http://${IP}:${WEB_PORT}"
echo "RCON Pass : ${RCON_PASS}"
echo "=============================================="
echo "Vào Web UI là dùng luôn, không cần nhập tài khoản."
echo "=============================================="
