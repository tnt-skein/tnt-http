--- Отказ клиента: таблица с приговором, которая читается и как строка.
---
--- Таблица, а не строка: тот, кто ведёт свои повторы, — например, обходит
--- равноправные узлы кластера, — обязан отличать «сеть пропала» от «ответ
--- больше предела». По одной строке этого не отличить, и такой вызывающий
--- повторял бы на каждом узле то, чего соседний узел не исправит.
---
--- Главное поле — род отказа (`kind`), и родов ровно пять:
---
--- * `invalid` — запрос не собран: негодная настройка, адрес, тело, вызов
---   потока не по правилам. Ошибка вызывающего, и повтор её не исправит.
--- * `unreachable` — ответа нет: сеть, срок, обрыв посреди тела, libcurl
---   бросил. Единственный род, который лечит другой узел или время.
--- * `refused` — ответ, может быть, и был, но клиент его не отдал: больше
---   предела, переходов больше предела, переход по негодной ссылке, отказ
---   слоя или размыкателя.
--- * `status` — сервер ответил кодом, но ответа как такового вызывающий
---   не получит: у потока код приходит в конце, когда тело уже прочитано.
--- * `idle` — за срок чтения куска не набралось: поток молчал либо слал
---   байты, но ни разделителя, ни нужного их числа не пришло. Поток при
---   этом открыт, и следующее чтение продолжит с того же места.
---
--- Признак `retriable` рядом с родом не лишний: он говорит, стал бы
--- повторять сам клиент, — а клиент повторяет только идемпотентные
--- методы. Тот, у кого свои правила (etcd шлёт POST даже на чтение),
--- судит по роду, а не по признаку.
---
--- Строкой отказ читается текстом причины: `tostring(err)`,
--- `('%s'):format(err)`, `'причина: ' .. err` и `json.encode` дают то же,
--- что дала бы строка `message`. Чего таблица не умеет — строковых методов:
--- `err:find(...)` на ней падает, и читать текст отказа надо через
--- `tostring(err)` или поле `message`.

local Module = {}

--- Запрос не собран: ошибка вызывающего.
Module.INVALID = 'invalid'

--- Ответа нет: сеть, срок, обрыв.
Module.UNREACHABLE = 'unreachable'

--- Клиент отказался отдать ответ сам.
Module.REFUSED = 'refused'

--- Сервер ответил кодом, который отдаётся отказом.
Module.STATUS = 'status'

--- За срок чтения куска не набралось; поток остаётся открытым.
Module.IDLE = 'idle'

---@class TntHttpFailure Отказ: род, приговор и два вида причины
---@field kind string Род отказа: invalid, unreachable, refused, status либо idle
---@field message string Причина с адресом — её получает вызывающий
---@field reason string|nil Причина без адреса — её пишут в журнал
---@field retriable boolean Стал бы повторять сам клиент
---@field status integer|nil Код ответа, если ответ был
---@field retry_after any Что сервер попросил в Retry-After
---@field response TntHttpResponse|nil Ответ, который стоит отдать наверх

--- Текст отказа: причина с адресом.
---@param failure TntHttpFailure
---@return string
local function describe(failure)
    return failure.message
end

--- Общая таблица поведения всех отказов.
---
--- `__serialize` отдаёт текст, а не поля: отказ, положенный в JSON
--- или в запись журнала, выглядит так же, как выглядела строка, и заодно
--- не тащит за собой ответ сервера целиком.
local Failure = {
    __tostring = describe,
    __serialize = describe,
    __concat = function(left, right)
        return tostring(left) .. tostring(right)
    end,
}

--- Собирает отказ.
---@param kind string Род отказа
---@param message string Причина с адресом
---@param extra table|nil Остальные поля: reason, retriable, status, retry_after, response
---@return TntHttpFailure
function Module.new(kind, message, extra)
    local failure = { kind = kind, message = message, retriable = false }

    for name, value in pairs(extra or {}) do
        failure[name] = value
    end

    return setmetatable(failure, Failure)
end

--- Отказ на запросе: причина с адресом — вызывающему, без адреса — журналу.
---
--- В параметрах запроса ездят ключи доступа, и короткая причина нужна
--- ровно затем, чтобы записать отказ, не уронив их в журнал.
---@param kind string Род отказа
---@param request { method: string, url: string } Запрос, на котором всё кончилось
---@param reason string Что именно не вышло
---@param extra table|nil Остальные поля
---@return TntHttpFailure
function Module.on(kind, request, reason, extra)
    local failure = Module.new(kind, ('%s %s: %s'):format(request.method, request.url, reason), extra)

    failure.reason = reason

    return failure
end

--- Отказ ли это клиента, а не чужая таблица.
---@param value any
---@return boolean
function Module.is(value)
    return getmetatable(value) == Failure
end

--- Приводит к отказу то, что пришло не от клиента: строку слоя, таблицу
--- слоя, слово размыкателя, брошенное исключение.
---
--- Род у всего этого один — `refused`: ответа вызывающий не получит,
--- и решил так кто-то на стороне клиента. Приговор берётся у самой
--- таблицы, если она его вынесла; иначе — тот, что назвал вызывающий.
---@param err any
---@param retriable boolean Приговор, если пришедшее его не выносит
---@return TntHttpFailure
function Module.of(err, retriable)
    if Module.is(err) then
        return err
    end

    if type(err) == 'table' then
        return Module.new(Module.REFUSED, tostring(err.message), { retriable = err.retriable == true })
    end

    return Module.new(Module.REFUSED, tostring(err), { retriable = retriable })
end

return Module
