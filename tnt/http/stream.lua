--- Поток: тело ответа читается кусками, а не отдаётся целиком.
---
--- Нужен там, где ответ не кончается или не помещается: наблюдение etcd
--- (`/v3/watch`), выгрузка построчно, события сервера. Обычный запрос для
--- этого не годится: он отдаёт тело целиком, и ответ, который не кончается,
--- не вернётся никогда.
---
--- Поток заведён в фасаде, а не оставлен обработчику libcurl: кто зовёт
--- обработчик сам, тот теряет корни и сертификаты клиента, его пределы
--- и различение тишины, обрыва и конца — всё, что у запроса уже собрано
--- здесь.
---
--- Что у потока то же, что у запроса, — и собирается тем же кодом: адрес
--- с параметрами, заголовки клиента и запроса, тело (`json`, `form`,
--- `body`), проверка сертификата, клиентский сертификат, сокет и срок
--- открытия — соединение и ответ вместе, как у попытки запроса.
---
--- Чего у потока нет, и это решение, а не недосмотр:
---
--- * **Повторов.** Прочитанное уже отдано вызывающему, и повтор с начала
---   отдал бы его второй раз. Переподключаться должен тот, кто знает,
---   с какого места продолжать: etcd продолжает с ревизии, а клиент HTTP
---   о ревизиях не знает ничего.
--- * **Переходов.** Код ответа приходит в конце (см. ниже): узнать, что
---   это был переход, можно только прочитав тело.
--- * **Слоёв.** Слой получает ответ и возвращает ответ, а поток ответом
---   не является: кэш, отдавший поток из памяти, или журнал, прочитавший
---   тело, сломали бы его.
--- * **Записей в журнал.** Отказ уходит вызывающему парой, а бесконечный
---   поток, переподключаемый раз в секунду, залил бы журнал одной строкой.
---
--- Чем заплачено за `http.client` (проверено запуском на 3.8, подробности
--- в шапке `tnt.http.transport`):
---
--- * **Код ответа известен только в конце.** Поток, на который сервер
---   ответил 404, отдаёт страницу ошибки кусками, как любое тело, и лишь
---   последнее чтение говорит отказом рода `status`. Кому нельзя принять
---   страницу ошибки за данные, тот проверяет разбор каждого куска.
--- * **Открытие ждёт первого куска тела**, а не заголовков: сервер,
---   приславший заголовки и замолчавший, даёт отказ по сроку открытия.
---   У методов с телом открытие возвращается, как только libcurl готов
---   слать.
--- * **Заголовки ответа видны только у методов без тела.**
--- * **Обратного давления нет.** `http.client` принимает тело с той
---   скоростью, с какой его шлёт сервер, и копит у себя, пока поток
---   открыт, — читает его кто-нибудь или нет. Поток с пределом в мегабайт
---   за две секунды без чтения принял все 300 МБ, что прислал сервер
---   (проверено запуском), а сжатое тело набивает память ещё быстрее.
---   Память потока ограничена только тем, как быстро его читают, и от
---   враждебного сервера поток не защищает.
--- * **Срок чтения выходит двумя путями.** Молчащий поток `http.client`
---   прерывает исключением, а поток, шлющий байты без разделителя, —
---   пустым возвратом, когда срок истёк посреди куска. Оба значат одно
---   и отдаются одним отказом `idle`.
---
--- Предел `max_body` у потока — счёт прочитанного, а не память: столько
--- поток отдаст наверх за всю жизнь. Кусок, переваливший предел, не
--- отдаётся, а поток закрывается. Бесконечному потоку этот предел ставят
--- нулём, и длину одного куска держит тогда `max_piece`: кусок длиннее
--- него — строка вместе с разделителем — не отдаётся, и поток тоже
--- закрывается. Без обоих длина куска не ограничена ничем. Чтению байтами
--- предел куска ставит само число, и просить байт больше предела куска —
--- ошибка вызывающего, а не отказ сервера: поток остаётся открытым.
---
--- Закрывать поток обязательно, а закрывать дважды безопасно. Файберов
--- поток не заводит, так что висеть на обрыве нечему; соединение же держит
--- libcurl, и отпускает его только закрытие: брошенный поток сервер
--- продолжает кормить. На отказе поток закрывается сам.

local failure_of = require('tnt.http.failure')
local policy = require('tnt.http.policy')
local response_of = require('tnt.http.response')
local settings_of = require('tnt.http.settings')
local transport = require('tnt.http.transport')

