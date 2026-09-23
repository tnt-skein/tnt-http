--- Клиент HTTP: сходить к чужой службе и вернуться с ответом.
---
--- Почти всё, что узел делает наружу, он делает по HTTP: складывает файл
--- в S3, ищет в OpenSearch, шлёт происшествие в Sentry, читает настройки
--- из etcd. Каждый такой клиент писал вокруг `http.client` один и тот же
--- обвес — адрес, заголовки, JSON, повторы, переходы, — и каждый писал
--- его чуть иначе. Обвес здесь один на всех.
---
---     local http = require('tnt.http')
---
---     local answer, err = http.get('https://api.example.org/customers', {
---         query = { page = 2, tag = { 'новый', 'важный' } },
---         headers = { authorization = 'Bearer …' },
---     })
---
---     if answer == nil then
---         return nil, err              -- ответа нет; err.kind скажет почему
---     end
---
---     if answer.status == 404 then
---         return nil, 'не найдено'     -- 404 — это ответ, а не отказ
---     end
---
---     local page = answer:raise():json()
---
---     local client = http.new({ base_url = 'https://api.example.org/v1' })
---     client:post('/customers', { json = { name = 'Иванов' } })
---
---     local events = client:stream({ url = '/events', max_body = 0, max_piece = 65536 })
---     local line = events:read('\n', 30)
---     events:close()
---
--- ## На чём это стоит и почему
---
--- Под клиентом — `http.client` Tarantool, то есть libcurl, а не свой
--- сокет с TLS поверх. Решение главное в пакете, и принято оно так.
---
--- За libcurl: TLS с проверкой сертификата и цепочки, HTTP/2, `chunked`,
--- сжатие, повторное использование соединений, прокси, IPv6 — всё это
--- уже написано, проверено миллионом узлов и не стоит нам ни строки.
--- Свой клиент поверх сокета пришлось бы начать с разбора заголовков
--- и `Transfer-Encoding: chunked`, а кончить своим кэшем соединений;
--- ошибка в любом из этих мест выглядит как «иногда теряется ответ»
--- и ищется неделями. Свой сокет оправдан там, где другого клиента нет
--- вовсе, — в SMTP, IMAP, POP3; в HTTP такой клиент есть, и он лучше
--- того, который мы написали бы.
---
--- Чем за это заплачено, и об этом надо знать заранее:
---
--- * **Предел размера — счёт отданного, а не память.** libcurl отдаёт
---   тело целиком и только целиком; остановить чужой гигабайт на середине
---   из Lua нечем. `max_body` значит «столько клиент отдаст наверх»:
---   ответ больше предела превращается в отказ, и ссылки на него не
---   остаётся ни у кого, — но пик памяти на приёме уже случился. Поток
---   (`stream`) от этого не лечит: `http.client` принимает тело с той
---   скоростью, с какой его шлёт сервер, и копит у себя, читают его или
---   нет, — обратного давления у него нет. Память потока ограничена лишь
---   тем, как быстро его читают, и от враждебного или сжатого тела не
---   защищают ни запрос, ни поток.
--- * **Срок соединения отдельно не выставляется.** `http.client` знает
---   один срок на всё обращение, и соединение идёт в его счёт: замер
---   на недоступном адресе дал ровно полный срок, а не долю соединения.
---   Поэтому `connect_timeout` и `timeout` складываются в один срок
---   попытки: при 2 и 5 секундах недоступный узел и молчащий сервер оба
---   держат попытку семь секунд, а не две и не пять. Раздельных сроков
---   этот клиент не обещает.
--- * **Пула соединений сверху нет, и не должно быть.** Кэш соединений
---   живёт внутри libcurl и настраивается через `max_connections`. Второй
---   пул поверх него стерёг бы не соединения, а обработчики libcurl,
---   а закрыть обработчик в Tarantool нечем — пул, выбрасывающий
---   простаивающие, тёк бы ими.
---
--- ## Что решено ещё
---
--- **Отказ сети — `nil, err`, ответ сервера — ответ.** Код 500 значит,
--- что у чужой службы беда; что с этим делать, знает прикладной код,
--- а не клиент. Там, где разбираться незачем, есть `answer:raise()`.
---
--- **Отказ — таблица с родом и приговором** (`tnt.http.failure`), а не
--- строка: тот, кто ведёт свои повторы, судит по роду, а не по словам.
--- Строкой он читается текстом причины — `tostring`, `%s` и склейка
--- работают с ним, как со строкой.
---
--- **Переходы по `Location` клиент проходит сам**, а не отдаёт libcurl:
--- иначе их не сосчитать (числа переходов `http.client` не принимает)
--- и не снять с чужого узла заголовок входа. Заголовок входа, уехавший
--- по чужой ссылке, — это отданный пароль. Цена ручного обхода — запрет
--- схем, который libcurl держал на своих переходах, приходится держать
--- самим: клиент ходит только по `http` и `https`, и адрес запроса, и цель
--- перехода с другой схемой — отказ. Иначе сервер, ответивший переходом
--- на `file:///etc/hosts`, получил бы файл узла телом ответа, а переходом
--- на `gopher://` слал бы свои байты на внутренний порт.
---
--- **Повторяются только идемпотентные методы**, и только те отказы,
--- которые лечит время. Решает это `tnt.http.policy` по RFC 9110, а
--- считает паузы `tnt.retry`: разброс, общий срок, бюджет и размыкатель
--- клиент не пишет заново. Повтор идёт к тому же адресу: о равноправных
--- узлах клиент не знает. Кто обходит несколько узлов (кластер etcd,
--- реплики одной службы), выключает повторы клиента
--- (`retry = { attempts = 1 }`) и ведёт свои — иначе два цикла
--- перемножают обращения. Настройки «куда идти на следующей попытке» нет
--- нарочно: соседнему узлу бывает нужен свой вход, свой токен и свой
--- курсор, а этого клиент HTTP не знает и знать не должен.
---
--- **Сокет (`unix_socket`) — это дорога до узла, а не узел.** Адрес в URL
--- остаётся логическим: по нему ставится `Host`, по нему сличаются узлы
--- на переходе и снимается `Authorization`. Дорога же одна на весь
--- запрос — так её держит и сам libcurl: все переходы, на свой узел
--- и на чужой, идут в тот же сокет. С сокета клиент в сеть не выходит,
--- а из сети в сокет не попадает: переход может сменить адрес, но не
--- дорогу и не протокол. Держится это на запрете схем выше: без него
--- переход на `file://` ушёл бы с сокета на диск узла (проверено
--- запуском). Проверка сертификата у `https://` через сокет остаётся
--- включённой и сверяет имя из URL.
---
--- **Слои запроса** (`layers`) — стык для `tnt.middleware`: список функций
--- вида `function(request, nxt)`, обёрнутых вокруг отправки. Слой получает
--- запрос в общем виде и возвращает `ответ, отказ`; отказ слоя — строка
--- или таблица `{ message, retriable }` — доходит вызывающему отказом
--- рода `refused`. У потока слоёв нет: см. `tnt.http.stream`.
---
--- **Опознаватель запроса и трасса уезжают сами.** В каждую попытку
--- запроса и в открытие потока клиент кладёт заголовки из контекста
--- файбера — `context.export()` из `tnt-context`: `x-request-id`, а внутри
--- трассы `traceparent` и `tracestate`. Ставить их руками не нужно,
--- а заданный вызывающим заголовок главнее и не перезаписывается.
--- От трассировки клиент не зависит и правил W3C не знает: строку
--- `traceparent` в контекст кладёт тот, кто ведёт трассу, клиент лишь
--- довозит её. Клиентский отрезок на попытку даёт **крюк модуля** —
--- `http.hook(name, hook)`, именованный список функций вокруг попытки
--- и открытия потока; его ставит трассировка при установке. Список
--- крюков — состояние, общее для всех клиентов процесса, и это нарочно:
--- клиенты собираются и внутри других пакетов, и до их настроек
--- приложение не дотягивается. Почему так и что делает крюк — шапка
--- `tnt.http.hook`. Настройка клиента `propagate = false` снимает
--- и заголовки, и крюки.
---
--- **Что можно подставить вместо клиента.** `tnt.http.transport` объявляет
--- libcurl внешней зависимостью: её подменяют проверки самого пакета,
--- и подмена глобальна. Прикладной код подменяет не её, а экземпляр
--- клиента: достаточно таблицы с `request(opts)`, `stream(opts)`
--- и `status()`. Поле `handle` в этот договор не входит — это обработчик
--- libcurl самого клиента, и мимо фасада через него не ходят: и запрос,
--- и поток открываются методами клиента.

