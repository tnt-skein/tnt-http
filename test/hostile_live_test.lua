--- Клиент против сервера, который ведёт себя не так, как httpbin.
---
--- Двойник пересказывает, что `http.client` отдаёт в неудобных случаях,
--- а проверить сам пересказ может только настоящий libcurl. Стенд здесь
--- не годится: httpbin не льёт тело без пауз и без разделителя, не молчит
--- после первой строки до самого закрытия, не отвечает переходом
--- на `file://` и не говорит, ждал ли клиент подтверждения тела. Поэтому
--- сервер поднимается прямо в проверке, на сокете Tarantool, — докер
--- не нужен, и проверки не пропускаются.
---
--- Каждый случай отсюда однажды разошёлся с пересказом: чтение падало
--- на `nil`, закрытие из другого файбера читалось обрывом, переход
--- на `file://` отдавал файл узла телом ответа, а тело больше мегабайта
--- теряло заголовки ответа после `100 Continue`.

local t = require('luatest')
local fiber = require('fiber')
local fio = require('fio')
local socket = require('socket')

local g = t.group('tnt.http.hostile_live')

local helper = dofile('test/helper.lua')

---@type any
local http

--- Поднятые проверкой серверы: гасятся после каждой.
---@type table[]
local servers

--- Каталог сокета: удаляется после проверки.
---@type string|nil
local directory

g.before_each(function()
    http = helper.load('tnt.http')
    servers = {}
end)

g.after_each(function()
    for _, server in ipairs(servers) do
        server:close()
    end

    if directory ~= nil then
        fio.rmtree(directory)
        directory = nil
    end

    helper.unload()
end)

--- Поднимает сервер, отвечающий так, как велит `serve`.
---@param serve fun(peer: table, head: string) Разговор с одним клиентом; head — заголовки запроса
---@param path string|nil Путь сокета; без него — TCP на свободном порту
---@return string address Начало адреса для клиента
local function serving(serve, path)
    -- Порт сокета — его путь: аннотации `socket` о таком не знают.
    ---@type any
    local port = path or 0

    local server = socket.tcp_server(path and 'unix/' or '127.0.0.1', port, function(peer)
        serve(peer, peer:read('\r\n\r\n', 2) or '')
    end)

    table.insert(servers, server)

    if path ~= nil then
        return 'http://sidecar.invalid'
    end

    return ('http://127.0.0.1:%d'):format(server:name().port)
end

--- Отвечает переходом на указанный адрес.
---@param location string
---@return fun(peer: table)
local function moving_to(location)
    return function(peer)
        peer:write(('HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\n\r\n'):format(location))
    end
end

--- Заголовок потока `chunked`.
local CHUNKED = 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'

--- Тело, которое libcurl без просьбы шлёт с `Expect: 100-continue`:
--- порог у него — мегабайт.
local BIG = ('x'):rep(2 * 1024 * 1024)

--- Настоящий ответ сервера, подтверждающего тело: заголовки при нём
--- те, что теряет `http.client` после ответа 100.
local STORED = 'HTTP/1.1 200 OK\r\nETag: "abc"\r\nLocation: /objects/big\r\nContent-Length: 2\r\n'
    .. 'Connection: close\r\n\r\nok'

--- Отвечает `100 Continue` всякому, кто подтверждения ждёт, и помнит,
--- ждали ли его: по этому видно, что ожидания не просил клиент, а не что
--- сервер его не заметил.
---
--- Тело дочитывается целиком — по длине либо до последнего куска
--- `chunked`, — и только потом уходит ответ: иначе libcurl, не дописавший
--- тело, видел бы обрыв, а не ответ.
---@param asked boolean[] Ждал ли подтверждения каждый запрос, по порядку
---@return fun(peer: table, head: string)
local function confirming(asked)
    return function(peer, head)
        local lowered = head:lower()
        local awaits = lowered:find('\r\nexpect: 100-continue\r\n', 1, true) ~= nil

        table.insert(asked, awaits)

        if awaits then
            peer:write('HTTP/1.1 100 Continue\r\n\r\n')
        end

        local length = tonumber(lowered:match('\r\ncontent%-length: (%d+)\r\n'))

        if length == nil then
            peer:read('\r\n0\r\n\r\n', 5)
        end

        while length ~= nil and length > 0 do
            -- Пустое чтение — клиент ушёл: без выхода цикл крутился бы
            -- без уступки и держал весь процесс проверок.
            local piece = peer:read(math.min(length, 65536), 5) or ''

            if piece == '' then
                break
            end

            length = length - #piece
        end

        peer:write(STORED)
    end
