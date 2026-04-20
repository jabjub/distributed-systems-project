#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Active-Active remote deployment for the Distributed Exchange System.
#
# This script is designed for a Windows local machine without Java/Maven/Erlang.
# It syncs source code to both Ubuntu containers, compiles remotely, then starts:
#   - nodeA@10.2.1.3 on 10.2.1.3
#   - nodeB@10.2.1.14 on 10.2.1.14
# -----------------------------------------------------------------------------

NODE_A_IP="${NODE_A_IP:-10.2.1.3}"
NODE_B_IP="${NODE_B_IP:-10.2.1.14}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-/opt/distributed-exchange}"
COOKIE_FILE="${COOKIE_FILE:-.erlang.cookie}"
ERLANG_COOKIE="${ERLANG_COOKIE:-exchange_cookie}"
CLEAN_START="${CLEAN_START:-1}"
TARGET_NODE="${TARGET_NODE:-}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_LIST="nodeA@${NODE_A_IP},nodeB@${NODE_B_IP}"

log() {
  printf '[deploy] %s\n' "$*"
}

is_target_node() {
  local node="$1"
  if [[ -z "${TARGET_NODE}" ]]; then
    return 0
  fi
  [[ "${TARGET_NODE}" == "${node}" ]]
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

remote_prepare() {
  local host="$1"
  log "Preparing remote project directory on ${host}"
  ssh -o BatchMode=yes "${REMOTE_USER}@${host}" \
    "set -euo pipefail; mkdir -p '${REMOTE_BASE_DIR}' '${REMOTE_BASE_DIR}/ebin' '${REMOTE_BASE_DIR}/logs'"
}

sync_workspace() {
  local host="$1"
  log "Syncing source workspace to ${host} (excluding local build artifacts)"

  if command -v rsync >/dev/null 2>&1; then
    rsync -az --delete \
      --exclude '.git/' \
      --exclude '.idea/' \
      --exclude '.vscode/' \
      --exclude 'target/' \
      --exclude '**/*.beam' \
      --exclude 'ebin/*.beam' \
      "${PROJECT_ROOT}/" \
      "${REMOTE_USER}@${host}:${REMOTE_BASE_DIR}/"
  else
    # scp fallback: create a temporary source archive with exclusions.
    local tmp_archive
    tmp_archive="$(mktemp "${PROJECT_ROOT}/deploy-src-XXXXXX.tar.gz")"
    if tar -C "${PROJECT_ROOT}" \
        --exclude='.git' \
        --exclude='.idea' \
        --exclude='.vscode' \
        --exclude='target' \
        --exclude='*.beam' \
        --exclude='ebin/*.beam' \
        -czf "${tmp_archive}" .; then
      scp "${tmp_archive}" "${REMOTE_USER}@${host}:${REMOTE_BASE_DIR}/workspace.tar.gz"
      ssh -o BatchMode=yes "${REMOTE_USER}@${host}" \
        "set -euo pipefail; cd '${REMOTE_BASE_DIR}'; tar -xzf workspace.tar.gz; rm -f workspace.tar.gz"
      rm -f "${tmp_archive}"
    else
      rm -f "${tmp_archive}"
      log "tar failed. Falling back to scp -r and remote cleanup."
      scp -r "${PROJECT_ROOT}/." "${REMOTE_USER}@${host}:${REMOTE_BASE_DIR}/"
      ssh -o BatchMode=yes "${REMOTE_USER}@${host}" \
        "set -euo pipefail; \
         cd '${REMOTE_BASE_DIR}'; \
         rm -rf .git .idea .vscode target; \
         find . -type f -name '*.beam' -delete"
    fi
  fi
}

push_cookie() {
  local host="$1"
  log "Installing Erlang cookie on ${host}"
  scp "${PROJECT_ROOT}/${COOKIE_FILE}" "${REMOTE_USER}@${host}:/root/.erlang.cookie"
  ssh -o BatchMode=yes "${REMOTE_USER}@${host}" "chmod 400 /root/.erlang.cookie"
}

remote_build() {
  local host="$1"
  log "Building Java and Erlang remotely on ${host}"
  ssh -o BatchMode=yes "${REMOTE_USER}@${host}" \
    "set -euo pipefail; \
     set +u; \
     source /root/.sdkman/bin/sdkman-init.sh; \
     set -u; \
     cd '${REMOTE_BASE_DIR}'; \
     mkdir -p ebin; \
     erlc -o ebin ./*.erl; \
      mvn -q -DskipTests clean package; \
      test -f target/trader-client-1.0-SNAPSHOT.jar"
}

remote_cleanup() {
  local host="$1"
  local node_name="$2"

  if [[ "${CLEAN_START}" != "1" ]]; then
    return 0
  fi

  log "Resetting runtime state on ${host} (${node_name})"
  if ! ssh -o BatchMode=yes "${REMOTE_USER}@${host}" \
     "set +e; \
      set +u; \
      source /root/.sdkman/bin/sdkman-init.sh; \
      set -u; \
      cd '${REMOTE_BASE_DIR}'; \
      mkdir -p logs run; \
      if [ -f \"run/erl-${node_name}.pid\" ]; then oldpid=\$(cat \"run/erl-${node_name}.pid\"); if [ -n \"\$oldpid\" ] && kill -0 \"\$oldpid\" >/dev/null 2>&1; then kill \"\$oldpid\" || true; sleep 2; fi; rm -f \"run/erl-${node_name}.pid\"; fi; \
      if [ -f \"run/java-${node_name}.pid\" ]; then oldpid=\$(cat \"run/java-${node_name}.pid\"); if [ -n \"\$oldpid\" ] && kill -0 \"\$oldpid\" >/dev/null 2>&1; then kill \"\$oldpid\" || true; sleep 2; fi; rm -f \"run/java-${node_name}.pid\"; fi; \
      pkill -f '[e]rl.*-name ${node_name}@${host}' || true; \
      pkill -f '[j]ava.*trader-client-1.0-SNAPSHOT.jar' || true; \
      if command -v ss >/dev/null 2>&1; then \
        ws_pid=\$(ss -ltnp 'sport = :8085' 2>/dev/null | sed -n 's/.*pid=\\([0-9]\\+\\),.*/\\1/p' | head -n 1 || true); \
        case \"\$ws_pid\" in \"\"|\"\$\$\") : ;; *) kill \"\$ws_pid\" || true; sleep 2 ;; esac; \
      fi; \
      rm -rf logs/* run/* Mnesia* || true; \
      true"; then
    log "Cleanup failed on ${host}; continuing."
  fi
}

start_remote_node() {
  local host="$1"
  local node_name="$2"
  local primary_remote="$3"
  local backup_remote="$4"

  log "Starting exchange services on ${host} as ${node_name}"
  if ! ssh -o BatchMode=yes "${REMOTE_USER}@${host}" \
      "REMOTE_BASE_DIR='${REMOTE_BASE_DIR}' NODE_NAME='${node_name}' NODE_HOST='${host}' NODE_A_IP='${NODE_A_IP}' NODE_B_IP='${NODE_B_IP}' NODE_LIST='${NODE_LIST}' ERLANG_COOKIE='${ERLANG_COOKIE}' PRIMARY_REMOTE='${primary_remote}' BACKUP_REMOTE='${backup_remote}' bash -s" <<'REMOTE_START'; then
set -euo pipefail
set +u
source /root/.sdkman/bin/sdkman-init.sh
set -u

cd "${REMOTE_BASE_DIR}"
mkdir -p logs run
: > "logs/deploy-${NODE_NAME}.log"
exec >> "logs/deploy-${NODE_NAME}.log" 2>&1
set -x

sed -i 's/\r$//' start_node_a.sh start_node_b.sh setup_mnesia.sh || true
chmod +x start_node_a.sh start_node_b.sh || true

export NODE_A_IP="${NODE_A_IP}"
export NODE_B_IP="${NODE_B_IP}"
export STOCK_CLUSTER_NODES="${NODE_LIST}"
export ERLANG_COOKIE="${ERLANG_COOKIE}"
export TRADER_BACKEND_NODES="${PRIMARY_REMOTE},${BACKUP_REMOTE}"
export TRADER_WS_HOST="${NODE_HOST}"
export TRADER_LOCAL_NODE_HOST="${NODE_HOST}"

epmd -daemon >/dev/null 2>&1 || true

set +e
erl_alive=0
if [ -f "run/erl-${NODE_NAME}.pid" ]; then
  oldpid="$(cat "run/erl-${NODE_NAME}.pid")"
  if [ -n "${oldpid}" ] && kill -0 "${oldpid}" >/dev/null 2>&1; then
    erl_alive=1
  fi
fi
if [ "${erl_alive}" -eq 0 ]; then
  : > "logs/${NODE_NAME}.log"
  nohup erl -name "${NODE_NAME}@${NODE_HOST}" -setcookie "${ERLANG_COOKIE}" -mnesia schema_location ram -pa "${REMOTE_BASE_DIR}/ebin" -eval 'application:ensure_all_started(exchange_app), timer:sleep(infinity).' -noshell -noinput </dev/null > "logs/${NODE_NAME}.log" 2>&1 &
  echo $! > "run/erl-${NODE_NAME}.pid"
else
  echo "[deploy] Erlang node already running for ${NODE_NAME}."
fi

java_alive=0
if [ -f "run/java-${NODE_NAME}.pid" ]; then
  oldpid="$(cat "run/java-${NODE_NAME}.pid")"
  if [ -n "${oldpid}" ] && kill -0 "${oldpid}" >/dev/null 2>&1; then
    java_alive=1
  fi
fi
if [ "${java_alive}" -eq 0 ]; then
  if command -v ss >/dev/null 2>&1; then
    ws_pid="$(ss -ltnp 'sport = :8085' 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\),.*/\1/p' | head -n 1 || true)"
    case "${ws_pid}" in ""|"$$") : ;; *) kill "${ws_pid}" || true; sleep 2 ;; esac
  fi
  : > "logs/trader-client-${NODE_NAME}.log"
  nohup java -jar target/trader-client-1.0-SNAPSHOT.jar </dev/null > "logs/trader-client-${NODE_NAME}.log" 2>&1 &
  echo $! > "run/java-${NODE_NAME}.pid"
