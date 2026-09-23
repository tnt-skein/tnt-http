--- Клиент через сокет против настоящего сервера.
---
--- Сервер поднимается прямо здесь, на сокете во временном каталоге:
--- докер для этого не нужен, а настоящий сервер нужен — двойник видит,
--- что путь сокета дошёл до libcurl, но не видит, что libcurl по нему
--- соединился, поставил `Host` из адреса и прошёл переход в тот же сокет.
---
--- Проверка пропускается, только если рока `http` нет: без него поднять
--- сервер нечем.

local t = require('luatest')
local fio = require('fio')
local json = require('json')

local g = t.group('tnt.http.socket_live')

local helper = dofile('test/helper.lua')

---@type any
local http

---@type any
local service

--- Путь сокета: во временном каталоге, и короткий — у sockaddr_un на macOS
--- всего 104 байта.
---@type string
local socket_path

--- Каталог сокета: удаляется вместе с ним.
---@type string
local directory

g.before_all(function()
    local found, server = pcall(require, 'http.server')

    if not found then
        return
    end

    directory = fio.tempdir()
    socket_path = fio.pathjoin(directory, 'http.sock')
    service = server.new('unix/', socket_path, { log_requests = false })

    -- Отвечает тем, что увидел: узлом из `Host` и заголовком входа.
    service:route({ path = '/whoami' }, function(request)
        return {
            status = 200,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({
                host = request.headers['host'],
                authorization = request.headers['authorization'] or 'нет',
            }),
        }
    end)

    service:route({ path = '/away' }, function()
        return { status = 302, headers = { location = 'http://other.example.net/whoami' } }
    end)

    service:route({ path = '/home' }, function()
        return { status = 302, headers = { location = '/whoami' } }
    end)

    service:route({ path = '/lines' }, function()
        return { status = 200, body = 'один\nдва\n' }
    end)

    service:start()
end)

g.after_all(function()
    if service ~= nil then
        service:stop()
        fio.rmtree(directory)
    end
end)

g.before_each(function()
    t.skip_if(service == nil, 'рока http нет: сервер на сокете поднять нечем')
    http = helper.load('tnt.http')
end)

g.after_each(function()
    helper.unload()
end)

--- Клиент, у которого дорога — сокет.
---@param opts table|nil
---@return any
local function client_of(opts)
    local settings = { unix_socket = socket_path, retry = { attempts = 1 } }

    return (assert(http.new(helper.merged(settings, opts))))
end

g.test_request_goes_through_the_socket_with_the_host_of_the_address = function()
    -- Узел в адресе не разрешается вовсе: имени `sidecar.invalid` нет
    -- ни в одном DNS, а ответ приходит.
    local answer, err = client_of():get('http://sidecar.invalid/whoami')

    t.assert_equals(err, nil)
    t.assert_equals(answer.status, 200)
    t.assert_equals(answer:json().host, 'sidecar.invalid')
end

g.test_redirect_to_another_host_stays_in_the_socket_without_the_login = function()
    -- Сокет — дорога, а не узел: переход меняет адрес, но не дорогу,
    -- а заголовок входа на чужой по адресу узел не едет.
    local client = client_of({ headers = { Authorization = 'Bearer тайна' } })
    local answer = assert(client:get('http://localhost/away'))

    t.assert_equals(answer.url, 'http://other.example.net/whoami')
    t.assert_equals(answer:json(), { host = 'other.example.net', authorization = 'нет' })
end

g.test_redirect_within_the_host_keeps_the_login = function()
    local client = client_of({ headers = { Authorization = 'Bearer тайна' } })

    t.assert_equals(assert(client:get('http://localhost/home')):json().authorization, 'Bearer тайна')
end

g.test_stream_goes_through_the_socket_too = function()
    local stream = assert(client_of():stream({ url = 'http://localhost/lines' }))

    t.assert_equals(stream:read(), 'один\n')
    t.assert_equals(stream:read(), 'два\n')
    t.assert_equals({ stream:read() }, {})
    t.assert_equals(stream.status, 200)
    t.assert_equals(stream:close(), true)
end

g.test_missing_socket_is_a_refusal = function()
    local answer, err =
        client_of({ unix_socket = fio.pathjoin(directory, 'нет.sock') }):get('http://localhost/whoami')

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
    -- До libcurl 8.9 — «Couldn't connect», с 8.9 — «Could not connect»:
    -- написание зависит от сборки Tarantool, образец принимает оба.
    t.assert_str_contains(err.reason, "Could ?n[o']t connect to server %(код 595%)", true)
end