end

g.test_body_poured_without_a_delimiter_is_idle_and_not_a_throw = function()
    -- Льёт кусками без пауз, пока клиент не закроет: на таком потоке
    -- `http.client` к сроку не бросает, а возвращает `nil`.
    local piece = ('a'):rep(1024)
    local frame = ('%x\r\n%s\r\n'):format(#piece, piece)

    local address = serving(function(peer)
        local written = peer:write(CHUNKED)

        while written ~= nil do
            written = peer:write(frame, 1)
        end
    end)

    local stream = assert(assert(http.new({ timeout = 5 })):stream({ url = address .. '/pour', max_body = 0 }))

    for _ = 1, 3 do
        local called, got, err = pcall(stream.read, stream, '\n', 0.01)

        t.assert_equals(called, true, got)
        t.assert_equals(got, nil)
        t.assert_equals(err and err.kind, 'idle')
    end

    t.assert_equals(stream.done, false)
    t.assert_equals(stream:close(), true)
end

g.test_close_from_another_fiber_leaves_the_reader_the_outcome_of_the_close = function()
    local address = serving(function(peer)
        peer:write(CHUNKED .. '6\r\nfirst\n\r\n')
        -- Молчит, пока клиент не закроет поток.
        peer:read(1, 5)
    end)

    local stream = assert(assert(http.new({ timeout = 5 })):stream({ url = address .. '/quiet' }))
    local outcome = fiber.channel(1)

    t.assert_equals(stream:read(), 'first\n')

    fiber.create(function()
        outcome:put({ stream:read('\n', 5) })
    end)

    fiber.sleep(0.05)
    stream:close()

    local read = outcome:get(5)

    t.assert_equals(read[1], nil)
    t.assert_equals(read[2].kind, 'invalid')
    t.assert_equals(read[2].reason, 'поток закрыт')
end

g.test_body_over_a_megabyte_keeps_the_headers_of_the_answer = function()
    -- libcurl шлёт такое тело с `Expect: 100-continue`, а `http.client`
    -- после ответа 100 отдаёт его пустые заголовки вместо настоящих:
    -- метка и адрес созданного пропали бы.
    local asked = {}
    local address = serving(confirming(asked))
    local client = assert(http.new({ retry = { attempts = 1 } }))
    local answer = assert(client:put(address .. '/big', { body = BIG }))

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.headers.etag, '"abc"')
    t.assert_equals(answer.headers.location, '/objects/big')
    t.assert_equals(asked, { false })
end

g.test_expect_named_by_the_caller_costs_the_headers_of_the_answer = function()
    -- Названный вызывающим `expect` уходит как есть — и платит за него он.
    -- Заодно проверка держит честным сервер выше: ответ 100 он шлёт,
    -- и заголовки при нём пропадают. Когда `http.client` станет разбирать
    -- заголовки последнего ответа, она разойдётся — и пустой `expect`
    -- пора пересматривать.
    local asked = {}
    local address = serving(confirming(asked))
    local client = assert(http.new({ retry = { attempts = 1 } }))
    local answer = assert(client:put(address .. '/small', { body = 'x', headers = { expect = '100-continue' } }))

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.headers, {})
    t.assert_equals(asked, { true })
end

g.test_stream_body_goes_without_awaiting_a_confirmation = function()
    -- Тело потока libcurl шлёт с ожиданием 100 при любой длине, и сервер,
    -- который 100 не шлёт, получал бы его секундой позже.
    local asked = {}
    local address = serving(confirming(asked))
    local client = assert(http.new({ timeout = 5 }))
    local stream = assert(client:stream({ method = 'PUT', url = address .. '/stream', body = 'abc' }))

    t.assert_equals(stream:read(2), 'ok')
    t.assert_equals({ stream:read(2) }, {})
    t.assert_equals(stream.status, 200)
    t.assert_equals(asked, { false })