local body_of = require('tnt.http.body')
local failure_of = require('tnt.http.failure')
local hook_of = require('tnt.http.hook')
local policy = require('tnt.http.policy')
local response_of = require('tnt.http.response')
local settings_of = require('tnt.http.settings')
local stream_of = require('tnt.http.stream')
local transport = require('tnt.http.transport')
local url_of = require('tnt.http.url')

local retry_of = require('tnt.retry')

local log = require('tnt.log').new('tnt.http')

local Module = {}

--- Части: доступны тем, кто собирает своё поведение.
Module.url = url_of
Module.body = body_of
Module.failure = failure_of
Module.policy = policy
Module.response = response_of
Module.settings = settings_of
Module.transport = transport

--- Крюки исходящего обращения: `http.hook(name, hook)` ставит, заменяет
--- или снимает, `http.hooks()` перечисляет по порядку постановки.
Module.hook = hook_of.set
Module.hooks = hook_of.names

--- Метод, которым идут, если метод не назвали.
local DEFAULT_METHOD = 'GET'

--- Заголовок, которым сервер указывает, куда идти дальше.
local LOCATION = 'location'

--- Заголовок, которым помечено тело: при смене метода он теряет смысл.
local CONTENT_TYPE = 'content-type'

---@class TntHttpRequest
---@field method string|nil Метод; по умолчанию GET
---@field url string|nil Адрес целиком либо относительный, если задан base_url
---@field path string|nil То же, что url: имя для тех, у кого есть base_url
---@field query table|nil Параметры запроса
---@field headers table<string, string>|nil Заголовки поверх заголовков клиента
---@field json any Тело: будет закодировано в JSON
---@field form table|nil Тело: будет закодировано как форма
---@field body string|nil Тело как есть
---@field timeout number|nil Срок ответа только для этого запроса
---@field connect_timeout number|nil Срок соединения только для этого запроса
---@field max_redirects integer|nil Предел переходов только для этого запроса
---@field max_body integer|nil Предел размера ответа только для этого запроса
---@field verify boolean|nil Проверять ли сертификат
---@field ca_file string|nil Файл доверенных корней
---@field ca_path string|nil Каталог доверенных корней
---@field ssl_cert string|nil Файл клиентского сертификата
---@field ssl_key string|nil Файл ключа клиентского сертификата
---@field unix_socket string|nil Сокет, через который идти
---@field accept_encoding string|nil Какое сжатие принимать
---@field user_agent string|nil Чем представляться
---@field retry table|nil Настройки повторов только для этого запроса

