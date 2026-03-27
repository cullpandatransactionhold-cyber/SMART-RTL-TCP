#!/bin/bash

PORT=1234

echo "[*] Checking system requirements..."

# Check for rtl_tcp
if ! command -v rtl_tcp &>/dev/null; then
    echo "[!] rtl_tcp not found. Please run ./setup.sh first."
    exit 1
fi

# Check for Python3
if ! command -v python3 &>/dev/null; then
    echo "[!] python3 not found. Please run ./setup.sh first."
    exit 1
fi

# Check for Python libraries for fake SDR
python3 - <<END
try:
    import numpy
    import soundfile
except ImportError:
    import sys
    sys.exit(1)
END

if [ $? -ne 0 ]; then
    echo "[!] Required Python packages not installed. Please run ./setup.sh first."
    exit 1
fi

# Check for RTL-SDR device
echo "[*] Checking for RTL-SDR device..."
if rtl_test -t &>/dev/null; then
    echo "[+] Real SDR detected → launching rtl_tcp"
    rtl_tcp -a 0.0.0.0 -p $PORT
else
    echo "[!] No SDR found → launching FAKE rtl_tcp"
    python3 fake_rtl_tcp.py
fi
