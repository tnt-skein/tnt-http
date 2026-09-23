--- Тесты транспорта: отказ сети отличается от ответа сервера.

local t = require('luatest')

local g = t.group('tnt.http.transport')

local helper = dofile('test/helper.lua')

---@type any
local transport

--- Обработчик, который отвечает одним и тем же.
---@param answer any Что вернуть; функция — что сделать
---@return table handle
---@return table asked Что у него спрашивали
local function handle_of(answer)
    local asked = {}

    return {
        request = function(_, method, url, body, options)
            table.insert(asked, { method = method, url = url, body = body, options = options })

            if type(answer) == 'function' then
                return answer()
            end

            return answer
        end,
    },
        asked
end

g.before_each(function()
    transport = helper.load('tnt.http.transport')
end)

g.after_each(function()
    transport._set_source(nil)
    helper.unload()
end)

g.test_real_handle_is_a_curl_client = function()
    -- Умолчание внешней зависимости — настоящий `http.client`: подменённый двойник
    -- показал бы только то, что проверка умеет подменять.
    local handle = transport.new({ max_connections = 1 })

    t.assert_type(handle.request, 'function')
end

g.test_handle_is_made_with_the_given_settings = function()
    local given

    transport._set_source({
        client = function(opts)
            given = opts

            return handle_of(nil)
        end,
    })

    transport.new({ max_connections = 4 })

    t.assert_equals(given, { max_connections = 4 })
end

g.test_answer_of_the_server_comes_back_as_it_is = function()
    local handle, asked = handle_of(helper.answer(200, { body = 'да' }))
    local raw, err = transport.perform(handle, 'GET', 'http://h/x', nil, { timeout = 1 })

    t.assert_equals(err, nil)
    t.assert_equals(raw.body, 'да')
    t.assert_equals(helper.at(asked, 1).method, 'GET')
    t.assert_equals(helper.at(asked, 1).url, 'http://h/x')
    t.assert_equals(helper.at(asked, 1).options, { timeout = 1 })
end

g.test_answer_without_headers_is_a_broken_network = function()
    -- Единственная надёжная примета: код 595 libcurl придумывает сам,
    -- и такой же мог бы придумать чужой сервер.
    local handle = handle_of(helper.no_answer())
    local raw, err = transport.perform(handle, 'GET', 'http://h/x', nil, {})

    t.assert_equals(raw, nil)
    t.assert_str_contains(err, 'GET http://h/x')
    t.assert_str_contains(err, 'сервер не ответил')
    t.assert_str_contains(err, 'Could not resolve hostname')
    t.assert_str_contains(err, '595')
end

g.test_nothing_at_all_instead_of_an_answer_is_a_broken_network = function()
    local handle = handle_of(nil)
    local raw, err = transport.perform(handle, 'GET', 'http://h/x', nil, {})

    t.assert_equals(raw, nil)
    t.assert_str_contains(err, 'сервер не ответил: nil')
end

g.test_curl_that_throws_does_not_drop_the_node = function()
    -- libcurl бросает на том, что вовсе не похоже на адрес, и ронять
    -- этим узел из-за опечатки в чужой ссылке несоразмерно.
    local handle = handle_of(function()
        error('curl: Unsupported protocol: Invalid argument', 0)
    end)

    local raw, err, reason = transport.perform(handle, 'GET', 'ftp://h/x', nil, {})

    t.assert_equals(raw, nil)
    t.assert_equals(err, 'GET ftp://h/x: libcurl отказал: curl: Unsupported protocol: Invalid argument')
    t.assert_equals(reason, 'libcurl отказал: curl: Unsupported protocol: Invalid argument')
end

g.test_a_throw_after_sending_is_not_named_unsent = function()
    -- Сервер прочитал запрос и сбросил соединение: libcurl бросает и так,
    -- и метка броска не вправе обещать, что запрос не ушёл.
    local handle = handle_of(function()
        error('curl: Failure when receiving data from the peer: Connection reset by peer', 0)
    end)

    local raw, err = transport.perform(handle, 'PUT', 'http://h/x', 'тело', {})

    t.assert_equals(raw, nil)
    t.assert_equals(
        err,
        'PUT http://h/x: libcurl отказал: curl: Failure when receiving data from the peer: Connection reset by peer'
    )
end

g.test_words_of_a_request_that_never_left_are_written_out = function()
    -- Выписаны здесь, а не взяты из модуля: слова сверяют чужие тексты
    -- libcurl, и слово, выпавшее из списка, обязано сломать проверку.
    t.assert_equals(transport.UNSENT, { 'resolve host', 'resolve proxy', 'connect to server', 'SSL connect error' })