---@class TntHttpStreamRequest
---@field method string|nil Метод; по умолчанию GET
---@field url string|nil Адрес целиком либо относительный, если задан base_url
---@field path string|nil То же, что url
---@field query table|nil Параметры запроса
---@field headers table<string, string>|nil Заголовки поверх заголовков клиента
---@field json any Тело: будет закодировано в JSON
---@field form table|nil Тело: будет закодировано как форма
---@field body string|nil Тело как есть
---@field duplex boolean|nil Держать отправку открытой для `write`
---@field timeout number|nil Срок ответа: он же срок чтения по умолчанию
---@field connect_timeout number|nil Срок соединения
---@field max_body integer|nil Сколько байт поток отдаст за жизнь; 0 — без предела
---@field max_piece integer|nil Сколько байт в одном куске; 0 — без предела
---@field verify boolean|nil Проверять ли сертификат
---@field ca_file string|nil Файл доверенных корней
---@field ca_path string|nil Каталог доверенных корней
---@field ssl_cert string|nil Файл клиентского сертификата
---@field ssl_key string|nil Файл ключа клиентского сертификата
---@field unix_socket string|nil Сокет, через который идти
---@field accept_encoding string|nil Какое сжатие принимать
---@field user_agent string|nil Чем представляться

---@class TntHttpMessage Запрос в общем виде: его же читают слои
---@field method string Метод заглавными буквами
---@field url string Адрес целиком, вместе с параметрами
---@field path string Путь без параметров
---@field query table|nil Параметры, какими их задали
---@field headers table<string, string> Заголовки; имена в нижнем регистре
---@field body string|nil Тело, уже собранное в строку

