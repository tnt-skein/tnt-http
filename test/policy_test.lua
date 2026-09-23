--- Тесты правил протокола: что повторять и куда переходить.

local t = require('luatest')

local g = t.group('tnt.http.policy')

local helper = dofile('test/helper.lua')

---@type any
local policy

g.before_each(function()
    policy = helper.load('tnt.http.policy')
end)

g.after_each(function()
    helper.unload()
end)

g.test_rfc_names_which_methods_may_be_repeated = function()
    -- RFC 9110, §9.2.2: DELETE, GET, HEAD, OPTIONS, PUT и TRACE.
    for _, method in ipairs({ 'GET', 'HEAD', 'OPTIONS', 'TRACE', 'PUT', 'DELETE' }) do
        t.assert_equals(policy.idempotent(method), true, method)
    end
end

g.test_post_and_patch_are_never_repeated_by_the_client = function()
    -- Оборвавшийся POST мог дойти до сервера, и повтор создаст второй
    -- заказ. Тому, кому нужен повтор POST, нужен ключ идемпотентности.
    t.assert_equals(policy.idempotent('POST'), false)
    t.assert_equals(policy.idempotent('PATCH'), false)
end

g.test_broken_connection_is_repeated_only_for_idempotent_methods = function()
    t.assert_equals(policy.retriable_failure('GET'), true)
    t.assert_equals(policy.retriable_failure('POST'), false)
end

g.test_server_troubles_are_repeated_and_client_mistakes_are_not = function()
    t.assert_equals(policy.retriable_status('GET', 503), true)
    t.assert_equals(policy.retriable_status('GET', 429), true)
    t.assert_equals(policy.retriable_status('GET', 404), false)
    t.assert_equals(policy.retriable_status('GET', 200), false)
end

g.test_not_implemented_is_not_repeated_though_it_is_five_hundred = function()
    -- 501 и 505 чинит не время, а другой запрос или другой сервер.
    t.assert_equals(policy.retriable_status('GET', 501), false)
    t.assert_equals(policy.retriable_status('GET', 505), false)
end

g.test_method_decides_before_the_code = function()
    t.assert_equals(policy.retriable_status('POST', 503), false)
end

g.test_redirect_codes_are_told_from_the_rest = function()
    for _, status in ipairs({ 301, 302, 303, 307, 308 }) do
        t.assert_equals(policy.redirects(status), true, tostring(status))
    end

    t.assert_equals(policy.redirects(305), false)
    t.assert_equals(policy.redirects(200), false)
end

g.test_see_other_always_turns_into_a_plain_fetch = function()
    -- RFC 9110, §15.4.4: ответ забирается отдельным запросом.
    local method, keeps_body = policy.after_redirect('POST', 303)

    t.assert_equals(method, 'GET')
    t.assert_equals(keeps_body, false)
    t.assert_equals(policy.after_redirect('PUT', 303), 'GET')
end

g.test_moved_and_found_turn_post_into_a_fetch = function()
    -- Так переходят и браузеры, и curl, и сервер, отвечающий так
    -- на отправку формы, рассчитывает именно на это.
    local method, keeps_body = policy.after_redirect('POST', 302)

    t.assert_equals(method, 'GET')
    t.assert_equals(keeps_body, false)
    t.assert_equals(policy.after_redirect('POST', 301), 'GET')
end

g.test_moved_and_found_keep_every_other_method = function()
    local method, keeps_body = policy.after_redirect('PUT', 301)

    t.assert_equals(method, 'PUT')
    t.assert_equals(keeps_body, true)
end

g.test_temporary_and_permanent_keep_method_and_body = function()
    -- 307 и 308 заведены ровно затем, чтобы метод и тело сохранились.
    local method, keeps_body = policy.after_redirect('POST', 307)

    t.assert_equals(method, 'POST')
    t.assert_equals(keeps_body, true)
    t.assert_equals(policy.after_redirect('POST', 308), 'POST')
end

g.test_head_stays_head_even_on_see_other = function()
    -- Спрашивали заголовки, а не тело.
    local method, keeps_body = policy.after_redirect('HEAD', 303)

    t.assert_equals(method, 'HEAD')
    t.assert_equals(keeps_body, true)
end

g.test_headers_travel_within_one_origin = function()
    local carried = policy.carried(
        { authorization = 'Bearer x', accept = 'application/json' },
        'https://api.example.org:443',
        'https://api.example.org:443'
    )

    t.assert_equals(carried.authorization, 'Bearer x')
    t.assert_equals(carried.accept, 'application/json')
end

g.test_login_headers_stay_behind_on_a_foreign_host = function()
    -- Заголовок входа, уехавший по чужой ссылке, — это отданный пароль.
    local carried = policy.carried({
        authorization = 'Bearer x',
        cookie = 'session=1',
        ['proxy-authorization'] = 'Basic y',
        accept = 'application/json',
    }, 'https://api.example.org:443', 'https://evil.example.net:443')

    t.assert_equals(carried.authorization, nil)
    t.assert_equals(carried.cookie, nil)
    t.assert_equals(carried['proxy-authorization'], nil)
    t.assert_equals(carried.accept, 'application/json')
end

g.test_carried_headers_are_a_copy = function()
    -- Заголовки запроса переживают повтор: вычеркнуть из них что-то
    -- на месте значит вычеркнуть навсегда.
    local headers = { authorization = 'Bearer x' }

    policy.carried(headers, 'https://a:443', 'https://b:443')

    t.assert_equals(headers.authorization, 'Bearer x')
end

g.test_answer_bigger_than_the_limit_is_named_by_its_size = function()
    t.assert_equals(policy.oversized(('x'):rep(11), 10), 11)
    t.assert_equals(policy.oversized(('x'):rep(10), 10), nil)
end

g.test_limit_of_one_byte_is_still_a_limit = function()
    -- Граница считается по самому телу, а не по «примерно столько»:
    -- ответ ровно в предел проходит, а больше на байт — уже нет.
    t.assert_equals(policy.oversized('xx', 1), 2)
    t.assert_equals(policy.oversized('x', 1), nil)
end

g.test_zero_limit_takes_any_answer = function()
    t.assert_equals(policy.oversized(('x'):rep(1000), 0), nil)
end

g.test_private_headers_are_named_by_the_package = function()
    -- Список читают и переходы, и те, кто собирает своё поведение.
    t.assert_equals(helper.at(policy.PRIVATE_HEADERS, 1), 'authorization')
end
