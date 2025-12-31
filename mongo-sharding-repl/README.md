# Задание 3 — MongoDB Sharding + Replication (2 шарда, 3 реплики на шард)

Цель: поднять стенд, где:
- MongoDB работает в режиме **шардирования** (2 шарда),
- у каждого шарда включена **репликация** (Replica Set из 3 нод),
- приложение показывает:
  - общее число документов в `somedb.helloDoc` (≥ 1000),
  - число документов на каждом шарде,
  - число реплик.

---

## Состав стенда

- `pymongo_api` — приложение `kazhem/pymongo_api:1.0.0`
- `mongos` — роутер MongoDB
- `configReplSet` — config server RS: `configSrv1`, `configSrv2`, `configSrv3`
- `shard1RS` — шард 1 RS: `shard1-1`, `shard1-2`, `shard1-3`
- `shard2RS` — шард 2 RS: `shard2-1`, `shard2-2`, `shard2-3`

Порты по умолчанию:
- `mongos`: 27017
- `configsvr`: 27019
- `shardsvr`: 27018

---

## Быстрый запуск

Из директории `mongo-sharding-repl`:

```bash
docker compose up -d
```

Инициализация репликации и шардирования (configRS + shardRS + addShard + shardCollection):

```bash
./scripts/init-sharding.sh
```

Заполнение базы `somedb`, коллекции `helloDoc` (1000 документов):

```bash
./scripts/mongo-init.sh
```

Проверка количества документов и распределения по шардам:

```bash
./scripts/check-counts.sh
```

Проверка количества реплик (в каждом RS должно быть `members=3`):

```bash
./scripts/check-replicas.sh
```

---

## Проверка приложения

* `http://localhost:8080`

---

## Что делает init-sharding.sh

1. Инициирует `configReplSet` из 3 нод.
2. Инициирует `shard1RS` и `shard2RS` (по 3 ноды).
3. Перезапускает `mongos` (после поднятия configRS).
4. Добавляет шарды в кластер MongoDB:

   * `shard1` => `shard1RS/...`
   * `shard2` => `shard2RS/...`
5. Включает шардирование для `somedb`, шардирует `somedb.helloDoc` по `{ age: 1 }`.
6. Делает split/move для детерминированного распределения:

   * split по `age = 500`
   * диапазон `age >= 500` уходит на `shard2`
