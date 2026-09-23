#!/usr/bin/env bash
# Поднимает httpbin для живых проверок клиента HTTP.
#
# httpbin — эхо-сервер протокола: он отвечает тем, что получил, и умеет
# всё, на чём клиент спотыкается в жизни, — переходы с кодом на выбор,
# коды 5xx, задержки, сжатие, вход по паролю, ответы на мегабайт.
#
# Настоящий сервер, а не двойник: двойник показывает, что мы правильно
# разговариваем сами с собой, а чужой сервер — что нас понимает кто-то
# ещё. Разница вылезает на первом же заголовке, который libcurl
# добавляет от себя.
#
#   test/stand/httpbin.sh          # поднять
#   test/stand/httpbin.sh stop     # погасить
#
# Посмотреть глазами: http://127.0.0.1:18080/
set -euo pipefail

cd "$(dirname "$0")"

HTTPBIN_IMAGE='kennethreitz/httpbin:latest'
HTTPBIN_CONTAINER='tnt-stand-httpbin'
HTTPBIN_PORT='18080'

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: httpbin поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${HTTPBIN_CONTAINER}" > /dev/null 2>&1 || true
    echo 'httpbin остановлен'
    exit 0
fi

mkdir -p run

# Повторный запуск безвреден: контейнер с тем же именем сносится
# и поднимается заново. Состояния у httpbin нет, жалеть нечего.
docker rm -f "${HTTPBIN_CONTAINER}" > /dev/null 2>&1 || true

# Образ собран только под amd64, и на машине с ARM его приходится
# просить явно: без этого docker отказывается тянуть его вовсе,
# а с этим он идёт через эмуляцию — медленнее, но работает.
docker run -d \
    --platform linux/amd64 \
    --name "${HTTPBIN_CONTAINER}" \
    -p "127.0.0.1:${HTTPBIN_PORT}:80" \
    "${HTTPBIN_IMAGE}" > /dev/null

echo "${HTTPBIN_CONTAINER}" > run/httpbin.containers

# Готовности ждём: проверки, запущенные сразу после подъёма, иначе
# пропустятся — и это выглядит как «всё хорошо», хотя ничего
# не проверено. Под эмуляцией первый запуск небыстрый.
for _ in $(seq 1 120); do
    if curl -s -f -o /dev/null "http://127.0.0.1:${HTTPBIN_PORT}/status/200"; then
        echo "httpbin поднят: http://127.0.0.1:${HTTPBIN_PORT}/"
        exit 0
    fi

    sleep 0.5
done

echo 'httpbin не ответил за 60 секунд: смотрите docker logs' >&2
exit 1
