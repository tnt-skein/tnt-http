--- Настройки клиента и отдельного запроса: умолчания, проверка, слияние.
---
--- Проверяется всё и сразу — при заведении клиента и перед каждым
--- запросом. Настройка клиента задаётся однажды и живёт годами, а её
--- ошибка проявляется только тогда, когда чужая служба и так лежит:
--- `verify = 'false'` строкой вместо `false` выключило бы проверку
--- сертификата ровно в том смысле, в каком строка `'false'` истинна,
--- то есть никогда.
---
--- Незнакомое имя настройки — отказ, а не безобидная добавка. `timout = 1`
--- не опечатка в комментарии: срок останется прежним, запрос будет ждать
--- десять секунд вместо одной, и не скажет об этом никто.
---
--- Умолчания выбраны в пользу предсказуемости, и каждое объяснено ниже.
--- Одни и те же настройки задаются и клиенту, и отдельному запросу, —
--- поэтому правила для них описаны один раз: два списка разошлись бы
--- на первой же новой настройке, и разошлись бы молча.

local validate = require('tnt.validate')

local Module = {}

--- Сколько ждать ответа.
---
--- Десять секунд: чужая служба, думающая дольше, думает и минуту, а файбер
--- всё это время занят. Тому, кто ходит за отчётом, срок задают явно.
Module.DEFAULT_TIMEOUT = 10

--- Сколько из общего срока отводится на соединение.
---
--- Три секунды: рукопожатие с живым сервером в той же сети укладывается
--- в десятки миллисекунд, а три секунды — это уже разрешение имени через
--- второй сервер DNS.
Module.DEFAULT_CONNECT_TIMEOUT = 3

--- Сколько переходов делать по `Location`.
---
--- Пять: столько же по умолчанию проходят браузеры. Ноль значит «не
--- переходить вовсе» — ответ 3xx тогда отдаётся вызывающему как есть.
Module.DEFAULT_REDIRECTS = 5

--- Сколько байт ответа принимать.
---
--- Восемь мегабайт: ответ API в них помещается с запасом, а выгрузка
--- таблицы целиком — нет, и это правильно. Узел не должен падать оттого,
--- что чужой сервер прислал гигабайт; ноль снимает предел совсем.
Module.DEFAULT_MAX_BODY = 8 * 1024 * 1024

--- Сколько соединений держать в кэше libcurl.
---
--- Восемь: кэш соединений — это и есть пул HTTP, и держать его больше,
--- чем узел делает одновременных запросов, незачем.
Module.DEFAULT_CONNECTIONS = 8

--- Чем представляться серверу.
---
--- Представляться нужно: чужие службы отвечают 403 на пустое имя, а в
--- журнале доступа имя клиента — единственный способ узнать, чей это был
--- запрос, когда узлов много.
Module.DEFAULT_USER_AGENT = 'tnt-http'

--- Самый короткий осмысленный срок.
---
--- Миллисекунда: срок, равный нулю, у libcurl значит «без срока», то есть
--- ровно обратное тому, что имел в виду написавший `timeout = 0`.
Module.LEAST_TIMEOUT = 0.001

--- Настройки, которые задаются и клиенту, и отдельному запросу.
---
--- Список белый нарочно, и всё, чего в нём нет, до libcurl не доходит.
--- Цена у этого есть: однажды он отрезал клиентские сертификаты, и это
--- полгода читалось как «Tarantool не умеет». Поэтому то, что `http.client`
--- 3.8 принимает, а здесь не взято, перечислено в `docs/http.md` вместе
--- с причиной, — а не оставлено на догадку.
---@type string[]
Module.SHARED = {
    'timeout',
    'connect_timeout',
    'max_redirects',
    'max_body',
    'verify',
    'ca_file',
    'ca_path',
    'ssl_cert',
    'ssl_key',
    'unix_socket',
    'accept_encoding',
    'user_agent',
}

