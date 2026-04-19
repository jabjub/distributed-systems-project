@echo off
title Node A - VirtualTrade Exchange (LEADER)
color 0A

echo ===================================================
echo  STARTING NODE A (LEADER)
echo ===================================================

set STOCK_CLUSTER_NODES=exchange_a@127.0.0.1,exchange_b@127.0.0.1
erl -name exchange_a@127.0.0.1 -setcookie exchange_cookie -mnesia schema_location ram -pa ebin -eval "application:ensure_all_started(exchange_app)."
