--- Тесты ответа: заголовки, разбор, бросок на чужом отказе.

local t = require('luatest')

local g = t.group('tnt.http.response')

local helper = dofile('test/helper.lua')

---@type any
local response

--- Запрос, на который якобы пришёл ответ.
local REQUEST = { method = 'GET', url = 'https://api.example.org/customers/7' }

g.before_each(function()
    response = helper.load('tnt.http.response')
end)

g.after_each(function()
    helper.unload()
end)

g.test_header_names_are_lowered = function()
    -- Один сервер пишет Content-Type, другой content-type: код, читающий
    -- ответ по точному имени, работает ровно до смены сервера.
    local answer = response.new(helper.json_answer('{}'), REQUEST)

    t.assert_equals(answer.headers['content-type'], 'application/json')
end

g.test_answer_remembers_where_it_came_from = function()
    local answer = response.new(helper.answer(200, { body = 'да' }), REQUEST)

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.body, 'да')
    t.assert_equals(answer.url, REQUEST.url)
    t.assert_equals(answer.method, 'GET')
end

g.test_missing_reason_and_body_become_empty_strings = function()
    -- HTTP/2 не передаёт причину словами вовсе, а у HEAD нет тела:
    -- `nil` в этих полях спотыкается на первой же склейке сообщения.
    local answer = response.new({ status = 204, headers = {} }, REQUEST)

    t.assert_equals(answer.reason, '')
    t.assert_equals(answer.body, '')
end

g.test_only_two_hundreds_are_counted_as_success = function()
    t.assert_equals(response.new(helper.answer(200), REQUEST):ok(), true)
    t.assert_equals(response.new(helper.answer(299), REQUEST):ok(), true)
    t.assert_equals(response.new(helper.answer(199), REQUEST):ok(), false)
    t.assert_equals(response.new(helper.answer(300), REQUEST):ok(), false)
end

g.test_body_is_parsed_as_json_on_demand = function()
    local answer = response.new(helper.json_answer('{"page":2}'), REQUEST)

    t.assert_equals(answer:json(), { page = 2 })
end

g.test_rubbish_instead_of_json_is_refused_with_a_reason = function()
    local answer = response.new(helper.answer(200, { body = 'не json' }), REQUEST)
    local value, err = answer:json()

    t.assert_equals(value, nil)
    t.assert_str_contains(err, 'не разобран как JSON')
end

g.test_raise_lets_a_good_answer_through = function()
    local answer = response.new(helper.answer(200), REQUEST)

    t.assert_equals(answer:raise(), answer)
end

g.test_raise_tells_who_refused_and_what_they_said = function()
    local answer = response.new(helper.answer(500, { reason = 'Internal Server Error', body = 'упало' }), REQUEST)

    local ok, err = pcall(answer.raise, answer)

    t.assert_equals(ok, false)
    -- Дословно, а не по куску: приписка места вызова («response.lua:75:»)
    -- ломает такое сравнение, откуда бы она ни взялась.
    t.assert_equals(err, 'GET https://api.example.org/customers/7: 500 Internal Server Error; упало')
end

g.test_headers_of_nothing_are_an_empty_table = function()
    t.assert_equals(response.headers_of(nil), {})
end
