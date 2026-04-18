import org.java_websocket.WebSocket;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.server.WebSocketServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Scanner;

public class TraderClient {
    private final String primaryHost;
    private final int primaryPort;
    private final String backupHost;
    private final int backupPort;

    private final Object connectionLock = new Object();
    private final List<String> sentSubscriptions = Collections.synchronizedList(new ArrayList<>());

    private volatile Socket socket;
    private volatile BufferedReader reader;
    private volatile BufferedWriter writer;
    private volatile boolean running = true;
    private volatile boolean reconnecting = false;
    private volatile long lastPongAt = System.currentTimeMillis();
    private volatile String currentHost;
    private volatile int currentPort;

    private Thread readerThread;
    private Thread heartbeatThread;

    // NEW: The embedded WebSocket Server for the UI
    private DashboardServer dashboardServer;

    public TraderClient(String primaryHost, int primaryPort, String backupHost, int backupPort) {
        this.primaryHost = primaryHost;
        this.primaryPort = primaryPort;
        this.backupHost = backupHost;
        this.backupPort = backupPort;
        this.currentHost = primaryHost;
        this.currentPort = primaryPort;
    }

    public static void main(String[] args) throws Exception {
        String primaryHost = args.length > 0 ? args[0] : "127.0.0.1";
        int primaryPort = args.length > 1 ? Integer.parseInt(args[1]) : 9000;
        String backupHost = args.length > 2 ? args[2] : "127.0.0.1";
        int backupPort = args.length > 3 ? Integer.parseInt(args[3]) : 9001;

        TraderClient client = new TraderClient(primaryHost, primaryPort, backupHost, backupPort);

        // 1. Start the WebSocket Server for the UI on port 8085
        client.startWebSocketServer(8085);

        // 2. Connect to the Erlang Backend
        client.connectInitial();
        client.startReaderThread();
        client.startHeartbeatThread();

        System.out.println("=========================================");
        System.out.println(" MIDDLEWARE GATEWAY ONLINE");
        System.out.println(" 1. Erlang TCP connected on " + client.currentPort);
        System.out.println(" 2. Web UI listening on ws://localhost:8085");
        System.out.println(" Type 'QUIT' to exit.");
        System.out.println("=========================================");

        Scanner scanner = new Scanner(System.in);
        while (client.running) {
            String input = scanner.nextLine();
            if ("QUIT".equalsIgnoreCase(input.trim())) {
                System.out.println("Shutting down gateway...");
                System.exit(0);
            }
            if (input.trim().length() > 0) {
                client.sendCommand(input.trim());
            }
        }
        scanner.close();
    }

    // --- NEW: WebSocket Server Logic ---
    private void startWebSocketServer(int port) {
        dashboardServer = new DashboardServer(new InetSocketAddress(port));
        dashboardServer.start();
    }

    private class DashboardServer extends WebSocketServer {
        public DashboardServer(InetSocketAddress address) {
            super(address);
        }

        @Override
        public void onOpen(WebSocket conn, ClientHandshake handshake) {
            System.out.println("[WEB] Browser connected to dashboard.");
        }

        @Override
        public void onClose(WebSocket conn, int code, String reason, boolean remote) {
            System.out.println("[WEB] Browser disconnected.");
        }

        @Override
        public void onMessage(WebSocket conn, String message) {
            // Forward messages from the browser straight to Erlang
            try {
                System.out.println("[WEB -> ERLANG] " + message);
                sendCommand(message);
            } catch (IOException e) {
                conn.send("ERROR: Middleware disconnected from Erlang.");
            }
        }

        @Override
        public void onError(WebSocket conn, Exception ex) {
            ex.printStackTrace();
        }

        @Override
        public void onStart() {
            System.out.println("[WEB] WebSocket server started successfully.");
        }
    }
    // -----------------------------------

    private void connectInitial() {
        System.out.println("Attempting to connect to exchange cluster...");
        establishConnectionLocked();
    }

    private void establishConnectionLocked() {
        int waitTime = 5000;
        final int MAX_WAIT = 60000;

        while (running) {
            try {
                connectTo(primaryHost, primaryPort);
                currentHost = primaryHost;
                currentPort = primaryPort;
                return;
            } catch (IOException primaryFailure) {
                try {
                    connectTo(backupHost, backupPort);
                    currentHost = backupHost;
                    currentPort = backupPort;
                    return;
                } catch (IOException backupFailure) {
                    System.out.println("All nodes down. Retrying in " + (waitTime / 1000) + " seconds...");
                    sleepQuietly(waitTime);
                    waitTime = Math.min(waitTime * 2, MAX_WAIT);
                }
            }
        }
    }