---@class TntHttpClient
---@field settings table Проверенные настройки клиента
---@field retry TntRetry Повторы: свои на клиента
---@field layers function[] Слои запроса: стык для `tnt.middleware`
---@field handle table Обработчик libcurl со своим кэшем соединений
local Client = {}
Client.__index = Client

--- Настройки запроса с подставленными методом и адресом.
---
--- Копия, а не правка на месте: таблицу настроек вызывающий вправе
--- держать у себя и слать по ней несколько запросов, и дописать в неё
--- метод значило бы испортить её навсегда.
---@param method string
---@param url string
---@param opts TntHttpRequest|nil
---@return table
local function aimed(method, url, opts)
    ---@type table<string, any>
    local prepared = {}

    for name, value in pairs(opts or {}) do
        prepared[name] = value
    end

    prepared.method = method
    prepared.url = url

    return prepared
end

--- Отказ, который повторять незачем.
---
--- Переходов больше предела не станет со второй попытки, и чужой ответ
--- не похудеет.
---@param request TntHttpMessage Запрос, на котором всё кончилось
---@param reason string Что именно не вышло
---@return TntHttpFailure
local function refusal(request, reason)
    return failure_of.on(failure_of.REFUSED, request, reason)
end

--- Запрос на новый адрес после перехода.
---@param current TntHttpMessage Запрос, на который пришёл переход
---@param status integer Код перехода
---@param location string Что сказал сервер в Location
---@return TntHttpMessage|nil request
---@return string|nil reason Почему перехода не вышло
local function after_redirect(current, status, location)
    local target = url_of.resolve(current.url, location)

    if target == nil then
        return nil, ('переход по негодной ссылке «%s»'):format(location)
    end

    ---@cast target string

    -- Схема цели сверяется здесь, а не у libcurl: свои переходы он
    -- по `file://` и `gopher://` не делает, но переходы проходит клиент,
    -- и без этой сверки ответ сервера читал бы файл узла (см. `url.WEB`).
    if not url_of.WEB[url_of.scheme(target)] then
        return nil, ('переход на схему «%s» не разрешён'):format(url_of.scheme(target))
    end

    local method, keeps_body = policy.after_redirect(current.method, status)
    local headers = policy.carried(current.headers, url_of.origin(current.url), url_of.origin(target))

    if not keeps_body then
        -- Метод сменился на GET: тела больше нет, и заголовок о его виде
        -- сбивал бы сервер с толку — он описывает то, чего не послали.
        headers[CONTENT_TYPE] = nil
    end

    return {
        method = method,
        url = target,
        path = url_of.path(target),
        query = current.query,
        headers = headers,
        body = keeps_body and current.body or nil,
    }
end

--- Отказ, случившийся до отправки: вызывающий попросил негодного.
---@param reason string
---@return nil
---@return TntHttpFailure
local function invalid(reason)
    return nil, failure_of.new(failure_of.INVALID, reason)
end

---@class TntHttpPrepared Всё, что нужно для отправки
---@field given table Проверенные настройки обращения
---@field resolved table Настройки клиента, перекрытые настройками обращения
---@field request TntHttpMessage Запрос в общем виде