else
  echo "[deploy] Java gateway already running for ${NODE_NAME}."
fi
set -e

sleep 5
erl_pid="$(cat "run/erl-${NODE_NAME}.pid" 2>/dev/null || true)"
java_pid="$(cat "run/java-${NODE_NAME}.pid" 2>/dev/null || true)"
if [ -z "${erl_pid}" ] || ! kill -0 "${erl_pid}" >/dev/null 2>&1; then
  echo "[deploy] Erlang failed to stay up on ${NODE_HOST}"
  tail -n 120 "logs/${NODE_NAME}.log" || true
  exit 1
fi
if [ -z "${java_pid}" ] || ! kill -0 "${java_pid}" >/dev/null 2>&1; then
  echo "[deploy] Java gateway failed to stay up on ${NODE_HOST}"
  tail -n 120 "logs/trader-client-${NODE_NAME}.log" || true
  exit 1
fi
REMOTE_START
    
    log "Remote start failed on ${host}. Dumping logs..."
    ssh -o BatchMode=yes "${REMOTE_USER}@${host}" \
       "set -euo pipefail; \
        cd '${REMOTE_BASE_DIR}'; \
        echo '[deploy] --- logs directory ---'; ls -la logs || true; \
        echo '[deploy] --- run directory ---'; ls -la run || true; \
        echo '[deploy] --- deploy log ---'; tail -n 200 "logs/deploy-${node_name}.log" || true; \
        echo '[deploy] --- erlang log ---'; tail -n 200 "logs/${node_name}.log" || true; \
        echo '[deploy] --- java log ---'; tail -n 200 "logs/trader-client-${node_name}.log" || true"
    exit 1
  fi
}

