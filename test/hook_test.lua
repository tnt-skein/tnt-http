--- Тесты крюка трассы: заголовки контекста в запросе и в потоке, крюки
--- вокруг попытки и открытия.
---
--- Контекст здесь настоящий, а не двойник: снимок живёт в хранилище
--- файбера, и заголовки берутся из него тем же путём, что и в бою.
--- Ключ проверки объявлен под своим именем и заголовком, а не под
--- `traceparent`: объявление общее на процесс, и настройки трассировки
--- разошлись бы с проверочными. Сервер — двойник libcurl: он помнит,
--- с какими заголовками к нему пришли, и по нему видно и отправку,
--- и её отсутствие.

local t = require('luatest')

local g = t.group('tnt.http.hook')

local helper = dofile('test/helper.lua')

---@type any
local http

---@type TntContext
local context

---@type TntTestingJournal
local journal

g.before_each(function()
    http = helper.load('tnt.http')
    context = helper.context()
    journal = helper.capture_log()
end)

g.after_each(function()
    journal.release()
    helper.forget()
end)

--- Крюк, который отмечается в списке и пропускает обращение дальше.
---@param seen string[]
---@param mark string
---@return function
local function noting(seen, mark)
    return function(_, proceed)
        table.insert(seen, mark)

        return proceed()
    end
end

--- Заголовки, которые ушли на сервер с обращением под номером.
---@param sent table[]
---@param index integer
---@return table<string, string>
local function headers_of(sent, index)
    return helper.at(sent, index).options.headers
end

g.test_context_headers_ride_with_the_request_without_any_hook = function()
    -- Порвать трассу забытым крюком нечем: заголовки едут из ядра.
    local client, sent = helper.client_of({ helper.answer(200) })

    context.run({ request_id = 'r-7', [helper.PROBE] = 'p-1' }, function()
        t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    end)

    t.assert_equals(headers_of(sent, 1)['x-request-id'], 'r-7')
    t.assert_equals(headers_of(sent, 1)[helper.PROBE_HEADER], 'p-1')
    t.assert_equals(http.hooks(), {})
end

g.test_context_headers_ride_with_the_stream = function()
    local sent = helper.streaming({ reads = { 'кусок\n' } })
    local client = assert(http.new())

    context.run({ request_id = 'r-7', [helper.PROBE] = 'p-1' }, function()
        local stream = assert(client:stream({ url = helper.SOMEWHERE }))

        t.assert_equals(stream:read(), 'кусок\n')
        stream:close()
    end)

    t.assert_equals(headers_of(sent, 1)['x-request-id'], 'r-7')
    t.assert_equals(headers_of(sent, 1)[helper.PROBE_HEADER], 'p-1')
    t.assert_equals(helper.at(sent, 1).options.chunked, true)
end

g.test_outside_a_context_area_nothing_is_added = function()
    -- Отрицательный контроль: проверка видит отсутствие заголовков,
    -- а не только их наличие.
    local client, sent = helper.client_of({ helper.answer(200) })
    local streamed = helper.streaming({})
    local streaming = assert(http.new())

    client:get(helper.SOMEWHERE)
    assert(streaming:stream({ url = helper.SOMEWHERE })):close()

    t.assert_equals(headers_of(sent, 1), { ['user-agent'] = 'tnt-http' })
    t.assert_equals(headers_of(streamed, 1), { ['user-agent'] = 'tnt-http' })
end

g.test_area_without_the_probe_sends_only_what_it_has = function()
    -- В области без трассы уходит только опознаватель запроса.
    local client, sent = helper.client_of({ helper.answer(200) })

    context.run({ request_id = 'r-7' }, function()
        client:get(helper.SOMEWHERE)
    end)

    t.assert_equals(headers_of(sent, 1), { ['user-agent'] = 'tnt-http', ['x-request-id'] = 'r-7' })
end

