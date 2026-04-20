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
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Scanner;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

public class TraderClient {
    private static final String DEFAULT_NODE_A = "nodeA@10.2.1.3";
    private static final String DEFAULT_NODE_B = "nodeB@10.2.1.14";
    private static final int DEFAULT_NODE_A_PORT = 9000;
    private static final int DEFAULT_NODE_B_PORT = 9001;
    private static final int DEFAULT_WS_PORT = 8085;
    private static final AtomicInteger SESSION_ROUND_ROBIN = new AtomicInteger(0);

    private final List<BackendEndpoint> backendEndpoints;

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

    public TraderClient(List<BackendEndpoint> backendEndpoints) {
        if (backendEndpoints == null || backendEndpoints.isEmpty()) {
            throw new IllegalArgumentException("At least one backend endpoint is required.");
        }
        this.backendEndpoints = Collections.unmodifiableList(new ArrayList<>(backendEndpoints));
        this.currentHost = this.backendEndpoints.get(0).remoteNode;
        this.currentPort = this.backendEndpoints.get(0).port;
    }

    public static void main(String[] args) throws Exception {
        List<BackendEndpoint> backends = parseBackends(args);
        int websocketPort = parseIntEnv("TRADER_WS_PORT", DEFAULT_WS_PORT);
        String websocketHost = parseStringEnv("TRADER_WS_HOST", "0.0.0.0");

        TraderClient client = new TraderClient(backends);

        // 1. Start the WebSocket Server for the UI on port 8085
        client.startWebSocketServer(websocketHost, websocketPort);

        // 2. Connect to the Erlang Backend
        client.connectInitial();
        client.startReaderThread();
        client.startHeartbeatThread();

        System.out.println("=========================================");
        System.out.println(" MIDDLEWARE GATEWAY ONLINE");
        System.out.println(" 1. Erlang TCP connected on " + client.currentPort);
        System.out.println(" 2. Web UI listening on ws://" + websocketHost + ":" + websocketPort);
        System.out.println(" Type 'QUIT' to exit.");
        System.out.println("=========================================");

        Scanner scanner = new Scanner(System.in);
        while (client.running) {
            if (!scanner.hasNextLine()) {
                sleepQuietly(500);
                continue;
            }
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
    private void startWebSocketServer(String host, int port) {
        dashboardServer = new DashboardServer(new InetSocketAddress(host, port));
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
            int startIndex = Math.floorMod(SESSION_ROUND_ROBIN.getAndIncrement(), backendEndpoints.size());
            IOException lastFailure = null;
            for (int i = 0; i < backendEndpoints.size(); i++) {
                BackendEndpoint endpoint = backendEndpoints.get((startIndex + i) % backendEndpoints.size());
                try {
                    connectTo(endpoint);
                    return;
                } catch (IOException connectFailure) {
                    lastFailure = connectFailure;
                }
            }

            String retryMsg = "All nodes down. Retrying in " + (waitTime / 1000) + " seconds...";
            System.out.println(retryMsg);
            if (lastFailure != null) {
                System.out.println("Last connection failure: " + lastFailure.getMessage());
            }
            broadcastSystemStatus(retryMsg);
            sleepQuietly(waitTime);
            waitTime = Math.min(waitTime * 2, MAX_WAIT);
        }
        throw new IOException("gateway stopped");
    }

    private void connectTo(BackendEndpoint endpoint) throws IOException {
        String remoteNode = endpoint.remoteNode;
        String localNode = buildLocalNodeName();
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
            currentHost = endpoint.remoteNode;
            currentPort = endpoint.port;
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
        String host = hostOrNode.trim().isEmpty() ? "10.2.1.3" : hostOrNode.trim();
        String baseName = port == DEFAULT_NODE_B_PORT ? "nodeB" : "nodeA";
        return baseName + "@" + host;
    }

    private static String buildLocalNodeName() {
        String hostPart = resolveLocalNodeHost();
        return "trader_client_" + UUID.randomUUID().toString().replace("-", "") + "@" + hostPart;
    }

    private static String resolveLocalNodeHost() {
        String configuredHost = parseStringEnv("TRADER_LOCAL_NODE_HOST", "");
        if (!configuredHost.isEmpty()) {
            return configuredHost;
        }
        try {
            return InetAddress.getLocalHost().getHostAddress();
        } catch (Exception ignored) {
            return "10.2.1.3";
        }
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

    private static List<BackendEndpoint> parseBackends(String[] args) {
        if (args.length >= 4) {
            BackendEndpoint first = new BackendEndpoint(resolveRemoteNode(args[0], Integer.parseInt(args[1])), Integer.parseInt(args[1]));
            BackendEndpoint second = new BackendEndpoint(resolveRemoteNode(args[2], Integer.parseInt(args[3])), Integer.parseInt(args[3]));
            return Arrays.asList(first, second);
        }

        String configuredNodes = firstNonBlank(
            args.length > 0 ? args[0] : null,
            System.getenv("TRADER_BACKEND_NODES"),
            DEFAULT_NODE_A + "," + DEFAULT_NODE_B
        );

        List<String> tokens = splitCsv(configuredNodes);
        List<BackendEndpoint> endpoints = new ArrayList<>();
        for (int i = 0; i < tokens.size(); i++) {
            String token = tokens.get(i);
            int defaultPort = (i % 2 == 0) ? DEFAULT_NODE_A_PORT : DEFAULT_NODE_B_PORT;
            String fallbackNodeName = (i % 2 == 0) ? "nodeA" : "nodeB";
            endpoints.add(parseSingleBackend(token, defaultPort, fallbackNodeName));
        }

        if (endpoints.isEmpty()) {
            endpoints.add(new BackendEndpoint(DEFAULT_NODE_A, DEFAULT_NODE_A_PORT));
            endpoints.add(new BackendEndpoint(DEFAULT_NODE_B, DEFAULT_NODE_B_PORT));
        }

        int startOffset = Math.floorMod(SESSION_ROUND_ROBIN.getAndIncrement(), endpoints.size());
        List<BackendEndpoint> ordered = new ArrayList<>(endpoints.size());
        for (int i = 0; i < endpoints.size(); i++) {
            ordered.add(endpoints.get((startOffset + i) % endpoints.size()));
        }
        return ordered;
    }

    private static BackendEndpoint parseSingleBackend(String raw, int defaultPort, String fallbackNodeName) {
        String token = raw == null ? "" : raw.trim();
        if (token.isEmpty()) {
            String fallbackNode = fallbackNodeName + "@10.2.1.3";
            return new BackendEndpoint(resolveRemoteNode(fallbackNode, defaultPort), defaultPort);
        }

        if (token.contains("@")) {
            return new BackendEndpoint(token, defaultPort);
        }

        String host = token;
        int port = defaultPort;
        int colonIdx = token.lastIndexOf(':');
        if (colonIdx > 0 && colonIdx < token.length() - 1) {
            host = token.substring(0, colonIdx).trim();
            try {
                port = Integer.parseInt(token.substring(colonIdx + 1).trim());
            } catch (NumberFormatException ignored) {
                port = defaultPort;
            }
        }

        String remoteNode = resolveRemoteNode(host, port);
        return new BackendEndpoint(remoteNode, port);
    }

    private static List<String> splitCsv(String raw) {
        List<String> result = new ArrayList<>();
        if (raw == null || raw.trim().isEmpty()) {
            return result;
        }
        String[] tokens = raw.split("[,;\\s]+");
        for (String token : tokens) {
            String trimmed = token.trim();
            if (!trimmed.isEmpty()) {
                result.add(trimmed);
            }
        }
        return result;
    }

    private static int parseIntEnv(String key, int fallback) {
        String raw = System.getenv(key);
        if (raw == null || raw.trim().isEmpty()) {
            return fallback;
        }
        try {
            return Integer.parseInt(raw.trim());
        } catch (NumberFormatException ignored) {
        }
        return fallback;
    }

    private static String parseStringEnv(String key, String fallback) {
        String raw = System.getenv(key);
        if (raw == null || raw.trim().isEmpty()) {
            return fallback;
        }
        return raw.trim();
    }

    private static String firstNonBlank(String... candidates) {
        for (String candidate : candidates) {
            if (candidate != null && !candidate.trim().isEmpty()) {
                return candidate.trim();
            }
        }
        return "";
    }

    private static final class BackendEndpoint {
        private final String remoteNode;
        private final int port;

        private BackendEndpoint(String remoteNode, int port) {
            this.remoteNode = remoteNode;
            this.port = port;
        }
    }
}
