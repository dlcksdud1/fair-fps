import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.*;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.nio.file.Files;
import java.nio.file.Path;

public class FairPlay {
    private static final int PORT = 7777;
    private static final Map<Integer, Client> clients =
        new ConcurrentHashMap<>();

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private static final ScheduledExecutorService coinScheduler =
        Executors.newSingleThreadScheduledExecutor();

    private static final AtomicInteger nextCoinId =
        new AtomicInteger(1);

    // 현재 존재하는 코인
    private static final Map<Integer, String> activeCoins =
        new ConcurrentHashMap<>();

    // 생성 지점별 코인 관리
    private static final Map<String, Integer> occupiedSpawns =
        new ConcurrentHashMap<>();

    private static final Map<Integer, double[]> playerPositions =
        new ConcurrentHashMap<>();

    private static final Map<Integer, int[]> playerCurrencies =
        new ConcurrentHashMap<>();

    private static final double PICKUP_DISTANCE = 73.0;

    private static final int MATCH_DURATION = 180;

    private static volatile boolean matchRunning = false;
    private static volatile int remainingSeconds = MATCH_DURATION;

    private static final int MAGAZINE_SIZE = 12;
    private static final long FIRE_INTERVAL_NS = 200_000_000L;
    private static final long RELOAD_DURATION_MS = 1500L;

    private static final double MUZZLE_OFFSET_X = 32.98;
    private static final double MUZZLE_OFFSET_Y = 9.0;

    private static final Map<Integer, WeaponState> weapons =
        new ConcurrentHashMap<>();

    // 코인 생성·획득·스포너 상태를 보호할 잠금
    private static final Object coinLock = new Object();

    private static final List<SpawnerConfig> spawners =
        new ArrayList<>();

    private static final Random random = new Random();

    public static void main(String[] args) throws IOException {
        startMatchTimer();
        loadSpawnConfig();
        for (SpawnerConfig config : spawners) {
            coinScheduler.scheduleAtFixedRate(
                () -> spawnRandomCoin(config),
                0,
                config.intervalMs,
                TimeUnit.MILLISECONDS
            );
        }
        try (ServerSocket server = new ServerSocket(PORT)) {
            System.out.println("FairPlay 서버 시작: " + PORT);

            while (true) {
                Socket socket = server.accept();
                int id;

                synchronized (clients) {
                    id = !clients.containsKey(1) ? 1 :
                        !clients.containsKey(2) ? 2 : 0;

                    if (id == 0) {
                        socket.close();
                        continue;
                    }

                    Client client = new Client(id, socket);
                    clients.put(id, client);
                    client.start();
                }
            }
        }
    }

    static void spawnCoin(
        String spawnKey,
        String coinType,
        double x,
        double y
    ){
        if (!matchRunning) {
            return;
        }
        // 해당 위치에 이미 코인이 있으면 생성하지 않음
        synchronized (coinLock) {
            if (occupiedSpawns.containsKey(spawnKey)) {
                return;
            }

            int coinId = nextCoinId.getAndIncrement();

            String message = MAPPER.createObjectNode()
                .put("type", "coin_spawn")
                .put("coin_id", coinId)
                .put("coin_type", coinType)
                .put("amount", 1)
                .put("x", x)
                .put("y", y)
                .toString();

            occupiedSpawns.put(spawnKey, coinId);
            activeCoins.put(coinId, message);

            broadcast(message, 0);

            System.out.println(
                "코인 생성 ID=" + coinId
                    + ", 종류=" + coinType
                    + ", 위치=(" + x + ", " + y + ")"
            );
        }
    }

