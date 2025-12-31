# Задание 10 — Миграция на Cassandra (модель данных, репликация, шардирование, стратегии целостности)

Контекст: при 50k RPS и range-based sharding в MongoDB добавление шардов вызывает дорогое перераспределение данных и просадку latency. Cassandra выбирается ради:
- leaderless репликации и высокой доступности,
- быстрого горизонтального масштабирования (consistent hashing / vnodes) без “полного” пересыпания данных,
- равномерного распределения при правильном partition key.

---

## 10.1. Какие данные критичны и что имеет смысл переносить в Cassandra

### 1) Критичность данных (целостность + скорость)

| Домен данных | Критичность целостности | Требования к скорости | Комментарий |
|---|---:|---:|---|
| **Корзины (carts)** | средняя/высокая | **очень высокая** | Частые записи/обновления, key-value паттерн, TTL — идеальный кандидат для Cassandra. |
| **Сессии пользователей (sessions)** | средняя | **очень высокая** | Очень частые операции, TTL, простая модель. Отлично ложится на Cassandra. |
| **История заказов по пользователю** | высокая | высокая | Чтение “последние N заказов” и запись новых заказов. Cassandra сильна в wide-row и time-series под конкретный access pattern. |
| **Статусы заказов (order status / timeline)** | высокая | высокая | Частые обновления статуса, чтение статуса. Можно хранить как состояние + события. |
| **Каталог/товары (products)** | средняя | высокая | Сложнее: много фильтров (category/price) Cassandra не любит ad-hoc. В Cassandra — только если модель read-оптимизирована под конкретные запросы (по product_id, по geo), а поиск — отдельным сервисом. |
| **Остатки по геозонам (inventory)** | **очень высокая** | **очень высокая** | Критично для продажи. Cassandra подходит для быстрых writes/reads по ключу (product_id+geo). Но бизнес-ограничения (не уйти в отрицательные остатки) потребуют LWT/транзакционных паттернов. |

### 2) Что переносить в Cassandra “точно имеет смысл”

**Лучшие кандидаты для Cassandra:**
1) `carts` + `sessions` (TTL, high write rate, predictable queries).
2) `orders_by_user` (история заказов) — time-series по пользователю.
3) `order_status` (текущее состояние заказа) и/или `order_events` (лента событий).
4) `inventory_by_product_geo` (остатки по product_id + geo) — если готовы к паттернам согласованности (QUORUM/LWT).

**Что не стоит пытаться делать “в чистой Cassandra”:**
- Гибкий поиск каталога по `category`, `price range`, “фильтры как в интернет-магазине” — это задача поискового движка. В Cassandra можно держать “источник правды” по `product_id` и несколько read-моделей под фиксированные запросы, но не заменять полнотекст/фасеты.

---

## 10.2. Концептуальная модель Cassandra (partition key, clustering key, защита от hot partitions)

Ниже — набор таблиц (read-оптимизированные модели). В Cassandra “нормализация” вторична; важнее — запросы.

### Общие установки keyspace (пример)
- `NetworkTopologyStrategy` (под датацентры/регионы)
- `RF=3` в каждом DC (пример), и `LOCAL_QUORUM` для критичных операций.

