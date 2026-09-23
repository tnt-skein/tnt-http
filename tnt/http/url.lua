--- Адреса: кодирование, параметры запроса, сборка и разбор.
---
--- Модуль чистый: ни сети, ни времени, ни настроек. Всё, что он делает, —
--- превращает то, что написал разработчик, в строку адреса, которую поймёт
--- чужой сервер, и разбирает чужую ссылку обратно.
---
--- Кодируется по RFC 3986: нетронутыми остаются только буквы латиницы,
--- цифры и `-._~`, всё прочее уходит байтами в виде `%XX`. Кириллица тем
--- самым кодируется побайтно в UTF-8 — ровно так её ждёт всякий сервер,
--- и ровно так её покажет любой журнал доступа.
---
--- Пробел кодируется как `%20`, а не как `+`. Плюс законен только в теле
--- формы, а `%20` понимают и путь, и параметр, и форма: один кодировщик
--- на все три места вместо трёх похожих, расходящихся на четвёртый год.
---
--- Параметры выстраиваются по имени, а не как придёт из `pairs`. Порядок
--- в Lua не определён, и без сортировки один и тот же запрос собирался бы
--- каждый раз по-новому: подпись запроса перестала бы сходиться, а тест
--- ловил бы ошибку через раз.

local Module = {}

--- Порты, которые не пишутся в адресе: они и так подразумеваются схемой.
---
--- Нужны при сравнении узлов на переходе: `https://example.org` и
--- `https://example.org:443` — один и тот же узел, и снимать с перехода
--- заголовок входа из-за разницы в записи было бы неверно.
local DEFAULT_PORTS = {
    http = 80,
    https = 443,
}

--- Порт узла, о схеме которого мы ничего не знаем.
---
--- Ноль, а не пусто: `origin` собирает строку для сравнения, и пропуск
--- в ней превратил бы два разных узла в одну и ту же строку.
local UNKNOWN_PORT = 0

--- Начало абсолютного адреса: схема и `://`.
local SCHEME = '^(%a[%w+%-.]*)://'

--- Сколько знаков занимает `://` — разделитель схемы и узла.
local SEPARATOR = 3

--- Кодирует строку для адреса.
---@param text any Строка либо число
---@return string
function Module.encode(text)
    local encoded = tostring(text):gsub('[^A-Za-z0-9%-%._~]', function(char)
        return ('%%%02X'):format(char:byte())
    end)

    return encoded
end

--- Схемы, по которым клиент ходит.
---
--- Только веб, хотя libcurl знает и `file://`, и `gopher://`, и `dict://`.
--- Переход по `Location` на такой адрес прочёл бы файл узла или отправил
--- произвольные байты на внутренний порт, а ответ вернул бы телом. Сам
--- libcurl таких переходов не делает, но переходы клиент проходит сам,
--- и держать этот запрет обязан тоже сам.
---@type table<string, boolean>
Module.WEB = { http = true, https = true }

--- Абсолютный ли адрес: со схемой и узлом.
---@param url string
---@return boolean
function Module.is_absolute(url)
    return url:match(SCHEME) ~= nil
end

--- Схема адреса в нижнем регистре; у относительного — пусто.
---
--- Регистр схемы по RFC 3986 не значит ничего: `HTTPS://` — тот же веб,
--- что `https://`, и отказ на нём был бы придиркой.
---@param url string
---@return string
function Module.scheme(url)
    return (url:match(SCHEME) or ''):lower()
end

--- Значение параметра строкой.
---
--- Логическое значение пишется словом, а не единицей и нулём: `false`,
--- превращённый в `0`, на той стороне читается как «задано» — а задано
--- было обратное.
---@param value any
---@return string|nil text
---@return string|nil err
local function scalar_of(value)
    local kind = type(value)

    if kind == 'string' or kind == 'number' then
        return tostring(value)
    end

    if kind == 'boolean' then
        return value and 'true' or 'false'
    end

    return nil, ('значение %s нельзя записать в параметр запроса'):format(kind)
end

--- Дописывает одно значение параметра.
---@param parts string[]
---@param name string
---@param value any
---@return boolean ok
---@return string|nil err
local function append(parts, name, value)
    local text, err = scalar_of(value)

    if text == nil then
        return false, ('параметр %s: %s'):format(name, err)
    end

    table.insert(parts, ('%s=%s'):format(Module.encode(name), Module.encode(text)))

    return true