local Module = {}

--- Чем читать, если не сказано: строками. Потоки, которые читают
--- кусками, почти всегда построчные — NDJSON, события сервера, etcd.
Module.LINE = '\n'

--- Методы, у которых `http.client` шлёт тело потока.
---
--- Прочим тело не уходит вовсе — `http.client` отвечает «HTTP request
--- method with no body to send», — и тело у них отвергается до открытия.
---@type table<string, boolean>
Module.UPLOADS = { POST = true, PUT = true, PATCH = true }

--- Как `http.client` называет вышедший срок ожидания.
local TIMED_OUT = 'TimedOut'

---@class TntHttpStream Поток ответа
---@field method string Метод
---@field url string Адрес с параметрами
---@field headers table<string, string> Заголовки ответа; у методов с телом пусто
---@field status integer|nil Код ответа: известен, когда поток кончился
---@field reason string|nil Что `http.client` сказал о коде
---@field raw table Поток `http.client`
---@field duplex boolean Открыта ли отправка
---@field timeout number Срок чтения и записи, если не назван
---@field limit integer Сколько байт поток отдаст за жизнь; 0 — без предела
---@field piece_limit integer Сколько байт в одном куске; 0 — без предела
---@field taken integer Сколько уже отдано
---@field done boolean Кончился ли поток: концом, отказом или закрытием
---@field outcome TntHttpFailure|nil Чем кончился; nil — кончился удачно
local Stream = {}
Stream.__index = Stream

--- Отказ, после которого поток открыт: вызвали не по правилам.
---@param reason string
---@return nil
---@return TntHttpFailure
function Stream:_invalid(reason)
    return nil, failure_of.on(failure_of.INVALID, self, reason)
end

--- Кончает поток и запоминает, чем.
---
--- `finish` с нулевым сроком рвёт идущую передачу сразу, а на кончившейся
--- безвреден: зовётся он поэтому на всяком конце, не разбирая какой.
---@param outcome TntHttpFailure|nil
---@return nil
---@return TntHttpFailure|nil
function Stream:_stop(outcome)
    pcall(self.raw.finish, self.raw, 0)
    self.done = true
    self.outcome = outcome

    return nil, outcome
end

--- Кончает поток отказом сети.
---@param reason string
---@return nil
---@return TntHttpFailure
function Stream:_unreachable(reason)
    local failure = failure_of.on(failure_of.UNREACHABLE, self, reason, {
        retriable = policy.retriable_failure(self.method),
    })

    self:_stop(failure)

    return nil, failure
end

--- Вышел ли срок ожидания: так `http.client` бросает на молчащем потоке.
---
--- Поле читается под `pcall`: брошенное — объект Tarantool, но бросить
--- могут и то, у чего полей нет вовсе.
---@param err any
---@return boolean
local function timed_out(err)
    local read, kind = pcall(function()
        return err.type
    end)

    return read and kind == TIMED_OUT
end

--- Срок ожидания, которому можно верить.
---
--- Ноль у `http.client` на идущем потоке значит не «не ждать», а «поток
--- кончился»: чтение с нулевым сроком отдаёт пустую строку — ту же, что
--- настоящий конец. Поэтому срок короче миллисекунды — отказ.
---@param timeout any
---@param fallback number
---@return number|nil
---@return string|nil err
local function wait_of(timeout, fallback)
    if timeout == nil then
        return fallback
    end

    if type(timeout) ~= 'number' or timeout < settings_of.LEAST_TIMEOUT then
        return nil,
            ('срок — число секунд не меньше %s, а пришло %s'):format(
                settings_of.LEAST_TIMEOUT,
                tostring(timeout)
            )
    end

    return timeout
end

--- Сколько байт может быть в следующем куске: меньший из остатка суммы
--- и предела куска.
---@return number|nil bound Пусто, если пределов нет
function Stream:_bound()
    ---@type number|nil
    local bound = self.piece_limit > 0 and self.piece_limit or nil

    if self.limit > 0 then
        bound = math.min(self.limit - self.taken, bound or math.huge)
    end

    return bound
end

