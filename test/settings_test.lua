--- Тесты настроек: умолчания, проверка и слияние с настройками запроса.

local t = require('luatest')

local g = t.group('tnt.http.settings')

local helper = dofile('test/helper.lua')

---@type any
local settings

g.before_each(function()
    settings = helper.load('tnt.http.settings')
end)

g.after_each(function()
    helper.unload()
end)

g.test_client_without_settings_gets_safe_defaults = function()
    -- Числа выписаны здесь, а не взяты из самого пакета: умолчание,
    -- сверенное с собой же, сходится при любом значении — и молча
    -- переезжает вместе с опечаткой.
    local checked = settings.client(nil)

    t.assert_equals(checked.timeout, 10)
    t.assert_equals(checked.connect_timeout, 3)
    t.assert_equals(checked.max_redirects, 5)
    t.assert_equals(checked.max_body, 8388608)
    t.assert_equals(checked.max_connections, 8)
    t.assert_equals(checked.user_agent, 'tnt-http')
    t.assert_equals(checked.accept_encoding, 'gzip, deflate')
    t.assert_equals(checked.layers, {})
end

g.test_cache_of_connections_holds_at_least_one = function()
    -- Кэш на ноль соединений — это не «без кэша», а libcurl без места
    -- под соединение, которое он только что открыл.
    t.assert_str_contains(select(2, settings.client({ max_connections = 0 })), 'число соединений')
    t.assert_equals(settings.client({ max_connections = 1 }).max_connections, 1)
end

g.test_certificate_is_checked_unless_told_otherwise = function()
    -- Шифрование без проверки защищает от подслушивания, но не от подмены.
    t.assert_equals(settings.client(nil).verify, true)
    t.assert_equals(settings.client({ verify = false }).verify, false)
end

g.test_unknown_setting_is_refused_by_name = function()
    -- `timout = 1` не опечатка в комментарии: срок остался бы прежним,
    -- и не сказал бы об этом никто.
    local checked, err = settings.client({ timout = 1 })

    t.assert_equals(checked, nil)
    t.assert_str_contains(err, 'timout')
end

g.test_setting_of_the_wrong_kind_is_refused = function()
    t.assert_str_contains(select(2, settings.client({ timeout = 'быстро' })), 'срок ответа')
    t.assert_str_contains(select(2, settings.client({ max_redirects = -1 })), 'предел переходов')
    t.assert_str_contains(select(2, settings.client({ max_body = -1 })), 'предел размера ответа')
end

g.test_timeout_of_zero_is_refused = function()
    -- Ноль у libcurl значит «без срока», то есть ровно обратное тому,
    -- что имел в виду написавший `timeout = 0`.
    t.assert_str_contains(select(2, settings.client({ timeout = 0 })), 'не меньше 0.001')
end

g.test_layer_that_is_not_a_function_is_refused = function()
    local checked, err = settings.client({ layers = { 1 } })

    t.assert_equals(checked, nil)
    t.assert_str_contains(err, 'должна быть функцией')
end

g.test_layer_that_is_a_function_is_taken = function()
    local layer = function(request, nxt)
        return nxt(request)
    end

    t.assert_equals(helper.at(settings.client({ layers = { layer } }).layers, 1), layer)
end

g.test_header_value_may_be_a_number = function()
    -- Отказ на `x-count = 7` был бы придиркой, а не защитой.
    t.assert_equals(settings.client({ headers = { ['x-count'] = 7 } }).headers['x-count'], '7')
end

g.test_request_takes_no_defaults = function()
    -- Иначе запрос без срока перебивал бы срок клиента умолчанием,
    -- и настройка клиента не значила бы ничего.
    local checked = settings.request({})

    t.assert_equals(checked.timeout, nil)
    t.assert_equals(checked.verify, nil)
end

g.test_request_knows_its_own_fields = function()
    local checked, err = settings.request({
        method = 'POST',
        url = 'https://h/x',
        path = '/x',
        query = { a = 1 },
        json = { b = 2 },
        retry = { attempts = 2 },
    })

    t.assert_equals(err, nil)
    t.assert_equals(checked.method, 'POST')
    t.assert_equals(checked.query, { a = 1 })
    t.assert_equals(checked.json, { b = 2 })
end

