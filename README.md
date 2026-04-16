# Distributed Exchange System

A distributed trading system built with Erlang and Java. This project utilizes Erlang nodes for the backend exchange logic and Mnesia for distributed database management, coupled with a Java-based client interface (`TraderClient`).

## Prerequisites
* **Erlang/OTP** (Ensure `erl` is added to your Windows PATH)
* **Java Development Kit (JDK)** (Ensure `javac` and `java` are in your Windows PATH)
* **PowerShell**

---

## Initial Setup & Compilation
Before running the system for the first time, you must compile the source code and generate your local database schemas. (Note: The `Mnesia` database folders are ignored by Git to prevent conflicts).

1. **Compile the Erlang Backend:**
   Open PowerShell in the project folder and run:
   erlc -o ebin/ *.erl

   Compile the Java Client:
Open PowerShell in the project folder and run:

PowerShell
javac TraderClient.java


Execution Guide

You must start the Erlang nodes with the correct cluster environment variables and cookies. Open two separate PowerShell windows inside the project folder.

In Window 1 (Node A):

PowerShell
$env:STOCK_CLUSTER_NODES="exchange_a@127.0.0.1,exchange_b@127.0.0.1"
erl -name exchange_a@127.0.0.1 -setcookie stockcookie -pa ebin


In Window 2 (Node B):

PowerShell
$env:STOCK_CLUSTER_NODES="exchange_a@127.0.0.1,exchange_b@127.0.0.1"
erl -name exchange_b@127.0.0.1 -setcookie stockcookie -pa ebin


Phase 2: Link & Load the Database (Erlang Shell)
Always execute this phase before starting the main application so the nodes have time to synchronize their Mnesia databases!

In Node A's Erlang Shell:
Ping Node B to establish the connection:

Erlang
net_adm:ping('exchange_b@127.0.0.1').

Wait for the shell to return pong before proceeding. If it returns pang, check your firewall settings)

Still in Node A, start Mnesia:

Erlang
mnesia:start().
In Node B's Erlang Shell:
Start Mnesia:

Erlang
mnesia:start().
(Node B will now silently sync up with Node A's database in the background).

Phase 3: Start the Stock Market (Erlang Shell)
Now that the database is running and synced, start the exchange application on both nodes.

In Node A:

Erlang
application:ensure_all_started(exchange_app).
(You should see the listener open on port 9000, and the TICKER will begin printing on Node A).

In Node B:

Erlang
application:ensure_all_started(exchange_app).
Phase 4: Launch the Frontend (PowerShell)
With the backend fully operational, launch the Java user interface.

Open a 3rd PowerShell window in the project folder and run:

java TraderClient 127.0.0.1 9000 127.0.0.1 9001

Troubleshooting & Resetting
pong doesn't appear: If net_adm:ping returns pang, check that your Windows Firewall is not blocking the Erlang Port Mapper Daemon (EPMD). Ensure both nodes are running simultaneously in separate windows.

Database/Mnesia Crash on Startup: If Erlang throws Mnesia errors or schemas fail to load, the local database files might be corrupted or out of sync.

Close all Erlang shells (q(). or Ctrl+C).

Delete the Mnesia.exchange_a@127.0.0.1 and Mnesia.exchange_b@127.0.0.1 folders from the project directory.

Start over completely from Phase 1.
