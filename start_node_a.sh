#!/usr/bin/env bash
set -euo pipefail

NODE_A_IP="${NODE_A_IP:-10.2.1.3}"
NODE_B_IP="${NODE_B_IP:-10.2.1.14}"
ERLANG_COOKIE="${ERLANG_COOKIE:-exchange_cookie}"
export STOCK_CLUSTER_NODES="${STOCK_CLUSTER_NODES:-nodeA@${NODE_A_IP},nodeB@${NODE_B_IP}}"

exec erl -name "nodeA@${NODE_A_IP}" -setcookie "${ERLANG_COOKIE}" -mnesia schema_location ram -pa ebin -eval "application:ensure_all_started(exchange_app)."
