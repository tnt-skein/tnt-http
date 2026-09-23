--- Тесты адресов: кодирование, параметры, склейка и разбор.

local t = require('luatest')

local g = t.group('tnt.http.url')

local helper = dofile('test/helper.lua')

---@type any
local url

g.before_each(function()
    url = helper.load('tnt.http.url')
end)

g.after_each(function()
    helper.unload()
end)

g.test_unreserved_letters_are_left_alone = function()
    -- Кодировать их нельзя: `%41` вместо `A` законен, но чужой сервер
    -- сравнивает подпись запроса побайтно и на такой строке не сойдётся.
    t.assert_equals(url.encode('aBZ09-._~'), 'aBZ09-._~')
end

g.test_space_is_encoded_as_percent_twenty = function()
    -- Не плюсом: плюс законен только в теле формы, а `%20` понимают
    -- и путь, и параметр, и форма.
    t.assert_equals(url.encode('два слова'), '%D0%B4%D0%B2%D0%B0%20%D1%81%D0%BB%D0%BE%D0%B2%D0%B0')
end

g.test_low_byte_is_encoded_with_leading_zero = function()
    -- `%A` вместо `%0A` — не процентная последовательность вовсе:
    -- сервер прочитает её как знак процента и букву.
    t.assert_equals(url.encode('\n'), '%0A')
end

g.test_number_is_encoded_as_its_text = function()
    t.assert_equals(url.encode(42), '42')
end

g.test_absolute_address_is_told_from_relative = function()
    t.assert_equals(url.is_absolute('https://example.org/x'), true)
    t.assert_equals(url.is_absolute('/x'), false)
end

g.test_schemes_of_any_shape_are_recognised = function()
    -- Схема бывает и в одну букву, и с плюсом внутри: `git+ssh` — такая
    -- же схема, как `https`, и не узнать её значит счесть адрес неполным.
    t.assert_equals(url.is_absolute('a://h'), true)
    t.assert_equals(url.is_absolute('git+ssh://h/x'), true)
end

g.test_scheme_is_read_in_lower_case = function()
    t.assert_equals(url.scheme('HTTPS://example.org/x'), 'https')
    t.assert_equals(url.scheme('file:///etc/hosts'), 'file')
    t.assert_equals(url.scheme('/x'), '')
end

g.test_only_the_web_is_walked = function()
    -- Выписано здесь, а не взято из модуля: список, сверенный с собой же,
    -- сходится при любом содержимом.
    t.assert_equals(url.WEB, { http = true, https = true })
end

g.test_query_is_sorted_by_name = function()
    -- Порядок `pairs` не определён, и без сортировки один и тот же запрос
    -- собирался бы каждый раз по-новому.
    t.assert_equals(url.encode_query({ b = 2, a = 1, c = 3 }), 'a=1&b=2&c=3')
end

g.test_query_encodes_cyrillic_in_name_and_value = function()
    t.assert_equals(url.encode_query({ ['имя'] = 'Пётр' }), '%D0%B8%D0%BC%D1%8F=%D0%9F%D1%91%D1%82%D1%80')
end

g.test_list_becomes_repeated_name = function()
    -- Так это понимают и Go, и Python, и PHP; `tag[]=a` понимает
    -- только PHP.
    t.assert_equals(url.encode_query({ tag = { 'a', 'b' } }), 'tag=a&tag=b')
end

g.test_boolean_goes_as_a_word = function()
    -- `false`, превращённый в `0`, на той стороне читается как «задано».
    t.assert_equals(url.encode_query({ draft = false, live = true }), 'draft=false&live=true')
end

g.test_null_value_is_skipped = function()
    -- box.NULL приходит из всякой таблицы, разобранной из JSON, и значит
    -- там ровно «значения нет».
    t.assert_equals(url.encode_query({ a = 1, b = box.NULL }), 'a=1')
end

g.test_non_string_name_is_refused = function()
    local query, err = url.encode_query({ 'a', 'b' })

    t.assert_equals(query, nil)
    t.assert_str_contains(err, 'должно быть строкой')
end

g.test_value_of_unusable_type_is_refused_by_name = function()
    local query, err = url.encode_query({ page = print })

    t.assert_equals(query, nil)
    t.assert_str_contains(err, 'параметр page')
    t.assert_str_contains(err, 'function')
end

g.test_value_of_unusable_type_inside_list_is_refused = function()
    local query, err = url.encode_query({ tag = { 'a', print } })

    t.assert_equals(query, nil)
    t.assert_str_contains(err, 'параметр tag')
end

g.test_address_without_parameters_stays_as_it_was = function()
    t.assert_equals(url.with_query('http://h/x', nil), 'http://h/x')
    t.assert_equals(url.with_query('http://h/x', {}), 'http://h/x')
end

g.test_parameters_join_the_ones_already_in_the_address = function()
    -- Базовый адрес службы иногда несёт свой ключ доступа, и затереть
    -- его параметрами запроса значит сломать работающий запрос.
    t.assert_equals(url.with_query('http://h/x?key=1', { page = 2 }), 'http://h/x?key=1&page=2')
    t.assert_equals(url.with_query('http://h/x', { page = 2 }), 'http://h/x?page=2')
end

g.test_address_of_parameters_alone_keeps_them = function()
    -- Относительная ссылка из одной строки запроса — тоже ссылка,
    -- и знак вопроса в ней стоит первым знаком.
    t.assert_equals(url.with_query('?a=1', { b = 2 }), '?a=1&b=2')
end

