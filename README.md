# headscale-split-tunnel

IP-based split tunneling для российских сервисов через Tailscale и Headscale.

Российские сервисы идут через VPS в России, остальной трафик — напрямую через локального провайдера.

## Документация

[doc/Full_Description.md](doc/Full_Description.md) — архитектура, принципы работы, инструкции по установке и проверке.

## Структура репозитория

```
headscale/
├── scripts/
│   ├── approve-gateway-routes.sh   # подтверждение маршрутов через Headscale HTTP API
│   ├── cron-approve-routes.sh      # loop-обёртка для Fly process group
│   ├── init.sh                     # инициализация БД перед запуском
│   └── deploy.sh                   # деплой на Fly.io
├── Dockerfile                      # образ на базе jauderho/headscale
├── fly.toml                        # конфигурация Fly.io (два process groups)
├── headscale.yaml                  # конфиг Headscale (не в git)
└── acl.json                        # ACL-политика (не в git)

vps/
├── config/
│   ├── asns.txt                    # статические ASN для включения
│   ├── asn-denylist.txt            # ASN для исключения (крупные операторы)
│   └── hosts.txt                   # DNS-имена российских сервисов
└── scripts/
    └── update-tailscale-ru-routes.sh   # генерация и публикация маршрутов
```

## Быстрый старт

### VPS

1. Установить зависимости: `tailscale`, `bgpq4`, `dnsutils`, `python3`
2. Включить IP forwarding
3. Скопировать `vps/config/` в `/etc/tailscale-ru-routes/`
4. Скопировать `vps/scripts/update-tailscale-ru-routes.sh` в `/usr/local/sbin/`
5. Подключить VPS к Headscale: `tailscale up --login-server ... --hostname ru-gateway`
6. Добавить cron: `17 */3 * * * /usr/local/sbin/update-tailscale-ru-routes.sh`

### Headscale на Fly.io

1. Создать `headscale/headscale.yaml` и `headscale/acl.json` по примерам из [документации](doc/Full_Description.md)
2. Установить секрет: `fly secrets set HEADSCALE_API_KEY=...`
3. Задеплоить: `cd headscale && flyctl deploy`
4. Запустить процессы: `fly scale count app=1 route_approver=1`

### Клиент

```bash
tailscale up --accept-routes
```