--- Чем читать: сколько байт или до какого разделителя — с поправкой на
--- пределы.
---
--- Читается на байт больше, чем кусок вправе занять: кусок, ровно
--- добравший до предела, отдаётся, а перевалить его может только тот, что
--- перевалил на самом деле. Без поправки строка без разделителя не
--- кончалась бы ничем — ни куском, ни отказом: чтение за чтением отдавало
--- бы `idle`, пока строка растёт. С поправкой отказ приходит, как только
--- предел перевален. Памяти поправка не бережёт: см. шапку.
---@param what any Число байт либо разделитель
---@return any spec Что понимает `read` у `http.client`
---@return string|nil err
function Stream:_spec(what)
    local bound = self:_bound()

    if type(what) == 'number' then
        if what < 1 or what % 1 ~= 0 then
            return nil,
                ('читать — целым числом байт больше нуля, а пришло %s'):format(
                    what
                )
        end

        if self.piece_limit > 0 and what > self.piece_limit then
            return nil,
                ('читать больше предела куска в %d байт нельзя, а просят %d'):format(
                    self.piece_limit,
                    what
                )
        end

        if bound == nil then
            return what
        end

        return math.min(what, bound + 1)
    end

    if type(what) ~= 'string' or what == '' then
        return nil,
            ('читать — числом байт или разделителем, а пришло %s'):format(
                tostring(what)
            )
    end

    if bound == nil then
        return what
    end

    return { delimiter = what, chunk = bound + 1 }
end

--- Отказ пределу, если кусок его перевалил.
---@param size integer Длина прочитанного куска; он уже в счёте
---@return string|nil reason
function Stream:_overflow(size)
    if self.limit > 0 and self.taken > self.limit then
        return ('поток больше предела в %d байт'):format(self.limit)
    end

    if self.piece_limit > 0 and size > self.piece_limit then
        return ('кусок больше предела в %d байт'):format(self.piece_limit)
    end

    return nil
end

--- Кончает поток, отдавший всё: код ответа появляется только теперь.
---@return nil
---@return TntHttpFailure|nil
function Stream:_ended()
    local raw = self.raw

    -- `finish` на кончившейся передаче не ждёт ничего, а код и слово
    -- ставит на сам поток: до него их нет вовсе.
    pcall(raw.finish, raw, 0)

    -- Обрыв посреди тела читается концом, и отличает его только код:
    -- libcurl оставляет ноль вместо кода сервера.
    if not transport.answered(raw) then
        return self:_unreachable(('поток оборвался: %s'):format(transport.reason_of(raw)))
    end

    self.status = raw.status
    self.reason = raw.reason

    if response_of.ok(raw.status) then
        return self:_stop(nil)
    end

    return self:_stop(
        failure_of.on(failure_of.STATUS, self, ('сервер ответил %d %s'):format(raw.status, raw.reason), {
            status = raw.status,
            retriable = policy.retriable_status(self.method, raw.status),
        })
    )
end