--- Правила общих настроек.
---
--- Умолчания подставляются только клиенту: у отдельного запроса те же
--- поля просто необязательны, и незаданное берётся у клиента. Если бы
--- умолчания стояли и здесь, запрос без срока перебивал бы срок клиента
--- умолчанием — и настройка клиента не значила бы ничего.
---@param defaults table Умолчания; пустая таблица — без них
---@return table<string, TntValidateRule>
local function shared_rules(defaults)
    return {
        timeout = validate.number({
            min = Module.LEAST_TIMEOUT,
            optional = true,
            default = defaults.timeout,
            title = 'срок ответа',
            gender = 'm',
        }),
        connect_timeout = validate.number({
            min = Module.LEAST_TIMEOUT,
            optional = true,
            default = defaults.connect_timeout,
            title = 'срок соединения',
            gender = 'm',
        }),
        max_redirects = validate.integer({
            min = 0,
            optional = true,
            default = defaults.max_redirects,
            title = 'предел переходов',
            gender = 'm',
        }),
        max_body = validate.integer({
            min = 0,
            optional = true,
            default = defaults.max_body,
            title = 'предел размера ответа',
            gender = 'm',
        }),
        verify = validate.boolean({
            optional = true,
            default = defaults.verify,
            title = 'проверка сертификата',
            gender = 'f',
        }),
        ca_file = validate.string({
            optional = true,
            title = 'файл доверенных корней',
            gender = 'm',
        }),
        ca_path = validate.string({
            optional = true,
            title = 'каталог доверенных корней',
            gender = 'm',
        }),
        -- Пути, а не содержимое: так их принимает libcurl. Пустая строка —
        -- опечатка, а не «без сертификата»: без сертификата значит без поля.
        -- Есть ли файл, здесь не проверяется: сертификаты подменяют на
        -- месте при выпуске новых, и отказ на пути, которого сегодня нет,
        -- ронял бы сборку клиента из-за того, что появится завтра.
        -- Не нашедшийся файл libcurl называет сам, и отказ доходит
        -- вызывающему словами «Problem with the local SSL certificate».
        ssl_cert = validate.string({
            min = 1,
            optional = true,
            title = 'клиентский сертификат',
            gender = 'm',
        }),
        ssl_key = validate.string({
            min = 1,
            optional = true,
            title = 'ключ клиентского сертификата',
            gender = 'm',
        }),
        unix_socket = validate.string({
            min = 1,
            optional = true,
            title = 'сокет',
            gender = 'm',
        }),
        accept_encoding = validate.string({
            optional = true,
            default = defaults.accept_encoding,
            title = 'принимаемое сжатие',
            gender = 'n',
        }),
        user_agent = validate.string({
            optional = true,
            default = defaults.user_agent,
            title = 'имя клиента',
            gender = 'n',
        }),
        headers = validate.map({
            optional = true,
            keys = validate.string(),
            -- Со значениями приводится: `x-count = 7` — обычное дело,
            -- а отказ на нём был бы придиркой, а не защитой.
            values = validate.string({ coerce = true }),
            title = 'заголовки',
            gender = 'm',
        }),
    }
end

--- Умолчания клиента.
---@return table
local function defaults_of()
    return {
        timeout = Module.DEFAULT_TIMEOUT,
        connect_timeout = Module.DEFAULT_CONNECT_TIMEOUT,
        max_redirects = Module.DEFAULT_REDIRECTS,
        max_body = Module.DEFAULT_MAX_BODY,
        -- Проверка сертификата включена: шифрование без неё защищает
        -- от подслушивания, но не от подмены, а тот, кто может читать
        -- трафик, обычно может и встать посередине.
        verify = true,
        -- Сжатие спрашивается сразу: ответы API сжимаются втрое, а
        -- разжимает их libcurl сам.
        accept_encoding = 'gzip, deflate',
        user_agent = Module.DEFAULT_USER_AGENT,
    }
end

--- Слой запроса: функция вокруг отправки.
local LAYER = validate.rule({
    name = 'слой',
    check = function(value)
        if type(value) ~= 'function' then
            return nil, 'быть функцией вида function(request, nxt)'
        end

        return value
    end,
})

--- Схема настроек клиента.
local CLIENT = shared_rules(defaults_of())