g.test_unknown_request_field_is_refused = function()
    t.assert_str_contains(select(2, settings.request({ jsno = {} })), 'jsno')
end

g.test_headers_are_lowered_and_the_request_wins = function()
    -- Иначе Content-Type клиента и content-type запроса уехали бы вдвоём,
    -- и какой применится, решал бы порядок в `pairs`.
    local headers = settings.headers(
        { ['Content-Type'] = 'application/json', accept = '*/*' },
        { ['CONTENT-TYPE'] = 'text/plain' }
    )

    t.assert_equals(headers, { ['content-type'] = 'text/plain', accept = '*/*' })
end

g.test_headers_of_nothing_are_an_empty_table = function()
    t.assert_equals(settings.headers(nil, nil), {})
end

g.test_request_settings_override_the_client_ones = function()
    local client = settings.client({ timeout = 10, max_body = 100 })
    local request = settings.request({ timeout = 1 })
    local resolved = settings.resolve(client, request)

    t.assert_equals(resolved.timeout, 1)
    t.assert_equals(resolved.max_body, 100)
end

g.test_false_from_the_request_overrides_true_of_the_client = function()
    -- `given or fallback` здесь неверно: `verify = false` — заданное
    -- значение, а не отсутствие.
    local resolved = settings.resolve(settings.client(nil), settings.request({ verify = false }))

    t.assert_equals(resolved.verify, false)
end

g.test_resolved_headers_are_the_client_ones_plus_the_request_ones = function()
    local client = settings.client({ headers = { accept = '*/*' } })
    local request = settings.request({ headers = { ['X-Trace'] = 'abc' } })
    local resolved = settings.resolve(client, request)

    t.assert_equals(resolved.headers, { accept = '*/*', ['x-trace'] = 'abc' })
end

g.test_client_certificate_and_socket_are_taken = function()
    -- Их отрезал когда-то белый список, а не Tarantool: `http.client`
    -- принимает все три.
    local checked = settings.client({ ssl_cert = '/c.pem', ssl_key = '/c.key', unix_socket = '/run/s.sock' })

    t.assert_equals(checked.ssl_cert, '/c.pem')
    t.assert_equals(checked.ssl_key, '/c.key')
    t.assert_equals(checked.unix_socket, '/run/s.sock')
    t.assert_equals(settings.SHARED, {
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
    })
end

g.test_empty_path_is_a_typo_and_not_an_absence = function()
    t.assert_str_contains(select(2, settings.client({ ssl_cert = '' })), 'клиентский сертификат')
    -- Сертификат рядом нарочно: без него ключ отвергла бы проверка пары,
    -- и пустой путь прошёл бы незамеченным её же словами.
    t.assert_str_contains(
        select(2, settings.client({ ssl_cert = 'c', ssl_key = '' })),
        'ключ клиентского сертификата должен быть строкой длиной не меньше 1'
    )
    t.assert_str_contains(select(2, settings.client({ unix_socket = '' })), 'сокет')
    t.assert_equals(settings.client({ unix_socket = 's' }).unix_socket, 's')
    t.assert_equals(settings.client({ ssl_cert = 'c', ssl_key = 'k' }).ssl_key, 'k')
end

g.test_key_without_a_certificate_does_nothing_and_is_refused = function()
    -- Один ключ libcurl молча пропускает. Обратное законно: ключ бывает
    -- в том же файле, что и сертификат.
    local client, err = settings.client({ ssl_key = '/c.key' })

    t.assert_equals(client, nil)
    t.assert_equals(
        err,
        'ключ клиентского сертификата без сертификата не действует: задайте ssl_cert'
    )
    t.assert_equals(settings.client({ ssl_cert = '/c.pem' }).ssl_cert, '/c.pem')
    t.assert_equals(settings.unpaired({ ssl_cert = '/c.pem', ssl_key = '/c.key' }), nil)
    t.assert_equals(settings.unpaired({ ssl_cert = '/c.pem' }), nil)
    t.assert_equals(settings.unpaired({}), nil)
    t.assert_str_contains(select(2, settings.client({ timout = 1, ssl_key = '/c.key' })), 'timout')
end

