--- Тесты потока: открытие, чтение кусками, конец, предел и закрытие.

local t = require('luatest')

local g = t.group('tnt.http.stream')

local helper = dofile('test/helper.lua')

--- Ошибки Tarantool: ими бросает `http.client`. Конструктор в аннотациях
--- описан не полностью, поэтому берётся через промежуточную ссылку.
---@type any
local box_error = box.error

---@type any
local http

g.before_each(function()
    http = helper.load('tnt.http')
end)

g.after_each(function()
    helper.forget()
end)

--- Клиент поверх двойника, отвечающего потоком.
---@param script table Как у `helper.stream_of`
---@param opts table|nil Настройки клиента
---@return any client
---@return table sent
---@return table asked
local function client_of(script, opts)
    local sent, asked = helper.streaming(script)

    return (assert(http.new(opts))), sent, asked
end

--- Поток, который обязан открыться.
---@param client any
---@param opts table|nil
---@return any
local function opened(client, opts)
    local stream, err = client:stream(opts or { url = helper.SOMEWHERE })

    t.assert_equals(err, nil)

    return stream
end

g.test_stream_is_addressed_like_a_request = function()
    -- Адрес, параметры, заголовки и сроки собирает тот же код, что
    -- у запроса: два способа собрать одно разошлись бы на первой правке.
    local client, sent = client_of({}, {
        base_url = 'https://h/v1',
        headers = { Authorization = 'Bearer тайна' },
        timeout = 4,
        connect_timeout = 1,
    })

    opened(client, { path = '/events', query = { from = 7 } })

    local request = helper.at(sent, 1)

    t.assert_equals(request.method, 'GET')
    t.assert_equals(request.url, 'https://h/v1/events?from=7')
    t.assert_equals(request.body, nil)
    t.assert_equals(request.options.chunked, true)
    t.assert_equals(request.options.timeout, 5)
    t.assert_equals(request.options.follow_location, false)
    t.assert_equals(request.options.headers.authorization, 'Bearer тайна')
    t.assert_equals(request.options.headers['user-agent'], 'tnt-http')
end

g.test_stream_takes_the_same_tls_and_socket = function()
    local client, sent = client_of({}, {
        verify = false,
        ca_file = '/ca.pem',
        ssl_cert = '/client.pem',
        ssl_key = '/client.key',
        unix_socket = '/run/sidecar.sock',
    })

    opened(client)

    local options = helper.at(sent, 1).options

    t.assert_equals(options.verify_peer, false)
    t.assert_equals(options.verify_host, false)
    t.assert_equals(options.ca_file, '/ca.pem')
    t.assert_equals(options.ssl_cert, '/client.pem')
    t.assert_equals(options.ssl_key, '/client.key')
    t.assert_equals(options.unix_socket, '/run/sidecar.sock')
end

