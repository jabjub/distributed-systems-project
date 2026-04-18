{application, exchange_app,
 [
  {description, "Distributed Stock Exchange Pub/Sub System"},
  {vsn, "1.0.0"},
  {registered, [exchange_sup, price_server, tcp_listener]},
  {applications,
   [kernel,
    stdlib,
    mnesia
   ]},
  {mod, {exchange_app, []}},
  {env, []}
 ]}.