g.test_request_may_take_its_own_certificate_and_socket = function()
    local client = settings.client({ ssl_cert = '/client.pem', unix_socket = '/a.sock' })
    local request = settings.request({ ssl_key = '/request.key', unix_socket = '/b.sock' })
    local resolved = settings.resolve(client, request)

    t.assert_equals(resolved.ssl_cert, '/client.pem')
    t.assert_equals(resolved.ssl_key, '/request.key')
    t.assert_equals(resolved.unix_socket, '/b.sock')
end

g.test_stream_keeps_the_sending_closed_unless_asked = function()
    t.assert_equals(settings.stream({}).duplex, false)
    t.assert_equals(settings.stream({ duplex = true }).duplex, true)
    t.assert_str_contains(select(2, settings.stream({ duplex = 'да' })), 'двусторонний поток')
end

g.test_stream_refuses_repeats_and_redirects_by_name = function()
    t.assert_str_contains(select(2, settings.stream({ retry = {} })), 'retry')
    t.assert_str_contains(select(2, settings.stream({ max_redirects = 1 })), 'max_redirects')
    t.assert_equals(settings.stream({ method = 'POST', json = {}, max_body = 0 }).max_body, 0)
    -- У запроса своего `duplex` нет: там отправка не бывает открытой.
    t.assert_str_contains(select(2, settings.request({ duplex = true })), 'duplex')
end

g.test_piece_limit_belongs_to_the_stream_only = function()
    t.assert_equals(settings.stream({}).max_piece, 0)
    t.assert_equals(settings.stream({ max_piece = 0 }).max_piece, 0)
    t.assert_equals(settings.stream({ max_piece = 4096 }).max_piece, 4096)
    t.assert_str_contains(select(2, settings.stream({ max_piece = -1 })), 'предел куска')
    t.assert_str_contains(select(2, settings.stream({ max_piece = 1.5 })), 'предел куска')
    -- У запроса кусок один — тело целиком, и его держит `max_body`.
    t.assert_str_contains(select(2, settings.request({ max_piece = 1 })), 'max_piece')
    t.assert_str_contains(select(2, settings.client({ max_piece = 1 })), 'max_piece')
end

g.test_propagation_is_on_unless_the_client_turns_it_off = function()
    -- Опознаватель и трасса обязаны доехать до чужой службы без единой
    -- строки в прикладном коде; выключает перенос тот, кто шлёт саму
    -- телеметрию, — и делает это при сборке клиента, а не на каждом вызове.
    t.assert_equals(settings.client(nil).propagate, true)
    t.assert_equals(settings.client({ propagate = false }).propagate, false)
    t.assert_str_contains(select(2, settings.client({ propagate = 'нет' })), 'перенос контекста')
    t.assert_str_contains(select(2, settings.request({ propagate = false })), 'propagate')
    t.assert_str_contains(select(2, settings.stream({ propagate = false })), 'propagate')
end

g.test_curl_options_carry_the_headers_and_the_summed_deadline = function()
    local resolved = settings.resolve(settings.client({ timeout = 4, connect_timeout = 1, verify = false }), {})
    local headers = { ['x-a'] = '1' }
    local options = settings.curl_options(resolved, headers, nil)

    t.assert_equals(options.headers, headers)
    t.assert_equals(options.timeout, 5)
    t.assert_equals(options.follow_location, false)
    t.assert_equals(options.verify_peer, false)
    t.assert_equals(options.verify_host, false)
    t.assert_equals(options.accept_encoding, 'gzip, deflate')
end

g.test_remaining_budget_cuts_the_deadline_but_not_below_the_least = function()
    -- Незачем начинать попытку длиннее, чем вызывающий согласен ждать
    -- целиком; но ноль у libcurl значит «без срока», и остаток режется
    -- не ниже миллисекунды.
    local resolved = settings.resolve(settings.client({ timeout = 4, connect_timeout = 1 }), {})

    t.assert_equals(settings.curl_options(resolved, {}, 2).timeout, 2)
    t.assert_equals(settings.curl_options(resolved, {}, 5).timeout, 5)
    t.assert_equals(settings.curl_options(resolved, {}, 9).timeout, 5)
    t.assert_equals(settings.curl_options(resolved, {}, 0).timeout, 0.001)
    t.assert_equals(settings.curl_options(resolved, {}, -1).timeout, 0.001)
end
