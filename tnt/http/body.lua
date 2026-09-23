--- Тело запроса и разбор тела ответа.
---
--- Разработчик пишет `json = { … }` или `form = { … }`, а не собирает
--- строку и не вспоминает, какой заголовок к ней полагается: забытый
--- `content-type` — самая частая причина ответа 415 от чужой службы,
--- и стоит она получаса на разглядывание вполне правильного запроса.
---
--- Способ задать тело ровно один на запрос. `json` вместе с `body` —
--- это не «одно дополняет другое», а два разных намерения, и угадывать,
--- какое из них главнее, значит однажды угадать не так.
---
--- Тело формы кодируется тем же кодировщиком, что и параметры адреса:
--- `application/x-www-form-urlencoded` — это и есть строка запроса,
--- перенесённая в тело. Второй кодировщик здесь разошёлся бы с первым
--- на первом же списке значений.

local json = require('json')

local url = require('tnt.http.url')

local Module = {}

--- Заголовок содержимого для каждого способа задать тело.
Module.JSON_TYPE = 'application/json'
Module.FORM_TYPE = 'application/x-www-form-urlencoded'

--- Сколько знаков чужого ответа показывать в отказе разбора.
---
--- Двести: этого хватает, чтобы узнать страницу ошибки прокси или
--- HTML-заглушку вместо JSON, и мало, чтобы залить журнал чужим ответом
--- целиком.
Module.FRAGMENT = 200

--- Способы задать тело: поле запроса и то, чем оно оборачивается.
---@type string[]
local WAYS = { 'json', 'form', 'body' }

--- Начало чужого ответа для сообщения об отказе.
---@param text string
---@return string
function Module.fragment(text)
    if #text > Module.FRAGMENT then
        -- Начало среза — отрицательным индексом: у `sub(1, n)` мутанты
        -- `0` и `1-1` дают ту же строку, а у `-#text` единственный мутант
        -- `+#text` не проходит загрузку. Строка здесь непуста, и срез
        -- от `-#text` начинается с первого байта.
        return text:sub(-#text, Module.FRAGMENT) .. '…'
    end

    return text
end

--- Единственный названный способ задать тело.
---@param opts table
---@return string|nil way
---@return string|nil err
local function way_of(opts)
    local found

    for _, name in ipairs(WAYS) do
        if opts[name] ~= nil then
            if found ~= nil then
                return nil,
                    ('тело задано дважды: %s и %s — оставьте что-то одно'):format(
                        found,
                        name
                    )
            end

            found = name
        end
    end

    return found
end

--- Готовое тело запроса.
---@class TntHttpBody
---@field body string|nil Что уйдёт на сервер
---@field content_type string|nil Каким заголовком его пометить

--- Собирает тело запроса из того, как его задали.
---@param opts table Настройки запроса: json, form либо body
---@return TntHttpBody|nil rendered
---@return string|nil err
function Module.render(opts)
    local way, wrong = way_of(opts)

    if wrong ~= nil then
        return nil, wrong
    end

    if way == nil then
        return {}
    end

    if way == 'json' then
        -- Через pcall: json.encode бросает на таблице, ссылающейся на себя,
        -- и на cdata, которую он не знает. Уронить этим запрос значит
        -- уронить узел из-за опечатки в теле.
        local ok, encoded = pcall(json.encode, opts.json)

        if not ok then
            return nil, ('тело не собралось в JSON: %s'):format(tostring(encoded))
        end

        return { body = encoded, content_type = Module.JSON_TYPE }
    end

    if way == 'form' then
        local encoded, err = url.encode_query(opts.form)

        if encoded == nil then
            return nil, ('тело формы не собралось: %s'):format(err)
        end

        return { body = encoded, content_type = Module.FORM_TYPE }
    end

    if type(opts.body) ~= 'string' then
        return nil,
            ('body — это готовая строка, а пришло %s: таблицу задают через json или form'):format(
                type(opts.body)
            )
    end

    return { body = opts.body }
end

--- Разбирает тело ответа как JSON.
---
--- Отказ называет и причину, и начало того, что пришло: чаще всего
--- это страница ошибки прокси или HTML-заглушка, и по одному слову
--- «invalid token» этого не понять.
---@param text string|nil
---@return any value
---@return string|nil err
function Module.parse(text)
    if text == nil or text == '' then
        return nil, 'ответ пуст: разбирать как JSON нечего'
    end

    local ok, value = pcall(json.decode, text)

    if not ok then
        return nil,
            ('ответ не разобран как JSON: %s; начало ответа: %s'):format(
                tostring(value),
                Module.fragment(text)
            )
    end

    return value
end

return Module