g.test_lines_are_read_by_default_within_the_limit = function()
    -- Читается на байт больше остатка: кусок, ровно добравший до предела,
    -- отдаётся, а перевалить предел может только тот, что перевалил.
    local client, _, asked = client_of({ reads = { 'один\n', 'два\n' } }, { max_body = 100, timeout = 7 })
    local stream = opened(client)

    t.assert_equals(stream:read(), 'один\n')
    t.assert_equals(stream:read(), 'два\n')
    t.assert_equals(helper.at(asked.reads, 1).spec, { delimiter = '\n', chunk = 101 })
    t.assert_equals(helper.at(asked.reads, 2).spec, { delimiter = '\n', chunk = 101 - #'один\n' })
    t.assert_equals(helper.at(asked.reads, 1).timeout, 7)
end

g.test_bytes_are_read_within_the_limit = function()
    local client, _, asked = client_of({ reads = { 'abc', 'de' } }, { max_body = 5 })
    local stream = opened(client)

    t.assert_equals(stream:read(3), 'abc')
    t.assert_equals(stream:read(3, 0.5), 'de')
    t.assert_equals(helper.at(asked.reads, 1).spec, 3)
    t.assert_equals(helper.at(asked.reads, 2).spec, 3)
    t.assert_equals(helper.at(asked.reads, 2).timeout, 0.5)
end

g.test_bytes_near_the_limit_are_asked_for_one_more_than_left = function()
    local client, _, asked = client_of({ reads = { 'abcd', 'e' } }, { max_body = 5 })
    local stream = opened(client)

    stream:read(4)
    stream:read(4)

    t.assert_equals(helper.at(asked.reads, 2).spec, 2)
end

g.test_without_a_limit_the_read_is_passed_as_it_is = function()
    local client, _, asked = client_of({ reads = { 'a\n', 'bc' } }, { max_body = 0 })
    local stream = opened(client)

    stream:read('\n')
    stream:read(1000)

    t.assert_equals(helper.at(asked.reads, 1).spec, '\n')
    t.assert_equals(helper.at(asked.reads, 2).spec, 1000)
end

g.test_piece_that_reaches_the_limit_exactly_is_given = function()
    local client = client_of({ reads = { 'abcde' } }, { max_body = 5 })
    local stream = opened(client)

    t.assert_equals(stream:read(10), 'abcde')
    t.assert_equals({ stream:read(10) }, {})
end

g.test_limit_of_one_byte_is_still_a_limit = function()
    -- Предел в ноль значит «без предела», а в единицу — один байт.
    local client = client_of({ reads = { 'ab' } }, { max_body = 1 })
    local piece, err = opened(client):read(2)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'refused')
end

g.test_sum_of_one_byte_bounds_a_line_too = function()
    local client, _, asked = client_of({ reads = { 'ab' } }, { max_body = 1 })
    local piece, err = opened(client):read('\n')

    t.assert_equals(piece, nil)
    t.assert_equals(err.reason, 'поток больше предела в 1 байт')
    t.assert_equals(helper.at(asked.reads, 1).spec, { delimiter = '\n', chunk = 2 })
end

g.test_piece_limit_of_one_byte_is_still_a_limit = function()
    -- Предел куска в ноль значит «без предела», а в единицу — один байт.
    local client, _, asked = client_of({ reads = { 'ab' } }, { max_body = 0 })
    local stream = opened(client, { url = helper.SOMEWHERE, max_piece = 1 })

    t.assert_equals(
        select(2, stream:read(2)).reason,
        'читать больше предела куска в 1 байт нельзя, а просят 2'
    )

    local piece, err = stream:read('\n')

    t.assert_equals(piece, nil)
    t.assert_equals(err.reason, 'кусок больше предела в 1 байт')
    t.assert_equals(helper.at(asked.reads, 1).spec, { delimiter = '\n', chunk = 2 })
end

g.test_piece_over_the_limit_is_refused_and_the_stream_closed = function()
    local client, _, asked = client_of({ reads = { 'abc', 'def' } }, { max_body = 5 })
    local stream = opened(client)

    stream:read(3)

    local piece, err = stream:read(3)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(
        err.message,
        'GET http://api.example.org/customers: поток больше предела в 5 байт'
    )
    t.assert_equals(asked.finishes, { 0 })
    t.assert_equals(select(2, stream:read(3)), err)
end

g.test_piece_limit_bounds_a_line_when_the_sum_is_unbounded = function()
    -- Наблюдению сумму ставят нулём: без предела куска длина одного кадра
    -- не ограничена ничем.
    local client, _, asked = client_of({ reads = { 'abc\n', 'abcd\n' } }, { max_body = 0 })
    local stream = opened(client, { url = helper.SOMEWHERE, max_piece = 4 })

    t.assert_equals(stream.piece_limit, 4)
    t.assert_equals(stream:read(), 'abc\n')
    t.assert_equals(stream.taken, 4)

    local piece, err = stream:read()

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(
        err.message,
        'GET http://api.example.org/customers: кусок больше предела в 4 байт'
    )
    t.assert_equals(helper.at(asked.reads, 1).spec, { delimiter = '\n', chunk = 5 })
    t.assert_equals(helper.at(asked.reads, 2).spec, { delimiter = '\n', chunk = 5 })
    t.assert_equals(asked.finishes, { 0 })
    t.assert_equals(stream.done, true)
end

g.test_piece_limit_does_not_count_the_sum = function()
    -- Предел куска — не сумма: куски по пределу идут, сколько бы их ни было.
    local client = client_of({ reads = { 'ab\n', 'cd\n', 'ef\n' } }, { max_body = 0 })
    local stream = opened(client, { url = helper.SOMEWHERE, max_piece = 3 })

    t.assert_equals(stream:read(), 'ab\n')
    t.assert_equals(stream:read(), 'cd\n')
    t.assert_equals(stream:read(), 'ef\n')
end

g.test_smaller_of_the_two_limits_bounds_the_read = function()
    local client, _, asked = client_of({ reads = { 'abcdef', 'gh\n', 'ij\n' } }, { max_body = 10 })
    local stream = opened(client, { url = helper.SOMEWHERE, max_piece = 6 })

    -- Остаток суммы больше предела куска: читается по пределу куска.
    t.assert_equals(stream:read(), 'abcdef')
    -- Остаток суммы — четыре байта, меньше предела куска.
    t.assert_equals(stream:read(), 'gh\n')
    t.assert_equals(helper.at(asked.reads, 1).spec, { delimiter = '\n', chunk = 7 })
    t.assert_equals(helper.at(asked.reads, 2).spec, { delimiter = '\n', chunk = 5 })

    local piece, err = stream:read()

    t.assert_equals(piece, nil)
    t.assert_equals(helper.at(asked.reads, 3).spec, { delimiter = '\n', chunk = 2 })
    t.assert_equals(err.reason, 'поток больше предела в 10 байт')
end

g.test_piece_over_both_limits_is_told_by_the_sum = function()
    -- Сумма судится первой: поток, отдавший своё, кончился бы и на куске
    -- по пределу.
    local client = client_of({ reads = { 'abcd' } }, { max_body = 3 })
    local stream = opened(client, { url = helper.SOMEWHERE, max_piece = 3 })

    t.assert_equals(select(2, stream:read()).reason, 'поток больше предела в 3 байт')
end

g.test_bytes_are_not_asked_over_the_piece_limit = function()
    -- Чтению байтами предел ставит само число: просить больше предела
    -- куска — ошибка вызывающего, и поток остаётся открытым.
    local client, _, asked = client_of({ reads = { 'abc', 'de' } }, { max_body = 0 })
    local stream = opened(client, { url = helper.SOMEWHERE, max_piece = 3 })

    local piece, err = stream:read(4)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(
        err.reason,
        'читать больше предела куска в 3 байт нельзя, а просят 4'
    )
    t.assert_equals(#asked.reads, 0)
    t.assert_equals(stream.done, false)
    t.assert_equals(stream:read(3), 'abc')
    t.assert_equals(helper.at(asked.reads, 1).spec, 3)
    t.assert_equals(stream:read(2), 'de')
    t.assert_equals(helper.at(asked.reads, 2).spec, 2)
end

g.test_bytes_under_both_limits_are_bounded_by_the_sum = function()
    local client, _, asked = client_of({ reads = { 'abcd', 'e' } }, { max_body = 5 })
    local stream = opened(client, { url = helper.SOMEWHERE, max_piece = 4 })

    stream:read(4)
    stream:read(4)

    t.assert_equals(helper.at(asked.reads, 1).spec, 4)
    t.assert_equals(helper.at(asked.reads, 2).spec, 2)
end

g.test_stream_without_a_piece_limit_has_none = function()
    local client, _, asked = client_of({ reads = { string.rep('я', 100) .. '\n' } }, { max_body = 0 })
    local stream = opened(client)

    t.assert_equals(stream.piece_limit, 0)
    t.assert_equals(stream:read(), string.rep('я', 100) .. '\n')
    t.assert_equals(helper.at(asked.reads, 1).spec, '\n')
end

g.test_stream_that_ends_well_has_its_status = function()
    local client, _, asked = client_of({ reads = { 'a' }, headers = { ['X-Mark'] = 'да' } })
    local stream = opened(client)

    t.assert_equals(stream.headers, { ['x-mark'] = 'да' })
    t.assert_equals(stream.status, nil)
    t.assert_equals(stream:read(1), 'a')

    local piece, err = stream:read(1)

    t.assert_equals(piece, nil)
    t.assert_equals(err, nil)
    t.assert_equals(stream.status, 200)
    t.assert_equals(stream.reason, 'Ok')
    t.assert_equals(helper.at(asked.finishes, 1), 0)
    -- Читать после конца можно: вернётся то же, чем поток кончился.
    t.assert_equals({ stream:read(1) }, {})
end

g.test_code_outside_success_comes_as_a_refusal_at_the_end = function()
    -- Код потока известен только в конце: страница ошибки уже прочитана,
    -- и сказать о ней можно лишь последним чтением.
    local client = client_of({ reads = { 'no such thing' }, finished = { status = 404, reason = 'Unknown' } })
    local stream = opened(client)

    t.assert_equals(stream:read(100), 'no such thing')

    local piece, err = stream:read(100)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'status')
    t.assert_equals(err.status, 404)
    t.assert_equals(err.retriable, false)
    t.assert_equals(err.reason, 'сервер ответил 404 Unknown')
    t.assert_equals(stream.status, 404)
end

g.test_code_of_the_lowest_success_and_failure_are_told_apart = function()
    local ok = opened((client_of({ finished = { status = 299, reason = 'Ok' } })))

    t.assert_equals({ ok:read() }, {})

    local failed = opened((client_of({ finished = { status = 300, reason = 'Ok' } })))

    t.assert_equals(select(2, failed:read()).kind, 'status')
end

g.test_transient_code_at_the_end_is_worth_reopening = function()
    local client = client_of({ finished = { status = 503, reason = 'Unknown' } })

    t.assert_equals(select(2, opened(client):read()).retriable, true)
end

g.test_break_in_the_middle_is_a_refusal_and_not_an_end = function()
    -- Обрыв читается концом, и отличает его только код: libcurl оставляет
    -- ноль вместо кода сервера.
    local client = client_of({ reads = { 'part 1\n' }, finished = { status = 0 } })
    local stream = opened(client)

    stream:read()

    local piece, err = stream:read()

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.retriable, true)
    t.assert_equals(err.reason, 'поток оборвался: сервер не ответил: nil (код 0)')
    t.assert_equals(stream.status, nil)
