#!/bin/sh
set -u
umask 077

main() {
  product=${1:-}
  action=${2:-}
  case "$product:$action" in
    codex:wait|codex:session-start|codex:claim|claude:wait|claude:session-start|claude:claim) ;;
    *) printf '%s\n' 'usage: wake.sh codex|claude wait|session-start|claim' >&2; exit 64 ;;
  esac

  if [ -n "${AGENT_CHAT_WAKE_DIR:-}" ]; then
    dir=$AGENT_CHAT_WAKE_DIR
  elif [ "$product" = codex ]; then
    dir=${CODEX_HOME:-$HOME/.codex}/agent-chat
  else
    dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-chat
  fi
  config=$dir/wake.env
  plugin_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
  idle_text='No new agent-chat notices. Call the agent-chat tool chat_identity once so this session keeps waiting, then end the turn with one word.'
  refused_text='The chat refused the agent-chat wake token, so this session stopped waiting for notices: the connection was removed or expired, or the agent or its workspace was deleted. Tell the person in one sentence, and say they can type Connect agent-chat to connect again.'
  connected_text='agent-chat connected this conversation, and it now waits for notices. Tell the person in one short sentence that it is connected, then end the turn.'
  code_refused_text='The chat refused the agent-chat connection code, so this conversation is not connected. Tell the person, and run the agent-chat connect skill again only if they ask.'
  address_missing_text='The agent-chat plugin has no chat address in its .mcp.json, so this conversation is not connected. Tell the person to reinstall the agent-chat plugin.'
  unreachable_text='agent-chat could not reach the chat to connect this conversation. Tell the person to check the network, and run the agent-chat connect skill again only if they ask.'
  foreign_code_text='The agent-chat connection code was not used, because this conversation did not get it from the chat_wake_code tool of agent-chat. Tell the person, and run the agent-chat connect skill again only if they ask.'
  already_connected_text='This conversation is already connected to agent-chat, so the new connection code was not used. To connect another agent, the person removes this connection on the Agents page of agent-chat, under Tokens and Plugin connections, and then runs the agent-chat connect skill again.'

  setting() {
    value=$(sed -n "s/^$1=//p" "$config" 2>/dev/null | tail -n 1 | tr -d '\r')
    printf '%s' "${value:-$2}"
  }

  number_setting() {
    value=$(setting "$1" "$2")
    case "$value" in
      ''|*[!0-9]*) printf '%s' "$2" ;;
      *) printf '%s' "$value" ;;
    esac
  }

  save_setting() {
    temporary=$config.$$.tmp
    { grep -v "^$1=" "$config" 2>/dev/null; [ -z "$2" ] || printf '%s=%s\n' "$1" "$2"; } > "$temporary" && mv -f "$temporary" "$config"
  }

  token_mark() {
    printf '%s' "$token" | cksum | cut -d ' ' -f 1
  }

  marked_number() {
    saved_mark='' saved_number=''
    [ -f "$1" ] || return 1
    read -r saved_mark saved_number < "$1" || [ -n "$saved_mark" ] || return 1
    if [ -z "$saved_number" ]; then
      is_number "$saved_mark" || return 1
      printf '%s' "$saved_mark"
    elif [ "$saved_mark" = "$(token_mark)" ] && is_number "$saved_number"; then
      printf '%s' "$saved_number"
    else
      return 2
    fi
  }

  save_marked() {
    printf '%s %s\n' "$(token_mark)" "$2" > "$1"
  }

  connected_as_before() {
    [ "$(setting AGENT_CHAT_WAKE_TOKEN '')" = "$token" ]
  }

  is_number() {
    case "$1" in
      ''|*[!0-9]*) return 1 ;;
      *) return 0 ;;
    esac
  }

  url=$(setting AGENT_CHAT_WAKE_URL '')
  url=${url%/}
  token=$(setting AGENT_CHAT_WAKE_TOKEN '')
  code=$(setting AGENT_CHAT_WAKE_CODE '')
  budget=$(number_setting AGENT_CHAT_WAKE_BUDGET_SECONDS 1740)
  wait_seconds=$(number_setting AGENT_CHAT_WAKE_WAIT_SECONDS 20)
  margin=$(number_setting AGENT_CHAT_WAKE_MARGIN_SECONDS 15)
  retry_min=$(number_setting AGENT_CHAT_WAKE_RETRY_MIN_SECONDS 2)
  retry_max=$(number_setting AGENT_CHAT_WAKE_RETRY_MAX_SECONDS 60)
  unknown_cursor=999999999999999
  body=$dir/.body.$$
  headers=$dir/.headers.$$
  auth=$dir/.auth.$$
  answer=$dir/.status.$$
  lock=$dir/wake.lock
  owns_lock=no
  child=''
  stop=''

  cleanup() {
    if [ -n "$child" ]; then
      kill -s KILL "$child" 2>/dev/null
      wait "$child" 2>/dev/null
    fi
    rm -f "$body" "$headers" "$auth" "$answer" "$config.$$.tmp"
    if [ "$owns_lock" = yes ]; then
      rm -f "$lock/pid"
      rmdir "$lock" 2>/dev/null
    fi
  }
  trap cleanup EXIT
  trap 'stop=143; [ -z "$child" ] || exit 143' TERM INT HUP

  await_child() {
    child=$!
    [ -z "$stop" ] || exit "$stop"
    wait "$child"
    finished=$?
    child=''
    return "$finished"
  }

  pause() {
    sleep "$1" &
    await_child
  }

  sweep() {
    for leftover in "$dir"/.auth.* "$dir"/.headers.* "$dir"/.body.* "$dir"/.status.* "$config".*.tmp; do
      owner=${leftover%.tmp}
      owner=${owner##*.}
      is_number "$owner" || continue
      [ "$owner" = "$$" ] || ! kill -0 "$owner" 2>/dev/null || continue
      rm -f "$leftover"
    done
  }
  sweep

  claim() {
    case "$code" in
      ''|*[!A-Za-z0-9_-]*) printf '%s\n' 'No valid AGENT_CHAT_WAKE_CODE in wake.env.' >&2; return 1 ;;
    esac
    printf '{"code":"%s"}' "$code" | curl -s -o "$body" -w '%{http_code}' --max-time "$((wait_seconds + margin))" -X POST \
      -H 'Content-Type: application/json' -H 'User-Agent: agent-chat-wake/1' \
      --data-binary @- "$url/wake/claim" > "$answer" &
    await_child && status=$(cat "$answer" 2>/dev/null) || status=000
    received=$(tr -d '\r\n' < "$body" 2>/dev/null)
    case "$status:$received" in
      200:saw_*)
        case "$received" in
          *[!A-Za-z0-9_-]*) printf '%s\n' 'The chat answered the claim with an invalid token.' >&2; return 1 ;;
        esac
        save_setting AGENT_CHAT_WAKE_TOKEN "$received" && save_setting AGENT_CHAT_WAKE_CODE '' || return 1
        token=$received
        save_marked "$dir/cursor" "$unknown_cursor" || return 1
        rm -f "$dir/stopped" "$dir/pending"
        return 0 ;;
    esac
    printf 'The chat refused the connection code (HTTP %s). Run the connect skill again for a new code.\n' "$status" >&2
    return 1
  }

  deliver_text() {
    if [ "$product" = codex ]; then
      printf '{"decision":"block","reason":"%s"}\n' "$1"
      exit 0
    fi
    printf '%s\n' "$1" >&2
    exit 2
  }

  issued_here() {
    [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
    tries=0
    while :; do
      grep -F '"server":"agent-chat","tool":"chat_wake_code"' "$transcript" 2>/dev/null | grep -F -q "\"structuredContent\":{\"code\":\"$offered\"" && return 0
      tries=$((tries + 1))
      [ "$tries" -lt 5 ] || return 1
      pause 1
    done
  }

  connect_from_stop() {
    [ ! -t 0 ] || return 0
    stop_input=$(cat)
    offered=$(printf '%s' "$stop_input" | grep -o 'agent-chat wake code: `\{0,1\}swc_[A-Za-z0-9_-]\{43\}`\{0,1\}\(\\n\)\{0,1\}"' | tail -n 1 | grep -o 'swc_[A-Za-z0-9_-]\{43\}')
    [ -n "$offered" ] || return 0
    [ -z "$token" ] || [ -f "$dir/stopped" ] || deliver_text "$already_connected_text"
    transcript=$(printf '%s' "$stop_input" | sed -n 's/.*"transcript_path" *: *"\([^"]*\)".*/\1/p' | head -n 1)
    issued_here || deliver_text "$foreign_code_text"
    plugin_url=$(sed -n 's/.*"url" *: *"\([^"]*\)".*/\1/p' "$plugin_root/.mcp.json" 2>/dev/null | head -n 1)
    plugin_url=${plugin_url%/}
    plugin_url=${plugin_url%/mcp}
    [ -n "$plugin_url" ] || deliver_text "$address_missing_text"
    mkdir -p "$dir" || exit 0
    url=$plugin_url
    code=$offered
    { save_setting AGENT_CHAT_WAKE_URL "$url" && save_setting AGENT_CHAT_WAKE_TOKEN '' && save_setting AGENT_CHAT_WAKE_CODE "$code"; } || exit 0
    status=''
    claim && deliver_text "$connected_text"
    save_setting AGENT_CHAT_WAKE_CODE ''
    [ "$status" != 000 ] || deliver_text "$unreachable_text"
    deliver_text "$code_refused_text"
  }

  [ "$product:$action" != codex:wait ] || connect_from_stop

  [ -d "$dir" ] || exit 0
  [ -n "$url" ] || exit 0

  if [ "$action" = claim ]; then
    claim || exit 1
    printf '%s\n' 'Connected: this session now wakes on agent-chat notices.'
    exit 0
  fi

  [ ! -f "$dir/stopped" ] || exit 0
  if [ -z "$token" ]; then
    [ -n "$code" ] || exit 0
    claim || exit 0
  fi
  printf 'Authorization: Bearer %s\n' "$token" > "$auth"

  cursor=$(marked_number "$dir/cursor")
  case $? in
    0) ;;
    2) cursor=$unknown_cursor ;;
    *) cursor=0 ;;
  esac

  request() {
    curl -s -o "$body" -D "$headers" -w '%{http_code}' --max-time "$2" \
      -H "@$auth" -H 'User-Agent: agent-chat-wake/1' "$url/wake?$1" > "$answer" &
    await_child && status=$(cat "$answer" 2>/dev/null) || status=000
    next=$(tr -d '\r' < "$headers" 2>/dev/null | sed -n 's/^[Xx]-[Aa][Gg][Ee][Nn][Tt]-[Cc][Hh][Aa][Tt]-[Cc][Uu][Rr][Ss][Oo][Rr]: *//p' | tail -n 1)
  }

  deliver_file() {
    if [ "$product" = codex ]; then
      cat "$body"
      exit 0
    fi
    cat "$body" >&2
    exit 2
  }

  if [ "$action" = session-start ]; then
    marked_number "$dir/pending" > /dev/null || exit 0
    request "after=$cursor&wait=0&format=session-start&redelivery=1" "$margin"
    [ "$status" != 200 ] || cat "$body"
    exit 0
  fi

  if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$holder" ]; then
      ! kill -0 "$holder" 2>/dev/null || exit 0
    elif [ -z "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      exit 0
    fi
    rm -f "$lock/pid"
    rmdir "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null || exit 0
  fi
  owns_lock=yes
  printf '%s\n' "$$" > "$lock/pid"

  if pending=$(marked_number "$dir/pending"); then
    cursor=$pending
    save_marked "$dir/cursor" "$cursor"
  fi
  rm -f "$dir/pending"

  if [ "$product" = codex ]; then format=stop; else format=text; fi
  deadline=$(( $(date +%s) + budget ))
  backoff=$retry_min
  while :; do
    left=$(( deadline - $(date +%s) ))
    wait_now=$wait_seconds
    [ $((wait_now + margin)) -le "$left" ] || wait_now=$((left - margin))
    [ "$wait_now" -ge 1 ] || break
    connected_as_before || exit 0
    request "after=$cursor&wait=$wait_now&format=$format" "$((wait_now + margin))"
    if ! connected_as_before; then
      [ "$status" != 200 ] || ! is_number "$next" || deliver_file
      exit 0
    fi
    case "$status" in
      200)
        if is_number "$next"; then
          save_marked "$dir/pending" "$next"
          deliver_file
        fi ;;
      204)
        if [ "$cursor" = "$unknown_cursor" ] && [ "$next" = "$unknown_cursor" ]; then
          cursor=0
          save_marked "$dir/cursor" "$cursor"
        elif is_number "$next" && [ "$next" != "$cursor" ]; then
          cursor=$next
          save_marked "$dir/cursor" "$cursor"
        fi
        backoff=$retry_min
        continue ;;
      401|403)
        : > "$dir/stopped"
        deliver_text "$refused_text" ;;
    esac
    left=$(( deadline - $(date +%s) - margin ))
    [ "$left" -ge 1 ] || break
    [ "$backoff" -le "$left" ] || backoff=$left
    pause "$backoff"
    backoff=$((backoff * 2))
    [ "$backoff" -le "$retry_max" ] || backoff=$retry_max
  done
  deliver_text "$idle_text"
}

main "$@"; exit