--- Проверяет настройки и собирает запрос в общем виде — том самом,
--- который видят слои.
---
--- Одно на запрос и на поток нарочно: адрес, заголовки и тело потока
--- обязаны собираться тем же кодом, иначе разойдутся на первой правке.
---@param check fun(opts: table|nil): table|nil, string|nil Проверка настроек
---@param opts table|nil Настройки обращения
---@return TntHttpPrepared|nil
---@return TntHttpFailure|nil err
function Client:_prepare(check, opts)
    local given, unfit = check(opts)

    if given == nil then
        ---@cast unfit string
        return invalid(unfit)
    end

    local resolved = settings_of.resolve(self.settings, given)
    local unpaired = settings_of.unpaired(resolved)

    if unpaired ~= nil then
        return invalid(unpaired)
    end

    local target = url_of.join(self.settings.base_url, given.url or given.path)

    if not url_of.is_absolute(target) then
        return invalid(
            ('адрес «%s» неполон: задайте клиенту base_url или пришлите адрес со схемой'):format(
                target
            )
        )
    end

    if not url_of.WEB[url_of.scheme(target)] then
        return invalid(
            ('схема «%s» не годится: клиент ходит только по http и https'):format(
                url_of.scheme(target)
            )
        )
    end

    local addressed, wrong = url_of.with_query(target, given.query)

    if addressed == nil then
        ---@cast wrong string
        return invalid(wrong)
    end

    local rendered, failed = body_of.render(given)

    if rendered == nil then
        ---@cast failed string
        return invalid(failed)
    end

    local headers = resolved.headers

    -- Заголовок содержимого ставится только там, где его не задали руками:
    -- вызывающий, написавший `application/vnd.api+json`, имел это в виду.
    if rendered.content_type ~= nil and headers[CONTENT_TYPE] == nil then
        headers[CONTENT_TYPE] = rendered.content_type
    end

    headers['user-agent'] = headers['user-agent'] or resolved.user_agent

    return {
        given = given,
        resolved = resolved,
        request = {
            method = (given.method or DEFAULT_METHOD):upper(),
            url = addressed,
            path = url_of.path(addressed),
            query = given.query,
            headers = headers,
            body = rendered.body,
        },
    }
end

--- Шлёт запрос, проходя переходы по `Location`.
---
--- Остаток общего срока спрашивается перед каждым обращением, а не один
--- раз на попытку: каждый переход — новое ожидание libcurl, и снимок начала
--- попытки дал бы каждому полный срок — попытка с тремя переходами длилась
--- бы втрое дольше, чем вызывающий согласен ждать целиком.
---@param request TntHttpMessage Запрос в общем виде
---@param resolved table Настройки этого запроса
---@param remaining fun(): number|nil Остаток общего срока повторов на этот миг
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Client:_send(request, resolved, remaining)
    local current = request

    -- Переходы считаются на убыль: «сколько ещё можно» и есть то, что
    -- проверяется на каждом шаге, а «сколько уже сделано» приходится
    -- каждый раз сличать с пределом.
    local hops = resolved.max_redirects

    while true do
        local raw, err, reason = transport.perform(
            self.handle,
            current.method,
            current.url,
            current.body,
            settings_of.curl_options(resolved, current.headers, remaining())
        )

        if raw == nil then
            ---@cast err string
            return nil,
                failure_of.new(failure_of.UNREACHABLE, err, {
                    reason = reason,
                    retriable = policy.retriable_failure(current.method),
                })
        end

        local answer = response_of.new(raw, current)
        local size = policy.oversized(answer.body, resolved.max_body)

        if size ~= nil then
            return nil,
                refusal(
                    current,
                    ('ответ в %d байт больше предела в %d'):format(size, resolved.max_body)
                )
        end

        local location = answer.headers[LOCATION]

        -- Переход — это код перехода вместе с адресом: `Location` в ответе
        -- 201 указывает на созданный ресурс, и идти по нему никто не просил.
        if location == nil or not policy.redirects(answer.status) then
            return answer
        end

        if hops == 0 then
            -- Предел в ноль переходов значит «не переходить вовсе»:
            -- ответ 3xx — это ответ, и вызывающий прочитает его сам.
            if resolved.max_redirects == 0 then
                return answer
            end

            return nil,
                refusal(
                    request,
                    ('переходов больше %d, дальше не идём'):format(resolved.max_redirects)
                )
        end

        local moved, wrong = after_redirect(current, answer.status, location)

        if wrong ~= nil then
            return nil, refusal(current, wrong)
        end

        ---@cast moved TntHttpMessage
        hops = hops - 1
        current = moved
    end