g.test_header_of_the_caller_wins_over_the_context = function()
    -- Заданный настройкой клиента, обращения, слоем или крюком —
    -- заданный, и контекст его не перезаписывает.
    local client, sent = helper.client_of({
        helper.answer(200),
        helper.answer(200),
        helper.answer(200),
        helper.answer(200),
    }, {
        headers = { ['X-Request-Id'] = 'своё' },
        layers = {
            function(request, nxt)
                if request.path == '/layered' then
                    request.headers[helper.PROBE_HEADER] = 'из слоя'
                end

                return nxt(request)
            end,
        },
    })

    context.run({ request_id = 'r-7', [helper.PROBE] = 'p-1' }, function()
        client:get(helper.SOMEWHERE)
        client:get(helper.SOMEWHERE, { headers = { [helper.PROBE_HEADER] = 'из обращения' } })
        client:get('http://api.example.org/layered')

        http.hook('свой', function(call, proceed)
            call.request.headers[helper.PROBE_HEADER] = 'из крюка'

            return proceed()
        end)

        client:get(helper.SOMEWHERE)
    end)

    t.assert_equals(headers_of(sent, 1)['x-request-id'], 'своё')
    t.assert_equals(headers_of(sent, 1)[helper.PROBE_HEADER], 'p-1')
    t.assert_equals(headers_of(sent, 2)[helper.PROBE_HEADER], 'из обращения')
    t.assert_equals(headers_of(sent, 3)[helper.PROBE_HEADER], 'из слоя')
    t.assert_equals(headers_of(sent, 4)[helper.PROBE_HEADER], 'из крюка')
    t.assert_equals(headers_of(sent, 4)['x-request-id'], 'своё')
end

g.test_context_headers_are_collected_after_the_layers = function()
    -- Слой видит запрос ещё без заголовков контекста, а отправка — уже
    -- с ними, и в область слоя они тоже входят: собираются они перед самой
    -- отправкой, в тот запрос, который слой отдал дальше.
    ---@type any
    local seen_by_layer

    local client, sent = helper.client_of({ helper.answer(200) }, {
        layers = {
            function(request, nxt)
                seen_by_layer = request.headers[helper.PROBE_HEADER]

                return context.run({ [helper.PROBE] = 'из области слоя' }, nxt, request)
            end,
        },
    })

    context.run({ request_id = 'r-7', [helper.PROBE] = 'p-1' }, function()
        client:get(helper.SOMEWHERE)
    end)

    t.assert_equals(seen_by_layer, nil)
    t.assert_equals(headers_of(sent, 1)[helper.PROBE_HEADER], 'из области слоя')
    t.assert_equals(headers_of(sent, 1)['x-request-id'], 'r-7')
end

g.test_context_headers_travel_through_redirects_even_to_a_foreign_host = function()
    -- W3C рассчитывает на пересылку опознавателей; тайна входа, наоборот,
    -- на чужой узел не едет.
    local client, sent = helper.client_of(
        { helper.moved(302, 'https://other.example.net/x'), helper.answer(200) },
        { headers = { Authorization = 'Bearer тайна' } }
    )

    context.run({ request_id = 'r-7' }, function()
        client:get(helper.SOMEWHERE)
    end)

    t.assert_equals(headers_of(sent, 2)['x-request-id'], 'r-7')
    t.assert_equals(headers_of(sent, 2).authorization, nil)
end

g.test_without_propagation_neither_headers_nor_hooks = function()
    -- Выгрузчик трасс иначе рождал бы отрезок о самой выгрузке.
    local called = 0

    http.hook('счёт', function(_, proceed)
        called = called + 1

        return proceed()
    end)

    local client, sent = helper.client_of({ helper.answer(200) }, { propagate = false })
    local streamed = helper.streaming({})
    local quiet = assert(http.new({ propagate = false }))

    context.run({ request_id = 'r-7' }, function()
        t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
        assert(quiet:stream({ url = helper.SOMEWHERE })):close()
    end)

    t.assert_equals(headers_of(sent, 1)['x-request-id'], nil)
    t.assert_equals(headers_of(streamed, 1)['x-request-id'], nil)
    t.assert_equals(called, 0)
    t.assert_equals(client:status().propagate, false)
    t.assert_equals(client:status().hooks, { 'счёт' })
