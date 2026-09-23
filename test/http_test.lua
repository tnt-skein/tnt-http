--- Тесты фасада: запрос целиком, переходы, повторы и слои.

local t = require('luatest')

local g = t.group('tnt.http')

local helper = dofile('test/helper.lua')

--- Фасад пакета: часть проверок смотрит на общий клиент, а не на свой.
---@type any
local http

g.before_each(function()
    http = helper.load('tnt.http')
end)

g.after_each(function()
    helper.forget()
end)

g.test_answer_of_the_server_comes_back_whole = function()
    local client, sent = helper.client_of({ helper.json_answer('{"page":2}') })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(err, nil)
    t.assert_equals(answer.status, 200)
    t.assert_equals(answer:json(), { page = 2 })
    t.assert_equals(helper.at(sent, 1).method, 'GET')
    t.assert_equals(helper.at(sent, 1).url, helper.SOMEWHERE)
end

g.test_broken_network_is_a_refusal_and_not_an_answer = function()
    local client = helper.client_of({ helper.no_answer(), helper.no_answer(), helper.no_answer() })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_str_contains(tostring(err), 'сервер не ответил')
end

g.test_server_trouble_is_an_answer_and_not_a_refusal = function()
    -- Код 500 значит, что у чужой службы беда; что с этим делать, знает
    -- прикладной код, а не клиент.
    local client = helper.client_of({ helper.answer(500), helper.answer(500), helper.answer(500) })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(err, nil)
    t.assert_equals(answer.status, 500)
end

g.test_base_address_is_a_prefix_for_every_call = function()
    local client, sent = helper.client_of({ helper.answer(200) }, { base_url = 'https://api.example.org/v1' })

    client:get('/customers/7')

    t.assert_equals(helper.at(sent, 1).url, 'https://api.example.org/v1/customers/7')
end

g.test_path_names_the_same_thing_as_url = function()
    local client, sent = helper.client_of({ helper.answer(200) }, { base_url = 'https://h' })

    client:request({ path = '/x' })

    t.assert_equals(helper.at(sent, 1).url, 'https://h/x')
end

g.test_address_without_scheme_and_without_base_is_refused = function()
    local client = helper.client_of({})
    local answer, err = client:get('/customers')

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_str_contains(tostring(err), 'неполон')
end

g.test_query_is_encoded_with_cyrillic_and_lists = function()
    local client, sent = helper.client_of({ helper.answer(200) })

    client:get(helper.SOMEWHERE, { query = { tag = { 'новый', 'важный' }, page = 2 } })

    t.assert_equals(
        helper.at(sent, 1).url,
        helper.SOMEWHERE .. '?page=2&tag=%D0%BD%D0%BE%D0%B2%D1%8B%D0%B9&tag=%D0%B2%D0%B0%D0%B6%D0%BD%D1%8B%D0%B9'
    )
end

g.test_unusable_query_stops_the_request = function()
    local client, sent = helper.client_of({})
    local answer, err = client:get(helper.SOMEWHERE, { query = { page = print } })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_str_contains(tostring(err), 'параметр page')
    t.assert_equals(#sent, 0)
end

g.test_unusable_body_stops_the_request = function()
    local client, sent = helper.client_of({})
    local answer, err = client:post(helper.SOMEWHERE, { body = { name = 'Иванов' } })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_str_contains(tostring(err), 'готовая строка')
    t.assert_equals(#sent, 0)
end

g.test_json_body_is_sent_with_its_header = function()
    local client, sent = helper.client_of({ helper.answer(201) })

    client:post(helper.SOMEWHERE, { json = { name = 'Иванов' } })

    t.assert_equals(helper.at(sent, 1).body, '{"name":"Иванов"}')
    t.assert_equals(helper.at(sent, 1).options.headers['content-type'], 'application/json')
end

g.test_own_content_type_is_not_overwritten = function()
    -- Вызывающий, написавший `application/vnd.api+json`, имел это в виду.
    local client, sent = helper.client_of({ helper.answer(201) })

    client:post(helper.SOMEWHERE, {
        json = { name = 'Иванов' },
        headers = { ['Content-Type'] = 'application/vnd.api+json' },
    })

    t.assert_equals(helper.at(sent, 1).options.headers['content-type'], 'application/vnd.api+json')
end

g.test_client_introduces_itself = function()
    -- Чужие службы отвечают 403 на пустое имя, а в журнале доступа имя
    -- клиента — единственный способ узнать, чей это был запрос.
    local client, sent = helper.client_of({ helper.answer(200) })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.headers['user-agent'], 'tnt-http')
end

g.test_own_name_replaces_the_default_one = function()
    local client, sent = helper.client_of({ helper.answer(200) }, { user_agent = 'панель/1.0' })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.headers['user-agent'], 'панель/1.0')
