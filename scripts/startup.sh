#!/bin/bash

# 1. System Updates & Dependencies
# --------------------------------
echo "Starting ComfyUI Setup..."
export DEBIAN_FRONTEND=noninteractive
BOOTSTRAP_MARKER="/var/lib/comfyui-bootstrap.complete"

# GCE runs this startup script on every boot. Once provisioning has completed,
# keep Spot-VM recovery fast: systemd restores Tailscale and both services
# without reinstalling drivers, Python packages, or ComfyUI.
if [ -f "$BOOTSTRAP_MARKER" ]; then
    echo "ComfyUI is already provisioned; starting existing services..."
    systemctl start tailscaled
    systemctl start comfyui
    systemctl start comfyui-downloader
    tailscale serve --bg --http=8188 http://127.0.0.1:8188
    exit 0
fi

apt-get update
apt-get install -y curl git python3-venv python3-pip build-essential wget software-properties-common linux-headers-$(uname -r)

# 1a. Private network access through Tailscale
# ---------------------------------------------
# The ComfyUI firewall rule is intentionally removed from Terraform. This VM
# joins the owner's Tailscale network using a key supplied as GCE metadata.
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
METADATA_HEADER="Metadata-Flavor: Google"
TAILSCALE_AUTH_KEY="$(curl -fsS --retry 5 --retry-delay 2 -H "$METADATA_HEADER" "$METADATA_URL/tailscale-auth-key")"
TAILSCALE_HOSTNAME="$(curl -fsS --retry 5 --retry-delay 2 -H "$METADATA_HEADER" "$METADATA_URL/tailscale-hostname")"

if ! tailscale ip -4 >/dev/null 2>&1; then
    if [ -z "$TAILSCALE_AUTH_KEY" ]; then
        echo "ERROR: Tailscale auth key is missing from instance metadata."
        exit 1
    fi

    tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --hostname="$TAILSCALE_HOSTNAME"
fi

# Do not retain the enrollment credential in the shell environment.
unset TAILSCALE_AUTH_KEY

# 2. Install NVIDIA Drivers & CUDA (Debian 12 specific)
# -------------------------------------------------------
echo "Installing NVIDIA Drivers..."

# Add contrib and non-free repositories. Debian's GCE image uses the newer
# deb822 source format, while some Debian images still use sources.list.
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sed -i '/^Components:/ { /non-free/! s/$/ contrib non-free non-free-firmware/ }' /etc/apt/sources.list.d/debian.sources
fi

if [ -f /etc/apt/sources.list ] && ! grep -q "non-free" /etc/apt/sources.list; then
    sed -i 's/deb http:\/\/deb.debian.org\/debian bookworm main/deb http:\/\/deb.debian.org\/debian bookworm main contrib non-free non-free-firmware/' /etc/apt/sources.list
fi

apt-get update

# Try to detect and install an NVIDIA driver plus its diagnostic utility.
apt-get install -y --no-install-recommends nvidia-driver-545 || \
apt-get install -y --no-install-recommends nvidia-driver || \
echo "WARNING: Driver installation may have issues. Will attempt CPU fallback."
apt-get install -y --no-install-recommends libcuda1 nvidia-smi || \
echo "WARNING: NVIDIA CUDA runtime utilities could not be installed. Will attempt CPU fallback."

# A driver installed during this boot needs one reboot before its kernel module
# can be loaded. Reboot once, then continue this first-boot setup normally.
DRIVER_REBOOT_MARKER="/var/lib/comfyui-driver-reboot-attempted"
if command -v nvidia-smi >/dev/null 2>&1 && ! nvidia-smi >/dev/null 2>&1 && [ ! -f "$DRIVER_REBOOT_MARKER" ]; then
    echo "NVIDIA driver installed; rebooting once to load its kernel module..."
    touch "$DRIVER_REBOOT_MARKER"
    systemctl reboot
    exit 0
fi

# Check if GPU is detected
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected:"
    nvidia-smi --query-gpu=name --format=csv,noheader
else
    echo "WARNING: NVIDIA driver not found. ComfyUI will run on CPU."
fi

# 3. Setup ComfyUI Directory & User
# ---------------------------------
# We create a dedicated user for the service for better security and reliability
SERVICE_USER="comfyui"
USER_HOME="/home/$SERVICE_USER"
COMFY_DIR="$USER_HOME/ComfyUI"

# Create the user if it doesn't exist
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "Creating user $SERVICE_USER..."
    useradd -m -s /bin/bash "$SERVICE_USER"
fi

# Ensure home directory permissions
chown -R $SERVICE_USER:$SERVICE_USER $USER_HOME

