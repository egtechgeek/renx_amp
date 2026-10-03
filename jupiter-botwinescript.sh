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

port_open() {
  timeout "${3:-0.4}" bash -c "echo >/dev/tcp/$1/$2" >/dev/null 2>&1
}

container_ipv4() {
  local cidr
  if command -v ip >/dev/null 2>&1; then
    cidr=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4; exit}')
    printf '%s' "${cidr%%/*}"
    return
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

private_ipv4() {
  [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]
}

find_docker_game_servers() {
  local port="$1"
  local mine stem i dir
  mine=$(container_ipv4)
  if ! private_ipv4 "$mine"; then
    return 0
  fi
  stem=${mine%.*}
  dir=$(mktemp -d)
  for ((i=1; i<=254; i++)); do
    [[ "$stem.$i" == "$mine" ]] && continue
    (
      if port_open "$stem.$i" "$port"; then
        echo "$stem.$i" > "$dir/$i"
      fi
    ) &
  done
  wait
  cat "$dir"/* 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
  rm -rf "$dir"
}

rcon_accepts() {
  local ip="$1" port="$2" pass="$3" out line
  out=$(RCON_PASS="$pass" timeout 2 bash -c '
    exec 3<>/dev/tcp/"$1"/"$2" || exit 1
    printf "a%s\n" "$RCON_PASS" >&3
    timeout 1.2 cat <&3
  ' _ "$ip" "$port" 2>/dev/null | tr -d '\r')
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == "a${pass}" ]] && continue
    [[ "$line" =~ ^[avl] ]] && return 0
  done <<<"$out"
  return 1
}

write_rcon_host() {
  local ip="$1"
  local ini="$BOT/Configs/RenX.Core.ini"
  local public escaped
  public=$(printf '%s' "$2" | sed 's/\./\\./g')
  if [[ ! -f "$ini" ]]; then
    return 0
  fi
  if grep -Eq "^Hostname=(host\\.docker\\.internal|172\\.[0-9.]+|${public})[[:space:]]*$" "$ini"; then
    sed -Ei "s/^Hostname=(host\\.docker\\.internal|172\\.[0-9.]+|${public})[[:space:]]*$/Hostname=${ip}/" "$ini"
    echo "RCON host set to $ip" | tee -a "$LOG"
  fi
}

choose_rcon_host() {
  local public="$1"
  local ini="$BOT/Configs/RenX.Core.ini"
  local port pass peer
  local -a peers=() matches=()
  port=$(awk -F= '/^Port=/ {print $2; exit}' "$ini" 2>/dev/null | tr -d '[:space:]')
  [[ "$port" =~ ^[0-9]+$ ]] || port=7777

  echo "Looking for a game server on port $port in this Docker network" | tee -a "$LOG"
  mapfile -t peers < <(find_docker_game_servers "$port")
  if ((${#peers[@]} == 1)); then
    echo "Game server found at ${peers[0]}" | tee -a "$LOG"
    write_rcon_host "${peers[0]}" "$public"
    return 0
  fi
  if ((${#peers[@]} > 1)); then
    echo "Several servers are listening on port $port:" | tee -a "$LOG"
    printf '  %s\n' "${peers[@]}" | tee -a "$LOG"
    pass=$(sed -n 's/^Password=//p' "$ini" | head -n 1 | tr -d '\r')
    if [[ -n "$pass" ]]; then
      for peer in "${peers[@]}"; do
        if rcon_accepts "$peer" "$port" "$pass"; then
          matches+=("$peer")
        fi
      done
    fi
    if ((${#matches[@]} == 1)); then
      echo "RCON password matched ${matches[0]}" | tee -a "$LOG"
      write_rcon_host "${matches[0]}" "$public"
      return 0
    fi
    echo "Set RCON Host to the server this bot should join." | tee -a "$LOG"
    return 0
  fi

  if [[ "$public" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && port_open "$public" "$port" 1.5; then
    echo "Public address $public is accepting port $port" | tee -a "$LOG"
    write_rcon_host "$public" "$public"
    return 0
  fi

  echo "No game server accepted port $port from this container. The public address is not reachable from inside Docker." | tee -a "$LOG"
  write_rcon_host "127.0.0.1" "$public"
}

if [[ "${1:-}" == "host" ]]; then
  choose_rcon_host "${2:-}"
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

echo "Wine setup complete" | tee -a "$LOG"
exit 0