end

g.test_request_that_never_left_is_told_by_the_words_of_any_libcurl = function()
    -- Оба написания: до 8.9 libcurl писал «Couldn't…», с 8.9 — «Could not…».
    for _, words in ipairs({
        "Couldn't resolve host name",
        'Could not resolve hostname',
        "Couldn't resolve proxy name",
        'Could not resolve proxy name',
        "Couldn't connect to server",
        'Could not connect to server',
        'SSL connect error',
    }) do
        local _, _, reason, sent = transport.perform(handle_of(helper.no_answer(words)), 'POST', 'http://h/x', '', {})

        t.assert_str_contains(reason, words)
        t.assert_equals(sent, false, words)
    end
end

g.test_request_that_could_have_left_is_named_sent = function()
    -- Срок, сброс, оборванное тело и пустота вместо ответа бывают и после
    -- того, как сервер запрос прочитал: о них судят «могло уйти».
    for _, answer in ipairs({
        helper.no_answer('Timeout was reached'),
        helper.no_answer('Failed sending data to the peer'),
        helper.answer(444, { reason = 'Server returned nothing (no headers, no data)' }),
        helper.answer(0, { reason = 'Unknown' }),
        'строка',
    }) do
        local raw, _, reason, sent = transport.perform(handle_of(answer), 'POST', 'http://h/x', '', {})

        t.assert_equals(raw, nil)
        t.assert_equals(sent, true, reason)
    end
end

g.test_throw_is_judged_by_its_words = function()
    -- Рукопожатие TLS libcurl бросает до отправки, сброс — после неё.
    local function thrown(words)
        return handle_of(function()
            error(helper.thrown(words).raises, 0)
        end)
    end

    t.assert_equals(select(4, transport.perform(thrown('SSL connect error'), 'POST', 'http://h/x', '', {})), false)
    t.assert_equals(
        select(4, transport.perform(thrown('Failure when receiving data from the peer'), 'POST', 'http://h/x', '', {})),
        true
    )
end

g.test_words_are_compared_as_text_and_not_as_a_pattern = function()
    -- Точка в словах — точка: образцом «no.route» совпал бы и с «noXroute».
    table.insert(transport.UNSENT, 'no.route')

    t.assert_equals(transport.sent('сервер не ответил: noXroute'), true)
    t.assert_equals(transport.sent('сервер не ответил: no.route'), false)
end

g.test_the_address_is_not_judged = function()
    -- Судится причина без адреса: слова в адресе — текст вызывающего.
    t.assert_equals(
        select(
            4,
            transport.perform(
                handle_of(helper.no_answer('Timeout was reached')),
                'GET',
                'http://connect to server/',
                nil,
                {}
            )
        ),
        true
    )
    t.assert_equals(transport.sent('сервер не ответил: Timeout was reached (код 408)'), true)
    t.assert_equals(
        transport.sent('поток не открылся: curl: SSL connect error: Invalid argument'),
        false
    )
end

g.test_reason_of_a_strange_answer_names_what_came = function()
    t.assert_str_contains(transport.reason_of('строка'), 'строка')
end

g.test_invented_codes_and_spoken_words_are_written_out = function()
    -- Выписаны здесь, а не взяты из модуля: коды, сверенные с собой же,
    -- сходятся при любом значении.
    t.assert_equals(transport.INVENTED, { [408] = true, [444] = true, [495] = true, [595] = true })
    t.assert_equals(transport.SPOKEN, { Ok = true, Unknown = true })
    t.assert_equals(transport.NOTHING, 0)
end

g.test_code_zero_is_not_an_answer_whatever_the_word = function()
    -- Так `http.client` отдаёт файл по `file://`: с заголовками, кодом 0
    -- и словом настоящего ответа. Ответом по HTTP это не было.
    local file = helper.answer(0, { reason = 'Unknown', body = '127.0.0.1 localhost' })
    local raw, err = transport.perform(handle_of(file), 'GET', 'file:///etc/hosts', nil, {})

    t.assert_equals(raw, nil)
    t.assert_equals(err, 'GET file:///etc/hosts: сервер не ответил: Unknown (код 0)')
    t.assert_equals(transport.answered(helper.answer(0, { reason = 'Ok' })), false)
    t.assert_equals(transport.answered(helper.answer(1, { reason = 'Ok' })), true)
end

