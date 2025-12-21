# Задание 1 — планирование (схемы)

Ниже — 5 вариантов схем (по этапам 1–3 и дополнениям из заданий 5–6). Ревьюер обычно проверяет **итоговый** вариант (вариант 5), но промежуточные полезны для контроля изменений.

## Вариант 0 — текущее решение

```mermaid
graph LR
    A[pymongo-api] --> B[MongoDB]
```

## Вариант 1 — шардирование (2 шарда)

```mermaid
graph LR
    app[pymongo-api] --> mongos[mongos router]

    subgraph cfg[ReplicaSet: configReplSet]
      cfg1[configSrv1]
      cfg2[configSrv2]
      cfg3[configSrv3]
    end

    subgraph sh[Shards]
      s1[shard1]
      s2[shard2]
    end

    mongos --> cfg1
    mongos --> cfg2
    mongos --> cfg3

    mongos --> s1
    mongos --> s2
```

## Вариант 2 — шардирование + репликация (по 3 реплики на шард)

```mermaid
graph LR
    app[pymongo-api] --> mongos[mongos router]

    subgraph cfg[ReplicaSet: configReplSet]
      cfg1[configSrv1]
      cfg2[configSrv2]
      cfg3[configSrv3]
    end

    subgraph shard1[ReplicaSet: shard1RS]
      s11[shard1-1]
      s12[shard1-2]
      s13[shard1-3]
    end

    subgraph shard2[ReplicaSet: shard2RS]
      s21[shard2-1]
      s22[shard2-2]
      s23[shard2-3]
    end

    mongos --> cfg1
    mongos --> cfg2
    mongos --> cfg3

    mongos --> s11
    mongos --> s12
    mongos --> s13

    mongos --> s21
    mongos --> s22
    mongos --> s23
```

## Вариант 3 — шардирование + репликация + кеширование (Redis)

```mermaid
graph LR
    app[pymongo-api] --> redis[redis cache]
    redis --> mongos[mongos router]

    subgraph cfg[ReplicaSet: configReplSet]
      cfg1[configSrv1]
      cfg2[configSrv2]
      cfg3[configSrv3]
    end

    subgraph shard1[ReplicaSet: shard1RS]
      s11[shard1-1]
      s12[shard1-2]
      s13[shard1-3]
    end

    subgraph shard2[ReplicaSet: shard2RS]
      s21[shard2-1]
      s22[shard2-2]
      s23[shard2-3]
    end

    mongos --> cfg1
    mongos --> cfg2
    mongos --> cfg3

    mongos --> s11
    mongos --> s12
    mongos --> s13

    mongos --> s21
    mongos --> s22
    mongos --> s23
```

## Вариант 4 — добавляем горизонтальное масштабирование + Service Discovery + API Gateway (задание 5)

```mermaid
graph LR
    user[Users] --> gw[API Gateway]

    consul[Consul] <--> gw

    gw --> app1[pymongo-api-1]
    gw --> app2[pymongo-api-2]
    gw --> app3[pymongo-api-3]

    app1 --> consul
    app2 --> consul
    app3 --> consul

    app1 --> redis[redis cache]
    app2 --> redis
    app3 --> redis

    redis --> mongos[mongos router]

    subgraph cfg[ReplicaSet: configReplSet]
      cfg1[configSrv1]
      cfg2[configSrv2]
      cfg3[configSrv3]
    end

    subgraph shard1[ReplicaSet: shard1RS]
      s11[shard1-1]
      s12[shard1-2]
      s13[shard1-3]
    end

    subgraph shard2[ReplicaSet: shard2RS]
      s21[shard2-1]
      s22[shard2-2]
      s23[shard2-3]
    end

    mongos --> cfg1
    mongos --> cfg2
    mongos --> cfg3

    mongos --> s11
    mongos --> s12
    mongos --> s13

    mongos --> s21
    mongos --> s22
    mongos --> s23
```

## Вариант 5 — добавляем CDN для статики (задание 6) — итоговая схема

```mermaid
graph LR
    subgraph regions[Users by region]
      u1[Users: EU]
      u2[Users: RU]
      u3[Users: ASIA]
    end

    subgraph cdn[CDN]
      c1[CDN: EU]
      c2[CDN: RU]
      c3[CDN: ASIA]
    end

    origin[Static content origin\nS3/Static server]

    u1 --> c1
    u2 --> c2
    u3 --> c3

    c1 --> origin
    c2 --> origin
    c3 --> origin

    u1 --> gw[API Gateway]
    u2 --> gw
    u3 --> gw

    consul[Consul] <--> gw

    gw --> app1[pymongo-api-1]
    gw --> app2[pymongo-api-2]
    gw --> app3[pymongo-api-3]

    app1 --> consul
    app2 --> consul
    app3 --> consul

    app1 --> redis[redis cache]
    app2 --> redis
    app3 --> redis

    redis --> mongos[mongos router]

    subgraph cfg[ReplicaSet: configReplSet]
      cfg1[configSrv1]
      cfg2[configSrv2]
      cfg3[configSrv3]
    end

    subgraph shard1[ReplicaSet: shard1RS]
      s11[shard1-1]
      s12[shard1-2]
      s13[shard1-3]
    end

    subgraph shard2[ReplicaSet: shard2RS]
      s21[shard2-1]
      s22[shard2-2]
      s23[shard2-3]
    end

    mongos --> cfg1
    mongos --> cfg2
    mongos --> cfg3

    mongos --> s11
    mongos --> s12
    mongos --> s13

    mongos --> s21
    mongos --> s22
    mongos --> s23
```