g.test_bad_parameter_stops_the_address = function()
    local address, err = url.with_query('http://h/x', { page = print })

    t.assert_equals(address, nil)
    t.assert_str_contains(err, 'параметр page')
end

g.test_base_path_is_a_prefix_not_a_root = function()
    -- По RFC 3986 разрешение относительной ссылки потеряло бы `v1`,
    -- но базовый адрес задают как раз затем, чтобы не повторять `v1`.
    t.assert_equals(url.join('https://s/v1', '/users'), 'https://s/v1/users')
end

g.test_slashes_on_the_seam_collapse_to_one = function()
    t.assert_equals(url.join('https://s/v1/', 'users'), 'https://s/v1/users')
    t.assert_equals(url.join('https://s/v1//', '//users'), 'https://s/v1/users')
end

g.test_absolute_target_ignores_the_base = function()
    t.assert_equals(url.join('https://s/v1', 'http://other/x'), 'http://other/x')
end

g.test_empty_sides_of_the_seam = function()
    t.assert_equals(url.join('https://s', nil), 'https://s')
    t.assert_equals(url.join('https://s', ''), 'https://s')
    t.assert_equals(url.join(nil, '/x'), '/x')
    t.assert_equals(url.join('', '/x'), '/x')
    t.assert_equals(url.join(nil, nil), '')
end

g.test_address_splits_into_scheme_authority_and_rest = function()
    local scheme, authority, rest = url.split('https://user@h:8443/a/b?c=1')

    t.assert_equals(scheme, 'https')
    t.assert_equals(authority, 'user@h:8443')
    t.assert_equals(rest, '/a/b?c=1')
end

g.test_relative_address_has_no_scheme = function()
    -- Узел пустой строкой, а не пустотой: `nil` пришлось бы проверять
    -- каждому, кто сравнивает узлы, и однажды кто-нибудь забыл бы.
    local scheme, authority, rest = url.split('/a/b')

    t.assert_equals(scheme, nil)
    t.assert_equals(authority, '')
    t.assert_equals(rest, '/a/b')
end

g.test_address_without_a_host_still_splits = function()
    -- `http:///x` — адрес без узла: разобрать его надо, а решать, годится
    -- ли он, будет тот, кто спрашивал.
    local scheme, authority, rest = url.split('http:///x')

    t.assert_equals(scheme, 'http')
    t.assert_equals(authority, '')
    t.assert_equals(rest, '/x')
end

g.test_path_drops_parameters_and_anchor = function()
    t.assert_equals(url.path('https://h/a/b?c=1#d'), '/a/b')
end

g.test_address_without_path_has_the_root_path = function()
    -- Слои запроса читают путь, и `nil` вместо пути ломает и метрику,
    -- и запись в журнале.
    t.assert_equals(url.path('https://h'), '/')
    t.assert_equals(url.path('https://h?c=1'), '/')
end

g.test_origin_spells_out_the_default_port = function()
    -- `https://example.org` и `https://example.org:443` — один узел,
    -- и снимать с перехода заголовок входа из-за записи нельзя.
    t.assert_equals(url.origin('https://example.org/x'), 'https://example.org:443')
    t.assert_equals(url.origin('http://example.org/x'), 'http://example.org:80')
    t.assert_equals(url.origin('https://example.org:443/x'), 'https://example.org:443')
end

g.test_origin_ignores_case_and_credentials = function()
    t.assert_equals(url.origin('HTTPS://User:Pass@Example.org/x'), 'https://example.org:443')
end

g.test_origin_of_a_host_with_an_empty_port_takes_the_default = function()
    -- `example.org:` — законная запись: порт пуст, значит он тот, что
    -- подразумевает схема. Двоеточие при этом в имени узла не остаётся.
    t.assert_equals(url.origin('http://example.org:/x'), 'http://example.org:80')
end

g.test_origin_of_empty_credentials_is_still_the_host = function()
    t.assert_equals(url.origin('http://@example.org/x'), 'http://example.org:80')
end

g.test_origin_of_unknown_scheme_has_no_port = function()
    t.assert_equals(url.origin('ftp://example.org/x'), 'ftp://example.org:0')
end

g.test_origin_of_explicit_port_keeps_it = function()
    t.assert_equals(url.origin('http://example.org:8080/x'), 'http://example.org:8080')
end

g.test_relative_address_has_no_origin = function()
    t.assert_equals(url.origin('/x'), nil)
    t.assert_equals(url.origin('http:///x'), nil)
end

g.test_absolute_location_is_taken_as_it_is = function()
    t.assert_equals(url.resolve('https://h/a', 'http://other/b'), 'http://other/b')
end

g.test_location_without_scheme_keeps_ours = function()
    t.assert_equals(url.resolve('https://h/a', '//other/b'), 'https://other/b')
end

g.test_location_from_the_root_keeps_the_host = function()
    t.assert_equals(url.resolve('https://h/a/b?c=1', '/x'), 'https://h/x')
end

g.test_relative_location_is_resolved_against_the_directory = function()
    -- Ровно по RFC 3986: `Location` пишет сервер, и вольничать с чужой
    -- ссылкой нельзя.
    t.assert_equals(url.resolve('https://h/a/b?c=1', 'x'), 'https://h/a/x')
    t.assert_equals(url.resolve('https://h/a/', 'x'), 'https://h/a/x')
    t.assert_equals(url.resolve('https://h', 'x'), 'https://h/x')
end

g.test_empty_or_unresolvable_location_is_refused = function()
    t.assert_equals(url.resolve('https://h/a', ''), nil)
    t.assert_equals(url.resolve('/a', 'x'), nil)
end
