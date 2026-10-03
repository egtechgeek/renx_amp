#!/bin/bash
# Install the libraries the v1.1.0 Windows build imports.
# jupiter.dll requires libssl-1_1-x64.dll and libcrypto-1_1-x64.dll.
# Bot.exe, jupiter.dll, and jessilib.dll require the Visual C++ 2019 runtime.

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
BOT="$SCRIPTDIR/jupiter-bot"
LOG="$SCRIPTDIR/winescript_log.txt"
OPENSSL_URL="https://slproweb.com/download/Win64OpenSSL_Light-1_1_1w.exe"
OPENSSL_EXE="$SCRIPTDIR/Win64OpenSSL_Light-1_1_1w.exe"

export WINEPREFIX="$BOT/.wine"
export WINEARCH=win64
export WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree,mshtml="

echo "Jupiter Bot Wine setup" > "$LOG"

if [[ ! -d "$BOT" ]]; then
  echo "Jupiter Bot directory not found: $BOT" | tee -a "$LOG"
  exit 1
fi

wget -q -N https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -O "$SCRIPTDIR/winetricks"
chmod +x "$SCRIPTDIR/winetricks"

echo "Installing Visual C++ 2019 runtime" | tee -a "$LOG"
timeout --signal=KILL 600 xvfb-run -a "$SCRIPTDIR/winetricks" -q vcrun2019 >> "$LOG" 2>&1 || true

if [[ ! -f "$BOT/libssl-1_1-x64.dll" || ! -f "$BOT/libcrypto-1_1-x64.dll" ]]; then
  echo "Installing OpenSSL 1.1.1 Win64 Light" | tee -a "$LOG"
  wget -q -N "$OPENSSL_URL" -O "$OPENSSL_EXE"
  timeout --signal=KILL 300 xvfb-run -a wine "$OPENSSL_EXE" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=C:\\OpenSSL-Win64 >> "$LOG" 2>&1 || true
  ssl_dll=$(find "$WINEPREFIX/drive_c" -name 'libssl-1_1-x64.dll' 2>/dev/null | head -n 1)
  if [[ -n "$ssl_dll" ]]; then
    ssl_dir=$(dirname "$ssl_dll")
    cp -f "$ssl_dir/libssl-1_1-x64.dll" "$ssl_dir/libcrypto-1_1-x64.dll" "$BOT/"
    cp -f "$ssl_dir/libssl-1_1-x64.dll" "$ssl_dir/libcrypto-1_1-x64.dll" "$WINEPREFIX/drive_c/windows/system32/" 2>/dev/null || true
  fi
  rm -f "$OPENSSL_EXE"
fi

rm -rf "$HOME/.cache/winetricks" "$HOME/.cache/fontconfig"
wineserver -k >/dev/null 2>&1 || true

missing=0
if [[ ! -f "$WINEPREFIX/drive_c/windows/system32/VCRUNTIME140_1.dll" && ! -f "$WINEPREFIX/drive_c/windows/syswow64/VCRUNTIME140_1.dll" ]]; then
  echo "Missing VCRUNTIME140_1.dll" | tee -a "$LOG"
  missing=1
fi
if [[ ! -f "$BOT/libssl-1_1-x64.dll" || ! -f "$BOT/libcrypto-1_1-x64.dll" ]]; then
  echo "Missing OpenSSL 1.1 DLLs next to Bot.exe" | tee -a "$LOG"
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  echo "Wine setup failed. See winescript_log.txt" | tee -a "$LOG"
  exit 1
fi

echo "Wine setup complete" | tee -a "$LOG"
exit 0