--- Читает кусок.
---
--- Три исхода, и различаются они вторым значением:
---
--- * кусок — непустая строка;
--- * `nil` без отказа — поток кончился удачно, и `status` уже известен;
--- * `nil` с отказом — род `idle` значит «за срок куска не набралось»,
---   и поток открыт; прочие роды поток закрыли.
---
--- Читать после конца можно: вернётся то же, чем поток кончился. Это
--- касается и закрытия из другого файбера посреди чтения: читающий
--- получит итог закрытия, а не обрыв, которым libcurl ответил на него.
---@param what integer|string|nil Сколько байт либо до какого разделителя; по умолчанию — строка
---@param timeout number|nil Сколько ждать; по умолчанию срок ответа
---@return string|nil piece
---@return TntHttpFailure|nil err
function Stream:read(what, timeout)
    if self.done then
        return nil, self.outcome
    end

    local spec, wrong = self:_spec(what or Module.LINE)

    if spec == nil then
        ---@cast wrong string
        return self:_invalid(wrong)
    end

    local wait, late = wait_of(timeout, self.timeout)

    if wait == nil then
        ---@cast late string
        return self:_invalid(late)
    end

    local called, piece = pcall(self.raw.read, self.raw, spec, wait)

    -- Пока чтение ждало, поток могли закрыть из другого файбера: `finish`
    -- будит читающего пустой строкой или исключением, и разбор их затёр бы
    -- итог закрытия обрывом. Проверка типов о переключении файберов
    -- не знает и считает, что поле не могло измениться с начала вызова.
    ---@diagnostic disable-next-line: unnecessary-if
    if self.done then
        return nil, self.outcome
    end

    if not called and not timed_out(piece) then
        return self:_unreachable(('поток оборвался: %s'):format(tostring(piece)))
    end

    -- Срок выходит двумя путями (см. шапку): исключением на молчании
    -- и `nil`, когда байты шли, а куска из них не собралось. Принятое
    -- до срока не пропадает в обоих: `http.client` держит его у себя,
    -- и следующее чтение начнёт с него.
    if not called or piece == nil then
        return nil, failure_of.on(failure_of.IDLE, self, ('за %s с кусок не собрался'):format(wait))
    end

    if piece == '' then
        return self:_ended()
    end

    self.taken = self.taken + #piece

    local overflow = self:_overflow(#piece)

    if overflow ~= nil then
        return self:_stop(failure_of.on(failure_of.REFUSED, self, overflow))
    end

    return piece
end

--- Дописывает тело запроса в открытую отправку.
---
--- Только у потока с `duplex`: у прочих тело ушло целиком при открытии,
--- и отправка закрыта — сервер иначе ждал бы продолжения и не отвечал.
---@param data string Непустой кусок тела
---@param timeout number|nil Сколько ждать; по умолчанию срок ответа
---@return boolean|nil ok
---@return TntHttpFailure|nil err
function Stream:write(data, timeout)
    if not self.duplex then
        return self:_invalid(
            'отправка закрыта: тело ушло при открытии, писать можно только в поток с duplex'
        )
    end

    if self.done then
        return self:_invalid('поток кончился: писать некуда')
    end

    -- Пустая запись у `http.client` закрывает отправку совсем: принять её
    -- за «ничего не писать» значило бы молча оборвать разговор.
    if type(data) ~= 'string' or data == '' then
        return self:_invalid(
            ('писать — непустой строкой, а пришло %s'):format(type(data))
        )
    end

    local wait, late = wait_of(timeout, self.timeout)

    if wait == nil then
        ---@cast late string
        return self:_invalid(late)
    end

    local called, written = pcall(self.raw.write, self.raw, data, wait)

    -- Закрытие из другого файбера посреди записи — не обрыв: см. `read`.
    ---@diagnostic disable-next-line: unnecessary-if
    if self.done then
        return nil, self.outcome
    end

    if not called then
        return self:_unreachable(('тело не ушло: %s'):format(tostring(written)))
    end

    -- Меньше, чем просили, `http.client` отдаёт, когда передача уже
    -- кончилась: сервер закрыл поток, и дописывать некому.
    if written ~= #data then
        return self:_unreachable('тело не ушло: сервер уже закончил поток')
    end

    return true
end

--- Закрывает поток. Повторное закрытие безопасно.
---@return boolean
function Stream:close()
    if not self.done then
        self:_stop(failure_of.on(failure_of.INVALID, self, 'поток закрыт'))
    end

    return true
end

--- Открывает поток.
---@param handle table Обработчик libcurl клиента
---@param request TntHttpMessage Запрос в общем виде
---@param options table Настройки для `http.client`
---@param resolved table Настройки этого потока: timeout, max_body, max_piece, duplex
---@return TntHttpStream|nil
---@return TntHttpFailure|nil err
function Module.open(handle, request, options, resolved)
    local uploads = Module.UPLOADS[request.method] == true

    if not uploads and (request.body ~= nil or resolved.duplex) then
        return nil,
            failure_of.on(
                failure_of.INVALID,
                request,
                'тело потока http.client шлёт только у POST, PUT и PATCH'
            )
    end

    local raw, err, reason = transport.open(handle, request.method, request.url, request.body, options)

    if raw == nil then
        ---@cast err string
        return nil,
            failure_of.new(failure_of.UNREACHABLE, err, {
                reason = reason,
                retriable = policy.retriable_failure(request.method),
            })
    end

    local stream = setmetatable({
        method = request.method,
        url = request.url,
        headers = response_of.headers_of(raw.headers),
        raw = raw,
        duplex = resolved.duplex,
        timeout = resolved.timeout,
        limit = resolved.max_body,
        piece_limit = resolved.max_piece,
        taken = 0,
        done = false,
    }, Stream)

    if uploads and not resolved.duplex then
        -- Пустая запись закрывает отправку: сервер, дочитывающий тело
        -- запроса до конца, иначе ждал бы продолжения и не ответил вовсе.
        local called, refused = pcall(raw.write, raw, '', resolved.timeout)

        if not called then
            return stream:_unreachable(('тело не ушло: %s'):format(tostring(refused)))
        end
    end

    return stream
end

return Module
