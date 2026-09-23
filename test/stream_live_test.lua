--- Поток против настоящего сервера.
---
--- Двойник потока повторяет то, что `http.client` отдавал на опытах, но
--- проверяет лишь, что мы понимаем свой пересказ. httpbin показывает, что
--- пересказ верен: куски приходят по мере отправки, молчание между ними
--- длится по-настоящему, код ответа появляется только в конце, а тело
--- запроса уходит `chunked` и дочитывается сервером до конца.
---
--- Сервер поднимается отдельно — `test/stand/httpbin.sh`, — и если его
--- нет, проверки честно пропускаются: гейты не должны зависеть от докера.

local t = require('luatest')
local json = require('json')

local g = t.group('tnt.http.stream_live')

local helper = dofile('test/helper.lua')

---@type any
local http

--- Где стоит httpbin: тот же адрес, что поднимает скрипт стенда.
local HOST = '127.0.0.1'
local PORT = 18080

--- Клиент, настроенный на стенд; проверка пропускается, если стенда нет.
---@param opts table|nil
---@return any
local function client_of(opts)
    t.skip_if(not helper.listening(HOST, PORT), 'httpbin не отвечает: test/stand/httpbin.sh')

    local settings = { base_url = ('http://%s:%d'):format(HOST, PORT) }

    return (assert(http.new(helper.merged(settings, opts))))
end

--- Дочитывает поток до конца.
---@param stream any
---@param what integer|string|nil
---@return string[] pieces
---@return any err Чем кончился поток
local function drained(stream, what)
    local pieces = {}

    while true do
        local piece, err = stream:read(what, 5)

        if piece == nil then
            stream:close()

            return pieces, err
        end

        table.insert(pieces, piece)
    end
end

g.before_each(function()
    http = helper.load('tnt.http')
end)

g.after_each(function()
    helper.unload()
end)

g.test_lines_of_a_stream_come_one_by_one = function()
    local stream = assert(client_of():stream({ path = '/stream/5' }))
    local lines, err = drained(stream)
    local ids = {}

    for _, line in ipairs(lines) do
        table.insert(ids, json.decode(line).id)
    end

    t.assert_equals(err, nil)
    t.assert_equals(ids, { 0, 1, 2, 3, 4 })
    t.assert_equals(stream.status, 200)
    t.assert_str_contains(stream.headers['content-type'], 'application/json')
end

g.test_silence_between_drops_is_told_and_the_stream_goes_on = function()
    -- httpbin роняет по байту раз в полсекунды: чтение со сроком короче
    -- паузы молчит, а следующее дочитывает то, что пришло после.
    local stream = assert(client_of():stream({ path = '/drip', query = { numbytes = 3, duration = 1.5, delay = 0 } }))

    t.assert_equals(stream:read(1, 5), '*')

    local piece, err = stream:read(1, 0.1)

    t.assert_equals(piece, nil)
    t.assert_equals(err.kind, 'idle')

    local rest, ended = drained(stream, 2)

    t.assert_equals(table.concat(rest), '**')
    t.assert_equals(ended, nil)
end

g.test_code_outside_success_comes_at_the_end = function()
    local stream = assert(client_of():stream({ path = '/status/404' }))
    local pieces, err = drained(stream)

    t.assert_equals(pieces, {})
    t.assert_equals(err.kind, 'status')
    t.assert_equals(err.status, 404)
    t.assert_equals(stream.status, 404)
end

g.test_stream_over_the_limit_is_cut = function()
    local stream = assert(client_of({ max_body = 1000 }):stream({ path = '/stream/20' }))
    local pieces, err = drained(stream)

    t.assert_equals(err.kind, 'refused')
    t.assert_str_contains(err.reason, 'больше предела в 1000 байт')
    t.assert_equals(#table.concat(pieces) <= 1000, true)
end

g.test_line_over_the_piece_limit_is_cut_when_the_sum_is_unbounded = function()
    -- Строки httpbin — по паре сотен байт: предел куска в сотню режет
    -- первую же, хотя суммы у потока нет вовсе.
    local stream = assert(client_of():stream({ path = '/stream/20', max_body = 0, max_piece = 100 }))
    local pieces, err = drained(stream)

    t.assert_equals(pieces, {})
    t.assert_equals(err.kind, 'refused')
    t.assert_str_contains(err.reason, 'кусок больше предела в 100 байт')

    local whole = assert(client_of():stream({ path = '/stream/3', max_body = 0, max_piece = 4096 }))
    local lines, ended = drained(whole)

    t.assert_equals(#lines, 3)
    t.assert_equals(ended, nil)
end

g.test_body_of_a_stream_reaches_the_server_whole = function()
    -- Тело потока уходит `chunked`, и отправку клиент закрывает сам: иначе
    -- сервер ждал бы продолжения тела и не ответил вовсе.
    local stream = assert(client_of():stream({
        path = '/anything',
        method = 'POST',
        json = { name = 'Иванов', tags = { 'a', 'b' } },
    }))

    local pieces, err = drained(stream, 4096)
    local echoed = json.decode(table.concat(pieces))

    t.assert_equals(err, nil)
    t.assert_equals(echoed.method, 'POST')
    t.assert_equals(echoed.json, { name = 'Иванов', tags = { 'a', 'b' } })
    t.assert_equals(echoed.headers['User-Agent'], 'tnt-http')
end