end

g.test_hooks_wrap_the_attempt_outside_the_layers_in_order = function()
    local order = {}

    local function wrapping(name)
        return function(_, proceed)
            table.insert(order, name .. ' туда')

            local answer, err = proceed()

            table.insert(order, name .. ' обратно')

            return answer, err
        end
    end

    http.hook('первый', wrapping('первый'))
    http.hook('второй', wrapping('второй'))

    local client = helper.client_of({ helper.answer(200) }, {
        layers = {
            function(request, nxt)
                table.insert(order, 'слой')

                return nxt(request)
            end,
        },
    })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    t.assert_equals(order, {
        'первый туда',
        'второй туда',
        'слой',
        'второй обратно',
        'первый обратно',
    })
    t.assert_equals(http.hooks(), { 'первый', 'второй' })
    t.assert_equals(journal.records(), {})
end

g.test_hook_sees_the_call_in_the_agreed_shape = function()
    ---@type any
    local seen

    http.hook('смотрящий', function(call, proceed)
        seen = call

        return proceed()
    end)

    local client = helper.client_of({ helper.answer(201) })

    client:post('http://h/customers?a=1', { query = { page = 2 }, json = { name = 'И' } })

    t.assert_equals(seen.kind, 'request')
    t.assert_equals(seen.attempt, 1)
    t.assert_equals(seen.request.method, 'POST')
    t.assert_equals(seen.request.url, 'http://h/customers?a=1&page=2')
    t.assert_equals(seen.request.path, '/customers')
    t.assert_equals(seen.request.body, '{"name":"И"}')
    t.assert_equals(seen.request.headers['content-type'], 'application/json')
end

