# tnt-http

Клиент HTTP для Tarantool поверх встроенного `http.client`, то есть
libcurl: адрес с параметрами, тело в JSON и в форму, сроки, переходы,
повторы и поток — с принятыми решениями вместо обвеса, который иначе
пишет каждый клиент чужой службы.

```lua
local http = require('tnt.http')

local api = assert(http.new({
    base_url = 'https://api.example.org/v1',
    headers = { authorization = 'Bearer …' },
    timeout = 3,
}))

local answer, err = api:get('/customers', { query = { page = 2, tag = { 'новый', 'важный' } } })

if answer == nil then
    return nil, err                    -- ответа нет: err.kind — unreachable, refused, invalid…
end

if answer.status == 404 then
    return nil, 'клиента нет'          -- 404 — это ответ, а не отказ
end

local customers = answer:raise():json()

api:post('/customers', { json = { name = 'Иванов' } })   -- content-type ставится сам
```

Зависимости: `tnt-retry` (паузы повторов и судья отказов), `tnt-context`
(опознаватель запроса и заголовки трассы из контекста файбера),
`tnt-validate` (проверка настроек), `tnt-log` (журнал), `tnt-must`
(проверки аргументов) и `tnt-external` (подмена libcurl в проверках).

## Зачем

Встроенный `http.client` ходит в сеть, но всё, на чём спотыкаются,
оставляет вызывающему, и каждый клиент чужой службы пишет этот обвес
заново. Пакет держит его в одном месте:

- **Адрес и тело.** Базовый адрес — приставка пути; параметры
  по RFC 3986 в постоянном порядке, список — повторённым именем;
  `json` и `form` ставят `content-type` сами.
- **Отказ отдельно от ответа.** Нет ответа — `nil, err`, где `err` —
  таблица с родом и приговором, читаемая и как строка; 404 и 500 —
  ответы.
- **Переходы по правилам HTTP.** Клиент считает их, снимает
  `Authorization` при уходе на чужой узел и ходит только по `http`
  и `https` — переход на `file://` не читает файл узла.
- **Повторы только там, где безопасно** — идемпотентные методы,
  отказы, которые лечит время, `Retry-After` в секундах; POST и PATCH
  не повторяются никогда.
- **Пределы по умолчанию**: срок 10 + 3 с, пять переходов, ответ до 8 МБ.
- **Поток** — тело кусками, с пределом на сумму и на кусок: наблюдение
  etcd, выгрузка построчно, события сервера.
- **Опознаватель запроса и трасса** уезжают в каждую попытку сами —
  из контекста файбера; клиентский отрезок трассы ставится крюком.
- **Незнакомая настройка — отказ**: `timout = 1` не оставляет срок
  по умолчанию молча.

## Установка

```sh
tt rocks install tnt-http --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-http.git
cd tnt-http && tt rocks make
```

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `http.new(opts)` | клиент со своими настройками и своим кэшем соединений; отказ — `nil, err` |
| `client:request(opts)` | запрос; ответ с любым кодом либо `nil, err` |
| `client:get`, `:post`, `:put`, `:patch`, `:delete`, `:head` | то же с методом: `(url, opts)` |
| `client:stream(opts)` | поток: `read(what, timeout)`, `write(data, timeout)`, `close()` |
| `client:status()` | что настроено — без значений заголовков и без ключа |
| `http.configure(opts)`, `http.default()` | общий клиент процесса |
| `http.get(url, opts)`… `http.stream(opts)` | те же вызовы общим клиентом |
| `http.hook(name, hook)`, `http.hooks()` | крюки вокруг каждой попытки и открытия потока |

Настройки: `base_url`, `headers`, `timeout` (10), `connect_timeout` (3,
складывается со сроком ответа), `max_redirects` (5), `max_body` (8 МБ),
`max_connections` (8), `verify` (`true`), `ca_file`, `ca_path`,
`ssl_cert`, `ssl_key`, `unix_socket`, `accept_encoding`
(`'gzip, deflate'`), `user_agent` (`'tnt-http'`), `retry` (настройки
`tnt-retry`), `layers`, `propagate` (`true`).

```lua
http.new({ timout = 1 })   --> nil, 'неизвестная настройка timout'
```

Ответ: `status`, `reason`, `headers` (имена в нижнем регистре), `body`,
`url` (после переходов), `method`; `ok()`, `json()`, `raise()`.

Отказ — таблица: `kind` (`invalid`, `unreachable`, `refused`, `status`,
`idle`), `message`, `reason` (без адреса — для журнала), `retriable`,
`status`, `retry_after`. `tostring(err)`, `'…' .. err`
и `json.encode` дают текст.

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov, рок http, tnt-env и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
make stand-up      # httpbin и etcd с mTLS в докере для живых проверок; make stand-down — погасить
```

Покрытие строк — 100 %, убитых мутантов — 100 % (316 проверок,
707 мутантов в десяти модулях). libcurl в проверках подменён
двойником, который помнит порядок обращений; пересказ двойника сверяют
пять живых проверок против настоящего libcurl: две поднимают свои
серверы сами, три идут против стенда и без него пропускаются.

## Документ

Полное описание с обоснованием решений: [docs/http.md](docs/http.md).

## Лицензия

MIT.