CLIENT.base_url = validate.string({
    optional = true,
    title = 'базовый адрес',
    gender = 'm',
})
CLIENT.max_connections = validate.integer({
    min = 1,
    -- Необязательность здесь не пишется: умолчание делает поле
    -- необязательным само, а два способа сказать одно и то же однажды
    -- расходятся.
    default = Module.DEFAULT_CONNECTIONS,
    title = 'число соединений',
    gender = 'n',
})
CLIENT.retry = validate.table({
    optional = true,
    title = 'настройки повторов',
    gender = 'f',
})
CLIENT.layers = validate.list({
    default = {},
    of = LAYER,
    title = 'слои запроса',
    gender = 'm',
})
-- Перенос контекста включён: опознаватель запроса и трасса обязаны доехать
-- до чужой службы без единой строки в прикладном коде, иначе записи одного
-- запроса на двух узлах не связать. Выключают его клиенты, которые шлют
-- саму телеметрию, — выгрузчик трасс и транспорт Sentry, — и клиенты
-- к недоверенной службе, которой опознаватели знать незачем. Настройка
-- клиента, а не обращения: решение о том, кому доверять, принимают при
-- сборке клиента, а не на каждом вызове.
CLIENT.propagate = validate.boolean({
    default = true,
    title = 'перенос контекста',
    gender = 'm',
})

--- Правила того, куда и с чем идти: общие у запроса и у потока.
---@return table<string, TntValidateRule>
local function addressed_rules()
    local rules = shared_rules({})

    rules.method = validate.string({
        optional = true,
        title = 'метод',
        gender = 'm',
    })
    rules.url = validate.string({ optional = true, title = 'адрес', gender = 'm' })
    rules.path = validate.string({ optional = true, title = 'путь', gender = 'm' })
    rules.query = validate.table({
        optional = true,
        title = 'параметры запроса',
        gender = 'm',
    })
    -- Тело проверяет `tnt.http.body`: способов задать его три, они спорят
    -- друг с другом, и сказать об этом внятно проще там, где тело собирают.
    rules.json = validate.any({ optional = true })
    rules.form = validate.any({ optional = true })
    rules.body = validate.any({ optional = true })

    return rules
end

--- Схема настроек одного запроса.
local REQUEST = addressed_rules()

REQUEST.retry = validate.table({
    optional = true,
    title = 'настройки повторов',
    gender = 'f',
})

--- Схема настроек потока.
---
--- Переходов и повторов у потока нет, и их настройки здесь — отказ по
--- имени, а не молчаливое «не действует»: `max_redirects = 3` у потока
--- было бы обещанием, которого никто не выполнит.
local STREAM = addressed_rules()

STREAM.max_redirects = nil
STREAM.duplex = validate.boolean({
    -- Отправка закрывается сразу после тела: сервер, ждущий конца тела
    -- запроса, иначе не ответит вовсе. Держать её открытой просят явно.
    default = false,
    title = 'двусторонний поток',
    gender = 'm',
})
-- Предел одного куска отдельно от суммы: бесконечному потоку сумму
-- ставят нулём, и тогда без него длина одной строки не ограничена ничем.
-- Задаётся только потоку: у запроса кусок один — тело целиком, и его
-- держит `max_body`.
STREAM.max_piece = validate.integer({
    min = 0,
    default = 0,
    title = 'предел куска',
    gender = 'm',
})

--- Ключ без сертификата: настройка, которая не действует.
---
--- libcurl берёт ключ только вместе с сертификатом, а один ключ молча
--- пропускает и идёт без клиентского сертификата вовсе (проверено
--- запуском). Сервер, который сертификата не требует, обслужит такой
--- запрос как безымянный, а требующий оборвёт рукопожатие отказом,
--- неотличимым от сетевого. Обратное законно: ключ бывает в том же файле,
--- что и сертификат.
---
--- Судится пара уже слитых настроек: ключ запроса при сертификате клиента —
--- обычное дело, и порознь их не рассудить.
---@param settings table Настройки клиента либо слитые настройки обращения
---@return string|nil err
function Module.unpaired(settings)
    if settings.ssl_key ~= nil and settings.ssl_cert == nil then
        return 'ключ клиентского сертификата без сертификата не действует: задайте ssl_cert'
    end

    return nil
