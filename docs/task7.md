# Задание 7 — Проектирование коллекций MongoDB для шардирования (Mobile World)

Документ описывает структуры коллекций `orders`, `products`, `carts`, выбор shard key и стратегию шардирования с учётом основных операций, а также минимальные команды MongoDB для настройки.

---

## 0) Контекст и требования

У магазина есть три основные коллекции MongoDB:

- `orders` — заказы
- `products` — товары и остатки по геозонам
- `carts` — корзины (гостевые и пользовательские)

Нужно выбрать shard key и стратегию шардирования так, чтобы:
- данные и нагрузка распределялись равномерно,
- критичные операции работали быстро (желательно таргетно по одному шарду),
- снижался риск “горячих” шардов/чанков.

---

## 1) Коллекция `orders`

### 1.1. Схема документа

```js
{
  _id: ObjectId(),                 // order_id (технический)
  order_id: "ORD-2025-00000123",   // опционально: бизнес-ID (уникальный)
  user_id: "U123456",
  created_at: ISODate("2025-12-31T12:00:00Z"),
  status: "paid" | "shipped" | "delivered" | "canceled",
  geo_zone: "RU-MOW",
  items: [
    { product_id: "P1001", price: NumberDecimal("1990.00"), qty: 1 },
    { product_id: "P2002", price: NumberDecimal("499.00"),  qty: 2 }
  ],
  total_amount: NumberDecimal("2988.00"),
  currency: "RUB"
}
````

### 1.2. Основные операции и запросы

* Быстрое создание заказа: `insertOne(...)`
* История заказов пользователя:
  `find({ user_id }).sort({ created_at: -1 }).limit(N)`
* Отображение статуса заказа:
  `findOne({ _id })` или `findOne({ order_id })`

### 1.3. Кандидаты shard key (оценка)

* `user_id` — идеально для истории заказов (самый частый бизнес-запрос)
* `created_at` — range-ключ даёт риск “горячих” чанков на свежем времени
* `geo_zone` — может перекосить в популярные регионы
* `_id` — равномерно, но не помогает истории заказов

### 1.4. Выбранная стратегия

**Shard key:** `{ user_id: "hashed" }` (hashed sharding)

**Почемуավորմ:**

* История заказов по `user_id` становится **1-shard query**.
* Hashed даёт **равномерность** и снижает риск “горячего” range по времени.
* Сортировка по `created_at` остаётся эффективной внутри шарда (через индекс).

**Компромисс:**

* Запросы “все заказы за период” → scatter-gather. Для аналитики лучше отдельная витрина/OLAP/ETL.

### 1.5. Индексы

```js
// shard key index (hashed)
db.orders.createIndex({ user_id: "hashed" })

// история заказов
db.orders.createIndex({ user_id: 1, created_at: -1 })

// опционально: бизнес-ID
db.orders.createIndex({ order_id: 1 }, { unique: true })

// опционально: выборки по статусу
db.orders.createIndex({ status: 1, created_at: -1 })
```

### 1.6. Команды шардирования

```js
use somedb
sh.enableSharding("somedb")

sh.shardCollection("somedb.orders", { user_id: "hashed" })
```

---

## 2) Коллекция `products`

### 2.1. Схема документа

```js
{
  _id: "P1001",                 // product_id (строка/UUID)
  name: "Smartphone X",
  category: "electronics",
  price: NumberDecimal("79990.00"),
  stock_by_geo: [
    { geo_zone: "RU-MOW", qty: 50 },
    { geo_zone: "RU-KGD", qty: 30 }
  ],
  attrs: { color: "black", size: "128GB" },
  updated_at: ISODate("2025-12-31T12:00:00Z")
}
```

### 2.2. Основные операции и запросы

* Карточка товара: `findOne({ _id })`
* Каталог: `find({ category, price: { $gte, $lte } })` + пагинация
* Обновление остатков при покупке (часто): `updateOne({ _id }, ...)`

### 2.3. Кандидаты shard key (оценка)

* `_id` (product_id) — отлично для карточек/обновлений (точечные операции)
* `category` — риск “горячей категории” (как в условии следующего задания)
* `geo_zone` — остатки завязаны на гео, но продукт как сущность глобален

### 2.4. Выбранная стратегия

**Shard key:** `{ _id: "hashed" }`

**Почему:**

* Карточка/обновления по `product_id` → **всегда 1-shard**.
* Hashed по `_id` обеспечивает **равномерность**, не привязываясь к популярности категории.

**Компромисс:**

* Каталог по `category/price` будет scatter-gather. В реальной системе каталог лучше отдавать через поисковый индекс (OpenSearch/Elastic) или read-модель (витрина), а MongoDB оставлять “source of truth”.

### 2.5. Индексы

```js
// shard key index (hashed) — отдельно, т.к. стандартный _id индекс не hashed
db.products.createIndex({ _id: "hashed" })