end

g.test_break_of_a_post_is_not_worth_repeating = function()
    local client = client_of({ finished = { status = 0 } })
    local stream = opened(client, { url = helper.SOMEWHERE, method = 'POST' })

    t.assert_equals(select(2, stream:read()).retriable, false)
end

g.test_silence_is_told_and_the_stream_stays_open = function()
    -- Срок чтения — не обрыв: наблюдению он нужен, чтобы проверить, не пора
    -- ли остановиться, а данные приходят следующим чтением.
    local client, _, asked = client_of({ reads = { helper.idle(), 'позже\n' } })
    local stream = opened(client)

    local piece, err = stream:read('\n', 0.25)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'idle')
    t.assert_equals(err.reason, 'за 0.25 с кусок не собрался')
    t.assert_equals(asked.finishes, {})
    t.assert_equals(stream:read(), 'позже\n')
end

g.test_bytes_without_a_piece_by_the_deadline_are_idle_and_not_a_throw = function()
    -- Поток, шлющий байты без разделителя, `http.client` к сроку не бросает,
    -- а возвращает `nil`. Прежде это роняло чтение на длине `nil`, и поток
    -- оставался открытым у того, кто его уже не закроет.
    local client, _, asked = client_of({ reads = { helper.unfinished(), 'хвост\n' } }, { max_body = 0 })
    local stream = opened(client)

    local piece, err = stream:read('\n', 0.5)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'idle')
    t.assert_equals(err.reason, 'за 0.5 с кусок не собрался')
    t.assert_equals(stream.done, false)
    t.assert_equals(stream.taken, 0)
    t.assert_equals(asked.finishes, {})
    t.assert_equals(stream:read(), 'хвост\n')
