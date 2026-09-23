#!/usr/bin/env bash
# Поднимает etcd, требующий клиентский сертификат, для живых проверок mTLS.
#
# Клиентские сертификаты однажды отрезал белый список настроек tnt-http,
# и полгода это читалось как «Tarantool не умеет». Двойник этого не
# поймает: он видит, что поле дошло до libcurl, но не видит, что libcurl
# предъявил сертификат, а сервер его принял. Поэтому — настоящий etcd
# с `--client-cert-auth`, без сертификата обрывающий рукопожатие.
#
# Корень, серверный и клиентский сертификаты выпускаются здесь же на год
# и только для проверки: сервер выписан на 127.0.0.1 и localhost, клиент —
# на имя `tnt-http-live`.
#
# Каталог сертификатов — `ETCD_MTLS_DIR`, по умолчанию общий на машину
# `/tmp/tnt-stand/<контейнер>`; живая проверка читает ту же переменную
# и то же умолчание. Не `test/stand/run/` своей копии: контейнер один
# на машину и переживает копию, которая его подняла, — сертификаты в ней
# видела бы только она, а копия со старыми сертификатами после чужого
# подъёма падала бы на рукопожатии. Имя контейнера —
# `STAND_ETCD_MTLS_CONTAINER`, порт — `STAND_ETCD_MTLS_PORT`.
#
#   test/stand/etcd_mtls.sh          # выпустить сертификаты и поднять
#   test/stand/etcd_mtls.sh stop     # погасить
set -euo pipefail

# Относительный каталог отсчитывается от места запуска: оттуда его
# читает и живая проверка. Ниже сценарий переходит в свой каталог, и без
# этого стенд лёг бы в одно место, а проверка искала бы его в другом.
case "${ETCD_MTLS_DIR:-}" in
    '' | /*) ;;
    *) ETCD_MTLS_DIR="${PWD}/${ETCD_MTLS_DIR}" ;;
esac

cd "$(dirname "$0")"

IMAGE='quay.io/coreos/etcd:v3.5.17'
CONTAINER="${STAND_ETCD_MTLS_CONTAINER:-tnt-stand-etcd-mtls}"
PORT="${STAND_ETCD_MTLS_PORT:-12391}"
DIR="${ETCD_MTLS_DIR:-/tmp/tnt-stand/${CONTAINER}}"

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: etcd с mTLS поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
    echo 'etcd с mTLS остановлен'
    exit 0
fi

if ! command -v openssl > /dev/null 2>&1; then
    echo 'openssl не найден: сертификаты выпустить нечем' >&2
    exit 1
fi

# Повторный запуск безвреден: контейнер с тем же именем сносится
# и поднимается заново. Сносится до выпуска сертификатов: каталог
# смонтирован в него, и проверки соседних копий иначе брали бы новый
# корень, пока отвечает старый сервер.
docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

# Выпускает ключ и сертификат, подписанный корнем.
#   $1 — имя файлов, $2 — CN, $3 — файл расширений
issue() {
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$2" \
        -keyout "${DIR}/$1.key" -out "${DIR}/$1.csr" 2> /dev/null
    openssl x509 -req -in "${DIR}/$1.csr" -days 365 \
        -CA "${DIR}/ca.pem" -CAkey "${DIR}/ca.key" -CAcreateserial \
        -extfile "$3" -out "${DIR}/$1.pem" 2> /dev/null
}

# Сертификаты выпускаются заново на каждый подъём: вчерашний каталог дал
# бы отказ рукопожатия, неотличимый от того, ради которого проверка
# написана. Срок — год, а не сутки: контейнер общий на машину и живёт
# дольше задачи, которая его подняла, и сертификат на сутки назавтра
# ронял бы проверки TLS во всех копиях.
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=tnt-http-live-ca' \
    -keyout "${DIR}/ca.key" -out "${DIR}/ca.pem" 2> /dev/null

# Серверному сертификату нужен и clientAuth: шлюз JSON внутри etcd ходит
# к своему же gRPC как клиент и предъявляет серверный сертификат. Без
# этого шлюз отвечает 503 «bad certificate» на всё, даже с верным
# клиентским сертификатом у нас.
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n' > "${DIR}/server.ext"
printf 'extendedKeyUsage=clientAuth\n' > "${DIR}/client.ext"

issue server localhost "${DIR}/server.ext"
issue client tnt-http-live "${DIR}/client.ext"

# etcd в образе запускается не от root: ключи должны читаться всеми.
chmod 644 "${DIR}"/*.key

docker run -d \
    --name "${CONTAINER}" \
    -p "127.0.0.1:${PORT}:2379" \
    -v "${DIR}:/certs:ro" \
    "${IMAGE}" \
    etcd \
    --name mtls \
    --data-dir /etcd-data \
    --listen-client-urls https://0.0.0.0:2379 \
    --advertise-client-urls "https://127.0.0.1:${PORT}" \
    --cert-file /certs/server.pem \
    --key-file /certs/server.key \
    --trusted-ca-file /certs/ca.pem \
    --client-cert-auth > /dev/null

for _ in $(seq 1 50); do
    if curl -s -f -o /dev/null --cacert "${DIR}/ca.pem" --cert "${DIR}/client.pem" --key "${DIR}/client.key" \
        -X POST "https://127.0.0.1:${PORT}/v3/maintenance/status" -d '{}'; then
        echo "etcd с mTLS поднят: https://127.0.0.1:${PORT}, сертификаты в ${DIR}"
        exit 0
    fi

    sleep 0.2
done

echo "etcd с mTLS не ответил за 10 секунд: смотрите docker logs ${CONTAINER}" >&2
exit 1
