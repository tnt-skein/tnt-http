--- Клиент против настоящего сервера.
---
--- Двойник показывает, что мы правильно разговариваем сами с собой.
--- Настоящий сервер показывает, что нас понимает кто-то ещё, — а это
--- разные утверждения: libcurl добавляет от себя заголовки, которых
--- в двойнике не было, сжимает и разжимает тело, а `Location` приходит
--- относительной ссылкой там, где двойник отдавал абсолютную.
---
--- Сервер поднимается отдельно — `test/stand/httpbin.sh`, — и если его
--- нет, проверки честно пропускаются: гейты не должны зависеть от докера.

local t = require('luatest')

local g = t.group('tnt.http.live')

local helper = dofile('test/helper.lua')

---@type any
local http

--- Где стоит httpbin: тот же адрес, что поднимает скрипт стенда.
local HTTPBIN = { host = '127.0.0.1', port = 18080 }

--- Адрес стенда целиком.
local BASE = ('http://%s:%d'):format(HTTPBIN.host, HTTPBIN.port)

--- Клиент, настроенный на стенд; проверка пропускается, если стенда нет.
---
--- Повторов по одной попытке нарочно: httpbin отвечает 503 ровно так же
--- и со второй, и с третьей попытки, а проверка ждала бы паузы между ними.
---@param opts table|nil
---@return any
local function client_of(opts)
    t.skip_if(not helper.listening(HTTPBIN.host, HTTPBIN.port), 'httpbin не отвечает: test/stand/httpbin.sh')

    local settings = { base_url = BASE, retry = { attempts = 1 } }

    return (assert(http.new(helper.merged(settings, opts))))
end

g.before_each(function()
    http = helper.load('tnt.http')
end)

g.after_each(function()
    helper.unload()
end)

g.test_query_reaches_the_server_as_it_was_written = function()
    -- Кириллица и списки — то место, где кодировщики расходятся чаще
    -- всего: сервер обязан прочитать ровно то, что написал разработчик.
    local answer = client_of():get('/get', { query = { ['имя'] = 'Пётр', tag = { 'a', 'b' } } })
    local echoed = answer:raise():json()

    t.assert_equals(echoed.args['имя'], 'Пётр')
    t.assert_equals(echoed.args.tag, { 'a', 'b' })
end

g.test_client_introduces_itself_to_a_real_server = function()
    local echoed = client_of():get('/get'):raise():json()

    t.assert_equals(echoed.headers['User-Agent'], 'tnt-http')
end

g.test_json_body_arrives_as_json = function()
    local answer = client_of():post('/post', { json = { name = 'Иванов', age = 40 } })
    local echoed = answer:raise():json()

    t.assert_equals(echoed.json, { name = 'Иванов', age = 40 })
    t.assert_equals(echoed.headers['Content-Type'], 'application/json')
end

g.test_form_body_arrives_as_a_form = function()
    local answer = client_of():post('/post', { form = { name = 'Иванов', tag = { 'a', 'b' } } })
    local echoed = answer:raise():json()

    t.assert_equals(echoed.form.name, 'Иванов')
    t.assert_equals(echoed.form.tag, { 'a', 'b' })
end

g.test_answer_headers_come_back_in_lower_case = function()
    -- httpbin отвечает `Content-Type`, а код читает `content-type`.
    local answer = client_of():get('/get')

    t.assert_str_contains(answer.headers['content-type'], 'application/json')
end

g.test_redirect_is_followed_to_the_end = function()
    local answer = client_of():get('/redirect-to', {
        query = { url = '/get', status_code = 302 },
    })

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.url, BASE .. '/get')
end

g.test_redirect_is_not_followed_when_the_limit_is_zero = function()
    local answer = client_of({ max_redirects = 0 }):get('/redirect-to', {
        query = { url = '/get', status_code = 302 },
    })

    t.assert_equals(answer.status, 302)
    t.assert_equals(answer.headers.location, '/get')
end

g.test_too_many_redirects_are_refused = function()
    local answer, err = client_of({ max_redirects = 2 }):get('/redirect/5')

    t.assert_equals(answer, nil)
    t.assert_str_contains(tostring(err), 'переходов больше 2')
end

g.test_server_trouble_is_an_answer_and_raise_turns_it_into_a_fall = function()
    local answer, err = client_of():get('/status/500')

    t.assert_equals(err, nil)
    t.assert_equals(answer.status, 500)
    t.assert_equals(pcall(answer.raise, answer), false)
end

g.test_oversized_answer_is_refused = function()
    -- Чужой сервер вправе прислать сколько угодно, а узел не обязан это
    -- принимать.
    local answer, err = client_of({ max_body = 1024 }):get('/bytes/4096')

    t.assert_equals(answer, nil)
    t.assert_str_contains(tostring(err), 'больше предела в 1024')
end

g.test_compressed_answer_is_unpacked_on_the_way = function()
    -- Сжатие спрашивается по умолчанию, а разжимает его libcurl сам:
    -- вызывающий видит обычный JSON.
    local echoed = client_of():get('/gzip'):raise():json()

    t.assert_equals(echoed.gzipped, true)
end

g.test_slow_server_runs_out_of_time = function()
    -- Сроки складываются: `http.client` знает один срок на обращение,
    -- и молчащий сервер держит попытку оба срока, а не только срок ответа.
    local client = client_of({ timeout = 0.4, connect_timeout = 0.4 })
    local started = require('clock').monotonic()
    local answer, err = client:get('/delay/3')
    local elapsed = require('clock').monotonic() - started

    t.assert_equals(answer, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_str_contains(tostring(err), 'сервер не ответил')
    t.assert_almost_equals(elapsed, 0.8, 0.2)
end

g.test_head_brings_headers_without_a_body = function()
    local answer = client_of():head('/get')

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.body, '')
    t.assert_str_contains(answer.headers['content-type'], 'application/json')
end

g.test_nobody_listening_is_a_refusal = function()
    -- Порт стенда плюс один: на нём заведомо никого нет.
    local client = client_of({ base_url = ('http://%s:%d'):format(HTTPBIN.host, HTTPBIN.port + 1) })
    local answer, err = client:get('/get')

    t.assert_equals(answer, nil)
    t.assert_str_contains(tostring(err), 'сервер не ответил')
end
