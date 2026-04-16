#!/usr/bin/env bash
erl -name exchange_a@192.168.1.101 -setcookie stockcookie -pa ebin -s exchange_app start
