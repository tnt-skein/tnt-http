--- Клиент против сервера, который ведёт себя не так, как httpbin.
---
--- Двойник пересказывает, что `http.client` отдаёт в неудобных случаях,
--- а проверить сам пересказ может только настоящий libcurl. Стенд здесь
--- не годится: httpbin не льёт тело без пауз и без разделителя, не молчит
--- после первой строки до самого закрытия и не отвечает переходом
--- на `file://`. Поэтому сервер поднимается прямо в проверке, на сокете
--- Tarantool, — докер не нужен, и проверки не пропускаются.
---
--- Каждый случай отсюда однажды разошёлся с пересказом: чтение падало
--- на `nil`, закрытие из другого файбера читалось обрывом, а переход
--- на `file://` отдавал файл узла телом ответа.

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
---@param serve fun(peer: table) Разговор с одним клиентом
---@param path string|nil Путь сокета; без него — TCP на свободном порту
---@return string address Начало адреса для клиента
local function serving(serve, path)
    -- Порт сокета — его путь: аннотации `socket` о таком не знают.
    ---@type any
    local port = path or 0

    local server = socket.tcp_server(path and 'unix/' or '127.0.0.1', port, function(peer)
        peer:read('\r\n\r\n', 2)
        serve(peer)
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
