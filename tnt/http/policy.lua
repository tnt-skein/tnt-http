--- Правила протокола: что повторять и куда переходить.
---
--- Здесь собрано то, что HTTP решает за всех одинаково, — и оно вынесено
--- из клиента нарочно: эти правила проверяются таблицей случаев, а не
--- разговором с сервером, и разбираться в них удобнее там, где нет ни
--- сокета, ни настроек.
---
--- Повтор решается двумя вопросами подряд, и первый важнее. Первый —
--- можно ли вообще повторять это действие: RFC 9110 (§9.2.2) называет
--- идемпотентными GET, HEAD, OPTIONS, TRACE, PUT и DELETE, и только их
--- клиенту разрешено повторять самому. POST не в списке: оборвавшийся
--- POST мог дойти до сервера и быть исполненным, и повтор создаст второй
--- заказ. Тому, кому нужен повтор POST, нужен ключ идемпотентности —
--- то есть `tnt.once`, а не клиент HTTP.
---
--- Второй вопрос — стоит ли повторять этот отказ. Отвечает на него
--- `tnt.retry.classify`, общий судья повторов: 408, 425 и 429
--- повторяются, 5xx повторяются, кроме 501 и 505
--- («не умею» и «не понимаю версию» — их чинит не время). Свой список
--- кодов здесь разошёлся бы с общим на первой же правке.
---
--- Переходы переписывают метод не по прихоти, а по RFC 9110 (§15.4):
--- 303 велит забрать ответ методом GET, 301 и 302 исторически делают
--- то же самое с POST — так поступают все браузеры и curl, и сервер,
--- отвечающий 302 на POST формы, рассчитывает именно на это. 307 и 308
--- заведены как раз затем, чтобы метод и тело сохранились.

local classify = require('tnt.retry.classify')

local Module = {}

--- Методы, которые клиенту разрешено повторять самому (RFC 9110, §9.2.2).
---@type table<string, boolean>
Module.IDEMPOTENT = {
    GET = true,
    HEAD = true,
    OPTIONS = true,
    TRACE = true,
    PUT = true,
    DELETE = true,
}

--- Коды, по которым клиент идёт на другой адрес.
---@type table<integer, boolean>
Module.REDIRECTS = {
    [301] = true,
    [302] = true,
    [303] = true,
    [307] = true,
    [308] = true,
}

--- Заголовки, которые не переезжают на чужой узел.
---
--- Заголовок входа, отправленный по чужой ссылке, отдаёт пароль тому,
--- кому его не давали: сервер, ответивший `Location: http://evil/`,
--- получил бы токен доступа к соседней службе. Так же поступают браузеры
--- и curl (`--location-trusted` — отдельная просьба, а не умолчание).
---@type string[]
Module.PRIVATE_HEADERS = { 'authorization', 'cookie', 'proxy-authorization' }

--- Метод, который забирает ответ после перехода, сохраняющего смысл.
local FETCH = 'GET'

--- Метод, у которого тела не бывает: перехода в GET он не требует.
local HEAD = 'HEAD'

--- Метод, ради которого 301 и 302 переписываются в GET.
local POST = 'POST'

--- «Смотри другое место»: ответ забирается отдельным запросом всегда.
local SEE_OTHER = 303

--- Коды, у которых переход сохраняет и метод, и тело.
---
--- Набором, а не сравнением с 307: разряд кодов перехода не сплошной,
--- и «всё, что больше» однажды накроет код, которого сегодня нет.
---@type table<integer, boolean>
local KEEPS_METHOD = { [307] = true, [308] = true }

--- Можно ли повторять само действие.
---@param method string
---@return boolean
function Module.idempotent(method)
    return Module.IDEMPOTENT[method] == true
end

--- Стоит ли повторять запрос, оборвавшийся до ответа.
---
--- Ответа нет, и узнать, дошёл ли запрос до сервера, неоткуда: обрыв
--- на пути туда и обрыв на пути обратно выглядят одинаково. Поэтому
--- решает только метод.
---@param method string
---@return boolean
function Module.retriable_failure(method)
    return Module.idempotent(method)
end

--- Стоит ли повторять этот ответ сервера.
---@param method string
---@param status integer
---@return boolean
function Module.retriable_status(method, status)
    if not Module.idempotent(method) then
        return false
    end

    return classify.verdict({ status = status }) == classify.TRANSIENT
end

--- Переход ли это и куда.
---@param status integer
---@return boolean
function Module.redirects(status)
    return Module.REDIRECTS[status] == true
end

--- Каким методом идти после перехода.
---
--- Возвращается и метод, и то, сохранилось ли тело: тело, оставшееся
--- при смене метода на GET, превратило бы переход в запрос, которого
--- сервер не ждёт.
---@param method string
---@param status integer
---@return string method
---@return boolean keeps_body
function Module.after_redirect(method, status)
    -- HEAD не превращается в GET даже на 303: спрашивали заголовки,
    -- а не тело, и тело в ответ было бы лишним трафиком.
    if method == HEAD then
        return HEAD, true
    end

    -- 307 и 308 заведены ровно затем, чтобы метод и тело сохранились.
    if KEEPS_METHOD[status] then
        return method, true
    end

    -- 303 велит забрать ответ отдельным запросом всегда, а 301 и 302 —
    -- только у POST: так переходят и браузеры, и curl, и сервер,
    -- отвечающий так на отправку формы, рассчитывает именно на это.
    if status == SEE_OTHER or method == POST then
        return FETCH, false
    end

    return method, true
end

--- Заголовки, с которыми идти на новый адрес.
---
--- Возвращается новая таблица: заголовки запроса переживают повтор,
--- и вычеркнуть из них что-то на месте значит вычеркнуть навсегда.
---@param headers table<string, string>
---@param from string|nil Узел, с которого переходим; его даёт `url.origin`
---@param to string|nil Узел, на который переходим
---@return table<string, string>
function Module.carried(headers, from, to)
    local carried = {}

    for name, value in pairs(headers) do
        carried[name] = value
    end

    if from == to then
        return carried
    end

    for _, name in ipairs(Module.PRIVATE_HEADERS) do
        carried[name] = nil
    end

    return carried
end

--- Не больше ли тело ответа, чем разрешено.
---
--- Меряется то, что клиент готов отдать наверх: байты к этому мигу уже
--- приняты libcurl, и остановить их на середине из Lua нечем. Предел
--- всё же нужен: ответ, который никто не читает, и тот занимает память
--- узла, пока его держит вызывающий, — а чужой сервер вправе прислать
--- гигабайт в ответ на однострочный запрос.
---@param text string Тело ответа
---@param limit integer Предел в байтах; 0 — без предела
---@return integer|nil size Размер, если он превышен
function Module.oversized(text, limit)
    if limit == 0 then
        return nil
    end

    if #text > limit then
        return #text
    end

    return nil
end

return Module
