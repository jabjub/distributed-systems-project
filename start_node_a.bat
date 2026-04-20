@echo off
title Node A - VirtualTrade Exchange (LEADER)
color 0A

echo ===================================================
echo  STARTING NODE A (LEADER)
echo ===================================================

if "%NODE_A_IP%"=="" set NODE_A_IP=10.2.1.3
if "%NODE_B_IP%"=="" set NODE_B_IP=10.2.1.14
if "%ERLANG_COOKIE%"=="" set ERLANG_COOKIE=exchange_cookie
if "%STOCK_CLUSTER_NODES%"=="" set STOCK_CLUSTER_NODES=nodeA@%NODE_A_IP%,nodeB@%NODE_B_IP%
erl -name nodeA@%NODE_A_IP% -setcookie %ERLANG_COOKIE% -mnesia schema_location ram -pa ebin -eval "application:ensure_all_started(exchange_app)."