end

--- Имена параметров по порядку.
---
--- Имя обязано быть строкой: список вида `{ 'a', 'b' }` — это не набор
--- параметров, и молча превратить его в `1=a&2=b` значит отправить чужому
--- серверу бессмыслицу и искать её потом в его журналах.
---@param params table
---@return string[]|nil names
---@return string|nil err
local function names_of(params)
    local names = {}

    for name in pairs(params) do
        if type(name) ~= 'string' then
            return nil,
                ('имя параметра запроса должно быть строкой, а не %s'):format(
                    type(name)
                )
        end

        table.insert(names, name)
    end

    table.sort(names)

    return names
end

--- Собирает параметры запроса в строку.
---
--- Список значений превращается в повторённое имя: `{ tag = { 'a', 'b' } }`
--- даёт `tag=a&tag=b`. Так это понимают и Go, и Python, и PHP; запись
--- `tag[]=a` понимает только PHP, и выбирать её умолчанием значит удивить
--- всех остальных.
---@param params table<string, any>
---@return string|nil query Без ведущего знака вопроса
---@return string|nil err
function Module.encode_query(params)
    local names, wrong = names_of(params)

    if names == nil then
        return nil, wrong
    end

    local parts = {}

    for _, name in ipairs(names) do
        local value = params[name]

        -- box.NULL приходит из всякой таблицы, разобранной из JSON, и значит
        -- он там ровно «значения нет»: слать `name=cdata<void *>` незачем.
        if value ~= box.NULL then
            if type(value) == 'table' then
                for _, item in ipairs(value) do
                    local ok, err = append(parts, name, item)

                    if not ok then
                        return nil, err
                    end
                end
            else
                local ok, err = append(parts, name, value)

                if not ok then
                    return nil, err
                end
            end
        end
    end

    return table.concat(parts, '&')
end

--- Дописывает параметры к адресу.
---
--- Уже стоящие в адресе параметры остаются: базовый адрес службы иногда
--- несёт свой ключ доступа, и затереть его параметрами запроса значит
--- сломать запрос там, где вызывающий ничего плохого не делал.
---@param url string
---@param params table|nil
---@return string|nil url
---@return string|nil err
function Module.with_query(url, params)
    if params == nil then
        return url
    end

    local query, err = Module.encode_query(params)

    if query == nil then
        return nil, err
    end

    if query == '' then
        return url
    end

    local separator = '?'

    -- Поиск по экранированному образцу, а не «как есть» с первого знака:
    -- у начала `1` мутанты `0` и `1-1` находят тот же знак, а мутант флага
    -- `false` — тоже, ведь одиночный `?` и в образце значит сам себя.
    if url:find('%?') ~= nil then
        separator = '&'
    end

    return url .. separator .. query
end

--- Склеивает базовый адрес с адресом запроса.
---
--- Путь базового адреса — это приставка, а не корень: у `https://s/v1` и
--- запроса `/users` получается `https://s/v1/users`. По RFC 3986 разрешение
--- относительной ссылки дало бы `https://s/users`, потеряв `v1`, — но
--- базовый адрес задают как раз для того, чтобы не повторять `v1` в каждом
--- вызове.
---
--- Косые черты на стыке сводятся к одной: базовый адрес пишут и со
--- слэшем на конце, и без него, а путь — и с ведущим слэшем, и без.
--- Четыре сочетания обязаны дать один и тот же адрес, иначе сервер
--- отвечает 404 на запрос, отличающийся от рабочего одним знаком.
---
--- Косые черты снимают `rstrip` и `lstrip` Tarantool, а не замена
--- по образцу: у повтора `+` после косой черты мутанты `-` и `*`
--- при замене пустой строкой снимают те же знаки, и строку пришлось бы
--- исключать из проверки целиком.
---@param base string|nil
---@param target string|nil
---@return string
function Module.join(base, target)
    if target == nil or target == '' then
        return base or ''
    end

    if base == nil or base == '' or Module.is_absolute(target) then
        return target
    end

    return base:rstrip('/') .. '/' .. target:lstrip('/')
end