end

--- Разбирает исход одной попытки в том виде, которого ждёт `tnt.retry`.
---
--- Ответ, который стоит повторить, возвращается отказом — иначе повторов
--- не будет вовсе, — но сам ответ едет в отказе с собой: когда попытки
--- кончатся, вызывающему нужен он, а не рассказ о нём.
---@param request TntHttpMessage
---@param answer TntHttpResponse|nil
---@param err any Отказ отправки от клиента либо отказ слоя
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil failure
local function outcome_of(request, answer, err)
    if answer == nil then
        -- Слой вправе отказать сам и сказать об этом строкой: приговор
        -- такому отказу выносится по методу, как отказу сети.
        return nil, failure_of.of(err, policy.retriable_failure(request.method))
    end

    if not policy.retriable_status(request.method, answer.status) then
        return answer
    end

    return nil,
        failure_of.on(
            failure_of.STATUS,
            request,
            ('сервер ответил %d %s'):format(answer.status, answer.reason),
            {
                status = answer.status,
                -- `Retry-After` передаётся как пришёл: читает его `tnt.retry`,
                -- и только числом секунд. Дату он не разбирает нарочно —
                -- она меряется чужими часами, а они расходятся с нашими.
                retry_after = answer.headers['retry-after'],
                retriable = true,
                response = answer,
            }
        )
end

--- Выполняет запрос.
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil answer Ответ с любым кодом; nil — ответа нет
---@return TntHttpFailure|nil err Почему ответа нет
function Client:request(opts)
    local prepared, failed = self:_prepare(settings_of.request, opts)

    if prepared == nil then
        return nil, failed
    end

    local request = prepared.request
    local resolved = prepared.resolved

    -- Повторы запроса проверяются до отправки: негодная настройка — ошибка
    -- вызывающего, и узнать о ней надо до первого байта, а не отказом,
    -- неотличимым от отказа сервера.
    local run, unfit = self.retry:policy(prepared.given.retry)

    if run == nil then
        return invalid(('настройки повторов: %s'):format(tostring(unfit)))
    end

    local answer, err = run(function(context)
        -- Крюки — снаружи слоёв, заголовки контекста — перед самой
        -- отправкой (см. шапку `tnt.http.hook`), и всё это собирается
        -- на попытку: в отправке заперт остаток общего срока, а он у каждой
        -- попытки свой. Отдаётся не снимок остатка, а вопрос о нём: слои
        -- вправе уступать управление до отправки, а переходов бывает
        -- несколько.
        local propagate = self.settings.propagate

        return outcome_of(
            request,
            hook_of.around(propagate, hook_of.REQUEST, context.attempt, request, self.layers, function(layered)
                return self:_send(layered, resolved, context.remaining)
            end)
        )
    end)

    if answer ~= nil then
        return answer
    end

    -- Сюда доходят и чужие слова: брошенное слоем и отказ размыкателя
    -- приходят от `tnt.retry` как есть, и повторять их клиент не стал бы.
    local failure = failure_of.of(err, false)

    if failure.response ~= nil then
        return failure.response
    end

    -- Адрес в записи есть и так — узлом и путём, — а строка запроса в неё
    -- не попадает нарочно: в параметрах ездят ключи доступа, и журнал —
    -- последнее место, где им стоит оседать.
    log.warn('запрос не удался', {
        method = request.method,
        origin = url_of.origin(request.url),
        path = request.path,
        err = failure.reason or failure.message,
    })

    return nil, failure
end