# 4. Clone ComfyUI
if [ ! -d "$COMFY_DIR" ]; then
    echo "Cloning ComfyUI..."
    sudo -u $SERVICE_USER git clone https://github.com/comfyanonymous/ComfyUI.git $COMFY_DIR
fi

# Install / update Manager in both cases
MANAGER_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Manager"

if [ ! -d "$MANAGER_DIR" ]; then
    echo "Installing ComfyUI-Manager..."
    sudo -u $SERVICE_USER git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$MANAGER_DIR"
else
    echo "Updating ComfyUI-Manager..."
    sudo -u $SERVICE_USER git -C "$MANAGER_DIR" pull
fi

# Ensure proper ownership
chown -R $SERVICE_USER:$SERVICE_USER $COMFY_DIR

# 5. Python Environment & Requirements
# ------------------------------------
echo "Setting up Python Environment..."
cd $COMFY_DIR

# Verify we have requirements.txt
if [ ! -f "requirements.txt" ]; then
    echo "ERROR: requirements.txt not found in $COMFY_DIR"
    exit 1
fi

# Create venv if not exists
if [ ! -d "venv" ]; then
    echo "Creating Python virtual environment..."
    sudo -u $SERVICE_USER python3 -m venv venv
fi

# Install a ComfyUI-compatible PyTorch release with CUDA support. CUDA 11.8 is
# supported by the Debian NVIDIA 535 driver used for the T4 and avoids requiring
# a newer proprietary CUDA driver on every disposable VM.
# Using the full venv pip path avoids activation issues.
echo "Installing PyTorch..."
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install --upgrade pip setuptools wheel
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install --upgrade --force-reinstall \
    torch==2.7.1+cu118 torchvision==0.22.1+cu118 torchaudio==2.7.1+cu118 \
    --index-url https://download.pytorch.org/whl/cu118

# Install ComfyUI requirements
echo "Installing ComfyUI dependencies..."
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install -r requirements.txt
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install flask requests

# The virtual environment now exists, so install Manager dependencies into the
# same environment used by ComfyUI.
echo "Installing ComfyUI-Manager dependencies..."
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install -r "$MANAGER_DIR/requirements.txt" || echo "Warning: Manager deps install failed"

# Permit explicit custom-node installs from Git URLs. ComfyUI is deliberately
# bound to loopback below, which is also required by Manager for this option.
MANAGER_CONFIG_DIR="$COMFY_DIR/user/__manager"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$MANAGER_CONFIG_DIR"
cat <<EOT > "$MANAGER_CONFIG_DIR/config.ini"
[default]
allow_git_url_install = true
allow_pip_install = false
EOT
# install creates missing intermediate directories as root. ComfyUI needs to
# create its default profile, settings, and optional user.css beneath user/.
chown -R "$SERVICE_USER:$SERVICE_USER" "$COMFY_DIR/user"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$COMFY_DIR/user/default/workflows"
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0644 /dev/null "$COMFY_DIR/user/default/user.css"


# 6. Create Systemd Service (Auto-start)
# --------------------------------------
echo "Creating Systemd Service..."

# Determine GPU availability for startup flags
if command -v nvidia-smi &> /dev/null; then
    COMFY_FLAGS="--listen 127.0.0.1 --port 8188 --lowvram"
    echo "GPU detected - ComfyUI will use CUDA acceleration in low-VRAM mode"
else
    COMFY_FLAGS="--listen 127.0.0.1 --port 8188 --cpu"
    echo "No GPU detected - ComfyUI will run in CPU mode (slower)"
fi

cat <<EOT > /etc/systemd/system/comfyui.service
[Unit]
Description=ComfyUI Stable Diffusion Server
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$COMFY_DIR
ExecStart=$COMFY_DIR/venv/bin/python main.py $COMFY_FLAGS
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOT

chmod 644 /etc/systemd/system/comfyui.service

# 7. Start the Service
# --------------------
systemctl daemon-reload
systemctl enable comfyui
systemctl start comfyui

# Keep ComfyUI loopback-only while making the same port available privately to
# devices in this tailnet. Background Serve configuration survives reboots.
tailscale serve --bg --http=8188 http://127.0.0.1:8188

# 8. Setup Custom Model Downloader Service
# ----------------------------------------
echo "Setting up Model Downloader Service..."

DOWNLOADER_SCRIPT="$USER_HOME/model_downloader.py"

# Embed the Python script
cat <<'EOT' > $DOWNLOADER_SCRIPT
import os
import re
import threading
import time
import urllib.parse
from pathlib import Path
import requests
from flask import Flask, request, jsonify, render_template_string, Response