    static void collectCoin(Client client, int coinId) {
        synchronized (coinLock) {

            if (!matchRunning) {
                client.send(MAPPER.createObjectNode()
                    .put("type", "coin_rejected")
                    .put("coin_id", coinId)
                    .put("reason", "match_not_running")
                    .toString());
                return;
            }

            String coinMessage = activeCoins.get(coinId);

            if (coinMessage == null) {
                client.send(MAPPER.createObjectNode()
                    .put("type", "coin_rejected")
                    .put("coin_id", coinId)
                    .put("reason", "not_found")
                    .toString());
                return;
            }

            try {
                JsonNode coin = MAPPER.readTree(coinMessage);

                double coinX = coin.path("x").asDouble();
                double coinY = coin.path("y").asDouble();

                double[] playerPos = playerPositions.get(client.id);

                if (playerPos == null) {
                    client.send(MAPPER.createObjectNode()
                        .put("type", "coin_rejected")
                        .put("coin_id", coinId)
                        .put("reason", "position_unknown")
                        .toString());
                    return;
                }

                double distance = Math.hypot(
                    playerPos[0] - coinX,
                    playerPos[1] - coinY
                );

                if (distance > PICKUP_DISTANCE) {
                    System.out.printf(
                        "[REJECT] Player%d Coin%d | "
                            + "Player=(%.1f, %.1f) "
                            + "Coin=(%.1f, %.1f) "
                            + "Distance=%.1f "
                            + "Limit=%.1f%n",
                        client.id,
                        coinId,
                        playerPos[0],
                        playerPos[1],
                        coinX,
                        coinY,
                        distance,
                        PICKUP_DISTANCE
                    );

                    client.send(MAPPER.createObjectNode()
                        .put("type", "coin_rejected")
                        .put("coin_id", coinId)
                        .put("reason", "too_far")
                        .toString());
                    return;
                }

                String coinType = coin.path("coin_type").asText();
                int amount = coin.path("amount").asInt();

                if ((!coinType.equals("silver")
                    && !coinType.equals("diamond"))
                    || amount <= 0) {
                    return;
                }

                // 검증 완료: 서버에서 코인 제거
                activeCoins.remove(coinId);

                // 해당 스포너의 생성 지점 비우기
                occupiedSpawns.entrySet().removeIf(
                    entry -> entry.getValue().equals(coinId)
                );

                // 서버가 보유 재화를 계산
                int[] currency = playerCurrencies.computeIfAbsent(
                    client.id, key -> new int[2]
                );

                if (coinType.equals("silver")) {
                    currency[0] += amount;
                } else {
                    currency[1] += amount;
                }

                // 양쪽 클라이언트에 코인 삭제 통보
                String removeMessage = MAPPER.createObjectNode()
                    .put("type", "coin_remove")
                    .put("coin_id", coinId)
                    .toString();

                broadcast(removeMessage, 0);

                // 획득한 플레이어에게만 보유량 통보
                client.send(MAPPER.createObjectNode()
                    .put("type", "currency_update")
                    .put("silver", currency[0])
                    .put("diamond", currency[1])
                    .toString());

                System.out.println(
                    "[COLLECT] Player" + client.id
                        + " " + coinType
                        + " +" + amount
                        + " (ID=" + coinId + ")"
                );

            } catch (IOException e) {
                System.out.println("코인 데이터 처리 실패: " + e.getMessage());
            }
        }
    }
    static void loadSpawnConfig() throws IOException {
        String content = Files.readString(
            Path.of("spawn_points.json"),
            StandardCharsets.UTF_8
        );

        JsonNode root = MAPPER.readTree(content);

        if (!root.isArray()) {
            throw new IOException("스포너 설정은 JSON 배열이어야 합니다.");
        }

        spawners.clear();

        Set<String> names = new HashSet<>();

        for (JsonNode node : root) {
            String name = node.path("name").asText("");
            String coinType = node.path("coin_type").asText("");
            double interval = node.path("interval").asDouble(0);
            int maxCoins = node.path("max_coins").asInt(0);

            if (name.isBlank() || !names.add(name)) {
                throw new IOException("스포너 이름이 비어 있거나 중복됨: " + name);
            }

            if (!coinType.equals("silver")
                && !coinType.equals("diamond")) {
                throw new IOException("잘못된 코인 종류: " + coinType);
            }

            if (!Double.isFinite(interval) || interval < 0.1
                || maxCoins < 1) {
                throw new IOException("잘못된 생성 설정: " + name);
            }

            JsonNode pointNodes = node.path("points");

            if (!pointNodes.isArray() || pointNodes.isEmpty()) {
                throw new IOException("생성 지점 없음: " + name);
            }

            List<SpawnPoint> points = new ArrayList<>();

            for (int i = 0; i < pointNodes.size(); i++) {
                JsonNode point = pointNodes.get(i);

                if (!point.path("x").isNumber()
                    || !point.path("y").isNumber()) {
                    throw new IOException("잘못된 좌표: " + name);
                }

                double x = point.path("x").asDouble();
                double y = point.path("y").asDouble();

                if (!Double.isFinite(x) || !Double.isFinite(y)) {
                    throw new IOException("유효하지 않은 좌표: " + name);
                }

                points.add(new SpawnPoint(
                    name + "_" + i, x, y
                ));
            }

            spawners.add(new SpawnerConfig(
                name,
                coinType,
                Math.max(100L, Math.round(interval * 1000)),
                Math.min(maxCoins, points.size()),
                points
            ));

            System.out.println(
                "[SPAWNER LOADED] " + name
                    + " type=" + coinType
                    + " points=" + points.size()
                    + " max=" + Math.min(maxCoins, points.size())
            );
        }
    }

