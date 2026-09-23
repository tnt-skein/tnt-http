--- Один запрос по сети через `http.client` Tarantool.
---
--- Весь разговор с libcurl заперт здесь, и весь он — в одном вызове.
--- Выше этого модуля нет ни `http.client`, ни его своеобразия: клиент
--- собирает запрос, а сюда отдаёт готовые метод, адрес, тело и настройки.
---
--- Отличить отказ сети от ответа сервера — единственное, ради чего этот
--- модуль существует отдельно. Отказ сети `http.client` отдаёт двумя
--- путями. Часть отказов приходит таблицей с придуманным кодом — 595
--- «не разрешилось имя», «не соединилось», а после отправки и «принятое
--- не записалось», «сжатие ответа не разобралось»; 408 «срок вышел», 444
--- «ничего не пришло», 495 «сертификат не прошёл», — и такой код
--- неотличим от кода, который прислал бы чужой сервер. Прочие libcurl
--- бросает исключением `curl: …`: негодный адрес и рукопожатие TLS — до
--- запроса, а сброс соединения, оборванное тело и мусор вместо ответа —
--- после того, как сервер запрос прочитал (проверено запуском на 3.8).
--- Поэтому ни путь, ни бросок не говорят, ушёл ли запрос: это решают
--- слова libcurl, и судит по ним тот, кому это важно.
---
--- Примет три, и нужны все. Первая: у настоящего ответа есть таблица
--- заголовков, а у придуманного, случившегося до заголовков, её нет.
--- Вторая нашлась запуском: срок, вышедший посреди тела, приходит
--- с заголовками — `{status = 408, reason = 'Timeout was reached',
--- headers = {...}, body = 'xxx'}`, — и по первой примете обрезанное тело
--- выглядело ответом сервера с кодом 408. Отличает его слово: своих слов
--- сервера `http.client` 3.8 не передаёт, у настоящего ответа там «Ok»
--- или «Unknown», а у придуманного — текст ошибки libcurl. Проверка слова
--- стоит только на придуманных кодах: если однажды слова сервера начнут
--- доходить, ошибиться она сможет лишь на этих четырёх кодах, а не на всех.
--- Третья — код ноль: разговора по HTTP не было, какое бы слово ни стояло
--- (см. ` Module.NOTHING`).
---
--- Срока по умолчанию здесь нет нарочно: его назначает вызывающий, а
--- клиент обязан выставить его на каждом запросе. У самого libcurl
--- умолчание — четыреста дней, и запрос без срока висит именно столько.
---
--- Поток открывается здесь же и тем же вызовом, с `chunked = true`.
--- Что `http.client` отдаёт на потоке, проверено запуском на 3.8:
---
--- * вызов возвращается, когда пришёл первый кусок тела (GET) либо когда
---   libcurl готов слать тело (POST, PUT, PATCH), — не по заголовкам;
---   сервер, приславший заголовки и замолчавший, даёт исключение
---   «timed out» по сроку;
--- * кода ответа до конца передачи нет: `status` появляется только после
---   `finish`, а заголовки видны лишь у методов без тела;
--- * обрыв посреди тела выглядит концом — чтение отдаёт пустую строку, —
---   и отличает его только код после `finish`: 0 вместо кода сервера;
--- * `finish(0)` на идущей передаче рвёт соединение сразу, и сервер это
---   замечает; поток, брошенный без `finish`, сервер не заметил и через
---   секунду после сборки мусора.

local external = require('tnt.external')

local Module = {}

--- Внешние средства: сам клиент libcurl.
---
--- Подменяется целиком, а не по вызову: проверке нужен двойник, который
--- помнит, о чём его просили, — и заводится он тем же способом, что
--- настоящий.
local source = external.install(Module, {
    client = function(opts)
        return require('http.client').new(opts)
    end,
})

--- Заводит обработчик libcurl.
---
--- Один на клиента: в нём живёт кэш соединений, и два обработчика —
--- это два несвязанных кэша, то есть вдвое больше рукопожатий на пустом
--- месте.
---@param opts table|nil max_connections и прочее, что понимает http.client
---@return table
function Module.new(opts)
    return source().client(opts)
end