--- Разбирает адрес на схему, узел и остаток.
---@param url string
---@return string|nil scheme
---@return string authority Узел с учётными данными и портом; без схемы пусто
---@return string rest Путь с параметрами
function Module.split(url)
    local scheme, authority = url:match(SCHEME .. '([^/?#]*)')

    if scheme == nil then
        return nil, '', url
    end

    ---@cast authority string
    return scheme, authority, url:sub(#scheme + SEPARATOR + #authority + 1)
end

--- Путь запроса: то, что уходит в строку запроса после метода.
---
--- Нужен слоям запроса: маршрут, метрика и запись в журнале смотрят
--- на путь, а не на адрес целиком — иначе каждый запрос к тому же
--- обработчику выглядит новым из-за параметров.
---@param url string
---@return string path Путь с ведущей косой чертой
function Module.path(url)
    local _, _, rest = Module.split(url)
    local path = rest:gsub('[?#].*$', '')

    if path == '' then
        return '/'
    end

    return path
end

--- Узел адреса в сравнимом виде: схема, имя и порт.
---
--- Нужен там, где решается, свой ли адрес: заголовок входа снимается
--- при переходе на чужой узел. Порт по умолчанию проставляется явно,
--- имя приводится к нижнему регистру, учётные данные отбрасываются —
--- иначе `HTTPS://Example.org` и `https://example.org:443` считались бы
--- разными узлами.
---@param url string
---@return string|nil origin
function Module.origin(url)
    local scheme, authority = Module.split(url)

    if scheme == nil or authority == '' then
        return nil
    end

    local host = authority:gsub('^[^@]*@', '')

    -- Порт читается и снимается одним образцом. Двумя они обязаны
    -- согласоваться, и мутант повтора в чтении (`%d*` вместо `%d+`)
    -- был неотличим: пустая запись порта даёт `tonumber('')`, то есть
    -- пустоту, как и промах. Здесь пустой порт ещё и решает, снято ли
    -- двоеточие, — `example.org:` без него осталось бы в имени узла.
    local name, digits = host:match('^(.*):(%d*)$')
    local port = tonumber(digits)

    host = (name or host):lower()
    scheme = scheme:lower()

    return ('%s://%s:%d'):format(scheme, host, port or DEFAULT_PORTS[scheme] or UNKNOWN_PORT)
end

--- Каталог пути: всё до последней косой черты включительно.
---
--- Каталог берётся захватом, а не снятием хвоста: у снятия `[^/]*$`
--- мутант `[^/]+$` неотличим — пустой хвост и так заменяется пустым.
--- Совпадение есть всегда: `split` оставляет остаток с косой чертой,
--- знаком вопроса или решёткой впереди, и после снятия параметров
--- непустой путь начинается с косой черты. Черта записана набором
--- `[/]`: вплотную к звёздочке генератор мутантов принял бы её
--- за конец блочного комментария.
---@param rest string Путь с параметрами
---@return string
local function directory_of(rest)
    local path = rest:gsub('[?#].*$', '')

    if path == '' then
        return '/'
    end

    return path:match('^.*[/]') --[[@as string]]
end

--- Приводит адрес перехода к абсолютному.
---
--- Здесь правила RFC 3986 соблюдаются полностью, в отличие от `join`:
--- `Location` пишет сервер, а не разработчик, и вольничать с чужой ссылкой
--- нельзя — переход уедет не туда, куда велено.
---@param current string Адрес, с которого переходим
---@param location string Что сказал сервер в заголовке Location
---@return string|nil url
function Module.resolve(current, location)
    if location == '' then
        return nil
    end

    if Module.is_absolute(location) then
        return location
    end

    local scheme, authority, rest = Module.split(current)

    if scheme == nil then
        return nil
    end

    -- Ссылка без схемы, но с узлом: `//other.example.org/path`. Начало
    -- проверяет якорный поиск, а не срез `sub(1, 2)`: у среза мутанты
    -- `sub(0, 2)` и `sub(1-1, 2)` дают ту же строку.
    if location:find('^//') ~= nil then
        return scheme .. ':' .. location
    end

    local root = ('%s://%s'):format(scheme, authority)

    if location:find('^/') ~= nil then
        return root .. location
    end

    return root .. directory_of(rest) .. location
end

return Module