--- Открывает поток: тело ответа читается кусками.
---
--- Повторов, переходов и слоёв у потока нет — почему, сказано в шапке
--- `tnt.http.stream`. Закрыть поток обязательно.
---@param opts TntHttpStreamRequest|nil
---@return TntHttpStream|nil
---@return TntHttpFailure|nil err
function Client:stream(opts)
    local prepared, failed = self:_prepare(settings_of.stream, opts)

    if prepared == nil then
        return nil, failed
    end

    local request = prepared.request
    local resolved = prepared.resolved

    resolved.duplex = prepared.given.duplex
    resolved.max_piece = prepared.given.max_piece

    -- Крюки и заголовки контекста — те же, что у попытки запроса, но один
    -- раз, при открытии: повторов у потока нет, слоёв — тоже.
    return hook_of.around(self.settings.propagate, hook_of.STREAM, nil, request, {}, function(current)
        return stream_of.open(self.handle, current, settings_of.curl_options(resolved, current.headers, nil), resolved)
    end)
end

--- Забирает ресурс.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Client:get(url, opts)
    return self:request(aimed('GET', url, opts))
end

--- Создаёт или отправляет: метод, который клиент не повторяет сам.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Client:post(url, opts)
    return self:request(aimed('POST', url, opts))
end

--- Кладёт ресурс целиком.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Client:put(url, opts)
    return self:request(aimed('PUT', url, opts))
end

--- Правит часть ресурса.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Client:patch(url, opts)
    return self:request(aimed('PATCH', url, opts))
end

--- Удаляет ресурс.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Client:delete(url, opts)
    return self:request(aimed('DELETE', url, opts))
end

--- Спрашивает заголовки, не забирая тела.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Client:head(url, opts)
    return self:request(aimed('HEAD', url, opts))
end

--- Имена заголовков клиента, без значений.
---
--- Значения не показываются никогда: в `authorization` лежит пароль,
--- а состояние читают и журнал, и панель, и человек через плечо.
---@param headers table<string, string>
---@return string[]
local function header_names(headers)
    local names = {}

    for name in pairs(headers) do
        table.insert(names, name)
    end

    table.sort(names)

    return names
end

--- Что настроено. Секретов здесь нет и не будет.
---@return table
function Client:status()
    return {
        base_url = self.settings.base_url,
        timeout = self.settings.timeout,
        connect_timeout = self.settings.connect_timeout,
        max_redirects = self.settings.max_redirects,
        max_body = self.settings.max_body,
        max_connections = self.settings.max_connections,
        verify = self.settings.verify,
        ssl_cert = self.settings.ssl_cert,
        -- Ключ — только признаком: путь к ключу сам не тайна, но рядом
        -- с ним лежит сам ключ, и подсказывать, где именно, незачем.
        ssl_key = self.settings.ssl_key ~= nil,
        unix_socket = self.settings.unix_socket,
        user_agent = self.settings.user_agent,
        headers = header_names(self.settings.headers or {}),
        layers = #self.layers,
        propagate = self.settings.propagate,
        -- Крюки общие на процесс, и показываются они у каждого клиента:
        -- по состоянию клиента судят, доедет ли из него трасса.
        hooks = hook_of.names(),
        retry = self.retry:status(),
    }
end

--- Проверенные части клиента: настройки и повторы.
---
--- Отделены от сборки нарочно: `configure` обязан отказать сразу, если
--- настройки негодны, но заводить обработчик libcurl при этом незачем —
--- общий клиент ленив, и до первого запроса его может не понадобиться.
---@param opts table|nil
---@return table|nil parts
---@return string|nil err
local function prepare(opts)
    local settings, wrong = settings_of.client(opts)

    if settings == nil then
        return nil, wrong
    end

    local retries, failed = retry_of.new(settings.retry)

    if retries == nil then
        return nil, ('настройки повторов: %s'):format(tostring(failed))
    end

    return { settings = settings, retry = retries }
end

--- Собирает клиента из проверенных частей.
---@param parts table
---@return TntHttpClient
local function build(parts)
    return setmetatable({
        settings = parts.settings,
        retry = parts.retry,
        layers = parts.settings.layers,
        handle = transport.new({ max_connections = parts.settings.max_connections }),
    }, Client)