end

g.test_redirect_to_a_file_is_refused_and_the_file_is_not_read = function()
    local address = serving(moving_to('file:///etc/hosts'))
    local answer, err = assert(http.new({ retry = { attempts = 1 } })):get(address .. '/away')

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(err.reason, 'переход на схему «file» не разрешён')
end

g.test_redirect_to_a_file_does_not_leave_the_socket_for_the_disk = function()
    directory = fio.tempdir()

    local path = fio.pathjoin(directory, 'h.sock')
    local address = serving(moving_to('file:///etc/hosts'), path)
    local client = assert(http.new({ unix_socket = path, retry = { attempts = 1 } }))
    local answer, err = client:get(address .. '/away')

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
end

g.test_redirect_to_gopher_sends_nothing_to_the_inner_port = function()
    local taken = fiber.channel(1)
    local inner = socket.tcp_server('127.0.0.1', 0, function(peer)
        taken:put(peer:read('\n', 1) or '')
    end)

    table.insert(servers, inner)

    local location = ('gopher://127.0.0.1:%d/_box.schema.user.grant%%0a'):format(inner:name().port)
    local answer, err = assert(http.new({ retry = { attempts = 1 } })):get(serving(moving_to(location)) .. '/x')

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(taken:get(0.2), nil)
end

g.test_closed_port_is_known_not_to_have_left = function()
    -- Порт 1 никто не слушает: соединение не открылось, и запрос
    -- не ушёл — на настоящем libcurl, а не в пересказе двойника.
    local client = assert(http.new({ retry = { attempts = 1 } }))
    local _, err = client:post('http://127.0.0.1:1/x', { body = 'x' })
    local _, refused = client:stream({ url = 'http://127.0.0.1:1/x', method = 'POST', body = 'x' })

    t.assert_equals({ err.kind, err.sent }, { 'unreachable', false })
    t.assert_equals({ refused.kind, refused.sent }, { 'unreachable', false })
end

g.test_reset_after_reading_could_have_left = function()
    -- Сервер дочитал запрос и сбросил соединение: запрос дошёл, и отказ
    -- обязан это сказать, хотя ответа нет.
    local server = helper.resetting()
    local _, err = assert(http.new({ retry = { attempts = 1 } })):post(server.url .. '/x', { body = 'x' })

    server.close()

    t.assert_equals({ err.kind, err.sent }, { 'unreachable', true })
    t.assert_equals(server.received(), 1)
end

g.test_file_url_is_not_an_answer_whether_curl_reads_it_or_not = function()
    -- Мимо фасада, прямо транспортом: адрес `file://` фасад отвергает сам.
    -- libcurl сборки Tarantool для macOS читает `file://` и отдаёт файл
    -- с кодом 0 и словом настоящего ответа, а статическая сборка для Linux
    -- схемы `file` не знает вовсе и отказывает до отправки. Какая сборка
    -- здесь, видно голым `http.client`; ответом транспорт не считает
    -- ни то, ни другое.
    local bare = require('http.client').new({ max_connections = 1 })
    local read, bare_raw = pcall(bare.request, bare, 'GET', 'file:///etc/hosts', nil, { timeout = 1 })

    local handle = http.transport.new({ max_connections = 1 })
    local raw, err = http.transport.perform(handle, 'GET', 'file:///etc/hosts', nil, { timeout = 1 })

    t.assert_equals(raw, nil)

    if read then
        t.assert_equals({ bare_raw.status, bare_raw.reason }, { 0, 'Unknown' })
        t.assert_equals(err, 'GET file:///etc/hosts: сервер не ответил: Unknown (код 0)')
    else
        t.assert_str_contains(err, 'GET file:///etc/hosts: libcurl отказал: curl: Unsupported protocol')
    end
end