// для каталога (будет исполняться на каждом шарде)
db.products.createIndex({ category: 1, price: 1 })

db.products.createIndex({ updated_at: -1 }) // опционально
```

### 2.6. Команды шардирования

```js
use somedb
sh.enableSharding("somedb")

sh.shardCollection("somedb.products", { _id: "hashed" })
```

---

## 3) Коллекция `carts`

### 3.1. Схема документа

```js
{
  _id: ObjectId(),                 // cart_id
  user_id: "U123456",              // null для гостей
  session_id: "S-8f3a...e12",       // null для залогиненных
  status: "active" | "ordered" | "abandoned",
  items: [
    { product_id: "P1001", quantity: 1 },
    { product_id: "P2002", quantity: 2 }
  ],
  created_at: ISODate("2025-12-31T12:00:00Z"),
  updated_at: ISODate("2025-12-31T12:05:00Z"),
  expires_at: ISODate("2026-01-01T12:00:00Z") // TTL
}
```

### 3.2. Основные операции и запросы

* Получить текущую корзину:

  * гость: `findOne({ session_id, status:"active" })`
  * пользователь: `findOne({ user_id, status:"active" })`
* Добавление/замена/удаление товара: update активной корзины
* Слияние гостевой → пользовательская:

  1. прочитать гостевую по `session_id`
  2. обновить/создать пользовательскую по `user_id`
  3. пометить гостевую `abandoned`

### 3.3. Особенность: два разных access-pattern

Для logged-in поток завязан на `user_id`, для guest — на `session_id`. Один shard key идеально закроет только один из потоков.

### 3.4. Выбранная стратегия (в рамках 3 коллекций)

**Shard key:** `{ user_id: "hashed" }`

**Почему:**

* Пользовательская корзина (самый ценный поток) → **1-shard query**.
* Частые обновления активной корзины пользователя идут в один шард.
* Гостевой поток остаётся возможным через индекс по `session_id` (но может быть scatter-gather).

**Компромисс:**

* Гостевые чтения по `session_id` будут не идеальны (scatter), но индекс уменьшает стоимость.

### 3.5. Индексы и TTL

```js
// shard key index (hashed)
db.carts.createIndex({ user_id: "hashed" })

// активная корзина пользователя
db.carts.createIndex({ user_id: 1, status: 1 })

// активная корзина гостя (может быть scatter, но с индексом)
db.carts.createIndex({ session_id: 1, status: 1 })

// TTL очистка
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
```

### 3.6. Команды шардирования

```js
use somedb
sh.enableSharding("somedb")

sh.shardCollection("somedb.carts", { user_id: "hashed" })
```

### 3.7. (Опционально, если разрешено расширение схемы)

Если нужно оптимально обслуживать гостей без scatter, обычно добавляют маленькую коллекцию-маппинг, например `cart_sessions`:

* shard key `{ session_id: "hashed" }`,
* хранит `session_id -> cart_id`, TTL,
* позволяет таргетно найти корзину гостя.

В задании это не требуется, поэтому оставлено как опциональная рекомендация.

---

## 4) Сводная таблица решений

| Коллекция  | Основной паттерн                           | Shard key               | Стратегия | Эффект                                                    |
| ---------- | ------------------------------------------ | ----------------------- | --------- | --------------------------------------------------------- |
| `orders`   | история заказов по `user_id`               | `{ user_id: "hashed" }` | hashed    | 1-shard для истории, равномерность, без hot-range         |
| `products` | точечные чтения/обновления по `product_id` | `{ _id: "hashed" }`     | hashed    | 1-shard для карточки/остатков, не зависит от категории    |
| `carts`    | активная корзина пользователя              | `{ user_id: "hashed" }` | hashed    | 1-shard для logged-in, TTL очистка, гостевые через индекс |

---

## 5) Минимальный набор команд MongoDB (сводно)

```js
use somedb
sh.enableSharding("somedb")

// orders
db.orders.createIndex({ user_id: "hashed" })
db.orders.createIndex({ user_id: 1, created_at: -1 })
db.orders.createIndex({ order_id: 1 }, { unique: true })
sh.shardCollection("somedb.orders", { user_id: "hashed" })

// products
db.products.createIndex({ _id: "hashed" })
db.products.createIndex({ category: 1, price: 1 })
sh.shardCollection("somedb.products", { _id: "hashed" })

// carts
db.carts.createIndex({ user_id: "hashed" })
db.carts.createIndex({ user_id: 1, status: 1 })
db.carts.createIndex({ session_id: 1, status: 1 })
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
sh.shardCollection("somedb.carts", { user_id: "hashed" })

```
