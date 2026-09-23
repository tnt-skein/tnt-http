--- Клиентский сертификат против сервера, который его требует.
---
--- Сертификаты однажды отрезал белый список настроек, и полгода это
--- читалось как «Tarantool не умеет». Двойник видит, что поле дошло
--- до libcurl; только настоящий сервер показывает, что libcurl сертификат
--- предъявил, а сервер его принял — и что без него разговора нет вовсе.
---
--- Сервер — etcd с `--client-cert-auth`: его поднимает
--- `test/stand/etcd_mtls.sh`, он же выпускает корень и оба сертификата
--- в `ETCD_MTLS_DIR`. Без стенда проверки пропускаются.

local t = require('luatest')
local fio = require('fio')
local json = require('json')

local g = t.group('tnt.http.tls_live')

local helper = dofile('test/helper.lua')

---@type any
local http

--- Где стоит etcd и где лежат сертификаты: те же, что у скрипта стенда.
local HOST = '127.0.0.1'
local PORT = 12391
local DIRECTORY = helper.mtls_directory()

--- Путь к файлу из каталога сертификатов.
---@param name string
---@return string
local function certificate(name)
    return fio.pathjoin(DIRECTORY, name)
end

--- Клиент к стенду; проверка пропускается, если стенда нет.
---
--- Клиент на каждую проверку свой: libcurl держит соединения в кэше,
--- и рукопожатие одной проверки иначе досталось бы другой.
---@param opts table|nil
---@param untrusted boolean|nil Не давать корень стенда
---@return any
local function client_of(opts, untrusted)
    t.skip_if(
        not helper.listening(HOST, PORT) or not fio.path.exists(certificate('client.pem')),
        'etcd с mTLS не поднят: test/stand/etcd_mtls.sh'
    )

    local settings = {
        base_url = ('https://%s:%d'):format(HOST, PORT),
        retry = { attempts = 1 },
        timeout = 3,
    }

    if not untrusted then
        settings.ca_file = certificate('ca.pem')
    end

    return (assert(http.new(helper.merged(settings, opts))))
end

--- Сертификат клиента с ключом.
local WITH_CERTIFICATE = { ssl_cert = certificate('client.pem'), ssl_key = certificate('client.key') }

--- Запрос состояния: тело — объект, а не `json = {}`, который закодировался
--- бы массивом, и шлюз etcd ответил бы на него 400.
local STATUS = { body = '{}', headers = { ['content-type'] = 'application/json' } }

g.before_each(function()
    http = helper.load('tnt.http')
end)

g.after_each(function()
    helper.unload()
end)

g.test_server_takes_the_client_certificate = function()
    local answer, err = client_of(WITH_CERTIFICATE):post('/v3/maintenance/status', STATUS)

    t.assert_equals(err, nil)
    t.assert_equals(answer.status, 200)
    t.assert_equals(answer:json().version, '3.5.17')
end

g.test_without_the_certificate_there_is_no_conversation = function()
    local answer, err = client_of():post('/v3/maintenance/status', STATUS)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
end

g.test_missing_certificate_file_is_named_by_libcurl = function()
    -- Есть ли файл, клиент не проверяет при сборке: сертификаты подменяют
    -- на месте. Не нашедшийся файл называет libcurl, и отказ доходит.
    local client = client_of({ ssl_cert = certificate('нет.pem'), ssl_key = certificate('client.key') })
    local answer, err = client:post('/v3/maintenance/status', STATUS)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_str_contains(err.reason, 'Problem with the local SSL certificate')
end

g.test_server_of_an_unknown_root_is_not_trusted = function()
    local answer, err = client_of(WITH_CERTIFICATE, true):post('/v3/maintenance/status', STATUS)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_str_contains(err.reason, '495')
end

g.test_stream_takes_the_client_certificate_too = function()
    -- Так устроено наблюдение etcd поверх потока: подписка дописывается
    -- в открытую отправку, события читаются строками.
    local stream, err = client_of(WITH_CERTIFICATE):stream({
        path = '/v3/watch',
        method = 'POST',
        duplex = true,
        headers = { ['content-type'] = 'application/json' },
        max_body = 0,
    })

    t.assert_equals(err, nil)
    t.assert_equals(stream:write(json.encode({ create_request = { key = 'a2V5' } })), true)

    local line = assert(stream:read('\n', 3))

    t.assert_equals(json.decode(line).result.created, true)
    t.assert_equals(stream:close(), true)
end