end

g.test_close_from_another_fiber_while_reading_keeps_its_outcome = function()
    -- `finish` будит читающего так же, как обрыв: пустой строкой с кодом
    -- libcurl. Итог закрытия обязан уцелеть — иначе остановку не отличить
    -- от сети.
    ---@type any
    local stream
    local client, _, asked = client_of({
        reads = {
            function()
                stream:close()

                return ''
            end,
        },
        finished = { status = 408, reason = 'Timeout was reached' },
    })

    stream = opened(client)

    local piece, err = stream:read()

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.reason, 'поток закрыт')
    t.assert_equals(asked.finishes, { 0 })
    t.assert_equals(select(2, stream:read()), err)
end

g.test_close_from_another_fiber_while_writing_keeps_its_outcome = function()
    ---@type any
    local stream
    local client = client_of({
        write = function()
            stream:close()

            error('io: request is finished', 0)
        end,
    })

    stream = opened(client, { url = helper.SOMEWHERE, method = 'POST', duplex = true })

    local ok, err = stream:write('x')

    t.assert_equals(ok, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.reason, 'поток закрыт')
    t.assert_equals(select(2, stream:read()), err)
end

g.test_other_throw_while_reading_closes_the_stream = function()
    local client, _, asked = client_of({ reads = { { raises = 'curl: Recv failure' } } })
    local stream = opened(client)

    local piece, err = stream:read()

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.reason, 'поток оборвался: curl: Recv failure')
    t.assert_equals(asked.finishes, { 0 })
