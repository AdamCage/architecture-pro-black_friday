# Задание 2 — MongoDB Sharding (2 шарда)

Цель: поднять стенд с **MongoDB sharding** на **2 шарда**, чтобы приложение показывало:
- общее количество документов в базе `somedb.helloDoc` (≥ 1000),
- количество документов **в каждом шарде**.

> Важно: современные версии MongoDB **не позволяют запускать `mongod --shardsvr` как standalone**. Поэтому каждый шард запущен как **replica set из 1 ноды** (`shard1RS`, `shard2RS`). Это не “репликация из задания 3”, а техническое требование MongoDB для shard-серверов.

---

## Состав стенда

- `pymongo_api` — приложение `kazhem/pymongo_api:1.0.0`
- `mongos` — роутер MongoDB
- `configSrv` — config server (replica set из 1 ноды)
- `shard1` — `shard1RS` (1 нода)
- `shard2` — `shard2RS` (1 нода)

### Порты по умолчанию
- `mongos`: `27017`
- `configSrv` (configsvr): `27019`
- `shard1/shard2` (shardsvr): `27018`

---

## Быстрый запуск (рекомендуется)

Из директории `mongo-sharding`:

```bash
docker compose up -d
```

Инициализация шардирования:

```bash
./scripts/init-sharding.sh
```

Наполнение базы `somedb`, коллекции `helloDoc` (1000 документов):

```bash
./scripts/mongo-init.sh
```

Проверка общего числа документов и распределения по шардам:

```bash
./scripts/check-counts.sh
```

Ожидаемый результат:

* Total docs via mongos: **1000**
* Docs on shard1: **500**
* Docs on shard2: **500**
* `sh.status()` показывает **2 chunks** и распределение примерно **50/50**.

---

## Проверка приложения

Приложение доступно на:

* `http://localhost:8080`

Оно должно отдавать JSON со статусом MongoDB и метриками.