--- Отказ, названный дважды: с адресом — вызывающему, без него — журналу.
---
--- В параметрах запроса ездят ключи доступа, и короткая причина нужна
--- ровно затем, чтобы записать отказ, не уронив их в журнал.
---@param method string
---@param url string
---@param reason string
---@return nil
---@return string message
---@return string reason
local function failed(method, url, reason)
    return nil, ('%s %s: %s'):format(method, url, reason), reason
end

--- Коды, которые `http.client` придумывает сам, когда ответа не было.
---@type table<integer, boolean>
Module.INVENTED = { [408] = true, [444] = true, [495] = true, [595] = true }

--- Код, которого у ответа по HTTP не бывает вовсе.
---
--- Ноль `http.client` ставит, когда разговора по HTTP не было: так после
--- `finish` отвечает поток, оборвавшийся посреди тела, и так приходит
--- обращение по другой схеме — `file://` отдаёт файл узла телом, с кодом 0
--- и словом «Unknown», тем же, что у настоящего ответа (проверено
--- запуском на сборке для macOS; статическая сборка для Linux схем
--- `file://` и `gopher://` не знает и отказывает до отправки). Поэтому
--- ноль — отказ при любом слове, а не придуманный код, который слово
--- сервера оправдывает.
Module.NOTHING = 0

--- Слова, которыми `http.client` называет настоящий ответ.
---@type table<string, boolean>
Module.SPOKEN = { Ok = true, Unknown = true }

--- Ответил ли сервер: см. шапку модуля.
---@param raw any Что вернул http.client
---@return boolean
function Module.answered(raw)
    if type(raw) ~= 'table' or raw.headers == nil or raw.status == Module.NOTHING then
        return false
    end

    return not Module.INVENTED[raw.status] or Module.SPOKEN[raw.reason] == true
end

--- Шлёт запрос и разбирает, ответил ли кто-нибудь.
---@param handle table Обработчик из ` Module.new`
---@param method string
---@param url string
---@param body string|nil
---@param options table Настройки запроса для http.client
---@return table|nil raw Ответ http.client
---@return string|nil err Отказ сети
---@return string|nil reason Он же без адреса
function Module.perform(handle, method, url, body, options)
    -- Через pcall: libcurl бросает и на том, что вовсе не похоже на адрес,
    -- и на сбросе соединения посреди разговора, а ронять этим узел
    -- несоразмерно. Метка броска нарочно не говорит, ушёл ли запрос:
    -- исключение бывает и до отправки, и после неё (см. шапку).
    local called, answer = pcall(handle.request, handle, method, url, body, options)

    if not called then
        return failed(method, url, ('libcurl отказал: %s'):format(tostring(answer)))
    end

    if not Module.answered(answer) then
        return failed(method, url, Module.reason_of(answer))
    end

    return answer
end

--- Открывает поток и разбирает, открылся ли он.
---
--- Поток, кончившийся раньше, чем вызов вернулся, приносит код сразу —
--- и если код придуманный, это тот же отказ сети, что у обычного запроса:
--- «никто не слушает» приходит именно так.
---@param handle table Обработчик из ` Module.new`
---@param method string
---@param url string
---@param body string|nil Начало тела: уходит сразу после открытия
---@param options table Настройки для http.client; `chunked` ставится здесь
---@return table|nil raw Поток http.client
---@return string|nil err Отказ сети
---@return string|nil reason Он же без адреса
function Module.open(handle, method, url, body, options)
    local chunked = {}

    for name, value in pairs(options) do
        chunked[name] = value
    end

    chunked.chunked = true

    local called, raw = pcall(handle.request, handle, method, url, body, chunked)

    if not called then
        return failed(method, url, ('поток не открылся: %s'):format(tostring(raw)))
    end

    if raw.status ~= nil and not Module.answered(raw) then
        return failed(method, url, Module.reason_of(raw))
    end

    return raw
end

--- Чем libcurl объяснил отказ.
---@param answer any Что вернул http.client
---@return string
function Module.reason_of(answer)
    if type(answer) ~= 'table' then
        return ('сервер не ответил: %s'):format(tostring(answer))
    end

    return ('сервер не ответил: %s (код %s)'):format(tostring(answer.reason), tostring(answer.status))
end

return Module