end

g.test_read_asked_wrongly_is_refused_and_the_stream_stays_open = function()
    local client, _, asked = client_of({ reads = { 'abc' } })
    local stream = opened(client)

    for _, what in ipairs({ 0, 1.5, '', {} }) do
        local piece, err = stream:read(what)

        t.assert_equals(piece, nil)
        t.assert_equals(err.kind, 'invalid')
    end

    t.assert_str_contains(
        select(2, stream:read(0)).reason,
        'целым числом байт больше нуля, а пришло 0'
    )
    t.assert_str_contains(select(2, stream:read({})).reason, 'числом байт или разделителем')
    t.assert_equals(#asked.reads, 0)
    t.assert_equals(stream:read(1), 'abc')
end

g.test_timeout_shorter_than_a_millisecond_is_refused = function()
    -- Ноль у `http.client` на идущем потоке значит «поток кончился»:
    -- чтение с нулевым сроком отдало бы пустую строку, как настоящий конец.
    local client, _, asked = client_of({ reads = { 'a' } })
    local stream = opened(client)

    local piece, err = stream:read(1, 0)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.reason, 'срок — число секунд не меньше 0.001, а пришло 0')
    t.assert_equals(select(2, stream:read(1, 'скоро')).kind, 'invalid')
    t.assert_equals(#asked.reads, 0)
    t.assert_equals(stream:read(1, 0.001), 'a')
end

g.test_close_breaks_the_transfer_once_and_may_be_repeated = function()
    local client, _, asked = client_of({ reads = { 'a' } })
    local stream = opened(client)

    t.assert_equals(stream:close(), true)
    t.assert_equals(stream:close(), true)
    t.assert_equals(asked.finishes, { 0 })

    local piece, err = stream:read()

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.reason, 'поток закрыт')
end

