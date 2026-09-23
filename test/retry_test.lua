--- Тесты повторов: что повторяется, сколько раз и как долго ждёт.

local t = require('luatest')

local g = t.group('tnt.http.retry')

local helper = dofile('test/helper.lua')

---@type number[]
local slept

g.before_each(function()
    helper.load('tnt.http')
    slept = helper.instant_retries()
end)

g.after_each(function()
    helper.forget()
end)

g.test_server_trouble_is_tried_again = function()
    local client, sent = helper.client_of({ helper.answer(503), helper.answer(200, { body = 'да' }) })
    local answer = client:get(helper.SOMEWHERE)

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.body, 'да')
    t.assert_equals(#sent, 2)
end

g.test_when_the_attempts_run_out_the_answer_is_still_an_answer = function()
    -- Вызывающему нужен ответ сервера, а не рассказ о том, что его
    -- повторяли: по коду 503 он решит сам.
    local client, sent = helper.client_of({
        helper.answer(503),
        helper.answer(503),
        helper.answer(503),
    })

    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(err, nil)
    t.assert_equals(answer.status, 503)
    t.assert_equals(#sent, 3)
end

g.test_post_is_never_repeated_by_the_client = function()
    -- Оборвавшийся POST мог дойти до сервера, и повтор создаст второй заказ.
    local client, sent = helper.client_of({ helper.answer(503) })
    local answer = client:post(helper.SOMEWHERE, { body = 'x' })

    t.assert_equals(answer.status, 503)
    t.assert_equals(#sent, 1)
end

g.test_client_mistake_is_not_repeated = function()
    local client, sent = helper.client_of({ helper.answer(404) })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 404)
    t.assert_equals(#sent, 1)
end

g.test_broken_network_is_tried_again_for_a_fetch = function()
    local client, sent = helper.client_of({ helper.no_answer(), helper.answer(200) })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    t.assert_equals(#sent, 2)
end

g.test_broken_network_is_not_tried_again_for_a_post = function()
    local client, sent = helper.client_of({ helper.no_answer() })
    local answer, err = client:post(helper.SOMEWHERE, { body = 'x' })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.retriable, false)
    t.assert_str_contains(tostring(err), 'сервер не ответил')
    t.assert_equals(#sent, 1)
end

g.test_too_many_redirects_are_not_tried_again = function()
    -- Переходов больше предела не станет со второй попытки.
    local client, sent = helper.client_of({ helper.moved(302, '/a'), helper.moved(302, '/b') }, { max_redirects = 1 })

    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_str_contains(tostring(err), 'переходов больше 1')
    t.assert_equals(#sent, 2)
end

g.test_oversized_answer_is_not_tried_again = function()
    -- Чужой ответ не похудеет со второй попытки.
    local client, sent = helper.client_of({ helper.answer(200, { body = ('x'):rep(100) }) }, { max_body = 10 })

    t.assert_equals(select(2, client:get(helper.SOMEWHERE)) ~= nil, true)
    t.assert_equals(#sent, 1)
end

g.test_server_asking_to_wait_is_obeyed = function()
    -- Сервер один знает, когда у него снова будет место.
    local client, sent = helper.client_of({
        helper.answer(429, { headers = { ['Retry-After'] = '2' } }),
        helper.answer(200),
    })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    t.assert_equals(#sent, 2)
    t.assert_equals(helper.at(slept, 1), 2)
end

g.test_server_asking_to_wait_too_long_stops_the_repeats = function()
    -- Прийти раньше значит сделать ровно то, о чём просили не делать,
    -- а ждать дольше потолка вызывающий не подписывался.
    local client, sent = helper.client_of({ helper.answer(429, { headers = { ['Retry-After'] = '600' } }) })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 429)
    t.assert_equals(#sent, 1)
    t.assert_equals(#slept, 0)
end

g.test_date_in_retry_after_is_ignored_and_the_backoff_is_used = function()
    -- Дата меряется чужими часами, а они расходятся с нашими: `tnt.retry`
    -- нарочно читает только число секунд.
    local client, sent = helper.client_of({
        helper.answer(503, { headers = { ['Retry-After'] = 'Wed, 21 Oct 2026 07:28:00 GMT' } }),
        helper.answer(200),
    }, { retry = { base = 0.5, jitter = 0 } })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 200)
    t.assert_equals(#sent, 2)
    t.assert_equals(helper.at(slept, 1), 0.5)
end

g.test_repeats_are_settled_for_the_client_once = function()
    local client, sent = helper.client_of({ helper.answer(503) }, { retry = { attempts = 1 } })

    t.assert_equals(client:get(helper.SOMEWHERE).status, 503)
    t.assert_equals(#sent, 1)
end

g.test_one_request_may_ask_for_its_own_repeats = function()
    local client, sent = helper.client_of({ helper.answer(503), helper.answer(503) })

    client:get(helper.SOMEWHERE, { retry = { attempts = 2 } })

    t.assert_equals(#sent, 2)
end

g.test_shared_deadline_shortens_the_attempt = function()
    -- Незачем начинать попытку длиннее, чем вызывающий согласен ждать
    -- целиком.
    local client, sent = helper.client_of({ helper.answer(200) }, {
        timeout = 30,
        connect_timeout = 1,
        retry = { deadline = 5 },
    })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.timeout, 5)
end

g.test_every_redirect_gets_only_what_is_left_of_the_deadline = function()
    -- Каждый переход — новое ожидание libcurl. Остаток, снятый один раз
    -- на начало попытки, дал бы каждому переходу полный срок, и попытка
    -- с тремя переходами длилась бы втрое дольше срока всего вызова.
    local client, sent = helper.client_of({
        helper.answer(302, { headers = { Location = '/2' }, takes = 1.5 }),
        helper.answer(302, { headers = { Location = '/3' }, takes = 1.5 }),
        helper.answer(200),
    }, {
        timeout = 30,
        connect_timeout = 1,
        retry = { deadline = 5 },
    })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 1).options.timeout, 5)
    t.assert_equals(helper.at(sent, 2).options.timeout, 3.5)
    t.assert_equals(helper.at(sent, 3).options.timeout, 2)
end

g.test_the_last_crumb_of_the_deadline_is_still_a_deadline = function()
    -- Срок, равный нулю, у libcurl значит «без срока», то есть ровно
    -- обратное тому, что осталось от общего срока.
    local client, sent = helper.client_of({ helper.answer(503), helper.answer(200) }, {
        retry = { deadline = 0.1005, base = 0.1, jitter = 0, attempts = 2 },
    })

    client:get(helper.SOMEWHERE)

    t.assert_equals(helper.at(sent, 2).options.timeout, 0.001)
end

g.test_failed_request_leaves_a_record_without_the_query = function()
    -- В параметрах запроса ездят ключи доступа, и журнал — последнее
    -- место, где им стоит оседать.
    local journal = helper.capture_log()
    local client = helper.client_of({ helper.no_answer() })

    client:post(helper.SOMEWHERE .. '?token=тайна', { body = 'x' })

    t.assert_equals(journal.logged('запрос не удался'), true)
    t.assert_equals(journal.logged('http://api.example.org:80'), true)
    t.assert_equals(journal.logged('сервер не ответил'), true)
    t.assert_equals(journal.logged('тайна'), false)
end

g.test_timeout_in_the_middle_of_the_body_is_tried_again_and_is_not_an_answer = function()
    -- Срок, вышедший посреди тела, приходит с заголовками и кодом 408:
    -- отдать его ответом значило бы отдать обрезанное тело.
    local cut = helper.answer(408, { reason = 'Timeout was reached', body = 'xx' })
    local client, sent = helper.client_of({ cut, cut }, { retry = { attempts = 2 } })

    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.retriable, true)
    t.assert_equals(err.reason, 'сервер не ответил: Timeout was reached (код 408)')
    t.assert_equals(#sent, 2)
end

g.test_throw_of_a_layer_is_not_worth_repeating = function()
    local client, sent = helper.client_of({}, {
        layers = {
            function()
                error('слой сломался', 0)
            end,
        },
    })

    local answer, err = client:get(helper.SOMEWHERE)

    t.assert_equals(answer, nil)
    t.assert_equals(err.retriable, false)
    t.assert_equals(#sent, 0)
end

g.test_layer_that_throws_does_not_drop_the_node = function()
    -- Слой пишет прикладной разработчик, и его ошибка — такой же отказ,
    -- как молчащий сервер: ронять из-за неё узел несоразмерно.
    local client, sent = helper.client_of({}, {
        layers = {
            function()
                error('слой сломался', 0)
            end,
        },
    })

    local answer, err = client:post(helper.SOMEWHERE, { body = 'x' })

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(tostring(err), 'слой сломался')
    t.assert_equals(#sent, 0)
end