end

---@class TntHttpSettings
---@field base_url string|nil Начало адреса, к которому дописываются пути
---@field headers table<string, string>|nil Заголовки на каждый запрос
---@field timeout number|nil Срок ответа, секунды
---@field connect_timeout number|nil Срок соединения, секунды; складывается со сроком ответа
---@field max_redirects integer|nil Предел переходов; 0 — не переходить
---@field max_body integer|nil Предел размера ответа в байтах; 0 — без предела
---@field max_connections integer|nil Размер кэша соединений libcurl
---@field verify boolean|nil Проверять ли сертификат сервера
---@field ca_file string|nil Файл доверенных корней
---@field ca_path string|nil Каталог доверенных корней
---@field ssl_cert string|nil Файл клиентского сертификата
---@field ssl_key string|nil Файл ключа клиентского сертификата
---@field unix_socket string|nil Сокет, через который идут все запросы клиента
---@field accept_encoding string|nil Какое сжатие принимать
---@field user_agent string|nil Чем представляться серверу
---@field retry table|nil Настройки `tnt.retry` для этого клиента
---@field layers function[]|nil Слои запроса: стык для `tnt.middleware`
---@field propagate boolean|nil Класть ли заголовки контекста и звать ли крюки; по умолчанию да

--- Заводит отдельный клиент: свои настройки, свой кэш соединений.
---
--- Отказ в сборке — строка, а не `TntHttpFailure`: запроса ещё нет,
--- и приговор выносить не о чем.
---@param opts TntHttpSettings|nil
---@return TntHttpClient|nil
---@return string|nil err
function Module.new(opts)
    local parts, err = prepare(opts)

    if parts == nil then
        return nil, err
    end

    return build(parts)
end

--- Части общего клиента, принятые последним `configure`.
---@type table
local configured

--- Общий клиент на процесс. Ленив нарочно: загрузка модуля не должна
--- заводить обработчик libcurl — его заводит первое обращение.
---@type TntHttpClient|nil
local shared

--- Настраивает общий клиент.
---
--- Настройки проверяются здесь, а собранный по ним клиент забывается:
--- следующее обращение соберёт новый. Иначе `configure` посреди работы
--- оставил бы прежний кэш соединений с новыми настройками.
---@param opts TntHttpSettings|nil
---@return boolean ok
---@return string|nil err
function Module.configure(opts)
    local parts, err = prepare(opts)

    if parts == nil then
        return false, err
    end

    configured = parts
    shared = nil

    return true
end

--- Общий клиент на процесс.
---@return TntHttpClient
function Module.default()
    if shared == nil then
        shared = build(configured)
    end

    return shared
end

--- Выполняет запрос общим клиентом.
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Module.request(opts)
    return Module.default():request(opts)
end

--- Открывает поток общим клиентом.
---@param opts TntHttpStreamRequest|nil
---@return TntHttpStream|nil
---@return TntHttpFailure|nil err
function Module.stream(opts)
    return Module.default():stream(opts)
end

--- Забирает ресурс общим клиентом.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Module.get(url, opts)
    return Module.default():get(url, opts)
end

--- Создаёт или отправляет общим клиентом.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Module.post(url, opts)
    return Module.default():post(url, opts)
end

--- Кладёт ресурс целиком общим клиентом.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Module.put(url, opts)
    return Module.default():put(url, opts)
end

--- Правит часть ресурса общим клиентом.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Module.patch(url, opts)
    return Module.default():patch(url, opts)
end

--- Удаляет ресурс общим клиентом.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Module.delete(url, opts)
    return Module.default():delete(url, opts)
end

--- Спрашивает заголовки общим клиентом.
---@param url string
---@param opts TntHttpRequest|nil
---@return TntHttpResponse|nil
---@return TntHttpFailure|nil err
function Module.head(url, opts)
    return Module.default():head(url, opts)
end

--- Что настроено у общего клиента.
---@return table
function Module.status()
    return Module.default():status()
end

Module.configure(nil)

return Module