    static void spawnRandomCoin(SpawnerConfig config) {
        synchronized (coinLock) {
            if (!matchRunning) {
                return;
            }

            int activeCount = 0;
            List<SpawnPoint> available = new ArrayList<>();

            for (SpawnPoint point : config.points) {
                if (occupiedSpawns.containsKey(point.key)) {
                    activeCount++;
                } else {
                    available.add(point);
                }
            }

            if (activeCount >= config.maxCoins
                || available.isEmpty()) {
                return;
            }

            SpawnPoint selected = available.get(
                random.nextInt(available.size())
            );

            spawnCoin(
                selected.key,
                config.coinType,
                selected.x,
                selected.y
            );
        }
    }

    static void startMatchTimer() {
        matchRunning = true;
        remainingSeconds = MATCH_DURATION;

        coinScheduler.scheduleAtFixedRate(() -> {
            if (!matchRunning) {
                return;
            }

            remainingSeconds--;

            broadcast(MAPPER.createObjectNode()
                .put("type", "match_timer")
                .put("remaining", remainingSeconds)
                .toString(), 0);

            if (remainingSeconds <= 0) {
                matchRunning = false;

                broadcast(MAPPER.createObjectNode()
                    .put("type", "match_end")
                    .toString(), 0);

                System.out.println("경기 종료!");
            }
        }, 1, 1, TimeUnit.SECONDS);
    }

    static void handleShoot(Client client, JsonNode json) {
        WeaponState weapon = weapons.computeIfAbsent(
            client.id, key -> new WeaponState()
        );

        synchronized (weapon) {
            if (!matchRunning) {
                System.out.println("[SHOOT REJECT] match not running");
                client.send("{\"type\":\"shoot_rejected\"}");
                return;
            }

            if (weapon.reloading) {
                System.out.println("[SHOOT REJECT] reloading");
                client.send("{\"type\":\"shoot_rejected\"}");
                return;
            }

            if (weapon.ammo <= 0) {
                System.out.println("[SHOOT REJECT] no ammo");
                client.send("{\"type\":\"shoot_rejected\"}");
                return;
            }

            long now = System.nanoTime();

            if (weapon.lastShotNs != 0
                && now - weapon.lastShotNs < FIRE_INTERVAL_NS) {
                client.send("{\"type\":\"shoot_rejected\"}");
                return;
            }

            JsonNode rotationNode = json.path("rotation");

            if (!rotationNode.isNumber()) {
                return;
            }

            double rotation = rotationNode.asDouble();

            if (!Double.isFinite(rotation)) {
                return;
            }

            double[] pos = playerPositions.get(client.id);

            if (pos == null) {
                return;
            }

            weapon.ammo--;
            weapon.lastShotNs = now;

            double cos = Math.cos(rotation);
            double sin = Math.sin(rotation);

            double muzzleX = pos[0]
                + MUZZLE_OFFSET_X * cos
                - MUZZLE_OFFSET_Y * sin;

            double muzzleY = pos[1]
                + MUZZLE_OFFSET_X * sin
                + MUZZLE_OFFSET_Y * cos;

            String bulletMessage = MAPPER.createObjectNode()
                .put("type", "bullet_spawn")
                .put("shooter_id", client.id)
                .put("x", muzzleX)
                .put("y", muzzleY)
                .put("rotation", rotation)
                .toString();

            broadcast(bulletMessage, 0);

            client.send(MAPPER.createObjectNode()
                .put("type", "ammo_update")
                .put("ammo", weapon.ammo)
                .put("reloading", false)
                .toString());

            System.out.println(
                "[SHOOT] Player" + client.id
                    + " ammo=" + weapon.ammo
            );
        }


    }

    static void handleReload(Client client) {
        WeaponState weapon = weapons.computeIfAbsent(
            client.id, key -> new WeaponState()
        );

        synchronized (weapon) {
            if (!matchRunning || weapon.reloading
                || weapon.ammo == MAGAZINE_SIZE) {
                return;
            }

            weapon.reloading = true;

            client.send(MAPPER.createObjectNode()
                .put("type", "ammo_update")
                .put("ammo", weapon.ammo)
                .put("reloading", true)
                .toString());
        }

        coinScheduler.schedule(() -> {
            synchronized (weapon) {
                // 이전 연결에서 시작한 재장전이 새 연결에 영향 주지 않도록
                if (weapons.get(client.id) != weapon) {
                    return;
                }

                weapon.reloading = false;

                if (!matchRunning) {
                    return;
                }

                weapon.ammo = MAGAZINE_SIZE;

                client.send(MAPPER.createObjectNode()
                    .put("type", "ammo_update")
                    .put("ammo", weapon.ammo)
                    .put("reloading", false)
                    .toString());
            }
        }, RELOAD_DURATION_MS, TimeUnit.MILLISECONDS);
    }