end

--- Проверяет настройки клиента.
---@param opts table|nil
---@return table|nil settings
---@return string|nil err
function Module.client(opts)
    local settings, err = validate.settings(opts or {}, CLIENT)

    if settings == nil then
        return nil, err
    end

    local unpaired = Module.unpaired(settings)

    if unpaired ~= nil then
        return nil, unpaired
    end

    return settings
end

--- Проверяет настройки одного запроса.
---@param opts table|nil
---@return table|nil settings
---@return string|nil err
function Module.request(opts)
    return validate.settings(opts or {}, REQUEST)
end

--- Проверяет настройки потока.
---@param opts table|nil
---@return table|nil settings
---@return string|nil err
function Module.stream(opts)
    return validate.settings(opts or {}, STREAM)
end

--- Заголовки клиента, дополненные заголовками запроса.
---
--- Имена приводятся к нижнему регистру здесь, а не при отправке: иначе
--- `Content-Type` клиента и `content-type` запроса уехали бы на сервер
--- вдвоём, и какой из них применится, решал бы порядок в `pairs`.
---@param base table<string, string>|nil
---@param extra table<string, string>|nil
---@return table<string, string>
function Module.headers(base, extra)
    local headers = {}

    for _, given in ipairs({ base or {}, extra or {} }) do
        for name, value in pairs(given) do
            headers[name:lower()] = value
        end
    end

    return headers
end

--- Заданное значение или взятое у клиента.
---
--- Просто `given or fallback` здесь неверно: `verify = false` — заданное
--- значение, а не отсутствие, и оно обязано перекрыть прежнее `true`.
---@param given any
---@param fallback any
---@return any
local function pick(given, fallback)
    if given == nil then
        return fallback
    end

    return given
end

--- Настройки этого запроса: настройки клиента, перекрытые запросом.
---@param settings table Проверенные настройки клиента
---@param request table Проверенные настройки запроса
---@return table
function Module.resolve(settings, request)
    local resolved = {}

    for _, name in ipairs(Module.SHARED) do
        resolved[name] = pick(request[name], settings[name])
    end

    resolved.headers = Module.headers(settings.headers, request.headers)

    return resolved
end

--- Срок одной попытки для libcurl.
---
--- Срок соединения складывается со сроком ответа: `http.client` знает
--- один срок на всё обращение, и соединение идёт в его счёт (см. шапку
--- `tnt.http`). Остаток общего срока повторов, если он задан, режет
--- получившееся — незачем начинать попытку длиннее, чем вызывающий согласен
--- ждать целиком.
---@param resolved table Настройки этого запроса
---@param left number|nil Сколько осталось от общего срока
---@return number
local function deadline_of(resolved, left)
    local total = resolved.connect_timeout + resolved.timeout

    if left == nil then
        return total
    end

    return math.max(math.min(left, total), Module.LEAST_TIMEOUT)
end

--- Настройки одного обращения для `http.client`.
---@param resolved table Настройки этого запроса
---@param headers table<string, string> Заголовки, которые уйдут на сервер
---@param left number|nil Сколько осталось от общего срока
---@return table
function Module.curl_options(resolved, headers, left)
    return {
        headers = headers,
        timeout = deadline_of(resolved, left),
        -- Переходы проходит клиент, а не libcurl: см. шапку `tnt.http`.
        follow_location = false,
        verify_peer = resolved.verify,
        verify_host = resolved.verify,
        ca_file = resolved.ca_file,
        ca_path = resolved.ca_path,
        ssl_cert = resolved.ssl_cert,
        ssl_key = resolved.ssl_key,
        -- Сокет один на все шаги запроса, переходы тоже идут в него:
        -- см. шапку `tnt.http`.
        unix_socket = resolved.unix_socket,
        accept_encoding = resolved.accept_encoding,
    }
end

return Module