end

g.test_own_name_in_the_headers_is_not_overwritten = function()
    -- Имя, заданное заголовком, — такое же заданное, как настройкой.
    local client, sent = helper.client_of({ helper.answer(200) }, { headers = { ['User-Agent'] = 'панель/1.0' } })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.headers['user-agent'], 'панель/1.0')
end

g.test_every_method_has_its_short_call = function()
    local client, sent = helper.client_of({
        helper.answer(200),
        helper.answer(201),
        helper.answer(200),
        helper.answer(200),
        helper.answer(204),
        helper.answer(200),
    })

    client:get(helper.SOMEWHERE)
    client:post(helper.SOMEWHERE, { body = 'x' })
    client:put(helper.SOMEWHERE, { body = 'x' })
    client:patch(helper.SOMEWHERE, { body = 'x' })
    client:delete(helper.SOMEWHERE)
    client:head(helper.SOMEWHERE)

    local methods = {}

    for _, request in ipairs(sent) do
        table.insert(methods, request.method)
    end

    t.assert_equals(methods, { 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD' })
end

g.test_method_is_written_in_capitals = function()
    local client, sent = helper.client_of({ helper.answer(200) })

    client:request({ url = helper.SOMEWHERE, method = 'get' })

    t.assert_equals(helper.at(sent, 1).method, 'GET')
end

g.test_settings_of_the_caller_stay_untouched = function()
    -- Таблицу настроек вызывающий вправе держать у себя и слать по ней
    -- несколько запросов.
    local client, _ = helper.client_of({ helper.answer(200) })
    local opts = { query = { a = 1 } }

    client:get(helper.SOMEWHERE, opts)

    t.assert_equals(opts.method, nil)
    t.assert_equals(opts.url, nil)
end

g.test_named_address_wins_over_the_one_in_settings = function()
    local client, sent = helper.client_of({ helper.answer(200) })

    client:get(helper.SOMEWHERE, { url = 'http://other/x' })

    t.assert_equals(helper.at(sent, 1).url, helper.SOMEWHERE)
end

g.test_request_goes_in_the_agreed_shape = function()
    -- Этот же вид читают слои, и разойтись с ними нельзя.
    ---@type any
    local seen

    local client = helper.client_of({ helper.answer(200) }, {
        layers = {
            function(request, nxt)
                seen = request

                return nxt(request)
            end,
        },
    })

    client:post('http://h/customers?a=1', { query = { page = 2 }, json = { name = 'И' } })

    t.assert_equals(seen.method, 'POST')
    t.assert_equals(seen.url, 'http://h/customers?a=1&page=2')
    t.assert_equals(seen.path, '/customers')
    t.assert_equals(seen.query, { page = 2 })
    t.assert_equals(seen.body, '{"name":"И"}')
    t.assert_equals(seen.headers['content-type'], 'application/json')
end

g.test_layers_wrap_the_sending_in_order = function()
    local order = {}

    local function layer(name)
        return function(request, nxt)
            table.insert(order, name .. ' туда')

            local answer, err = nxt(request)

            table.insert(order, name .. ' обратно')

            return answer, err
        end
    end

    local client = helper.client_of(
        { helper.answer(200) },
        { layers = { layer('первый'), layer('второй') } }
    )

    client:get(helper.SOMEWHERE)

    t.assert_equals(order, {
        'первый туда',
        'второй туда',
        'второй обратно',
        'первый обратно',
    })
end

g.test_layer_may_answer_instead_of_the_server = function()
    -- Так встанет и кэш, и двойник в проверке прикладного кода.
    local client, sent = helper.client_of({}, {
        layers = {
            function()
                return { status = 200, reason = 'Ok', headers = {}, body = 'из кэша' }
            end,
        },
    })

    local answer = client:get(helper.SOMEWHERE)

    t.assert_equals(answer.body, 'из кэша')
    t.assert_equals(#sent, 0)
end

g.test_layer_may_add_a_header = function()
    local client, sent = helper.client_of({ helper.answer(200) }, {
        layers = {
            function(request, nxt)
                request.headers['x-trace'] = 'abc'

                return nxt(request)
            end,
        },
    })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.headers['x-trace'], 'abc')
end

g.test_redirect_is_followed = function()
    local client, sent = helper.client_of({
        helper.moved(302, '/new'),
        helper.answer(200, { body = 'да' }),
    })

    local answer = client:get(helper.SOMEWHERE)

    t.assert_equals(answer.body, 'да')
    t.assert_equals(helper.at(sent, 2).url, 'http://api.example.org/new')
    t.assert_equals(answer.url, 'http://api.example.org/new')
end

g.test_redirect_without_an_address_is_just_an_answer = function()
    -- Сервер ответил 302 и забыл сказать куда: идти некуда, и ответ
    -- отдаётся как есть.
    local client, sent = helper.client_of({ helper.answer(302) })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 302)
    t.assert_equals(#sent, 1)
end

g.test_address_in_a_created_answer_is_not_a_redirect = function()
    -- `Location` в ответе 201 указывает на созданный ресурс: идти по нему
    -- никто не просил.
    local client, sent = helper.client_of({
        helper.answer(201, { headers = { Location = '/customers/7' } }),
    })

    t.assert_equals(client:post(helper.SOMEWHERE, { body = 'x' }).status, 201)
    t.assert_equals(#sent, 1)
end

g.test_zero_redirects_means_the_three_hundred_is_the_answer = function()
    local client, sent = helper.client_of({ helper.moved(302, '/new') }, { max_redirects = 0 })
    local answer = client:get(helper.SOMEWHERE)

    t.assert_equals(answer.status, 302)
    t.assert_equals(#sent, 1)
end

g.test_too_many_redirects_are_refused = function()
    local client = helper.client_of({
        helper.moved(302, '/a'),
        helper.moved(302, '/b'),
    }, { max_redirects = 1 })

    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(
        err.message,
        'GET http://api.example.org/customers: переходов больше 1, дальше не идём'
    )
end

g.test_redirect_to_a_bad_link_is_refused = function()
    local client = helper.client_of({ helper.moved(302, '') })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(err.reason, 'переход по негодной ссылке «»')
end

g.test_redirect_off_the_web_is_refused_before_it_is_followed = function()
    -- libcurl свои переходы по таким схемам не делает, но переходы проходит
    -- клиент: без сверки ответ сервера прочёл бы файл узла, а `gopher://`
    -- отправил бы свои байты на внутренний порт.
    for _, location in ipairs({
        'file:///etc/hosts',
        'gopher://127.0.0.1:3301/_box.schema.user.grant',
        'DICT://127.0.0.1:11211/info',
    }) do
        local client, sent = helper.client_of({ helper.moved(302, location) })
        local answer, err = client:get(helper.SOMEWHERE)

        t.assert_equals(answer, nil)
        t.assert_equals(err.kind, 'refused')
        t.assert_equals(#sent, 1)
    end

    local client = helper.client_of({ helper.moved(302, 'file:///etc/hosts') }, { unix_socket = '/run/s.sock' })

    t.assert_equals(
        select(2, client:get(helper.SOMEWHERE)).reason,
        'переход на схему «file» не разрешён'
    )
end

g.test_redirect_to_the_web_in_capitals_is_followed = function()
    local client, sent = helper.client_of({ helper.moved(302, 'HTTPS://h/x'), helper.answer(200) })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    t.assert_equals(helper.at(sent, 2).url, 'HTTPS://h/x')
end

g.test_address_off_the_web_is_refused_before_sending = function()
    local client, sent = helper.client_of({})

    for _, address in ipairs({ 'file:///etc/passwd', 'gopher://h/_x' }) do
        local answer, err = client:get(address)

        t.assert_equals(answer, nil)
        t.assert_equals(err.kind, 'invalid')
    end

    t.assert_equals(
        tostring(select(2, client:stream({ url = 'ftp://h/x' }))),
        'схема «ftp» не годится: клиент ходит только по http и https'
    )
    t.assert_equals(#sent, 0)
end

g.test_key_without_a_certificate_is_refused = function()
    -- libcurl берёт ключ только вместе с сертификатом, а один ключ молча
    -- пропускает: запрос ушёл бы безымянным.
    local client, err = http.new({ ssl_key = '/client.key' })

    t.assert_equals(client, nil)
    t.assert_equals(
        err,
        'ключ клиентского сертификата без сертификата не действует: задайте ssl_cert'
    )

    local bare, sent = helper.client_of({ helper.answer(200) })
    local answer, refused = bare:get(helper.SOMEWHERE, { ssl_key = '/client.key' })

    t.assert_equals(answer, nil)
    t.assert_equals(refused.kind, 'invalid')
    t.assert_equals(#sent, 0)

    local certified = helper.client_of({ helper.answer(200) }, { ssl_cert = '/client.pem' })

    t.assert_equals(certified:get(helper.SOMEWHERE, { ssl_key = '/client.key' }).status, 200)
end

g.test_login_header_stays_behind_on_a_foreign_host = function()
    -- Заголовок входа, уехавший по чужой ссылке, — это отданный пароль.
    local client, sent = helper.client_of(
        { helper.moved(302, 'https://evil.example.net/x'), helper.answer(200) },
        { headers = { Authorization = 'Bearer тайна' } }
    )

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.headers.authorization, 'Bearer тайна')
    t.assert_equals(helper.at(sent, 2).options.headers.authorization, nil)
end

g.test_login_header_travels_within_one_host = function()
    local client, sent = helper.client_of(
        { helper.moved(302, '/new'), helper.answer(200) },
        { headers = { Authorization = 'Bearer тайна' } }
    )

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 2).options.headers.authorization, 'Bearer тайна')
end

g.test_post_becomes_a_fetch_after_a_found = function()
    local client, sent = helper.client_of({ helper.moved(302, '/new'), helper.answer(200) })

    client:post(helper.SOMEWHERE, { json = { name = 'Иванов' } })

    t.assert_equals(helper.at(sent, 2).method, 'GET')
    t.assert_equals(helper.at(sent, 2).body, nil)
    t.assert_equals(helper.at(sent, 2).options.headers['content-type'], nil)
end

g.test_post_survives_a_temporary_redirect = function()
    local client, sent = helper.client_of({ helper.moved(307, '/new'), helper.answer(200) })

    client:post(helper.SOMEWHERE, { json = { name = 'Иванов' } })

    t.assert_equals(helper.at(sent, 2).method, 'POST')
    t.assert_equals(helper.at(sent, 2).body, '{"name":"Иванов"}')
end

g.test_answer_bigger_than_the_limit_is_refused = function()
    -- Чужой сервер вправе прислать гигабайт в ответ на однострочный
    -- запрос, и узел не должен падать из-за этого.
    local client = helper.client_of({ helper.answer(200, { body = ('x'):rep(100) }) }, { max_body = 10 })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(err.retriable, false)
    t.assert_str_contains(tostring(err), 'ответ в 100 байт больше предела в 10')
end

g.test_zero_limit_takes_any_answer = function()
    local client = helper.client_of({ helper.answer(200, { body = ('x'):rep(100) }) }, { max_body = 0 })

    t.assert_equals(client:get(helper.SOMEWHERE).body, ('x'):rep(100))
end

g.test_deadline_of_an_attempt_is_the_two_terms_added_up = function()
    -- Раздельных сроков `http.client` не принимает: доля соединения
    -- остаётся счётной величиной, а сроком идёт сумма.
    local client, sent = helper.client_of({ helper.answer(200) }, { timeout = 4, connect_timeout = 1 })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.timeout, 5)
end

g.test_request_may_shorten_the_deadline_of_the_client = function()
    local client, sent = helper.client_of({ helper.answer(200) }, { timeout = 30, connect_timeout = 1 })

    client:get(helper.SOMEWHERE, { timeout = 1 })

    t.assert_equals(helper.at(sent, 1).options.timeout, 2)
end

g.test_certificate_check_reaches_curl = function()
    local client, sent = helper.client_of({ helper.answer(200) }, { verify = false, ca_file = '/ca.pem' })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.verify_peer, false)
    t.assert_equals(helper.at(sent, 1).options.verify_host, false)
    t.assert_equals(helper.at(sent, 1).options.ca_file, '/ca.pem')
end

g.test_client_certificate_and_socket_reach_curl = function()
    -- Отрезал их когда-то белый список, а не Tarantool.
    local client, sent = helper.client_of({ helper.answer(200) }, { ssl_cert = '/client.pem', ssl_key = '/client.key' })

    client:get(helper.SOMEWHERE, { unix_socket = '/run/docker.sock' })

    t.assert_equals(helper.at(sent, 1).options.ssl_cert, '/client.pem')
    t.assert_equals(helper.at(sent, 1).options.ssl_key, '/client.key')
    t.assert_equals(helper.at(sent, 1).options.unix_socket, '/run/docker.sock')
end

g.test_redirect_through_a_socket_stays_in_the_socket_without_the_login = function()
    -- Сокет — дорога, а не узел: переход меняет адрес, но не дорогу, а узлы
    -- сличаются по адресу, и заголовок входа на чужой узел не едет.
    local client, sent = helper.client_of(
        { helper.moved(302, 'http://other.example.net/x'), helper.answer(200) },
        { unix_socket = '/run/sidecar.sock', headers = { Authorization = 'Bearer тайна' } }
    )

    client:get('http://localhost/start')

    t.assert_equals(helper.at(sent, 2).url, 'http://other.example.net/x')
    t.assert_equals(helper.at(sent, 2).options.unix_socket, '/run/sidecar.sock')
    t.assert_equals(helper.at(sent, 2).options.headers.authorization, nil)
end

g.test_bad_repeats_of_one_request_are_refused_before_sending = function()
    local client, sent = helper.client_of({})
    local answer, err = client:get(helper.SOMEWHERE, { retry = { attemps = 2 } })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_str_contains(tostring(err), 'настройки повторов: ')
    t.assert_str_contains(tostring(err), 'attemps')
    t.assert_equals(#sent, 0)
end

g.test_failure_kinds_are_reachable_from_the_facade = function()
    t.assert_equals(http.failure.UNREACHABLE, 'unreachable')
end

g.test_redirects_are_not_left_to_curl = function()
    -- Иначе их не сосчитать и не снять с чужого узла заголовок входа.
    local client, sent = helper.client_of({ helper.answer(200) })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.follow_location, false)
end

g.test_bad_settings_are_refused_at_once = function()
    local client, err = http.new({ timout = 1 })

    t.assert_equals(client, nil)
    t.assert_str_contains(err, 'timout')
end

g.test_bad_retry_settings_are_refused_at_once = function()
    local client, err = http.new({ retry = { attemps = 3 } })

    t.assert_equals(client, nil)
    t.assert_str_contains(err, 'настройки повторов')
end

g.test_status_shows_the_settings_without_the_secrets = function()
    -- Состояние читают и журнал, и панель, и человек через плечо.
    local client = helper.client_of({}, {
        base_url = 'https://h',
        headers = { Authorization = 'Bearer тайна', Accept = '*/*' },
    })

    local status = client:status()

    t.assert_equals(status.base_url, 'https://h')
    t.assert_equals(status.headers, { 'Accept', 'Authorization' })
    t.assert_equals(status.timeout, 10)
    t.assert_equals(status.layers, 0)
    t.assert_equals(status.retry.attempts, 3)
    t.assert_equals(status.ssl_key, false)
    t.assert_not_str_contains(require('json').encode(status), 'тайна')
end

g.test_status_shows_the_certificate_and_only_that_a_key_is_there = function()
    local client = helper.client_of({}, {
        ssl_cert = '/etc/tnt/client.pem',
        ssl_key = '/etc/tnt/secret/client.key',
        unix_socket = '/run/sidecar.sock',
    })

    local status = client:status()

    t.assert_equals(status.ssl_cert, '/etc/tnt/client.pem')
    t.assert_equals(status.ssl_key, true)
    t.assert_equals(status.unix_socket, '/run/sidecar.sock')
    t.assert_not_str_contains(require('json').encode(status), 'client.key')
end

g.test_shared_client_is_made_on_first_use_and_kept = function()
    helper.serving({ helper.answer(200), helper.answer(200) })

    t.assert_equals(http.default(), http.default())
    t.assert_equals(http.get(helper.SOMEWHERE).status, 200)
    t.assert_equals(http.status().timeout, 10)
end

g.test_configure_replaces_the_shared_client = function()
    local sent = helper.serving({ helper.answer(200) })

    t.assert_equals(http.configure({ base_url = 'https://h/v1' }), true)
    http.get('/x')

    t.assert_equals(helper.at(sent, 1).url, 'https://h/v1/x')
end

g.test_configure_refuses_bad_settings_and_keeps_the_old_ones = function()
    local ok, err = http.configure({ timout = 1 })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'timout')
end

g.test_shared_client_has_every_short_call = function()
    local sent = helper.serving({
        helper.answer(200),
        helper.answer(201),
        helper.answer(200),
        helper.answer(200),
        helper.answer(204),
        helper.answer(200),
        helper.answer(200),
    })

    http.get(helper.SOMEWHERE)
    http.post(helper.SOMEWHERE, { body = 'x' })
    http.put(helper.SOMEWHERE, { body = 'x' })
    http.patch(helper.SOMEWHERE, { body = 'x' })
    http.delete(helper.SOMEWHERE)
    http.head(helper.SOMEWHERE)
    http.request({ url = helper.SOMEWHERE, method = 'OPTIONS' })

    local methods = {}

    for _, request in ipairs(sent) do
        table.insert(methods, request.method)
    end

    t.assert_equals(methods, { 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS' })
end

g.test_unknown_request_setting_is_refused_before_the_request = function()
    -- Ошибка в настройках обязана обнаружиться сразу, а не посреди работы.
    local client, sent = helper.client_of({})
    local answer, err = client:get(helper.SOMEWHERE, { jsno = { name = 'Иванов' } })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_str_contains(tostring(err), 'jsno')
    t.assert_equals(#sent, 0)
end

g.test_layer_may_refuse_by_itself = function()
    -- Слой вправе отказать сам — и сказать об этом просто строкой.
    local journal = helper.capture_log()
    local client, sent = helper.client_of({}, {
        layers = {
            function()
                return nil, 'кэш ответил отказом'
            end,
        },
    })

    local answer, err = client:post(helper.SOMEWHERE, { body = 'x' })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(tostring(err), 'кэш ответил отказом')
    t.assert_equals(#sent, 0)
    t.assert_equals(journal.logged('кэш ответил отказом'), true)
end
