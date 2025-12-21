# Задание 2 — MongoDB шардирование (2 шарда)

## Запуск

Из директории `mongo-sharding`:

```bash
docker compose up -d
```

## Инициализация шардирования

### Вариант А: одной командой (скрипт)

```bash
./scripts/init-sharding.sh
```

Скрипт:
- инициализирует config server replica set `configReplSet`;
- добавляет 2 шарда (`shard1`, `shard2`);
- включает шардирование для БД `somedb`;
- шардирует коллекцию `somedb.helloDoc` по ключу `{ age: 1 }` и заранее делит диапазон:
  - `age: 0..499` -> `shard1`
  - `age: 500..999` -> `shard2`

### Вариант Б: вручную через `mongosh` (как в задании)

1) Инициализировать config server:

```bash
docker compose exec -T configSrv mongosh --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27019" }]
})
EOF
```

2) Добавить шарды и настроить шардирование:

```bash
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
sh.addShard("shard1:27018")
sh.addShard("shard2:27018")

sh.enableSharding("somedb")

use somedb

db.helloDoc.createIndex({ age: 1 })
sh.shardCollection("somedb.helloDoc", { age: 1 })

sh.splitAt("somedb.helloDoc", { age: 500 })
sh.moveChunk("somedb.helloDoc", { age: 500 }, "shard2")
EOF
```

## Заполнение данными

```bash
./scripts/mongo-init.sh
```

(Заполняет `somedb.helloDoc` 1000 документами.)

## Проверка

### 1) Приложение

Откройте в браузере:
- http://localhost:8080

### 2) Количество документов (общее и по шардам)

Удобный вариант:

```bash
./scripts/check-counts.sh
```

Либо вручную:

**Общее количество через `mongos`:**

```bash
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF
```

**Количество документов на каждом шарде (прямое подключение):**

```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF

docker compose exec -T shard2 mongosh --port 27018 --quiet <<'EOF'
use somedb
print(db.helloDoc.countDocuments())
EOF
```

**Распределение по шардам:**

```bash
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
db.helloDoc.getShardDistribution()
EOF
```
