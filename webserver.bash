#!/bin/bash
set -u

PORT=8080
LISTEN_ADDR="0.0.0.0"          # bind to all interfaces (LAN reachable)
webroot="$HOME/m/ncserver"     # adjust if needed
logfile="$webroot/access.log"

get_mime_type() {
  case "$1" in
    *.html) echo "text/html" ;;
    *.css)  echo "text/css" ;;
    *.js)   echo "application/javascript" ;;
    *.png)  echo "image/png" ;;
    *.jpg|*.jpeg) echo "image/jpeg" ;;
    *.gif)  echo "image/gif" ;;
    *.svg)  echo "image/svg+xml" ;;
    *.txt)  echo "text/plain" ;;
    *)      echo "application/octet-stream" ;;
  esac
}

resolve_path() {
  local raw="$1"
  [ "$raw" = "/" ] && raw="/index.html"
  raw="${raw#/}"         # strip leading /
  raw="${raw//../}"      # basic traversal guard
  echo "$webroot/$raw"
}

# Now includes client_ip
log_line() {
  # Args: status method path bytes mime client_ip
  local ts status method path bytes mime client_ip
  ts=$(date +"%Y-%m-%d %H:%M:%S")
  status="$1"; method="$2"; path="$3"; bytes="$4"; mime="$5"; client_ip="$6"
  printf '%s - %s [%s] "%s %s" %s %s\n' \
    "$ts" "$LISTEN_ADDR:$PORT" "$client_ip" "$method" "$path" "$status" "$bytes ($mime)" >> "$logfile"
}

echo "Starting mini netcat webserver on ${LISTEN_ADDR}:${PORT} ..."
echo "(Logs: $logfile)"
mkdir -p "$webroot"
if [ ! -f "$logfile" ]; then
  touch "$logfile"
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') - server starting on $LISTEN_ADDR:$PORT" >> "$logfile"

while true; do
  # Temp file to receive extracted client IP for this connection
  tmp_ip="$(mktemp)"

  # Start netcat as a coprocess.
  #  - Append the full verbose output to the log (as before)
  #  - ALSO pipe it through sed to extract the client IP into $tmp_ip
  coproc NC {
    nc -l -p "$PORT" -s "$LISTEN_ADDR" -v \
      2> >(tee -a "$logfile" | sed -u -n 's/.*Connection from \([0-9a-fA-F\.:]*\).*/\1/p' > "$tmp_ip")
  }

  # Wait briefly for client IP to appear (browser connects almost immediately)
  client_ip=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if read -r client_ip < "$tmp_ip"; then
      [ -n "$client_ip" ] && break
    fi
    sleep 0.05
  done
  rm -f "$tmp_ip"

  # Read the request line (up to CR) from the client
  IFS=$'\r' read -r request_line <&"${NC[0]}" || { exec {NC[0]}>&- {NC[1]}>&-; continue; }

  method=$(awk '{print $1}' <<<"$request_line")
  path=$(awk '{print $2}' <<<"$request_line")

  # Consume headers until blank line to avoid keep-alive hangs
  while IFS=$'\r' read -r hdr <&"${NC[0]}"; do
    [ -z "$hdr" ] && break
  done

  if [ "$method" != "GET" ]; then
    body="Only GET is supported."
    clen=${#body}
    {
      echo -e "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: $clen\r\nConnection: close\r\n\r\n"
      echo -n "$body"
    } >&"${NC[1]}"
    log_line 405 "$method" "${path:-/}" "$clen" "text/plain" "${client_ip:-unknown}"
    exec {NC[0]}>&- {NC[1]}>&-
    continue
  fi

  filepath=$(resolve_path "${path:-/}")
  echo "Request (${client_ip:-unknown}): $method ${path:-/} -> $filepath" >&2

  if [ -f "$filepath" ]; then
    mime=$(get_mime_type "$filepath")
    clen=$(wc -c <"$filepath")
    {
      echo -e "HTTP/1.1 200 OK\r\nContent-Type: $mime\r\nContent-Length: $clen\r\nConnection: close\r\n\r\n"
      cat "$filepath"
    } >&"${NC[1]}"
    log_line 200 "$method" "${path:-/}" "$clen" "$mime" "${client_ip:-unknown}"
  else
    body="404 Not Found: ${path:-/}"
    clen=${#body}
    {
      echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: $clen\r\nConnection: close\r\n\r\n"
      echo -n "$body"
    } >&"${NC[1]}"
    log_line 404 "$method" "${path:-/}" "$clen" "text/plain" "${client_ip:-unknown}"
  fi

  exec {NC[0]}>&- {NC[1]}>&-
done