```sql
CREATE KEYSPACE mobile_world
WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'dc1': 3,
  'dc2': 3
};
````

---

### A) Корзины

**Запросы:**

* получить активную корзину по `user_id`
* получить гостевую корзину по `session_id`
* обновлять items
* TTL очистка

#### 1) carts_by_user

```sql
CREATE TABLE mobile_world.carts_by_user (
  user_id text,
  status text,              -- active/ordered/abandoned
  cart_id uuid,
  updated_at timestamp,
  created_at timestamp,
  expires_at timestamp,
  items map<text, int>,     -- product_id -> qty (упрощённо)
  PRIMARY KEY ((user_id), status)
);
```

* **Partition key:** `user_id` — равномерно при большом количестве пользователей.
* **Clustering:** `status` (1 строка для active). Можно хранить только `active` как отдельную таблицу.
* TTL: можно задавать на строку или на отдельные поля (практичнее — на строку целиком).

#### 2) carts_by_session (гости)

```sql
CREATE TABLE mobile_world.carts_by_session (
  session_id text,
  status text,
  cart_id uuid,
  updated_at timestamp,
  created_at timestamp,
  expires_at timestamp,
  items map<text, int>,
  PRIMARY KEY ((session_id), status)
);
```

* **Partition key:** `session_id` — равномерно.
* Это убирает “двойной паттерн” из MongoDB (там был выбор shard key).

**Hot partition риск:** низкий (session_id/user_id высококардинальные).
**Решардинг при расширении кластера:** минимальный (consistent hashing распределит partition’ы по новым нодам без “тотального” ребаланса).

---

### B) Заказы — история по пользователю (основной read-path)

**Запросы:**

* “последние N заказов пользователя”
* иногда по времени

#### orders_by_user (time-series)

```sql
CREATE TABLE mobile_world.orders_by_user (
  user_id text,
  order_day date,           -- bucket (anti-hot partition)
  created_at timestamp,
  order_id uuid,
  status text,
  geo_zone text,
  total_amount decimal,
  currency text,
  PRIMARY KEY ((user_id, order_day), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC);
```

* **Partition key:** `(user_id, order_day)` — критично.

  * Если сделать только `user_id`, у “тяжёлых” пользователей может стать широкая и горячая партиция.
  * `order_day` (или `order_month`) разбивает на бакеты и защищает от hot partitions.
* **Clustering:** `created_at DESC` + `order_id` — быстро отдаёт последние заказы.

**Как читать:**

* последние заказы за текущий день (и при необходимости — за несколько дней с объединением на уровне сервиса).

---

### C) Заказ — текущее состояние (быстрый доступ по order_id)

**Запросы:**

* получить статус заказа
* обновлять статус

#### order_state_by_id

```sql
CREATE TABLE mobile_world.order_state_by_id (
  order_id uuid,
  user_id text,
  created_at timestamp,
  status text,
  geo_zone text,
  total_amount decimal,
  currency text,
  last_updated_at timestamp,
  PRIMARY KEY ((order_id))
);
```

* **Partition key:** `order_id` (UUID) — равномерно.
* Это “single-row state” для быстрого чтения.

---

### D) Заказ — события/таймлайн (опционально, если нужна аудит-лента)

**Запросы:**

* история смен статусов по заказу

#### order_events_by_id

```sql
CREATE TABLE mobile_world.order_events_by_id (
  order_id uuid,
  event_time timestamp,
  event_type text,          -- created/paid/shipped/...
  payload text,             -- JSON (упрощённо)
  PRIMARY KEY ((order_id), event_time)
) WITH CLUSTERING ORDER BY (event_time DESC);
```

* **Partition key:** `order_id`
* **Clustering:** `event_time DESC`

---

### E) Товары — источник правды по product_id

**Запросы:**

* карточка товара по `product_id`
* (поиск/фильтры — вне Cassandra или отдельные read-модели)

#### product_by_id

```sql
CREATE TABLE mobile_world.product_by_id (
  product_id text,
  name text,
  category text,
  price decimal,
  attrs map<text, text>,
  updated_at timestamp,
  PRIMARY KEY ((product_id))
);
```

* **Partition key:** `product_id` — равномерно.

---

### F) Остатки по геозонам (критично на покупках)

**Запросы:**

* прочитать остаток `product_id + geo`
* атомарно уменьшить остаток при покупке (если требуются строгие гарантии)

#### inventory_by_product_geo

```sql
CREATE TABLE mobile_world.inventory_by_product_geo (
  product_id text,
  geo_zone text,
  qty int,
  updated_at timestamp,
  PRIMARY KEY ((product_id), geo_zone)
);
```

* **Partition key:** `product_id` — равномерно.
* **Clustering:** `geo_zone` — внутри продукта.

**Hot partition риск:** продукт-хит может стать горячим по `product_id`.
Митигировать можно “бакетизацией” по складам/хэш-суффиксам, но это усложняет агрегацию. На практике:

* держат небольшой RF и масштабируют кластер,
* кешируют “остаток” на чтение,
* а записи распределяют по inventory сервису с очередями.

---

### G) (Опционально) Read-модель “каталог по категории” с бакетизацией

Если нужно обслуживать простую витрину без поискового движка, можно сделать денормализованную таблицу с бакетами, чтобы не получить горячую категорию.

```sql
CREATE TABLE mobile_world.products_by_category_bucket (
  category text,
  bucket int,               -- 0..N-1 (hash(product_id)%N)
  price decimal,
  product_id text,
  name text,
  updated_at timestamp,
  PRIMARY KEY ((category, bucket), price, product_id)
) WITH CLUSTERING ORDER BY (price ASC);
```

* **Partition key:** `(category, bucket)` — защищает от hot partition по “electronics”.
* **Минус:** запрос “category=electronics” требует fan-out по bucket’ам.

Рекомендация: вместо этого — поисковый движок.

---

## 10.2. Обоснование по “горячим” партициям и масштабированию

### Почему Cassandra меньше страдает при добавлении нод

* данные распределяются по токен-рингу (vnodes), при добавлении ноды переезжает **часть токен-диапазонов**, а не “всё” и не из каждого узла во все.
* миграция — фоновые стримы + repair, без полного “тотального” ребаланса как в некоторых сценариях range-sharding.

### Как избегаем hot partitions

* Высококардинальные ключи: `user_id`, `session_id`, `order_id`, `product_id` — базово распределяют нагрузку.
* Бакетизация по времени для `orders_by_user`: `(user_id, order_day)` — защищает от сверхшироких партиций.
* Для категорий — либо вынести поиск, либо бакетизировать `(category, bucket)`.

---

## 10.3. Стратегии целостности: Hinted Handoff, Read Repair, Anti-Entropy Repair

Стратегии в Cassandra решают разные задачи; их можно комбинировать.

### 1) Hinted Handoff

**Что делает:** если реплика временно недоступна, координатор сохраняет “hint” и позже доставляет запись.
**Плюсы:** повышает write availability и снижает потребность в немедленном repair.
**Минусы:** при длительных отключениях может накопить много hints; в итоге догон может создать нагрузку.

**Где применять:**

* `carts_*`, `sessions` (если выделяете) — допустима eventual consistency, важна доступность.
* `order_events_by_id` — события можно “доставить позже” при сбое реплики.

### 2) Read Repair

**Что делает:** при чтении сравнивает реплики (в зависимости от consistency level) и исправляет расхождения.
**Плюсы:** улучшает консистентность “на горячих чтениях”.
**Минусы:** увеличивает latency чтений и нагрузку, особенно при больших объёмах.

**Где применять:**

* `order_state_by_id` — частые чтения статуса, важно быстро уменьшать расхождения.
* `inventory_by_product_geo` — если читаете часто и хотите быстрее выравнивать реплики (но осторожно с latency).

### 3) Anti-Entropy Repair (Repair)

**Что делает:** периодическая фоновая сверка данных между репликами (Merkle trees), исправление расхождений.
**Плюсы:** гарантирует, что реплики не разъедутся надолго; критично при leaderless.
**Минусы:** ресурсоёмко; нужно планировать окна/частоту.

**Где применять:**

* Все “долгоживущие” сущности: `orders_by_user`, `order_state_by_id`, `product_by_id`, `inventory_by_product_geo`.
* Для TTL-heavy данных (carts/sessions) repair можно делать реже или аккуратно, чтобы не тратить ресурсы на быстроумирающие данные.

---

## Рекомендованная политика по сущностям

| Сущность                            | Consistency Level (пример)                           | Hinted Handoff | Read Repair | Anti-Entropy Repair | Обоснование                                                                                                                   |
| ----------------------------------- | ---------------------------------------------------- | -------------: | ----------: | ------------------: | ----------------------------------------------------------------------------------------------------------------------------- |
| `carts_by_user`, `carts_by_session` | `LOCAL_QUORUM` на write, `LOCAL_ONE/QUORUM` на read  |             да | ограниченно |    минимально/редко | Высокий write rate, TTL, важна доступность; строгая глобальная консистентность не нужна.                                      |
| `orders_by_user`                    | write `LOCAL_QUORUM`, read `LOCAL_QUORUM`            |             да | опционально |      да (регулярно) | История заказов важна, но допускает небольшую eventual; repair нужен для долговечности.                                       |
| `order_state_by_id`                 | write `LOCAL_QUORUM`, read `LOCAL_QUORUM`            |             да |          да |                  да | Статус заказа важен, читается часто; read repair помогает быстро выравнивать.                                                 |
| `order_events_by_id`                | write `LOCAL_QUORUM`, read `LOCAL_ONE/QUORUM`        |             да | опционально |                  да | События можно догнать hints; repair гарантирует целостность истории.                                                          |
| `product_by_id`                     | write `LOCAL_QUORUM`, read `LOCAL_ONE` (витрина)     |             да |       редко |                  да | Карточки читаются много; читаем быстрее, целостность добиваем repair’ом.                                                      |
| `inventory_by_product_geo`          | write `LOCAL_QUORUM` (или выше), read `LOCAL_QUORUM` |      осторожно | да/умеренно |      да (регулярно) | Остатки критичны. Если нужна строгая защита от oversell — использовать LWT для decrement или отдельный сервис резервирования. |

---

## Примеры создания таблиц (CQL) — минимальный набор

```sql
-- keyspace
CREATE KEYSPACE mobile_world
WITH replication = {'class':'NetworkTopologyStrategy','dc1':3,'dc2':3};

-- carts
CREATE TABLE mobile_world.carts_by_user (
  user_id text,
  status text,
  cart_id uuid,
  updated_at timestamp,
  created_at timestamp,
  expires_at timestamp,
  items map<text, int>,
  PRIMARY KEY ((user_id), status)
);

CREATE TABLE mobile_world.carts_by_session (
  session_id text,
  status text,
  cart_id uuid,
  updated_at timestamp,
  created_at timestamp,
  expires_at timestamp,
  items map<text, int>,
  PRIMARY KEY ((session_id), status)
);

-- orders: history by user with day bucket
CREATE TABLE mobile_world.orders_by_user (
  user_id text,
  order_day date,
  created_at timestamp,
  order_id uuid,
  status text,
  geo_zone text,
  total_amount decimal,
  currency text,
  PRIMARY KEY ((user_id, order_day), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC);

-- orders: current state by id
CREATE TABLE mobile_world.order_state_by_id (
  order_id uuid,
  user_id text,
  created_at timestamp,
  status text,
  geo_zone text,
  total_amount decimal,
  currency text,
  last_updated_at timestamp,
  PRIMARY KEY ((order_id))
);

-- orders: events
CREATE TABLE mobile_world.order_events_by_id (
  order_id uuid,
  event_time timestamp,
  event_type text,
  payload text,
  PRIMARY KEY ((order_id), event_time)
) WITH CLUSTERING ORDER BY (event_time DESC);

-- products: by id
CREATE TABLE mobile_world.product_by_id (
  product_id text,
  name text,
  category text,
  price decimal,
  attrs map<text, text>,
  updated_at timestamp,
  PRIMARY KEY ((product_id))
);

-- inventory: by product+geo
CREATE TABLE mobile_world.inventory_by_product_geo (
  product_id text,
  geo_zone text,
  qty int,
  updated_at timestamp,
  PRIMARY KEY ((product_id), geo_zone)
);
```

---

## Итог

1. В Cassandra имеет смысл переносить **write-heavy и key-based** домены: корзины/сессии/историю заказов/статусы/остатки.
2. Модель строится “от запросов”: partition key высококардинальный + бакеты для time-series/категорий, чтобы не ловить hot partitions.
3. Целостность обеспечивается комбинацией:

* Hinted Handoff (доступность на write),
* Read Repair (быстро выравнивать на горячих чтениях),
* Anti-Entropy Repair (гарантировать долговременную согласованность).
