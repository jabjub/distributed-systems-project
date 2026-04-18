@echo off
title Node A - VirtualTrade Exchange (LEADER)
echo Starting Node A and linking to Node B...

set STOCK_CLUSTER_NODES=exchange_a@127.0.0.1,exchange_b@127.0.0.1
erl -name exchange_a@127.0.0.1 -setcookie stockcookie -pa ebin -eval "application:ensure_all_started(exchange_app)."