#!/bin/bash

set -e

# ----------------------------
# Configuration
# ----------------------------
INSTALL_DIR="/opt/rtl-smart-server"
SERVICE_NAME="rtl-smart"
PORT=1234
AUDIO_FILE="fm_fallback.wav"
TTS_MESSAGE="No S-D-R Found, Please check if you have an R-T-L S-D-R Plugged in."

# ----------------------------
# Step 1: Install system packages
# ----------------------------
echo "[*] Installing system dependencies..."
sudo apt update
sudo apt install -y git rtl-sdr python3 python3-pip ffmpeg espeak

echo "[*] Installing Python libraries..."
pip3 install numpy soundfile pyttsx3

# ----------------------------
# Step 2: Create install folder
# ----------------------------
echo "[*] Creating install folder at $INSTALL_DIR..."
sudo rm -rf "$INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown -R $USER:$USER "$INSTALL_DIR"

cd "$INSTALL_DIR"

# ----------------------------
# Step 3: Generate FM fallback WAV from TTS
# ----------------------------
echo "[*] Generating TTS FM fallback file..."
python3 - <<EOF
import pyttsx3
import soundfile as sf
import numpy as np

engine = pyttsx3.init()
engine.setProperty('rate', 150)

# Generate speech to WAV file
filename = '$AUDIO_FILE'

# pyttsx3 saves via driver callback
# We'll just speak and record using tempfile
import tempfile
import subprocess

with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
    tmpfile = tmp.name

# Use espeak via subprocess to generate WAV directly
subprocess.run(['espeak', '-w', tmpfile, '$TTS_MESSAGE'])

# Move generated WAV to final audio file
import shutil
shutil.move(tmpfile, filename)
EOF

# ----------------------------
# Step 4: Create smart_rtl_tcp.sh
# ----------------------------
cat > smart_rtl_tcp.sh <<'EOF'
#!/bin/bash

PORT=1234

echo "[*] Checking system requirements..."

# Check rtl_tcp
if ! command -v rtl_tcp &>/dev/null; then
    echo "[!] rtl_tcp not found. Please run setup again."
    exit 1
fi

# Check python3
if ! command -v python3 &>/dev/null; then
    echo "[!] python3 not found. Please run setup again."
    exit 1
fi

# Check Python modules
python3 - <<END
try:
    import numpy
    import soundfile
except ImportError:
    import sys
    sys.exit(1)
END

if [ $? -ne 0 ]; then
    echo "[!] Required Python packages missing. Please run setup again."
    exit 1
fi

# Run real or fake SDR
echo "[*] Checking for RTL-SDR device..."
if rtl_test -t &>/dev/null; then
    echo "[+] Real SDR detected → launching rtl_tcp"
    rtl_tcp -a 0.0.0.0 -p $PORT
else
    echo "[!] No SDR found → launching FAKE rtl_tcp (TTS fallback)"
    python3 fake_rtl_tcp.py
fi
EOF

chmod +x smart_rtl_tcp.sh

# ----------------------------
# Step 5: Create fake_rtl_tcp.py
# ----------------------------
cat > fake_rtl_tcp.py <<'EOF'
import socket
import numpy as np
import soundfile as sf
import threading

HOST = "0.0.0.0"
PORT = 1234
SAMPLE_RATE = 2048000
FM_DEVIATION = 75000
AUDIO_FILE = "fm_fallback.wav"

print("[*] Loading audio...")
try:
    audio, sr = sf.read(AUDIO_FILE)
except Exception:
    raise FileNotFoundError(f"{AUDIO_FILE} not found.")

if len(audio.shape) > 1:
    audio = audio[:,0]

# Resample
audio = np.interp(np.linspace(0, len(audio), int(len(audio)*SAMPLE_RATE/sr)), np.arange(len(audio)), audio)
audio = audio / np.max(np.abs(audio))

print("[*] Generating FM IQ...")
phase = np.cumsum(audio) * (2*np.pi*FM_DEVIATION / SAMPLE_RATE)
iq = np.exp(1j*phase)

iq_u8 = np.empty(iq.size*2, dtype=np.uint8)
iq_u8[0::2] = ((iq.real*127)+128).astype(np.uint8)
iq_u8[1::2] = ((iq.imag*127)+128).astype(np.uint8)

def handle_client(conn, addr):
    print(f"[+] Client connected: {addr}")
    conn.send(b"RTL0\x00\x00\x00\x00")
    while True:
        try:
            conn.sendall(iq_u8.tobytes())
        except:
            break
    conn.close()
    print(f"[-] Client disconnected: {addr}")

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind((HOST, PORT))
    s.listen(5)
    print("[*] Fake rtl_tcp server running (TTS fallback)...")
    while True:
        conn, addr = s.accept()
        threading.Thread(target=handle_client, args=(conn, addr), daemon=True).start()
EOF

# ----------------------------
# Step 6: Blacklist DVB drivers
# ----------------------------
echo "[*] Blacklisting conflicting DVB drivers..."
sudo bash -c 'cat > /etc/modprobe.d/blacklist-rtl.conf <<EOF
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF'

# ----------------------------
# Step 7: Create systemd service
# ----------------------------
echo "[*] Creating systemd service..."
sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Smart RTL TCP Server (Real + Fake SDR TTS)
After=network.target

[Service]
ExecStart=/bin/bash $INSTALL_DIR/smart_rtl_tcp.sh
WorkingDirectory=$INSTALL_DIR
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF"

# ----------------------------
# Step 8: Enable & start service
# ----------------------------
echo "[*] Reloading systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

echo "[*] Enabling service..."
sudo systemctl enable $SERVICE_NAME

echo "[*] Starting service..."
sudo systemctl start $SERVICE_NAME

echo "[+] Setup complete!"
echo "Check status with: sudo systemctl status $SERVICE_NAME --no-pager"