    private void connectTo(String host, int port) throws IOException {
        Socket newSocket = new Socket();
        SocketAddress address = new InetSocketAddress(host, port);
        newSocket.connect(address, 3000);
        newSocket.setTcpNoDelay(true);
        synchronized (connectionLock) {
            closeCurrentLocked();
            socket = newSocket;
            reader = new BufferedReader(new InputStreamReader(newSocket.getInputStream(), StandardCharsets.UTF_8));
            writer = new BufferedWriter(new OutputStreamWriter(newSocket.getOutputStream(), StandardCharsets.UTF_8));
            lastPongAt = System.currentTimeMillis();
        }
    }

    private void startReaderThread() {
        readerThread = new Thread(this::readerLoop, "trader-reader");
        readerThread.setDaemon(false);
        readerThread.start();
    }

    private void startHeartbeatThread() {
        heartbeatThread = new Thread(this::heartbeatLoop, "trader-heartbeat");
        heartbeatThread.setDaemon(true);
        heartbeatThread.start();
    }

    private void readerLoop() {
        while (running) {
            try {
                BufferedReader currentReader = reader;
                if (currentReader == null) {
                    Thread.yield();
                    continue;
                }
                String line = currentReader.readLine();
                if (line == null) {
                    throw new IOException("socket closed");
                }

                if ("PONG".equals(line)) {
                    lastPongAt = System.currentTimeMillis();
                } else {
                    System.out.println("[ERLANG -> WEB] " + line);
                    // NEW: Broadcast Erlang's message to the Web Dashboard!
                    if (dashboardServer != null) {
                        dashboardServer.broadcast(line);
                    }
                }

            } catch (IOException readerFailure) {
                reconnect();
            }
        }
    }

    private void heartbeatLoop() {
        while (running) {
            try {
                sendCommand("PING");
            } catch (IOException ignored) {}
            sleepQuietly(5000);
            if (System.currentTimeMillis() - lastPongAt > 10000) {
                System.out.println("Heartbeat timeout. Server unresponsive during sync.");
                reconnect();
            }
        }
    }

    public void sendCommand(String cmd) throws IOException {
        synchronized (connectionLock) {
            if (cmd.startsWith("SUB ") && !sentSubscriptions.contains(cmd)) {
                sentSubscriptions.add(cmd);
            }
            try {
                writeLineLocked(cmd);
            } catch (IOException sendFailure) {
                reconnect();
                if (!cmd.startsWith("SUB ")) {
                    writeLineLocked(cmd);
                }
            }
        }
    }

    private void writeLineLocked(String cmd) throws IOException {
        BufferedWriter currentWriter = writer;
        if (currentWriter == null) {
            throw new IOException("socket unavailable");
        }
        currentWriter.write(cmd);
        currentWriter.write("\n");
        currentWriter.flush();
    }

    private void reconnect() {
        synchronized (connectionLock) {
            if (reconnecting) {
                return;
            }
            reconnecting = true;
            try {
                System.out.println("Connection lost. Attempting failover...");
                closeCurrentLocked();
                establishConnectionLocked();
                replaySubscriptionsLocked();
                System.out.println("Reconnected to " + currentHost + ":" + currentPort);
            } catch (IOException e) {
                System.err.println("Error during failover data replay: " + e.getMessage());
            } finally {
                reconnecting = false;
            }
        }
    }

    private void replaySubscriptionsLocked() throws IOException {
        List<String> snapshot = new ArrayList<>(sentSubscriptions);
        for (String subscription : snapshot) {
            writeLineLocked(subscription);
        }
    }

    private void closeCurrentLocked() {
        try { if (writer != null) writer.flush(); } catch (IOException ignored) {}
        try { if (reader != null) reader.close(); } catch (IOException ignored) {}
        try { if (socket != null && !socket.isClosed()) socket.close(); } catch (IOException ignored) {}
        socket = null;
        reader = null;
        writer = null;
    }

    private static void sleepQuietly(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }
}