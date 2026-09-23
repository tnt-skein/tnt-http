--- Общие средства тестов клиента HTTP.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.context`, `tnt.validate`, `tnt.retry`, `tnt.log`,
--- `tnt.must`, `tnt.external` — берутся из `.rocks` обычным `require`:
--- проверяется этот пакет, а не они. Контекст при этом настоящий, а не
--- двойник: заголовки из него проверяются на том же хранилище файбера,
--- что и в бою. Двойник часов ставится на установленный цикл повторов,
--- ловушка журнала — на установленный `tnt.log`: тот же экземпляр,
--- которым пишет клиент.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы, которые
--- двигает проверка, ловушка журнала и сценарий ответов — грузится так же
--- и один раз на процесс: второй экземпляр загрузчика не знал бы, что
--- вытеснил первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через помощник, а не из оснастки напрямую: помощник —
--- единственное, чем файл проверок отличается от того же файла в наборе,
--- где пакет живёт рядом со своими зависимостями.

local fiber = require('fiber')
local fio = require('fio')
--- Сеть. Через any: сервер со сбросом заводит голый сокет вызовом самого
--- модуля и зовёт методы такого сокета, а объявленных типов ни на то,
--- ни на другое нет.
---@type any
local socket = require('socket')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
    { name = 'tnt.testing.protocol', path = 'test/testing/protocol.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    clock = package.loaded['tnt.testing.clock'].new,
    capture_log = package.loaded['tnt.testing.journal'].capture,
    script = package.loaded['tnt.testing.protocol'].script,
}

--- Ошибки Tarantool: ими бросает `http.client`. Конструктор в аннотациях
--- описан не полностью, поэтому берётся через промежуточную ссылку.
---@type any
local box_error = box.error

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.http.url', path = 'tnt/http/url.lua' },
    { name = 'tnt.http.body', path = 'tnt/http/body.lua' },
    { name = 'tnt.http.response', path = 'tnt/http/response.lua' },
    { name = 'tnt.http.failure', path = 'tnt/http/failure.lua' },
    { name = 'tnt.http.policy', path = 'tnt/http/policy.lua' },
    { name = 'tnt.http.settings', path = 'tnt/http/settings.lua' },
    { name = 'tnt.http.transport', path = 'tnt/http/transport.lua' },
    { name = 'tnt.http.stream', path = 'tnt/http/stream.lua' },
    { name = 'tnt.http.hook', path = 'tnt/http/hook.lua' },
    { name = 'tnt.http', path = 'tnt/http.lua' },
}

--- Ключ контекста, объявленный самой проверкой: под своим именем
--- и заголовком, а не `traceparent`. Объявление ключа общее на процесс,
--- и настройки трассировки разошлись бы с проверочными.
helper.PROBE = 'http_probe'

--- Заголовок, которым ключ проверки уезжает из процесса.
helper.PROBE_HEADER = 'x-http-probe'

--- Объявляет ключ проверки у контекста.
---
--- Контекст — установленный, один на процесс, и объявление живёт в нём.
--- Объявляется оно всё же перед каждой проверкой, а не один раз на файл:
--- так проверка не зависит от того, какой файл шёл первым, а повтор
--- с теми же настройками безвреден.
---@return TntContext
function helper.context()
    local context = helper.module('tnt.context')

    context.declare(helper.PROBE, { header = helper.PROBE_HEADER, log = false })

    return context
end

--- Уже загруженный модуль: проверке клиента нужны и соседи.
helper.module = testing.module

--- Модуль пакета из исходников.
---
--- Заново на каждую проверку: крюки, общий клиент и подменённые средства
--- живут в модулях, и оставленные соседней проверкой сделали бы порядок
--- проверок частью их смысла.
---@param name string Какой модуль отдать: tnt.http, tnt.http.url…
---@return any
function helper.load(name)
    return testing.load_sources(helper.MODULES, name)
end

--- Убирает исходники и возвращает то, что они вытеснили.
function helper.unload()
    testing.unload_sources(helper.MODULES)
end

--- Ловушка журнала: записи клиента видны проверке, а не только в выводе.
---@return TntTestingJournal
function helper.capture_log()
    return testing.capture_log()
end

--- Каталог сертификатов etcd с mTLS для живой проверки: тот же, куда
--- их выпускает `test/stand/etcd_mtls.sh`, и та же переменная окружения.
---@return string
function helper.mtls_directory()
    return require('tnt.env').new():string('ETCD_MTLS_DIR', 'test/stand/run/etcd-mtls')
end

--- Куда ходят проверки, которым адрес безразличен.
helper.SOMEWHERE = 'http://api.example.org/customers'

--- Настройки проверки поверх умолчаний: новая таблица, умолчания целы.
---@param defaults table
---@param overrides table|nil
---@return table
function helper.merged(defaults, overrides)
    local merged = {}

    for _, given in ipairs({ defaults, overrides or {} }) do
        for name, value in pairs(given) do
            merged[name] = value
        end
    end

    return merged
end

--- Отвечает ли кто-нибудь на этом порту: живые проверки без стенда
--- пропускаются, а не падают.
---@param host string
---@param port integer
---@return boolean
function helper.listening(host, port)
    local connection = socket.tcp_connect(host, port, 0.3)

    if connection == nil then
        return false
    end

    connection:close()

    return true
end

--- Ответ, который отдал бы настоящий сервер.
---
--- Заголовки приходят как есть, в том числе с заглавными буквами: чужой
--- сервер пишет их как вздумается, и приведение к нижнему регистру —
--- работа клиента, а не проверки.
---@param status integer
---@param overrides table|nil Поля поверх умолчаний
---@return table
function helper.answer(status, overrides)
    local answer = {
        status = status,
        reason = 'Ok',
        headers = {},
        body = '',
    }

    for name, value in pairs(overrides or {}) do
        answer[name] = value
    end

    return answer
end

--- Ответ 200 с телом JSON.
---@param body string
---@return table
function helper.json_answer(body)
    return helper.answer(200, {
        headers = { ['Content-Type'] = 'application/json' },
        body = body,
    })
end

--- Ответ, которого не было: так `http.client` сообщает об отказе сети
--- до отправки — имя не разрешилось, соединение не открылось.
---
--- Заголовков нет вовсе, и это единственная надёжная примета: код 595
--- libcurl придумывает сам, и такой же мог бы придумать чужой сервер.
--- Слова по умолчанию — libcurl 8.11 статической сборки Tarantool 3.8
--- для Linux; до 8.9 libcurl писал «Couldn't resolve host name».
---@param reason string|nil
---@return table
function helper.no_answer(reason)
    return { status = 595, reason = reason or 'Could not resolve hostname' }
end

--- Бросок libcurl: так `http.client` 3.8 сообщает об отказах без
--- придуманного кода — и до отправки (негодный адрес, рукопожатие TLS),
--- и после неё (сброс соединения, оборванное тело, мусор вместо ответа).
---
--- Текст — как у настоящего: `curl:`, слова libcurl и errno словами,
--- которое `http.client` дописывает сам.
---@param words string Слова libcurl
---@param cause string|nil errno словами
---@return table
function helper.thrown(words, cause)
    return { raises = ('curl: %s: %s'):format(words, cause or 'Invalid argument') }
end

--- Сервер, который дочитывает заголовки запроса и сбрасывает соединение.
---
--- Так выглядит служба, упавшая с запросом в руках: запрос дошёл, ответа
--- нет, и libcurl бросает «Failure when receiving data from the peer».
--- Сервер на голом сокете, а не на `tcp_server`: тот закрывает соединение
--- сам и мягко, и вместо сброса libcurl видел бы пустой ответ (код 444).
---@return table server url — начало адреса; received() — сколько запросов дошло; close()
function helper.resetting()
    local listener = socket('AF_INET', 'SOCK_STREAM', 'tcp')

    assert(listener:bind('127.0.0.1', 0))
    assert(listener:listen(16))

    local received = 0

    local worker = fiber.create(function()
        while listener:readable() do
            local peer = listener:accept()

            if peer ~= nil then
                if peer:read('\r\n\r\n', 2) ~= nil then
                    received = received + 1
                end

                -- Ноль секунд задержки при закрытии — это сброс (RST), а не FIN.
                peer:linger(true, 0)
                peer:close()
            end
        end
    end)

    return {
        url = ('http://127.0.0.1:%d'):format(listener:name().port),
        received = function()
            return received
        end,
        close = function()
            worker:cancel()
            listener:close()
        end,
    }
end

--- Переход на другой адрес.
---@param status integer
---@param location string
---@return table
function helper.moved(status, location)
    return helper.answer(status, { headers = { Location = location } })
end

--- Ставит двойник libcurl на место настоящего.
---
--- Двойник помнит, о чём его просили, и отдаёт заранее написанные ответы
--- по порядку. Настоящий сокет для этого не нужен, а вот порядок
--- обращений — нужен весь: переходы и повторы только по нему и видны.
---@param script table[] Ответы по порядку; `error` в ответе — брошенное
---@return table sent Что уходило на сервер
function helper.serving(script)
    local sent = {}
    local answers = testing.script(script)

    local handle = {
        request = function(_, method, url, body, options)
            table.insert(sent, { method = method, url = url, body = body, options = options })

            -- Кончившийся сценарий — ошибка проверки: клиент, сходивший
            -- к серверу лишний раз, обязан об этом сказать.
            local answer = answers.next()

            if answer.takes ~= nil then
                helper.passes(answer.takes)
            end

            if answer.raises ~= nil then
                error(answer.raises, 0)
            end

            return answer
        end,
    }

    helper.module('tnt.http.transport')._set_source({
        client = function()
            return handle
        end,
    })

    return sent
end

--- Чтение, на котором вышел срок: так `http.client` бросает на молчащем потоке.
---@return table
function helper.idle()
    return { raises = box_error.new({ type = 'TimedOut', reason = 'timed out' }) }
end

--- Чтение, на котором срок вышел посреди куска.
---
--- Байты шли, но ни разделителя, ни нужного их числа не пришло: так
--- `http.client` не бросает, а возвращает `nil` (найдено запуском против
--- сервера, льющего тело без пауз и без разделителя).
---@return function
function helper.unfinished()
    return function()
        return nil
    end
end

--- Поток, который отдал бы `http.client` с `chunked = true`.
---
--- Чтения идут по списку: строка — кусок, таблица с `raises` — брошенное,
--- функция — что она вернёт (так чтение отдаёт `nil` или закрывает поток
--- посреди ожидания), конец списка — пустая строка, то есть конец
--- передачи. Код и слово появляются на потоке только после `finish`,
--- как у настоящего.
---@param script table reads, finished = { status, reason }, headers, opened, write
---@return table raw Поток
---@return table asked Что у него просили: reads, writes, finishes
function helper.stream_of(script)
    local asked = { reads = {}, writes = {}, finishes = {} }
    local at = 0
    local finished = script.finished or { status = 200, reason = 'Ok' }

    -- Заголовки у настоящего потока есть всегда, кроме отказа до ответа:
    -- у методов с телом это пустая таблица.
    local raw = { headers = script.headers or {}, status = script.opened }

    function raw.read(_, spec, timeout)
        at = at + 1
        table.insert(asked.reads, { spec = spec, timeout = timeout })

        local item = (script.reads or {})[at]

        if item == nil then
            return ''
        end

        if type(item) == 'function' then
            return item()
        end

        if type(item) == 'table' then
            error(item.raises, 0)
        end

        return item
    end

    function raw.write(_, data, timeout)
        table.insert(asked.writes, { data = data, timeout = timeout })

        if script.write ~= nil then
            return script.write(data)
        end

        return #data
    end

    function raw.finish(self, timeout)
        table.insert(asked.finishes, timeout)
        self.status = finished.status
        self.reason = finished.reason
    end

    return raw, asked
end

--- Ставит двойник libcurl, отвечающий потоком.
---@param script table Как у `stream_of`; `refuses` — что бросить при открытии
---@return table sent Что уходило на сервер
---@return table asked Что просили у потока
---@return table raw Сам поток
function helper.streaming(script)
    local sent = {}
    local raw, asked = helper.stream_of(script)

    helper.module('tnt.http.transport')._set_source({
        client = function()
            return {
                request = function(_, method, url, body, options)
                    table.insert(sent, { method = method, url = url, body = body, options = options })

                    if script.refuses ~= nil then
                        error(script.refuses, 0)
                    end

                    return raw
                end,
            }
        end,
    })

    return sent, asked, raw
end

--- Снимает двойники и забывает исходники.
function helper.forget()
    helper.module('tnt.http.transport')._set_source(nil)
    helper.module('tnt.retry.runner')._set_source(nil)
    helper.unload()
end

--- Часы повторов: двойник оснастки, заводится заново на каждую проверку.
---
--- Заведены и до первой проверки: ответ двойника сервера с `takes` двигает
--- их и там, где повторы остались настоящими.
---@type TntTestingClock
local clock = testing.clock()

--- Повторы без настоящего ожидания.
---
--- Пауза перед повтором доходит до секунд, и проверка трёх попыток
--- стоила бы секунд вместо миллисекунд. Часы здесь двигает сама пауза:
--- сколько попросили поспать, на столько они и ушли вперёд. Отметка цикла
--- событий идёт вровень с ними — работы без уступки у двойника нет.
---
--- Двигает их и ответ двойника сервера, у которого задано `takes`:
--- так видно, сколько срока остаётся следующему обращению.
---@return number[] slept Длительности пауз по порядку
function helper.instant_retries()
    clock = testing.clock()

    helper.module('tnt.retry.runner')._set_source({
        now = clock.monotonic,
        scheduler_now = clock.scheduler_now,
        sleep = clock.sleep,
    })

    return clock.slept
end

--- Двигает часы повторов вперёд.
---@param seconds number
function helper.passes(seconds)
    clock.advance(seconds)
end

--- Ставит двойник сервера и заводит клиента поверх него.
---
--- Порядок важен: клиент забирает обработчик при сборке, и двойник,
--- поставленный после, достался бы уже некому.
---@param script table[] Ответы сервера по порядку
---@param opts table|nil Настройки клиента
---@return any client
---@return table sent Что уходило на сервер
function helper.client_of(script, opts)
    local sent = helper.serving(script)

    return (assert(helper.module('tnt.http').new(opts))), sent
end

--- Запрос под указанным номером; его отсутствие — ошибка самой проверки.
---@param sent table[]
---@param index integer
---@return table
function helper.at(sent, index)
    return (assert(sent[index], ('запроса №%d не было'):format(index)))
end

return helper
