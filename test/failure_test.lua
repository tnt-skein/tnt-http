--- Тесты отказа: род, приговор и чтение прежним текстом.

local t = require('luatest')

local g = t.group('tnt.http.failure')

local helper = dofile('test/helper.lua')

--- Ошибки Tarantool: ими бросает `http.client`. Конструктор в аннотациях
--- описан не полностью, поэтому берётся через промежуточную ссылку.
---@type any
local box_error = box.error

---@type any
local failure

g.before_each(function()
    failure = helper.load('tnt.http.failure')
end)

g.after_each(function()
    helper.unload()
end)

g.test_kinds_are_named_once = function()
    -- Имена выписаны здесь, а не взяты из пакета: род сверяют строкой
    -- в чужом коде, и переименование обязано сломать проверку.
    t.assert_equals(failure.INVALID, 'invalid')
    t.assert_equals(failure.UNREACHABLE, 'unreachable')
    t.assert_equals(failure.REFUSED, 'refused')
    t.assert_equals(failure.STATUS, 'status')
    t.assert_equals(failure.IDLE, 'idle')
end

g.test_failure_is_not_worth_repeating_unless_told = function()
    local refused = failure.new('refused', 'нет')

    t.assert_equals(refused.kind, 'refused')
    t.assert_equals(refused.message, 'нет')
    t.assert_equals(refused.retriable, false)
    t.assert_equals(failure.new('unreachable', 'нет', { retriable = true, status = 503 }).status, 503)
    t.assert_equals(failure.new('unreachable', 'нет', { retriable = true }).retriable, true)
end

g.test_failure_reads_as_the_old_text = function()
    -- Прежде отказ доходил строкой, и склеивать его, печатать и класть
    -- в JSON продолжают так же.
    local broken = failure.new('unreachable', 'GET http://h/: сервер не ответил')

    t.assert_equals(tostring(broken), 'GET http://h/: сервер не ответил')
    t.assert_equals(
        ('служба не ответила: %s'):format(broken),
        'служба не ответила: GET http://h/: сервер не ответил'
    )
    t.assert_equals('причина: ' .. broken, 'причина: GET http://h/: сервер не ответил')
    t.assert_equals(broken .. ' — и всё', 'GET http://h/: сервер не ответил — и всё')
    t.assert_equals(require('json').decode(require('json').encode({ err = broken })), {
        err = 'GET http://h/: сервер не ответил',
    })
end

g.test_failure_on_a_request_keeps_the_reason_without_the_address = function()
    -- В параметрах запроса ездят ключи доступа, а причина без адреса
    -- нужна ровно затем, чтобы записать отказ в журнал.
    local refused = failure.on(
        'refused',
        { method = 'GET', url = 'http://h/?token=тайна' },
        'больше предела',
        {
            status = 200,
        }
    )

    t.assert_equals(refused.message, 'GET http://h/?token=тайна: больше предела')
    t.assert_equals(refused.reason, 'больше предела')
    t.assert_equals(refused.status, 200)
    t.assert_equals(refused.kind, 'refused')
end

g.test_own_failure_is_told_from_a_foreign_table = function()
    t.assert_equals(failure.is(failure.new('idle', 'тихо')), true)
    t.assert_equals(failure.is({ message = 'чужое' }), false)
    t.assert_equals(failure.is('строка'), false)
end

g.test_own_failure_passes_through_as_it_is = function()
    local own = failure.new('status', 'сервер ответил 503', { retriable = true })

    t.assert_is(failure.of(own, false), own)
end

g.test_table_of_a_layer_keeps_its_verdict = function()
    local taken = failure.of({ message = 'кэш пуст', retriable = true }, false)

    t.assert_equals(taken.kind, 'refused')
    t.assert_equals(taken.message, 'кэш пуст')
    t.assert_equals(taken.retriable, true)
    t.assert_equals(failure.of({ message = 'кэш пуст' }, true).retriable, false)
end

g.test_word_of_a_layer_gets_the_verdict_it_is_given = function()
    local taken = failure.of('размыкатель разомкнут', true)

    t.assert_equals(taken.kind, 'refused')
    t.assert_equals(taken.message, 'размыкатель разомкнут')
    t.assert_equals(taken.retriable, true)
    t.assert_equals(failure.of(box_error.new({ type = 'TimedOut', reason = 'timed out' }), false).message, 'timed out')
end
