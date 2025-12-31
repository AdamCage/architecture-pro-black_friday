# Задание 4 - cache

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

## Проверка кеширования `<100ms` для повторных запросов

Кешируется эндпоинт `/<collection_name>/users`.

### Вариант Bash (Git Bash / WSL)

```bash
curl -s -o /dev/null -w "1st: %{time_total}s\n" http://localhost:8080/helloDoc/users
curl -s -o /dev/null -w "2nd: %{time_total}s\n" http://localhost:8080/helloDoc/users
curl -s -o /dev/null -w "3rd: %{time_total}s\n" http://localhost:8080/helloDoc/users
```

Ожидание: `2nd/3rd < 0.1s`.
