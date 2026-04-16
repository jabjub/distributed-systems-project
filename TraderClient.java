import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
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
        client.connectInitial();
        client.startReaderThread();
        client.startHeartbeatThread();

        // 1. THE STATIC PART: Load default subscriptions automatically
        System.out.println("Loading default subscriptions...");
        client.sendCommand("SUB AAPL 151");
        client.sendCommand("SUB TSLA 205");

        // 2. THE INTERACTIVE PART: Keep the terminal open for new additions
        Scanner scanner = new Scanner(System.in);
        System.out.println("=========================================");
        System.out.println(" DEFAULTS LOADED. TERMINAL READY.");
        System.out.println(" Type more subscriptions (e.g., SUB MSFT 300)");
        System.out.println(" Type 'QUIT' to exit.");
        System.out.println("=========================================");

        while (client.running) {
            // This line keeps the program alive, waiting for your keyboard!
            String input = scanner.nextLine(); 
            
            if ("QUIT".equalsIgnoreCase(input.trim())) {
                System.out.println("Shutting down terminal...");
                System.exit(0);
            }
            
            if (input.trim().length() > 0) {
                client.sendCommand(input.trim());
                System.out.println("[SENT] " + input);
            }
        }
        scanner.close();
    }

    private void connectInitial() {
        System.out.println("Attempting to connect to exchange cluster...");
        establishConnectionLocked();
    }

    private void establishConnectionLocked() {
        int waitTime = 5000; // Start at 5 seconds
        final int MAX_WAIT = 60000; // Cap at 60 seconds

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
                    // Double the wait time for the next loop, but never exceed MAX_WAIT
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
                
                // --- THE SILENCER ---
                if ("PONG".equals(line)) {
                    // Update the heartbeat timer, but DO NOT print anything!
                    lastPongAt = System.currentTimeMillis();
                } else {
                    // If it's an ALERT or ACK, print it clearly on a new line
                    System.out.println("\n[SERVER] " + line);
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
            } catch (IOException ignored) {
            }

            // Wait 5 seconds before sending the next PING
            sleepQuietly(5000);

            // If the server hasn't answered a PING in 10 seconds, THEN we failover
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
                // Catch the exception thrown by replaySubscriptionsLocked()
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