g.test_proceed_sends_once_and_repeats_its_outcome = function()
    -- Крюк, позвавший proceed дважды, иначе слал бы запрос дважды.
    local first, second

    http.hook('дважды', function(_, proceed)
        first = proceed()
        second = proceed()

        return second
    end)

    local client, sent = helper.client_of({ helper.answer(200, { body = 'раз' }) })
    local answer = client:get(helper.SOMEWHERE)

    t.assert_equals(#sent, 1)
    t.assert_equals(first, second)
    t.assert_equals(answer.body, 'раз')
end

g.test_hook_that_throws_before_sending_does_not_stop_the_request = function()
    http.hook('сломанный', function()
        error('телеметрия упала', 0)
    end)

    local client, sent = helper.client_of({ helper.answer(200, { body = 'да' }) })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(err, nil)
    t.assert_equals(answer.body, 'да')
    t.assert_equals(#sent, 1)

    local record = assert(
        journal.find(
            'WARN [tnt.http] крюк исходящего обращения бросил и пропущен'
        )
    )

    t.assert_equals(record.record.fields.hook, 'сломанный')
    t.assert_equals(record.record.fields.kind, 'request')
    t.assert_equals(record.record.fields.method, 'GET')
    t.assert_equals(record.record.fields.err, 'телеметрия упала')
end

g.test_hook_that_throws_after_sending_keeps_the_outcome = function()
    http.hook('сломанный', function(_, proceed)
        proceed()

        error('после отправки', 0)
    end)

    local client, sent = helper.client_of({ helper.answer(200, { body = 'да' }) })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(err, nil)
    t.assert_equals(answer.body, 'да')
    t.assert_equals(#sent, 1)
    t.assert_equals(journal.logged('после отправки'), true)
end

g.test_broken_outer_hook_does_not_skip_the_inner_one = function()
    local seen = {}

    http.hook('внешний', function()
        error('упал', 0)
    end)
    http.hook('внутренний', noting(seen, 'внутренний'))

    local client, sent = helper.client_of({ helper.answer(200) })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    t.assert_equals(seen, { 'внутренний' })
    t.assert_equals(#sent, 1)
end

g.test_stream_hook_that_throws_is_told_with_its_kind = function()
    http.hook('сломанный', function()
        error('на потоке', 0)
    end)

    local sent = helper.streaming({})
    local stream = assert(assert(http.new()):stream({ url = helper.SOMEWHERE }))

    stream:close()

    t.assert_equals(#sent, 1)

    local record = assert(journal.find('на потоке'))

    t.assert_equals(record.record.fields.kind, 'stream')
end

g.test_outcome_of_the_sending_wins_over_the_words_of_the_hook = function()
    -- Что вернул крюк, позвавший proceed, не читается: сломанная
    -- телеметрия не стоит ответа.
    http.hook('болтливый', function(_, proceed)
        proceed()

        return nil, 'а я скажу иначе'
    end)

    local client = helper.client_of({ helper.answer(200, { body = 'да' }) })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(err, nil)
    t.assert_equals(answer.body, 'да')
end

g.test_hook_that_does_not_proceed_cancels_the_sending = function()
    -- Отрицательный контроль для двойника: запрос не ушёл, и это видно.
    -- Отказ без слов получает имя виновного.
    http.hook('глухой', function() end)

    local client, sent = helper.client_of({ helper.answer(200) })
    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_equals(#sent, 0)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(err.retriable, false)
    t.assert_equals(
        tostring(err),
        'крюк «глухой» не отправил обращение и не назвал причины'
    )
end

g.test_hook_may_refuse_with_its_own_words_for_request_and_stream = function()
    http.hook('сторож', function()
        return nil, 'наружу нельзя'
    end)

    local client, sent = helper.client_of({})
    local answer, err = client:post(helper.SOMEWHERE, { body = 'x' })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(tostring(err), 'наружу нельзя')
    t.assert_equals(#sent, 0)

    local streamed = helper.streaming({})
    local stream, refused = assert(http.new()):stream({ url = helper.SOMEWHERE })

    t.assert_equals(stream, nil)
    t.assert_equals(refused.kind, 'refused')
    t.assert_equals(tostring(refused), 'наружу нельзя')
    t.assert_equals(#streamed, 0)
end

g.test_hook_may_answer_instead_of_the_server = function()
    -- Как слой: двойник в проверке прикладного кода встаёт и крюком.
    http.hook('кэш', function()
        return { status = 200, reason = 'Ok', headers = {}, body = 'из кэша' }
    end)

    local client, sent = helper.client_of({})

    t.assert_equals(client:get(helper.SOMEWHERE).body, 'из кэша')
    t.assert_equals(#sent, 0)
end

g.test_every_attempt_gets_its_own_call_and_its_own_headers = function()
    -- Дописанное крюком в заголовки одной попытки до следующей не доезжает:
    -- у двойника первая запись хранит заголовки первой попытки, и общая
    -- таблица показала бы в ней «2».
    helper.instant_retries()

    local attempts = {}

    http.hook('счёт', function(call, proceed)
        table.insert(attempts, call.attempt)
        call.request.headers['x-attempt'] = tostring(call.attempt)

        return proceed()
    end)

    local client, sent = helper.client_of({ helper.answer(503), helper.answer(200) })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    t.assert_equals(attempts, { 1, 2 })
    t.assert_equals(headers_of(sent, 1)['x-attempt'], '1')
    t.assert_equals(headers_of(sent, 2)['x-attempt'], '2')
end

g.test_header_collected_inside_proceed_carries_the_area_of_the_hook = function()
    -- Так заголовок трассы несёт отрезок крюка, а не вызывающего,
    -- и у каждой попытки он свой; снимок вызывающего после вызова прежний.
    helper.instant_retries()

    http.hook('отрезок', function(call, proceed)
        return context.run({ [helper.PROBE] = 'отрезок-' .. call.attempt }, proceed)
    end)

    local client, sent = helper.client_of({ helper.answer(503), helper.answer(200) })

    context.run({ [helper.PROBE] = 'вызывающий' }, function()
        t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
        t.assert_equals(context.get(helper.PROBE), 'вызывающий')
    end)

    t.assert_equals(headers_of(sent, 1)[helper.PROBE_HEADER], 'отрезок-1')
    t.assert_equals(headers_of(sent, 2)[helper.PROBE_HEADER], 'отрезок-2')
end

g.test_stream_opening_goes_through_the_hooks_once = function()
    local calls = {}

    http.hook('поток', function(call, proceed)
        table.insert(calls, { kind = call.kind, attempt = call.attempt, method = call.request.method })

        return proceed()
    end)

    local sent = helper.streaming({ reads = { 'кусок\n' } })
    local stream = assert(assert(http.new()):stream({ url = helper.SOMEWHERE }))

    t.assert_equals(stream:read(), 'кусок\n')
    t.assert_equals(stream:read(), nil)
    stream:close()

    t.assert_equals(calls, { { kind = 'stream', method = 'GET' } })
    t.assert_equals(#sent, 1)
end

g.test_hooks_are_named_replaced_and_removed = function()
    local seen = {}

    http.hook('а', noting(seen, 'а'))
    http.hook('б', noting(seen, 'б'))
    -- Замена оставляет место в порядке.
    http.hook('а', noting(seen, 'а2'))

    t.assert_equals(http.hooks(), { 'а', 'б' })

    http.hook('б', nil)
    http.hook('в', noting(seen, 'в'))
    -- Снятый и поставленный снова встаёт последним.
    http.hook('б', noting(seen, 'б2'))

    t.assert_equals(http.hooks(), { 'а', 'в', 'б' })

    local client = helper.client_of({ helper.answer(200) })

    client:get(helper.SOMEWHERE)

    t.assert_equals(seen, { 'а2', 'в', 'б2' })

    http.hook('а', nil)
    http.hook('в', nil)
    http.hook('б', nil)
    -- Снять то, чего нет, безвредно.
    http.hook('нет такого', nil)

    t.assert_equals(http.hooks(), {})
end

g.test_names_are_a_copy_and_not_the_list_itself = function()
    http.hook('tnt.trace', noting({}, 'x'))

    local names = http.hooks()

    table.insert(names, 'подложенный')

    t.assert_equals(http.hooks(), { 'tnt.trace' })
end

g.test_status_shows_the_hooks_and_the_propagation = function()
    http.hook('tnt.trace', noting({}, 'x'))

    local client = helper.client_of({}, { base_url = 'https://h' })

    t.assert_equals(client:status().hooks, { 'tnt.trace' })
    t.assert_equals(client:status().propagate, true)
    t.assert_equals(http.status().hooks, { 'tnt.trace' })
    t.assert_equals(http.status().propagate, true)
end

g.test_hook_is_named_by_a_string_and_is_a_function = function()
    -- Ошибка программиста: исключение на строке вызывающего, а не молчание.
    t.assert_error_msg_contains(
        'имя крюка — непустая строка, а не пустая',
        http.hook,
        '',
        print
    )
    t.assert_error_msg_contains(
        'имя крюка — непустая строка, а не число',
        http.hook,
        7,
        print
    )
    t.assert_error_msg_contains(
        'крюк — функция или вызываемая таблица, а не строка',
        http.hook,
        'имя',
        'print'
    )
    t.assert_equals(http.hooks(), {})

    -- Вина — на строке того, кто позвал `http.hook`, а не внутри клиента.
    local ok, err = pcall(function()
        http.hook('имя', 'print')
    end)

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'hook_test.lua:')
    t.assert_str_contains(
        tostring(err),
        'крюк — функция или вызываемая таблица, а не строка'
    )
end