    static void broadcast(String message, int exceptId) {
        for (Client client : clients.values()) {
            if (client.id != exceptId) {
                client.send(message);
            }
        }
    }

    static class Client extends Thread {

        final int id;
        final Socket socket;
        final BufferedReader reader;
        final PrintWriter writer;

        Client(int id, Socket socket) throws IOException {
            this.id = id;
            this.socket = socket;
            this.reader = new BufferedReader(new InputStreamReader(
                socket.getInputStream(), StandardCharsets.UTF_8));
            this.writer = new PrintWriter(new OutputStreamWriter(
                socket.getOutputStream(), StandardCharsets.UTF_8), true);
        }

        synchronized void send(String message) {
            writer.println(message);
        }

        @Override
        public void run() {
            System.out.println("Player" + id + " 접속");

            send("{\"type\":\"welcome\",\"id\":" + id + "}");
            int[] currency = playerCurrencies.computeIfAbsent(
                id, key -> new int[2]
            );

            send(MAPPER.createObjectNode()
                .put("type", "currency_update")
                .put("silver", currency[0])
                .put("diamond", currency[1])
                .toString());
            WeaponState weapon = new WeaponState();
            weapons.put(id, weapon);

            send(MAPPER.createObjectNode()
                .put("type", "ammo_update")
                .put("ammo", weapon.ammo)
                .put("reloading", false)
                .toString());
            for (String coinMessage : activeCoins.values()) {
                send(coinMessage);
            }

            try {
                String line;
                while ((line = reader.readLine()) != null) {

                    JsonNode json;

                    try {
                        json = MAPPER.readTree(line);
                    } catch (Exception e) {
                        System.out.println("잘못된 JSON: " + line);
                        continue;
                    }

                    if (json == null || !json.isObject()) {
                        continue;
                    }

                    String type = json.path("type").asText("");

                    if ("position".equals(type)) {

                        JsonNode xNode = json.path("x");
                        JsonNode yNode = json.path("y");
                        JsonNode rotationNode = json.path("rotation");

                        if (!xNode.isNumber()
                            || !yNode.isNumber()
                            || !rotationNode.isNumber()) {
                            continue;
                        }

                        double x = xNode.asDouble();
                        double y = yNode.asDouble();
                        double rotation = rotationNode.asDouble();

                        if (!Double.isFinite(x)
                            || !Double.isFinite(y)
                            || !Double.isFinite(rotation)) {
                            continue;
                        }

                        playerPositions.put(id, new double[]{x, y});

                        String message = MAPPER.createObjectNode()
                            .put("type", "position")
                            .put("id", id)
                            .put("x", x)
                            .put("y", y)
                            .put("rotation", rotation)
                            .toString();

                        broadcast(message, id);
                    }
                    else if ("collect_coin".equals(type)) {
                        JsonNode coinIdNode = json.path("coin_id");

                        if (!coinIdNode.isIntegralNumber()
                            || !coinIdNode.canConvertToInt()) {
                            continue;
                        }

                        int coinId = coinIdNode.asInt();
                        collectCoin(this, coinId);
                    }
                    else if ("shoot_request".equals(type)) {
                        handleShoot(this, json);
                    }
                    else if ("reload_request".equals(type)) {
                        handleReload(this);
                    }
                }
            } catch (IOException e) {
                System.out.println("Player" + id + " 연결 종료");
            } finally {
                playerPositions.remove(id);
                clients.remove(id, this);
                weapons.remove(id, weapon);
                broadcast("{\"type\":\"leave\",\"id\":" + id + "}", id);

                try {
                    socket.close();
                } catch (IOException ignored) {
                }

                System.out.println("Player" + id + " 퇴장");
            }
        }
    }

    static class WeaponState {
        int ammo = MAGAZINE_SIZE;
        long lastShotNs = 0;
        boolean reloading = false;
    }

    static class SpawnPoint {
        final String key;
        final double x;
        final double y;

        SpawnPoint(String key, double x, double y) {
            this.key = key;
            this.x = x;
            this.y = y;
        }
    }

    static class SpawnerConfig {
        final String name;
        final String coinType;
        final long intervalMs;
        final int maxCoins;
        final List<SpawnPoint> points;

        SpawnerConfig(
            String name,
            String coinType,
            long intervalMs,
            int maxCoins,
            List<SpawnPoint> points) {

            this.name = name;
            this.coinType = coinType;
            this.intervalMs = intervalMs;
            this.maxCoins = maxCoins;
            this.points = points;
        }
    }
}
