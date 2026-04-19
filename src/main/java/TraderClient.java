import org.java_websocket.WebSocket;
import org.java_websocket.handshake.ClientHandshake;
import org.java_websocket.server.WebSocketServer;
import com.ericsson.otp.erlang.OtpErlangAtom;
import com.ericsson.otp.erlang.OtpErlangBinary;
import com.ericsson.otp.erlang.OtpErlangDouble;
import com.ericsson.otp.erlang.OtpErlangObject;
import com.ericsson.otp.erlang.OtpErlangPid;
import com.ericsson.otp.erlang.OtpErlangString;
import com.ericsson.otp.erlang.OtpErlangTuple;
import com.ericsson.otp.erlang.OtpMbox;
import com.ericsson.otp.erlang.OtpNode;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Scanner;
import java.util.UUID;

public class TraderClient {
    private final String primaryHost;
    private final int primaryPort;
    private final String backupHost;
    private final int backupPort;

    private final Object connectionLock = new Object();
    private final List<String> sentSubscriptions = Collections.synchronizedList(new ArrayList<>());

    private static final String ERLANG_COOKIE = "exchange_cookie";
    private static final String ERLANG_SERVER = "price_server";

    private volatile OtpNode otpNode;
    private volatile OtpMbox mbox;
    private volatile boolean running = true;
    private volatile boolean reconnecting = false;
    private volatile long lastPongAt = System.currentTimeMillis();
    private volatile String currentHost;
    private volatile int currentPort;

