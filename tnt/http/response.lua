--- Ответ сервера.
---
--- Ответ — это данные, а не исключение. Код 500 значит, что у чужой
--- службы беда, и прикладной код вправе решить, что с этим делать:
--- отдать своему клиенту 502, взять значение из кэша, промолчать. Поэтому
--- `http.get` отдаёт ответ с любым кодом, а `nil, err` — только тогда,
--- когда ответа нет вовсе.
---
--- Там, где разбираться незачем, есть `raise`: он бросает на всяком коде
--- вне 2xx и возвращает сам ответ на удачном — чтобы вызов писался одной
--- строкой и читался слева направо.
---
--- Имена заголовков приведены к нижнему регистру. В HTTP регистр имени
--- не значит ничего, но один сервер пишет `Content-Type`, другой
--- `content-type`, а третий `CONTENT-TYPE`, и код, читающий ответ
--- по точному имени, работает ровно до смены сервера.

local body_of = require('tnt.http.body')
local fail = require('tnt.must.fail')

local Module = {}

--- Разряд удачных кодов.
local OK_FIRST = 200
local OK_LAST = 299

---@class TntHttpResponse
---@field status integer Код ответа
---@field reason string Что сервер написал словами
---@field headers table<string, string> Заголовки; имена в нижнем регистре
---@field body string Тело ответа; у HEAD и 204 — пустая строка
---@field url string Адрес, с которого ответ получен, — с учётом переходов
---@field method string Каким методом ответ получен
local Response = {}
Response.__index = Response

--- Удачен ли код: из разряда 2xx.
---
--- Отдельно от ответа: у потока ответа как таблицы нет, а код, пришедший
--- в конце, судится по тому же разряду.
---@param status integer
---@return boolean
function Module.ok(status)
    return status >= OK_FIRST and status <= OK_LAST
end

--- Удачен ли ответ: код из разряда 2xx.
---@return boolean
function Response:ok()
    return Module.ok(self.status)
end

--- Разбирает тело как JSON.
---
--- Отдельным вызовом, а не полем: разбор может не выйти, а поле,
--- которое иногда `nil` и никогда не говорит почему, — худший из способов
--- сообщить об отказе.
---@return any value
---@return string|nil err
function Response:json()
    return body_of.parse(self.body)
end

--- Бросает, если код не из 2xx; иначе возвращает сам ответ.
---
--- Пригождается там, где чужой отказ и есть конец работы: обход,
--- разовая задача, миграция. В обработчике запроса лучше `ok()`.
---@return TntHttpResponse
function Response:raise()
    if not self:ok() then
        local message = ('%s %s: %d %s; %s'):format(
            self.method,
            self.url,
            self.status,
            self.reason,
            body_of.fragment(self.body)
        )

        -- Без места: в сообщении нужен чужой сервер, а не файл и строка
        -- этого модуля — падение случилось не здесь. Бросается строка,
        -- как и прежде, а не объект отказа.
        fail.raise(message)
    end

    return self
end

--- Заголовки с именами в нижнем регистре.
---@param headers table<string, any>|nil
---@return table<string, string>
function Module.headers_of(headers)
    local lowered = {}

    for name, value in pairs(headers or {}) do
        lowered[name:lower()] = value
    end

    return lowered
end

--- Собирает ответ из того, что отдал транспорт.
---@param raw table Ответ http.client
---@param request table Запрос, на который он пришёл
---@return TntHttpResponse
function Module.new(raw, request)
    return setmetatable({
        status = raw.status,
        -- Причина словами приходит не от всякого сервера: HTTP/2 её
        -- не передаёт вовсе, и пустая строка здесь честнее, чем nil,
        -- на котором споткнётся склейка сообщения об отказе.
        reason = raw.reason or '',
        headers = Module.headers_of(raw.headers),
        body = raw.body or '',
        url = request.url,
        method = request.method,
    }, Response)
end

return Module