verify_cluster() {
  log "Verifying active-active node connectivity and Java gateways"
  ssh -o BatchMode=yes "${REMOTE_USER}@${NODE_A_IP}" \
    "set -euo pipefail; \
     set +u; \
     source /root/.sdkman/bin/sdkman-init.sh; \
     set -u; \
      erl -noshell -name verify@${NODE_A_IP} -setcookie '${ERLANG_COOKIE}' -eval 'io:format(\"~p\", [net_adm:ping('\"'\"'nodeB@${NODE_B_IP}'\"'\"')]), halt().' | grep -F 'pong' >/dev/null; \
      test -f '/opt/distributed-exchange/run/java-nodeA.pid' && kill -0 \$(cat '/opt/distributed-exchange/run/java-nodeA.pid') >/dev/null 2>&1"
  ssh -o BatchMode=yes "${REMOTE_USER}@${NODE_B_IP}" \
    "set -euo pipefail; \
     set +u; \
     source /root/.sdkman/bin/sdkman-init.sh; \
     set -u; \
     erl -noshell -name verify@${NODE_B_IP} -setcookie '${ERLANG_COOKIE}' -eval 'io:format(\"~p\", [net_adm:ping('\"'\"'nodeA@${NODE_A_IP}'\"'\"')]), halt().' | grep -F 'pong' >/dev/null; \
     test -f '/opt/distributed-exchange/run/java-nodeB.pid' && kill -0 \$(cat '/opt/distributed-exchange/run/java-nodeB.pid') >/dev/null 2>&1"
}

main() {
  require_cmd ssh
  require_cmd scp

  if [[ ! -f "${PROJECT_ROOT}/${COOKIE_FILE}" ]]; then
    echo "Missing cookie file: ${PROJECT_ROOT}/${COOKIE_FILE}" >&2
    exit 1
  fi

  if is_target_node "nodeA"; then
    remote_prepare "${NODE_A_IP}"
  fi
  if is_target_node "nodeB"; then
    remote_prepare "${NODE_B_IP}"
  fi

  if is_target_node "nodeA"; then
    sync_workspace "${NODE_A_IP}"
    push_cookie "${NODE_A_IP}"
    remote_build "${NODE_A_IP}"
    remote_cleanup "${NODE_A_IP}" "nodeA"
    start_remote_node "${NODE_A_IP}" "nodeA" "nodeA@${NODE_A_IP}" "nodeB@${NODE_B_IP}"
  fi

  if is_target_node "nodeB"; then
    sync_workspace "${NODE_B_IP}"
    push_cookie "${NODE_B_IP}"
    remote_build "${NODE_B_IP}"
    remote_cleanup "${NODE_B_IP}" "nodeB"
    start_remote_node "${NODE_B_IP}" "nodeB" "nodeB@${NODE_B_IP}" "nodeA@${NODE_A_IP}"
  fi

  if [[ -z "${TARGET_NODE}" ]]; then
    verify_cluster
  fi
  log "Remote build + deployment completed successfully."
}

main "$@"
