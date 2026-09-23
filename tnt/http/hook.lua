--- Крюки исходящего обращения и заголовки контекста: то, что клиент
--- добавляет к каждой попытке запроса и к открытию потока сверх настроек
--- вызывающего.
---
--- Опознаватель запроса и трасса обязаны доехать до чужой службы, иначе
--- записи одного запроса на двух узлах не связать ничем. Довезти их могут
--- две вещи, и держатся они на разном.
---
--- **Заголовки — из контекста, без всякой установки.** `context.export()`
--- отдаёт ключи контекста, у которых объявлен заголовок: `x-request-id`,
--- а внутри трассы — `traceparent` и `tracestate`. Они ложатся в заголовки
--- обращения непосредственно перед отправкой — после крюков и слоёв, —
--- и только туда, где заголовка ещё нет: заданный вызывающим (настройкой
--- клиента, обращения, слоем или крюком) главнее. Правил W3C и имён
--- заголовков трассы клиент не знает: он отдаёт наружу то, что контекст
--- назвал заголовком, а строку `traceparent` кладёт в контекст тот, кто
--- ведёт трассу.
--- Вне всякой области контекста заголовков нет, в области без трассы
--- уходит только `x-request-id`.
---
--- **Крюки — именованный список модуля.** Клиентский отрезок трассы
--- на попытку — замер её длительности, исход, повтор отдельной операцией —
--- это знание трассировки, а не клиента, и приходит оно крюком:
--- `http.hook(name, hook)` ставит или заменяет крюк, `http.hook(name, nil)`
--- снимает. Крюк оборачивает одну попытку запроса вместе с её переходами
--- по `Location` либо открытие потока:
---
---     http.hook('timing', function(call, proceed)
---         -- call.kind — 'request' или 'stream', call.attempt — номер попытки,
---         -- call.request — запрос в общем виде; заголовки можно дописать до proceed
---         local started = clock.monotonic()
---         local answer, err = proceed()
---
---         log.info('исходящее обращение', { method = call.request.method, elapsed = clock.monotonic() - started })
---
---         return answer, err
---     end)
---
--- Крюки идут снаружи внутрь в порядке постановки, слои клиента — внутри
--- крюков, заголовки контекста собираются внутри `proceed`, после слоёв,
--- перед самой отправкой: так заголовок несёт отрезок, который завёл крюк,
--- а слой, дописавший свой заголовок, не теряет его. `proceed` отправляет один раз,
--- и его итог — итог попытки: что вернул крюк, позвавший `proceed`,
--- не читается. Крюк, не позвавший `proceed`, отменил отправку: его отказ
--- доходит вызывающему отказом рода `refused`, а пустота — отказом с его
--- именем. Крюк зовётся под `pcall`: бросивший до `proceed` отправку
--- не срывает — клиент отправляет сам, бросивший после — итог отправки
--- не теряет; о сорвавшемся пишется `warn` с его именем, с подавлением
--- повторов. Сломанная телеметрия не стоит запроса, но и молчать о ней
--- нельзя.
---
--- Каждая попытка идёт по своей копии запроса: то, что крюк, слой или
--- контекст дописали в заголовки одной попытки, до следующей не доезжает.
--- Иначе заголовок трассы второй попытки нёс бы отрезок первой — он уже
--- лежал бы в заголовках как «заданный вызывающим».
---
--- **Состояние, общее на процесс, — нарочно.** Список крюков общий для всех
--- экземпляров клиента процесса: клиенты собираются и внутри других
--- пакетов — клиент хранилища конфигурации, приёмник уведомлений,
--- транспорт Sentry, — и до их настроек приложение не дотягивается; крюк,
--- поставленный настройкой одного клиента, терялся бы ровно там, где клиент
--- собран не приложением. Общее объявление `external.install` не годится тоже: слот у него
--- один, а крюков бывает два — трасса и крошки Sentry. Состав виден
--- в `http.hooks()` и в `status()`; проверки снимают свои крюки
--- `http.hook(name, nil)`. Настройка клиента `propagate = false` снимает
--- и заголовки, и крюки: она обязательна клиентам, которые шлют саму
--- телеметрию — выгрузчику трасс и транспорту Sentry, — иначе выгрузка
--- отрезка рождала бы отрезок о самой себе.

local context = require('tnt.context')
local must = require('tnt.must')

local failure_of = require('tnt.http.failure')

--- Журнал с подавлением повторов: крюк, бросающий на каждой попытке,
--- иначе писал бы одну и ту же строку сотни раз в секунду.
local log = require('tnt.log').changes('tnt.http')

--- Уровень вины: строка того, кто позвал `http.hook`.
local CALLER = 2

--- Проверки аргументов с виной на строке вызывающего.
local caller = must.at(CALLER)

local Module = {}

--- Род обращения: одна попытка запроса вместе с её переходами.
Module.REQUEST = 'request'

--- Род обращения: открытие потока.
Module.STREAM = 'stream'

---@class TntHttpCall Одно обращение, которое оборачивает крюк
---@field kind string Род: `request` либо `stream`
---@field attempt integer|nil Номер попытки запроса с единицы; у потока пусто
---@field request TntHttpMessage Запрос в общем виде: заголовки можно дописать до `proceed`

---@alias TntHttpHook fun(call: TntHttpCall, proceed: fun(): any, TntHttpFailure|nil): any, TntHttpFailure|nil

--- Имена крюков в порядке постановки.
---@type string[]
local order = {}

--- Крюки по именам.
---@type table<string, TntHttpHook>
local hooks = {}

