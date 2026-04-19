@echo off
title Node B - VirtualTrade Exchange (BACKUP)
color 0B

echo ===================================================
echo  STARTING NODE B (BACKUP)
echo ===================================================

set STOCK_CLUSTER_NODES=exchange_a@127.0.0.1,exchange_b@127.0.0.1
erl -name exchange_b@127.0.0.1 -setcookie exchange_cookie -mnesia schema_location ram -pa ebin -eval "application:ensure_all_started(exchange_app)."