app = Flask(__name__)

# Configuration
COMFY_DIR = Path(os.environ.get("COMFY_DIR", "/home/comfyui/ComfyUI"))
SECRET_TOKEN = os.environ.get("DOWNLOADER_TOKEN", "comfyui_secret_123")
CHUNK_SIZE = 1024 * 1024  # 1MB

active_downloads = {}
downloads_lock = threading.Lock()

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ComfyUI Model Downloader</title>
    <style>
        body { font-family: sans-serif; background-color: #1e1e1e; color: #fff; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .container { background-color: #2d2d2d; padding: 2rem; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); max-width: 600px; width: 100%; text-align: center; }
        h1 { color: #4CAF50; margin-top: 0; }
        .info { text-align: left; margin-bottom: 2rem; padding: 1rem; background-color: #3d3d3d; border-radius: 4px; }
        .info p { margin: 0.5rem 0; word-break: break-all; }
        .progress-container { width: 100%; background-color: #444; border-radius: 4px; margin-bottom: 1rem; overflow: hidden; }
        .progress-bar { width: 0%; height: 24px; background-color: #4CAF50; transition: width 0.3s ease; }
        .status-text { font-size: 1.2rem; font-weight: bold; margin-bottom: 0.5rem; }
        .error { color: #f44336; }
        .success { color: #4CAF50; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Model Downloader</h1>
        
        <div class="info">
            <p><strong>URL:</strong> {{ url }}</p>
            <p><strong>Destination:</strong> {{ rel_path }}/{{ filename }}</p>
        </div>

        {% if error %}
            <div class="status-text error">{{ error }}</div>
        {% elif already_exists %}
            <div class="status-text success">File already exists!</div>
            <p>No download necessary.</p>
        {% else %}
            <div class="status-text" id="status">Starting download...</div>
            <div class="progress-container">
                <div class="progress-bar" id="progressBar"></div>
            </div>
            <div id="details">Waiting for data...</div>
            
            <script>
                const targetPath = "{{ target_path }}";
                const source = new EventSource(`/progress?file=${encodeURIComponent(targetPath)}`);
                
                source.onmessage = function(event) {
                    const data = JSON.parse(event.data);
                    
                    if (data.status === 'downloading') {
                        document.getElementById('progressBar').style.width = data.percent + '%';
                        document.getElementById('status').innerText = `Downloading... ${data.percent.toFixed(1)}%`;
                        
                        const downloadedMB = (data.downloaded / 1024 / 1024).toFixed(1);
                        const totalMB = data.total ? (data.total / 1024 / 1024).toFixed(1) + ' MB' : 'Unknown size';
                        const speedMBps = (data.speed / 1024 / 1024).toFixed(2);
                        
                        document.getElementById('details').innerText = `${downloadedMB} MB / ${totalMB} at ${speedMBps} MB/s`;
                    } else if (data.status === 'completed') {
                        document.getElementById('progressBar').style.width = '100%';
                        document.getElementById('status').innerText = 'Download Complete!';
                        document.getElementById('status').className = 'status-text success';
                        document.getElementById('details').innerText = 'File saved successfully.';
                        source.close();
                    } else if (data.status === 'error') {
                        document.getElementById('status').innerText = `Error: ${data.message}`;
                        document.getElementById('status').className = 'status-text error';
                        source.close();
                    } else if (data.status === 'not_found' || data.status === 'starting') {
                        document.getElementById('status').innerText = 'Initializing connection...';
                    }
                };
            </script>
        {% endif %}
    </div>
</body>
</html>
"""

def extract_filename(response, url):
    cd = response.headers.get('content-disposition') if response else None
    if cd:
        fname = re.findall('filename="?([^"]+)"?', cd)
        if len(fname) > 0: return fname[0]
    parsed = urllib.parse.urlparse(url)
    filename = os.path.basename(parsed.path)
    return filename if filename else "downloaded_model.safetensors"

def download_file(url, target_filepath):
    str_path = str(target_filepath)
    part_filepath = target_filepath.parent / (target_filepath.name + ".part")
    
    with downloads_lock:
        active_downloads[str_path] = {'status': 'starting', 'downloaded': 0, 'total': 0, 'percent': 0, 'speed': 0, 'start_time': time.time()}

    try:
        response = requests.get(url, stream=True, timeout=30)
        response.raise_for_status()
        
        total_size = int(response.headers.get('content-length', 0))
        downloaded = 0
        last_update_time = time.time()
        last_downloaded = 0
        
        with downloads_lock:
            active_downloads[str_path]['total'] = total_size
            active_downloads[str_path]['status'] = 'downloading'

        with open(part_filepath, 'wb') as f:
            for chunk in response.iter_content(chunk_size=CHUNK_SIZE):
                if chunk:
                    f.write(chunk)
                    downloaded += len(chunk)
                    
                    current_time = time.time()
                    if current_time - last_update_time > 0.5:
                        speed = (downloaded - last_downloaded) / (current_time - last_update_time)
                        with downloads_lock:
                            info = active_downloads[str_path]
                            info['downloaded'] = downloaded
                            info['percent'] = (downloaded / total_size * 100) if total_size else 0
                            info['speed'] = speed
                        last_update_time = current_time
                        last_downloaded = downloaded

        os.rename(part_filepath, target_filepath)
        with downloads_lock:
            active_downloads[str_path]['status'] = 'completed'
            active_downloads[str_path]['percent'] = 100

    except Exception as e:
        if part_filepath.exists(): os.remove(part_filepath)
        with downloads_lock:
            active_downloads[str_path]['status'] = 'error'
            active_downloads[str_path]['message'] = str(e)

@app.route("/", methods=["GET"])
def index():
    token = request.args.get('token')
    if not token or token != SECRET_TOKEN:
        return "Unauthorized. Invalid or missing token.", 401

    url = request.args.get('url')
    rel_path_arg = request.args.get('path')

    if not url or not rel_path_arg:
        return "Missing 'url' or 'path' parameters.", 400

    clean_path = os.path.normpath(rel_path_arg)
    if clean_path.startswith('..') or clean_path.startswith('/'):
        return "Invalid path parameter.", 400

    target_dir = COMFY_DIR / clean_path
    
    try:
        resolved_target = target_dir.resolve(strict=False)
        resolved_base = COMFY_DIR.resolve(strict=False)
        if not str(resolved_target).startswith(str(resolved_base)): return "Path resolves outside of ComfyUI directory.", 403
    except Exception as e:
        return f"Path error: {str(e)}", 400

    target_dir.mkdir(parents=True, exist_ok=True)

    try:
        head_resp = requests.head(url, timeout=5, allow_redirects=True)
        if head_resp.status_code == 405: # fallback
            head_resp = requests.get(url, stream=True, timeout=5)
            head_resp.close()
        filename = extract_filename(head_resp, url)
    except Exception:
        filename = extract_filename(None, url)

    target_filepath = target_dir / filename
    str_path = str(target_filepath)
    is_already_exists = target_filepath.exists()
    
    with downloads_lock:
        is_currently_downloading = str_path in active_downloads and active_downloads[str_path]['status'] in ['starting', 'downloading']

    if not is_already_exists and not is_currently_downloading:
        threading.Thread(target=download_file, args=(url, target_filepath), daemon=True).start()

        # Small delay to let thread initialize state before rendering UI
        time.sleep(0.5)

    return render_template_string(
        HTML_TEMPLATE, url=url, rel_path=clean_path, filename=filename, target_path=str_path, already_exists=is_already_exists, error=None
    )

@app.route("/progress")
def progress():
    file_path = request.args.get('file')
    def generate():
        while True:
            with downloads_lock:
                if file_path in active_downloads:
                    info = active_downloads[file_path]
                    import json
                    yield f"data: {json.dumps(info)}\n\n"
                    if info['status'] in ['completed', 'error']: break
                else:
                    yield f"data: {{\"status\": \"not_found\"}}\n\n"
            time.sleep(0.5)
    return Response(generate(), mimetype='text/event-stream')

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8189)
EOT

chown $SERVICE_USER:$SERVICE_USER $DOWNLOADER_SCRIPT
chmod +x $DOWNLOADER_SCRIPT

# Create Systemd Service for the Downloader
cat <<EOT > /etc/systemd/system/comfyui-downloader.service
[Unit]
Description=ComfyUI HTTP Model Downloader
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$USER_HOME
Environment=COMFY_DIR=$COMFY_DIR
Environment=DOWNLOADER_TOKEN=comfyui_secret_123
ExecStart=$COMFY_DIR/venv/bin/python $DOWNLOADER_SCRIPT
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable comfyui-downloader
systemctl start comfyui-downloader

if ! systemctl is-active --quiet comfyui || ! systemctl is-active --quiet comfyui-downloader; then
    echo "ERROR: ComfyUI provisioning did not start all required services. Bootstrap will retry on the next boot."
    exit 1
fi

touch "$BOOTSTRAP_MARKER"
echo "Setup Complete! Model downloader running on port 8189."
