--- Тесты тела запроса и разбора тела ответа.

local t = require('luatest')

local g = t.group('tnt.http.body')

local helper = dofile('test/helper.lua')

---@type any
local body

g.before_each(function()
    body = helper.load('tnt.http.body')
end)

g.after_each(function()
    helper.unload()
end)

g.test_request_without_body_carries_nothing = function()
    local rendered = body.render({})

    t.assert_equals(rendered.body, nil)
    t.assert_equals(rendered.content_type, nil)
end

g.test_json_is_encoded_and_marked = function()
    -- Забытый content-type — самая частая причина ответа 415 от чужой
    -- службы, и ищется он дольше всего.
    local rendered = body.render({ json = { name = 'Иванов' } })

    t.assert_equals(rendered.body, '{"name":"Иванов"}')
    t.assert_equals(rendered.content_type, 'application/json')
end

g.test_form_is_encoded_like_a_query = function()
    local rendered = body.render({ form = { b = 2, a = 'два слова' } })

    t.assert_equals(rendered.body, 'a=%D0%B4%D0%B2%D0%B0%20%D1%81%D0%BB%D0%BE%D0%B2%D0%B0&b=2')
    t.assert_equals(rendered.content_type, 'application/x-www-form-urlencoded')
end

g.test_ready_string_goes_as_it_is = function()
    -- Без заголовка: вид такого тела знает только вызывающий.
    local rendered = body.render({ body = '<xml/>' })

    t.assert_equals(rendered.body, '<xml/>')
    t.assert_equals(rendered.content_type, nil)
end

g.test_two_ways_at_once_are_refused = function()
    -- Не «одно дополняет другое», а два разных намерения: угадывать,
    -- какое главнее, значит однажды угадать не так.
    local rendered, err = body.render({ json = {}, body = 'x' })

    t.assert_equals(rendered, nil)
    t.assert_equals(err, 'тело задано дважды: json и body — оставьте что-то одно')
end

g.test_table_in_body_is_refused_by_name = function()
    local rendered, err = body.render({ body = { name = 'Иванов' } })

    t.assert_equals(rendered, nil)
    t.assert_str_contains(err, 'body — это готовая строка, а пришло table')
end

g.test_json_that_cannot_be_encoded_is_refused = function()
    -- Уронить этим запрос значит уронить узел из-за опечатки в теле.
    local rendered, err = body.render({ json = { call = print } })

    t.assert_equals(rendered, nil)
    t.assert_str_contains(err, 'тело не собралось в JSON')
end

g.test_form_that_cannot_be_encoded_is_refused = function()
    local rendered, err = body.render({ form = { call = print } })

    t.assert_equals(rendered, nil)
    t.assert_str_contains(err, 'тело формы не собралось')
    t.assert_str_contains(err, 'параметр call')
end

g.test_json_answer_is_parsed = function()
    t.assert_equals(body.parse('{"page":2}'), { page = 2 })
end

g.test_empty_answer_says_so = function()
    local value, err = body.parse('')

    t.assert_equals(value, nil)
    t.assert_equals(err, 'ответ пуст: разбирать как JSON нечего')
    t.assert_equals(select(2, body.parse(nil)), 'ответ пуст: разбирать как JSON нечего')
end

g.test_broken_json_shows_the_beginning_of_the_answer = function()
    -- Чаще всего это страница ошибки прокси, и по одному слову
    -- «invalid token» этого не понять.
    local value, err = body.parse('<html>502 Bad Gateway</html>')

    t.assert_equals(value, nil)
    t.assert_str_contains(err, 'ответ не разобран как JSON')
    t.assert_str_contains(err, '502 Bad Gateway')
end

g.test_long_answer_is_cut_and_marked = function()
    -- Двести знаков: хватает узнать страницу ошибки прокси и мало,
    -- чтобы залить журнал чужим ответом целиком. Ответ ровно в двести
    -- знаков не режется — резать в нём нечего.
    t.assert_equals(body.FRAGMENT, 200)
    t.assert_equals(body.fragment(('x'):rep(201)), ('x'):rep(200) .. '…')
    t.assert_equals(body.fragment(('x'):rep(200)), ('x'):rep(200))
    t.assert_equals(body.fragment('коротко'), 'коротко')
end
