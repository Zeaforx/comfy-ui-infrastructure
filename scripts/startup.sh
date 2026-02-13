#!/bin/bash

# 1. System Updates & Dependencies
# --------------------------------
echo "Starting ComfyUI Setup..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y git python3-venv python3-pip build-essential wget software-properties-common linux-headers-$(uname -r)

# 2. Install NVIDIA Drivers & CUDA (Debian 12 specific)
# -------------------------------------------------------
echo "Installing NVIDIA Drivers..."

# Add contrib and non-free repos if not already present
if ! grep -q "non-free" /etc/apt/sources.list; then
    sed -i 's/deb http:\/\/deb.debian.org\/debian bookworm main/deb http:\/\/deb.debian.org\/debian bookworm main contrib non-free non-free-firmware/' /etc/apt/sources.list
fi

apt-get update

# Try to detect and install latest NVIDIA drivers
apt-get install -y --no-install-recommends nvidia-driver-545 || \
apt-get install -y --no-install-recommends nvidia-driver || \
echo "WARNING: Driver installation may have issues. Will attempt CPU fallback."

# Give driver time to load
sleep 5

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
# ----------------
if [ ! -d "$COMFY_DIR" ]; then
    echo "Cloning ComfyUI..."
    sudo -u $SERVICE_USER git clone https://github.com/comfyanonymous/ComfyUI.git $COMFY_DIR
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to clone ComfyUI"
        exit 1
    fi
else
    echo "ComfyUI directory already exists."
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

# Install PyTorch with CUDA support (Crucial for T4)
# Using full path to venv's pip to avoid activation issues
echo "Installing PyTorch..."
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install --upgrade pip setuptools wheel
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install ComfyUI requirements
echo "Installing ComfyUI dependencies..."
sudo -u $SERVICE_USER $COMFY_DIR/venv/bin/pip install -r requirements.txt

# 6. Create Systemd Service (Auto-start)
# --------------------------------------
echo "Creating Systemd Service..."

# Determine GPU availability for startup flags
if command -v nvidia-smi &> /dev/null; then
    COMFY_FLAGS="--listen 0.0.0.0 --port 8188"
    echo "GPU detected - ComfyUI will use CUDA acceleration"
else
    COMFY_FLAGS="--listen 0.0.0.0 --port 8188 --cpu"
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

echo "Setup Complete! ComfyUI should be running on port 8188."