g.test_close_after_the_end_does_not_break_anything = function()
    local client, _, asked = client_of({})
    local stream = opened(client)

    stream:read()

    t.assert_equals(stream:close(), true)
    t.assert_equals({ stream:read() }, {})
    t.assert_equals(#asked.finishes, 2)
end

g.test_body_goes_at_the_opening_and_the_sending_is_closed = function()
    -- Сервер, дочитывающий тело запроса до конца, иначе ждал бы
    -- продолжения и не ответил вовсе.
    local client, sent, asked = client_of({}, { timeout = 6 })

    opened(client, { url = helper.SOMEWHERE, method = 'POST', json = { key = 'k' } })

    t.assert_equals(helper.at(sent, 1).method, 'POST')
    t.assert_equals(helper.at(sent, 1).body, '{"key":"k"}')
    t.assert_equals(helper.at(sent, 1).options.headers['content-type'], 'application/json')
    t.assert_equals(asked.writes, { { data = '', timeout = 6 } })
end

g.test_sending_that_cannot_be_closed_closes_the_stream = function()
    local client, _, asked = client_of({
        write = function()
            error('io: request must be io', 0)
        end,
    })

    local stream, err = client:stream({ url = helper.SOMEWHERE, method = 'PUT', body = 'x' })

    t.assert_equals(stream, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.reason, 'тело не ушло: io: request must be io')
    t.assert_equals(asked.finishes, { 0 })
end

g.test_duplex_keeps_the_sending_open_for_writes = function()
    local client, _, asked = client_of({ reads = { '{"created":true}\n' } }, { timeout = 3 })
    local stream = opened(client, { url = helper.SOMEWHERE, method = 'PATCH', duplex = true })

    t.assert_equals(asked.writes, {})
    t.assert_equals(stream:write('{"create_request":{}}'), true)
    t.assert_equals(stream:write('ещё', 0.5), true)
    t.assert_equals(asked.writes, {
        { data = '{"create_request":{}}', timeout = 3 },
        { data = 'ещё', timeout = 0.5 },
    })
    t.assert_equals(stream:read(), '{"created":true}\n')
end

g.test_write_to_a_stream_without_duplex_is_refused = function()
    local client, _, asked = client_of({})
    local stream = opened(client, { url = helper.SOMEWHERE, method = 'POST' })

    local ok, err = stream:write('x')

    t.assert_equals(ok, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_str_contains(err.reason, 'duplex')
    t.assert_equals(#asked.writes, 1)
end

g.test_write_asked_wrongly_is_refused = function()
    local client, _, asked = client_of({})
    local stream = opened(client, { url = helper.SOMEWHERE, method = 'POST', duplex = true })

    t.assert_equals(
        select(2, stream:write('')).reason,
        'писать — непустой строкой, а пришло string'
    )
    t.assert_equals(select(2, stream:write(7)).kind, 'invalid')
    t.assert_equals(select(2, stream:write('x', 0)).kind, 'invalid')
    t.assert_equals(asked.writes, {})

    stream:close()

    t.assert_equals(select(2, stream:write('x')).reason, 'поток кончился: писать некуда')
end

g.test_write_that_throws_closes_the_stream = function()
    local client, _, asked = client_of({
        write = function()
            error(box_error.new({ type = 'TimedOut', reason = 'timed out' }))
        end,
    })

    local stream = opened(client, { url = helper.SOMEWHERE, method = 'POST', duplex = true })
    local ok, err = stream:write('x')

    t.assert_equals(ok, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.reason, 'тело не ушло: timed out')
    t.assert_equals(asked.finishes, { 0 })
end

g.test_write_after_the_server_finished_closes_the_stream = function()
    -- Меньше, чем просили, `http.client` отдаёт, когда передача кончилась.
    local client = client_of({
        write = function()
            return 0
        end,
    })

    local stream = opened(client, { url = helper.SOMEWHERE, method = 'POST', duplex = true })
    local ok, err = stream:write('x')

    t.assert_equals(ok, nil)
    t.assert_equals(err.reason, 'тело не ушло: сервер уже закончил поток')
    t.assert_equals(stream.done, true)
end

g.test_body_of_a_method_without_one_is_refused_before_the_opening = function()
    -- Тело потока `http.client` шлёт только у POST, PUT и PATCH; прочим
    -- оно не уходит вовсе.
    local client, sent = client_of({})

    for _, opts in ipairs({
        { url = helper.SOMEWHERE, json = { a = 1 } },
        { url = helper.SOMEWHERE, method = 'DELETE', body = 'x' },
        { url = helper.SOMEWHERE, duplex = true },
    }) do
        local stream, err = client:stream(opts)

        t.assert_equals(stream, nil)
        t.assert_equals(err.kind, 'invalid')
        t.assert_str_contains(err.reason, 'только у POST, PUT и PATCH')
    end

    t.assert_equals(#sent, 0)
end

g.test_stream_that_did_not_open_is_a_refusal = function()
    local client = client_of({ refuses = 'timed out' })
    local stream, err = client:stream({ url = helper.SOMEWHERE })

    t.assert_equals(stream, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.retriable, true)
    t.assert_equals(err.message, 'GET http://api.example.org/customers: поток не открылся: timed out')
    t.assert_equals(err.reason, 'поток не открылся: timed out')
end

g.test_stream_of_a_post_that_did_not_open_is_not_worth_repeating = function()
    local client = client_of({ refuses = 'timed out' })

    t.assert_equals(select(2, client:stream({ url = helper.SOMEWHERE, method = 'POST' })).retriable, false)
end

g.test_stream_settings_are_checked_by_name = function()
    -- Переходов и повторов у потока нет, и их настройки — отказ, а не
    -- молчаливое «не действует».
    local client, sent = client_of({})

    for _, name in ipairs({ 'retry', 'max_redirects', 'strem' }) do
        local stream, err = client:stream({ url = helper.SOMEWHERE, [name] = 1 })

        t.assert_equals(stream, nil)
        t.assert_equals(err.kind, 'invalid')
        t.assert_str_contains(tostring(err), name)
    end

    t.assert_equals(select(2, client:stream({ url = '/relative' })).kind, 'invalid')
    t.assert_equals(#sent, 0)
end

g.test_shared_client_opens_a_stream_too = function()
    local sent = helper.streaming({ reads = { 'a\n' } })
    local stream = assert(http.stream({ url = helper.SOMEWHERE }))

    t.assert_equals(stream:read(), 'a\n')
    t.assert_equals(#sent, 1)
end
