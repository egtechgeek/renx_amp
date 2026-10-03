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

resolve_docker_host_ip() {
  local ip hex
  ip=$(getent ahostsv4 host.docker.internal 2>/dev/null | awk 'NR==1 {print $1; exit}')
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
    return
  fi
  ip=$(awk 'tolower($2)=="host.docker.internal" {print $1; exit}' /etc/hosts 2>/dev/null)
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
    return
  fi
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3; exit}')
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return
    fi
  fi
  hex=$(awk '$2=="00000000" {print $3; exit}' /proc/net/route 2>/dev/null)
  if [[ -n "$hex" && "$hex" != "00000000" ]]; then
    printf '%d.%d.%d.%d' "0x${hex:6:2}" "0x${hex:4:2}" "0x${hex:2:2}" "0x${hex:0:2}"
  fi
}

map_docker_host() {
  local ip hosts ini
  ip=$(resolve_docker_host_ip)
  if [[ -z "$ip" ]]; then
    echo "Could not find an address for the Docker host" | tee -a "$LOG"
    return 0
  fi
  echo "Docker host address: $ip" | tee -a "$LOG"

  hosts="$WINEPREFIX/drive_c/windows/system32/drivers/etc/hosts"
  if [[ -d "$WINEPREFIX/drive_c/windows/system32" ]]; then
    mkdir -p "$(dirname "$hosts")"
    [[ -f "$hosts" ]] || printf '127.0.0.1\tlocalhost\n' > "$hosts"
    grep -vi 'host\.docker\.internal' "$hosts" > "$hosts.tmp" || true
    printf '%s\thost.docker.internal\n' "$ip" >> "$hosts.tmp"
    mv "$hosts.tmp" "$hosts"
  fi

  if [[ -w /etc/hosts ]]; then
    grep -vi 'host\.docker\.internal' /etc/hosts > /tmp/jupiter-hosts || true
    printf '%s\thost.docker.internal\n' "$ip" >> /tmp/jupiter-hosts
    cat /tmp/jupiter-hosts > /etc/hosts
    rm -f /tmp/jupiter-hosts
  fi

  ini="$BOT/Configs/RenX.Core.ini"
  if [[ -f "$ini" ]] && grep -q '^Hostname=host\.docker\.internal[[:space:]]*$' "$ini"; then
    sed -i 's/^Hostname=host\.docker\.internal[[:space:]]*$/Hostname='"$ip"'/' "$ini"
    echo "RCON host set to $ip" | tee -a "$LOG"
  fi
}

if [[ "${1:-}" == "host" ]]; then
  echo "Mapping Docker host for Wine" | tee -a "$LOG"
  map_docker_host
  exit 0
fi

echo "Jupiter Bot Wine setup. Log: $LOG" | tee "$LOG"

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

find_dll() {
  find "$1" -iname "$2" -type f 2>/dev/null | head -n 1
}

missing=0
runtime_dll=$(find_dll "$WINEPREFIX" "vcruntime140_1.dll")
if [[ -z "$runtime_dll" ]]; then
  echo "Missing vcruntime140_1.dll" | tee -a "$LOG"
  missing=1
else
  cp -f "$runtime_dll" "$WINEPREFIX/drive_c/windows/system32/vcruntime140_1.dll" 2>/dev/null || true
fi
if [[ ! -f "$BOT/libssl-1_1-x64.dll" || ! -f "$BOT/libcrypto-1_1-x64.dll" ]]; then
  echo "Missing OpenSSL 1.1 DLLs next to Bot.exe" | tee -a "$LOG"
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  echo "Wine setup failed. Log: $LOG" | tee -a "$LOG"
  tail -n 40 "$LOG"
  exit 1
fi

map_docker_host
echo "Wine setup complete" | tee -a "$LOG"
exit 0