--- Ставит, заменяет или снимает крюк.
---
--- Замена оставляет крюк на прежнем месте в порядке: повторная постановка
--- под тем же именем безвредна — так установку трассировки зовут и при
--- старте, и при перечитывании настроек. Снятый и поставленный снова
--- встаёт последним.
---@param name string Имя крюка, например `trace`
---@param hook TntHttpHook|nil Крюк; `nil` снимает
function Module.set(name, hook)
    caller.not_empty(name, 'имя крюка')
    caller.optional.callable(hook, 'крюк')

    if hook == nil then
        for index, known in ipairs(order) do
            if known == name then
                table.remove(order, index)

                break
            end
        end
    elseif hooks[name] == nil then
        table.insert(order, name)
    end

    hooks[name] = hook
end

--- Имена поставленных крюков в порядке постановки.
---@return string[]
function Module.names()
    local names = {}

    for _, name in ipairs(order) do
        table.insert(names, name)
    end

    return names
end

--- Копия запроса на одну попытку: заголовки — своей таблицей.
---@param request TntHttpMessage
---@return TntHttpMessage
local function copied(request)
    ---@type table<string, any>
    local copy = {}

    for name, value in pairs(request) do
        copy[name] = value
    end

    ---@type table<string, string>
    local headers = {}

    for name, value in pairs(request.headers) do
        headers[name] = value
    end

    copy.headers = headers

    return copy --[[@as TntHttpMessage]]
end

--- Дописывает заголовки контекста туда, где их ещё нет.
---@param headers table<string, string>
local function carried(headers)
    for name, value in pairs(context.export()) do
        if headers[name] == nil then
            headers[name] = value
        end
    end
end

--- Собирает цепочку слоёв вокруг отправки.
---
--- Слои идут снаружи внутрь в порядке перечисления: первый в списке
--- видит запрос первым и ответ последним. Цепочка собирается на попытку,
--- а не на клиента: внутри неё заперты настройки именно этого вызова.
---@param layers function[]
---@param core fun(request: TntHttpMessage): any, TntHttpFailure|nil
---@return fun(request: TntHttpMessage): any, TntHttpFailure|nil
local function chained(layers, core)
    local nxt = core

    for index = #layers, 1, -1 do
        local layer = layers[index]
        local inner = nxt

        nxt = function(request)
            return layer(request, inner)
        end
    end

    return nxt
end

--- Один крюк под `pcall` вокруг остатка цепочки.
---@param name string Имя крюка — для записи о срыве
---@param hook TntHttpHook
---@param call TntHttpCall
---@param inner fun(): any, TntHttpFailure|nil Остаток цепочки: следующий крюк либо отправка
---@return any answer
---@return TntHttpFailure|nil err
local function guarded(name, hook, call, inner)
    local sent = false
    local answer, failure

    -- Отправляет один раз: повторный вызов отдаёт прежний итог. Крюк,
    -- позвавший `proceed` дважды, иначе слал бы запрос дважды — второй
    -- платёж из-за телеметрии.
    local function proceed()
        if not sent then
            sent = true
            answer, failure = inner()
        end

        return answer, failure
    end

    local called, returned, refused = pcall(hook, call, proceed)

    if not called then
        log.warn('крюк исходящего обращения бросил и пропущен', {
            hook = name,
            kind = call.kind,
            method = call.request.method,
            err = tostring(returned),
        })

        -- Бросивший до отправки — отправляем сами; бросивший после —
        -- отдаём то, что уже отправлено.
        return proceed()
    end

    if sent then
        return answer, failure
    end

    -- Крюк отменил отправку. Ответ, если он его дал, — ответ; отказ
    -- приводится к отказу клиента, а пустота получает имя виновного:
    -- отказ без слов не расследовать.
    if returned ~= nil then
        return returned
    end

    local reason = refused
        or ('крюк «%s» не отправил обращение и не назвал причины'):format(name)

    return nil, failure_of.of(reason, false)
end

--- Оборачивает отправку крюками и слоями и кладёт заголовки контекста.
---
--- Снаружи внутрь: крюки в порядке постановки, слои клиента в порядке
--- перечисления, заголовки контекста — последними, в тот запрос, который
--- слои отдали на отправку. Отправка получает копию запроса на эту
--- попытку. Без переноса (`propagate = false`) нет ни крюков, ни заголовков
--- контекста, а копия остаётся копией: слоям одной попытки незачем видеть
--- следы предыдущей.
---@param propagate boolean Настройка клиента: класть ли контекст и звать ли крюки
---@param kind string Род обращения: `Module.REQUEST` либо `Module.STREAM`
---@param attempt integer|nil Номер попытки; у потока пусто
---@param request TntHttpMessage Запрос в общем виде
---@param layers function[] Слои клиента; у потока их нет
---@param send fun(request: TntHttpMessage): any, TntHttpFailure|nil Отправка
---@return any answer
---@return TntHttpFailure|nil err
function Module.around(propagate, kind, attempt, request, layers, send)
    local current = copied(request)

    local core = chained(layers, function(layered)
        if propagate then
            carried(layered.headers)
        end

        return send(layered)
    end)

    if not propagate then
        return core(current)
    end

    local call = { kind = kind, attempt = attempt, request = current }

    local nxt = function()
        return core(current)
    end

    -- Снаружи внутрь в порядке постановки: первый поставленный видит
    -- обращение первым и итог последним.
    for index = #order, 1, -1 do
        local name = order[index]
        local hook = hooks[name]
        local inner = nxt

        nxt = function()
            return guarded(name, hook, call, inner)
        end
    end

    return nxt()
end

return Module