    private Thread readerThread;
    private Thread heartbeatThread;
    private static final int HEARTBEAT_FAILURE_THRESHOLD = 3;

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
        broadcastSystemStatus("Connecting to exchange cluster...");
        try {
            establishConnectionLocked();
        } catch (IOException e) {
            throw new RuntimeException("Unable to connect to Erlang cluster", e);
        }
    }

    private void establishConnectionLocked() throws IOException {
        int waitTime = 5000;
        final int MAX_WAIT = 60000;

        while (running) {
            try {
                connectTo(primaryHost, primaryPort);
                currentPort = primaryPort;
                return;
            } catch (IOException primaryFailure) {
                try {
                    connectTo(backupHost, backupPort);
                    currentPort = backupPort;
                    return;
                } catch (IOException backupFailure) {
                    String retryMsg = "All nodes down. Retrying in " + (waitTime / 1000) + " seconds...";
                    System.out.println(retryMsg);
                    broadcastSystemStatus(retryMsg);
                    sleepQuietly(waitTime);
                    waitTime = Math.min(waitTime * 2, MAX_WAIT);
                }
            }
        }
        throw new IOException("gateway stopped");
    }

    private void connectTo(String host, int port) throws IOException {
        String remoteNode = resolveRemoteNode(host, port);
        String localNode = buildLocalNodeName(remoteNode);
        OtpNode newNode = new OtpNode(localNode, ERLANG_COOKIE);
        OtpMbox newMbox = newNode.createMbox();

        if (!newNode.ping(remoteNode, 3000)) {
            newNode.close();
            throw new IOException("cannot reach " + remoteNode);
        }

        synchronized (connectionLock) {
            closeCurrentLocked();
            otpNode = newNode;
            mbox = newMbox;
            currentHost = remoteNode;
            lastPongAt = System.currentTimeMillis();
        }
        broadcastSystemStatus("Connected to backend node " + remoteNode + ".");
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
                OtpMbox currentMbox = mbox;
                if (currentMbox == null) {
                    sleepQuietly(50);
                    continue;
                }
                OtpErlangObject msg = currentMbox.receive(1000);
                if (msg == null) {
                    continue;
                }
                if (msg instanceof OtpErlangTuple) {
                    OtpErlangTuple tuple = (OtpErlangTuple) msg;
                    if (tuple.arity() == 4 && tuple.elementAt(0) instanceof OtpErlangAtom) {
                        String tag = ((OtpErlangAtom) tuple.elementAt(0)).atomValue();
                        if ("alert".equals(tag)) {
                            String stock = otpToString(tuple.elementAt(1));
                            String price = otpToString(tuple.elementAt(2));
                            String rawSub = otpToString(tuple.elementAt(3));
                            sentSubscriptions.remove(rawSub);
                            String payload = "ALERT [" + rawSub + "] fulfilled at " + price;
                            System.out.println("[ERLANG -> WEB] " + payload + " (" + stock + ")");
                            if (dashboardServer != null) {
                                dashboardServer.broadcast(payload);
                            }
                            continue;
                        }
                    }
                }
            } catch (Exception readerFailure) {
                if (!running) {
                    return;
                }
                reconnect();
            }
        }
    }

    private void heartbeatLoop() {
        int failedHeartbeats = 0;
        while (running) {
            sleepQuietly(5000);
            String remoteNode = currentHost;
            OtpNode nodeSnapshot = otpNode;
            boolean heartbeatOk = nodeSnapshot != null
                && remoteNode != null
                && nodeSnapshot.ping(remoteNode, 1500);
            if (!heartbeatOk) {
                failedHeartbeats++;
            } else {
                failedHeartbeats = 0;
                lastPongAt = System.currentTimeMillis();
            }

            if (failedHeartbeats < HEARTBEAT_FAILURE_THRESHOLD) {
                continue;
            }

            failedHeartbeats = 0;
            if (running) {
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
                sendToErlangLocked(cmd);
            } catch (IOException sendFailure) {
                reconnect();
                if (!cmd.startsWith("SUB ")) {
                    sendToErlangLocked(cmd);
                }
            }
        }
    }

    private void sendToErlangLocked(String cmd) throws IOException {
        OtpMbox currentMbox = mbox;
        String remoteNode = currentHost;
        if (currentMbox == null || remoteNode == null) {
            throw new IOException("otp mailbox unavailable");
        }

        String[] tokens = cmd.trim().split("\\s+");
        if (tokens.length == 3 && "SUB".equalsIgnoreCase(tokens[0])) {
            double threshold;
            try {
                threshold = Double.parseDouble(tokens[2]);
            } catch (NumberFormatException e) {
                throw new IOException("Invalid threshold in command: " + cmd, e);
            }

            OtpErlangPid javaPid = currentMbox.self();
            OtpErlangTuple payload = new OtpErlangTuple(new OtpErlangObject[]{
                new OtpErlangAtom("subscribe"),
                javaPid,
                new OtpErlangBinary(tokens[1].getBytes(StandardCharsets.UTF_8)),
                new OtpErlangDouble(threshold),
                new OtpErlangBinary(cmd.getBytes(StandardCharsets.UTF_8))
            });
            currentMbox.send(ERLANG_SERVER, remoteNode, payload);
            return;
        }

        OtpErlangTuple passthrough = new OtpErlangTuple(new OtpErlangObject[]{
            new OtpErlangAtom("command"),
            currentMbox.self(),
            new OtpErlangBinary(cmd.getBytes(StandardCharsets.UTF_8))
        });
        currentMbox.send(ERLANG_SERVER, remoteNode, passthrough);
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
                sleepQuietly(300);
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
            sendToErlangLocked(subscription);
        }
    }

    private void closeCurrentLocked() {
        OtpMbox oldMbox = mbox;
        OtpNode oldNode = otpNode;
        mbox = null;
        otpNode = null;
        if (oldMbox != null) {
            oldMbox.close();
        }
        if (oldNode != null) {
            oldNode.close();
        }
    }

    private static String resolveRemoteNode(String hostOrNode, int port) {
        if (hostOrNode.contains("@")) {
            return hostOrNode;
        }
        String host = hostOrNode.trim().isEmpty() ? "127.0.0.1" : hostOrNode.trim();
        String baseName = port == 9001 ? "exchange_b" : "exchange_a";
        return baseName + "@" + host;
    }

    private static String buildLocalNodeName(String remoteNode) {
        String hostPart = "127.0.0.1";
        int at = remoteNode.indexOf('@');
        if (at >= 0 && at + 1 < remoteNode.length()) {
            hostPart = remoteNode.substring(at + 1);
        } else {
            try {
                hostPart = InetAddress.getLocalHost().getHostAddress();
            } catch (Exception ignored) {
                hostPart = "127.0.0.1";
            }
        }
        return "trader_client_" + UUID.randomUUID().toString().replace("-", "") + "@" + hostPart;
    }

    private static String otpToString(OtpErlangObject value) throws Exception {
        if (value instanceof OtpErlangBinary) {
            return new String(((OtpErlangBinary) value).binaryValue());
        }
        if (value instanceof OtpErlangDouble) {
            return String.format("%.2f", ((OtpErlangDouble) value).doubleValue());
        }
        if (value instanceof OtpErlangString) {
            return ((OtpErlangString) value).stringValue();
        }
        return value.toString();
    }

    private static void sleepQuietly(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    private void broadcastSystemStatus(String message) {
        if (dashboardServer != null) {
            dashboardServer.broadcast("SYSTEM: " + message);
        }
    }
}
