rockspec_format = '3.0'

package = 'tnt-http'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-http.git',
    branch = 'main',
}

description = {
    summary = 'Клиент HTTP для Tarantool: адрес, тело, сроки, переходы, повторы и поток',
    detailed = [[
        Клиент поверх http.client Tarantool, то есть libcurl, с принятыми
        решениями вместо обвеса, который иначе пишет каждый клиент чужой
        службы: базовый адрес, параметры запроса с кодированием по
        RFC 3986, тело в JSON и в форму, заголовки в нижнем регистре,
        ответ с json() и raise(). Незнакомая настройка — отказ, а не
        молчаливое «не действует».

        Отказ сети возвращается парой nil, err, где err — таблица с родом
        (invalid, unreachable, refused, status, idle) и приговором,
        читаемая и как строка; ответ 500 остаётся ответом. Переходы
        по Location клиент проходит сам: считает их, снимает заголовок
        входа при уходе на чужой узел и ходит только по http и https.
        Повторяет только идемпотентные методы и только отказы, которые
        лечит время, с уважением к Retry-After. Поток отдаёт тело кусками
        с пределом на сумму и на кусок; клиентский сертификат и сокет —
        настройками.

        Зависит от tnt-retry (паузы повторов и судья отказов), tnt-context
        (опознаватель запроса и заголовки трассы уезжают в каждую попытку
        сами), tnt-validate (проверка настроек), tnt-log (журнал), tnt-must
        (проверки аргументов) и tnt-external (подмена libcurl в проверках).
        Клиентский отрезок трассы на попытку ставится именованным крюком
        модуля: от трассировки клиент не зависит. Покрытие строк и убитых
        мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-http',
    issues_url = 'https://github.com/tnt-skein/tnt-http/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'http', 'http-client', 'libcurl', 'retry', 'streaming' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки аргументов крюка и бросок raise() без места.
    'tnt-must',
    -- Заголовки контекста файбера: x-request-id и трасса в каждой попытке.
    'tnt-context',
    -- Журнал отказов и сорвавшихся крюков.
    'tnt-log',
    -- Паузы повторов, общий срок, бюджет, размыкатель и судья отказов.
    'tnt-retry',
    -- libcurl как внешняя зависимость: её подменяют проверки.
    'tnt-external',
    -- Проверка настроек клиента, запроса и потока.
    'tnt-validate',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.http'] = 'tnt/http.lua',
        ['tnt.http.body'] = 'tnt/http/body.lua',
        ['tnt.http.failure'] = 'tnt/http/failure.lua',
        ['tnt.http.hook'] = 'tnt/http/hook.lua',
        ['tnt.http.policy'] = 'tnt/http/policy.lua',
        ['tnt.http.response'] = 'tnt/http/response.lua',
        ['tnt.http.settings'] = 'tnt/http/settings.lua',
        ['tnt.http.stream'] = 'tnt/http/stream.lua',
        ['tnt.http.transport'] = 'tnt/http/transport.lua',
        ['tnt.http.url'] = 'tnt/http/url.lua',
    },
}