g.test_timeout_in_the_middle_of_the_body_is_a_broken_network = function()
    -- Найдено запуском: срок, вышедший посреди тела, приходит с заголовками,
    -- и по одной таблице заголовков обрезанное тело выглядело ответом 408.
    local handle = handle_of(helper.answer(408, {
        reason = 'Timeout was reached',
        headers = { ['content-length'] = '10' },
        body = 'xxx',
    }))

    local raw, err, reason = transport.perform(handle, 'GET', 'http://h/x', nil, {})

    t.assert_equals(raw, nil)
    t.assert_equals(err, 'GET http://h/x: сервер не ответил: Timeout was reached (код 408)')
    t.assert_equals(reason, 'сервер не ответил: Timeout was reached (код 408)')
end

g.test_code_of_libcurl_with_the_word_of_a_server_is_an_answer = function()
    -- Сервер вправе ответить 408 сам: слово у такого ответа — «Unknown».
    for _, answer in ipairs({
        helper.answer(408, { reason = 'Unknown' }),
        helper.answer(595, { reason = 'Ok' }),
        helper.answer(500, { reason = 'Какое-то слово' }),
    }) do
        t.assert_equals(transport.perform(handle_of(answer), 'GET', 'http://h/x', nil, {}), answer)
    end
end

g.test_every_invented_code_with_a_word_of_libcurl_is_a_broken_network = function()
    for _, status in ipairs({ 0, 444, 495, 595 }) do
        t.assert_equals(transport.answered(helper.answer(status, { reason = 'curl word' })), false, status)
    end

    t.assert_equals(transport.answered(helper.answer(407, { reason = 'curl word' })), true)
    t.assert_equals(transport.answered('строка'), false)
    -- Без заголовков ответа не бывает, какой бы код ни стоял.
    t.assert_equals(transport.answered({ status = 200, reason = 'Ok' }), false)
end

g.test_end_of_a_stream_is_judged_by_the_code_and_the_word_only = function()
    -- У потока с телом таблицы заголовков нет и после настоящего ответа:
    -- по первой примете он кончался бы обрывом при любом коде.
    t.assert_equals(transport.concluded({ status = 200, reason = 'Ok' }), true)
    t.assert_equals(transport.concluded({ status = 1, reason = 'Ok' }), true)
    t.assert_equals(transport.concluded({ status = 408, reason = 'Unknown' }), true)
    t.assert_equals(transport.concluded({ status = 408, reason = 'Timeout was reached' }), false)
    t.assert_equals(transport.concluded({ status = 0, reason = 'Ok', headers = {} }), false)
end

g.test_stream_is_opened_with_chunked_and_the_options_stay_untouched = function()
    local stream = { headers = {} }
    local handle, asked = handle_of(stream)
    local options = { timeout = 2, headers = { a = 'b' } }

    local raw, err = transport.open(handle, 'POST', 'http://h/watch', '{}', options)

    t.assert_equals(err, nil)
    t.assert_is(raw, stream)
    t.assert_equals(helper.at(asked, 1).method, 'POST')
    t.assert_equals(helper.at(asked, 1).url, 'http://h/watch')
    t.assert_equals(helper.at(asked, 1).body, '{}')
    t.assert_equals(helper.at(asked, 1).options, { timeout = 2, headers = { a = 'b' }, chunked = true })
    t.assert_equals(options.chunked, nil)
end

g.test_stream_that_throws_on_opening_is_a_broken_network = function()
    local handle = handle_of(function()
        error('timed out', 0)
    end)

    local raw, err, reason = transport.open(handle, 'GET', 'http://h/x', nil, {})

    t.assert_equals(raw, nil)
    t.assert_equals(err, 'GET http://h/x: поток не открылся: timed out')
    t.assert_equals(reason, 'поток не открылся: timed out')
end

g.test_stream_that_ended_with_an_invented_code_is_a_broken_network = function()
    -- «Никто не слушает» приходит потоком, кончившимся до возврата вызова.
    local handle = handle_of(helper.no_answer('Could not connect to server'))
    local raw, err, _, sent = transport.open(handle, 'GET', 'http://h/x', nil, {})

    t.assert_equals(raw, nil)
    t.assert_equals(err, 'GET http://h/x: сервер не ответил: Could not connect to server (код 595)')
    t.assert_equals(sent, false)
end

g.test_stream_that_threw_on_opening_could_have_left = function()
    local handle = handle_of(function()
        error('timed out', 0)
    end)

    t.assert_equals(select(4, transport.open(handle, 'POST', 'http://h/x', '{}', {})), true)
end

g.test_stream_that_ended_before_the_return_with_an_answer_is_a_stream = function()
    local finished = helper.answer(200)

    t.assert_is(transport.open(handle_of(finished), 'GET', 'http://h/x', nil, {}), finished)
end
