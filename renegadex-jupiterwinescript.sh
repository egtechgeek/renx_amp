#!/bin/bash

SCRIPT_NAME=$(echo \"$0\" | xargs readlink -f)
SCRIPTDIR=$(dirname "$SCRIPT_NAME")

jupiter_stop() {
  pkill -f 'JUPITER_BOT_WAIT' >/dev/null 2>&1 || true
  pkill -f 'Bot\.exe -config Config\.ini' >/dev/null 2>&1 || true
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

if [[ "${1:-}" == "jupiter-stop" ]]; then
  jupiter_stop
  echo "Jupiter Bot stopped"
  exit 0
fi

if [[ "${1:-}" == "jupiter" ]]; then
  BOT="$SCRIPTDIR/jupiter-bot"
  PORT="${2:-7777}"
  [[ "$PORT" =~ ^[0-9]+$ ]] || PORT=7777
  if [[ ! -f "$BOT/Bot.exe" ]]; then
    echo "Jupiter Bot is not installed yet"
    exit 0
  fi
  jupiter_stop
  HOST=$(container_ipv4)
  [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || HOST=127.0.0.1
  if [[ -f "$BOT/Configs/RenX.Core.ini" ]]; then
    sed -i "s/^Hostname=.*/Hostname=${HOST}/" "$BOT/Configs/RenX.Core.ini"
  fi
  echo "Jupiter Bot will connect to ${HOST}:$PORT when Renegade X is listening. Log: $BOT/bot.log"
  setsid nohup bash -c '
    export JUPITER_BOT_WAIT=1
    export WINEPREFIX="$1/renegadex/.wine"
    export WINEARCH=win64
    export WINEDEBUG=-all
    export WINEDLLOVERRIDES="mscoree,mshtml="
    port="$2"
    bot="$3"
    host="$4"
    for ((n=0; n<180; n++)); do
      if timeout 0.4 bash -c "echo >/dev/tcp/$host/$port" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    cd "$bot" || exit 1
    echo "Starting Jupiter Bot"
    exec /usr/bin/wine Bot.exe -config Config.ini -pluginsdir Plugins -configsdir Configs
  ' _ "$SCRIPTDIR" "$PORT" "$BOT" "$HOST" >> "$BOT/bot.log" 2>&1 < /dev/null &
  exit 0
fi

exec 6>display.log
/usr/bin/Xvfb -displayfd 6 -nolisten tcp -nolisten unix &
XVFB_PID=$!
while [[ ! -s display.log ]]; do
  sleep 1
done
read -r DPY_NUM < display.log
rm display.log

export WINEPREFIX="$SCRIPTDIR/renegadex/.wine"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEARCH=win64
export WINEDEBUG=fixme-all
export DISPLAY=:$DPY_NUM

wget -q -N https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks
chmod +x winetricks

PACKAGES="corefonts vcrun2008 vcrun2010 xact xact_x64 msxml3 d3dcompiler_43 d3dx9 d3dx9_43 win7 dotnet452 win7"
echo "" > winescript_log.txt 2>&1
for PACKAGE in $PACKAGES; do
  ./winetricks -q $PACKAGE >> winescript_log.txt 2>&1
done
rm -rf ~/.cache/winetricks ~/.cache/fontconfig

BOT="$SCRIPTDIR/jupiter-bot"
if [[ -d "$BOT" ]]; then
  if ! find "$WINEPREFIX" -iname 'vcruntime140_1.dll' -type f 2>/dev/null | grep -q .; then
    echo "Installing Visual C++ 2019 runtime for Jupiter Bot"
    ./winetricks -q vcrun2019 >> winescript_log.txt 2>&1 || true
  fi
  runtime=$(find "$WINEPREFIX" -iname 'vcruntime140_1.dll' -type f 2>/dev/null | head -n 1)
  if [[ -n "$runtime" ]]; then
    cp -f "$runtime" "$WINEPREFIX/drive_c/windows/system32/vcruntime140_1.dll" 2>/dev/null || true
  fi
  if [[ ! -f "$BOT/libssl-1_1-x64.dll" || ! -f "$BOT/libcrypto-1_1-x64.dll" ]]; then
    echo "Installing OpenSSL 1.1.1 for Jupiter Bot"
    OPENSSL_EXE="$SCRIPTDIR/Win64OpenSSL_Light-1_1_1w.exe"
    wget -q -N "https://slproweb.com/download/Win64OpenSSL_Light-1_1_1w.exe" -O "$OPENSSL_EXE" || true
    if [[ -f "$OPENSSL_EXE" ]]; then
      wine "$OPENSSL_EXE" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=C:\\OpenSSL-Win64 >> winescript_log.txt 2>&1 || true
      ssl_dll=$(find "$WINEPREFIX/drive_c" -name 'libssl-1_1-x64.dll' 2>/dev/null | head -n 1)
      if [[ -n "$ssl_dll" ]]; then
        ssl_dir=$(dirname "$ssl_dll")
        cp -f "$ssl_dir/libssl-1_1-x64.dll" "$ssl_dir/libcrypto-1_1-x64.dll" "$BOT/" || true
        cp -f "$ssl_dir/libssl-1_1-x64.dll" "$ssl_dir/libcrypto-1_1-x64.dll" "$WINEPREFIX/drive_c/windows/system32/" 2>/dev/null || true
      fi
      rm -f "$OPENSSL_EXE"
    fi
  fi
fi
if [[ -f "$WINEPREFIX/user.reg" ]] && ! grep -q '"DisabledIPv6"=dword:00000001' "$WINEPREFIX/user.reg"; then
  printf '\n[Software\\\\Wine\\\\Network] %s\n"DisabledIPv6"=dword:00000001\n' "$(date +%s)" >> "$WINEPREFIX/user.reg"
fi

exec 6>&-
kill $XVFB_PID

exit 0
