# Задание 3 — MongoDB шардирование + репликация

Реализовано:
- 2 шарда в MongoDB (`shard1RS`, `shard2RS`)
- для каждого шарда — replica set из 3 реплик
- config server — replica set из 3 реплик (`configReplSet`)
- приложение `kazhem/pymongo_api:1.0.0`, подключение через `mongos`

БД: `somedb` 
Коллекция: `helloDoc`

---

## Запуск

Из директории `mongo-sharding-repl`:

```bash
docker compose up -d
```

---

## Настройка репликации и шардирования

### Вариант А (рекомендуемый): одним скриптом

```bash
./scripts/init-sharding.sh
```

Скрипт:
1) Инициирует replica set config server: `configReplSet` (3 ноды: `configSrv1..3`)
2) Инициирует replica set шарда 1: `shard1RS` (3 ноды: `shard1-1..3`)
3) Инициирует replica set шарда 2: `shard2RS` (3 ноды: `shard2-1..3`)
4) Перезапускает `mongos`
5) Добавляет шарды как replica set’ы и настраивает шардирование для `somedb.helloDoc`

Шардирование сделано **range-based по полю `age`** и заранее делит диапазон:
- `age < 500` -> `shard1RS`
- `age >= 500` -> `shard2RS`

---

### Вариант Б: вручную через `mongosh`

#### 1) Config Server replica set

```bash
docker compose exec -T configSrv1 mongosh --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27019", priority: 2 },
    { _id: 1, host: "configSrv2:27019", priority: 1 },
    { _id: 2, host: "configSrv3:27019", priority: 1 }
  ]
})
EOF
```

#### 2) Replica set для shard1

```bash
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1RS",
  members: [
    { _id: 0, host: "shard1-1:27018", priority: 2 },
    { _id: 1, host: "shard1-2:27018", priority: 1 },
    { _id: 2, host: "shard1-3:27018", priority: 1 }
  ]
})
EOF
```

#### 3) Replica set для shard2

```bash
docker compose exec -T shard2-1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard2RS",
  members: [
    { _id: 0, host: "shard2-1:27018", priority: 2 },
    { _id: 1, host: "shard2-2:27018", priority: 1 },
    { _id: 2, host: "shard2-3:27018", priority: 1 }
  ]
})
EOF
```

#### 4) Перезапустить mongos

```bash
docker compose restart mongos
```

#### 5) Добавить шарды и включить шардирование

```bash
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
sh.addShard("shard1RS/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2RS/shard2-1:27018,shard2-2:27018,shard2-3:27018")

sh.enableSharding("somedb")

use somedb

db.helloDoc.createIndex({ age: 1 })
sh.shardCollection("somedb.helloDoc", { age: 1 })

sh.splitAt("somedb.helloDoc", { age: 500 })
sh.moveChunk("somedb.helloDoc", { age: 500 }, "shard2RS")
EOF
```

---

## Заполнение данными

```bash
./scripts/mongo-init.sh
```

Скрипт вставляет 1000 документов в `somedb.helloDoc` через `mongos`:
- `{ age: 0..999, name: "ly0".."ly999" }`

---

## Проверка

### 1) Приложение

Открыть в браузере:
- http://localhost:8080

В JSON должно быть:
- `mongo_topology_type: "Sharded"`
- `collections.helloDoc.documents_count >= 1000`
- `shards` — список шардов, где в `host` видны **3 реплики** каждого шарда.

### 2) Количество документов и распределение по шардам

```bash
./scripts/check-counts.sh
```

### 3) Количество реплик в каждом replica set

```bash
./scripts/check-replicas.sh
```
