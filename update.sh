#!/bin/sh
# update.sh - обновление файлов роутера из github.com/zipfo/almond3s-gismeteo
# (plain-файлы поштучно, без архивов)
#
# Запуск на роутере (нужен интернет, репозиторий должен быть public):
#   curl -fsSL https://raw.githubusercontent.com/zipfo/almond3s-gismeteo/main/update/update.sh | sh
# Если репозиторий создан «в корень» (без папки update/):
#   curl -fsSL https://raw.githubusercontent.com/zipfo/almond3s-gismeteo/main/update.sh | sh
# Если ветка называется master - подставить master в URL.
#
# Как ищет файлы: каждый файл пробуется по двум путям - <путь> (файлы в корне
# репозитория) и update/<путь> (файлы внутри папки update/), и по двум веткам
# - main, затем master. Работает при любой из двух раскладок репозитория.
#
# Бэкап и восстановление:
#   - ПЕРВЫЙ запуск: перед записью оригинальные файлы роутера копируются
#     в /root/almond3s-bak/<путь> (этот снимок - «оригинал», он больше
#     никогда не перезаписывается);
#   - ПОСЛЕДУЮЩИЕ запуски: если бэкап найден, скрипт спрашивает:
#       [r] - восстановить файлы из бэкапа (откат к оригиналу)
#       [u] - обновить файлы из GitHub
#       пусто/что угодно - выход (ничего не меняем);
#   - без терминала (ответить не на чем) скрипт не гадает и выходит с ошибкой.
#
# Тестовые переопределения (обычно не нужны):
#   UPDATE_BASE=<url>  - база скачивания вместо raw.githubusercontent.com
#                        (поддерживается file://...)
#   UPDATE_ROOT=<dir>  - ставить файлы в <dir>/... вместо корня /
#   UPDATE_ANSWER=<r|u> - ответ вместо вопроса (для автоматизации/тестов)

REPO="zipfo/almond3s-gismeteo"

# Что обновляем - пути на роутере (= пути в репозитории).
# netfetch.sh тут не «на всякий случай»: weather_fetch.sh начинается со
# строки «. /etc/almond3s/scripts/netfetch.sh», и если файла нет, ash роняет
# весь скрипт (rc=2) - кэш погоды молча перестаёт обновляться по крону.
FILES="etc/almond3s/scripts/netfetch.sh etc/almond3s/scripts/weather_fetch.sh usr/libexec/almond3s/ui.uc"

WORK="/tmp/almond3s-upd"
ROOT="${UPDATE_ROOT:-}"
BAK="$ROOT/root/almond3s-bak"

log() { echo "[almond3s-upd] $*"; }

# Вопрос в терминал: stdin может быть занят телом скрипта (curl | sh),
# поэтому и читаем и пишем через /dev/tty.
ask() {
    REPLY=""
    if [ -n "$UPDATE_ANSWER" ]; then
        REPLY="$UPDATE_ANSWER"
        log "ответ задан заранее (UPDATE_ANSWER): $REPLY"
        return 0
    fi
    [ -r /dev/tty ] && [ -w /dev/tty ] || return 1
    ( printf '%s' "$1" > /dev/tty ) 2>/dev/null || return 1
    read REPLY < /dev/tty || return 1
    return 0
}

restart_lcd() {
    # Только при установке в реальный корень (не в тестовый UPDATE_ROOT).
    if [ -z "$ROOT" ] && [ -x /etc/init.d/almond3s-lcd ]; then
        if /etc/init.d/almond3s-lcd restart; then
            log "almond3s-lcd перезапущен - изменения активны"
        else
            log "ВНИМАНИЕ: перезапуск almond3s-lcd не удался"
        fi
    fi
}

restore() {
    N=0
    for rel in $FILES; do
        src="$BAK/$rel"
        if [ ! -f "$src" ]; then
            log "в бэкапе нет /$rel - пропущен"
            continue
        fi
        mkdir -p "$(dirname "$ROOT/$rel")"
        cp -p "$src" "$ROOT/$rel"
        chmod 755 "$ROOT/$rel"
        log "восстановлен: /$rel"
        N=$((N + 1))
    done
    [ "$N" -gt 0 ] || { log "бэкап пуст - нечего восстанавливать"; exit 1; }
    restart_lcd
    log "готово: восстановлено файлов: $N (из $BAK)"
    log "расписание погоды подхватит weather_fetch.sh само, в течение 15 минут"
    exit 0
}

# --- бэкап уже есть? это не первый запуск - спрашиваем, что делать --------
HAS_BAK=0
for rel in $FILES; do
    [ -f "$BAK/$rel" ] && { HAS_BAK=1; break; }
done
if [ "$HAS_BAK" = 1 ]; then
    if ! ask "Найден бэкап: $BAK
  [r] - восстановить файлы из бэкапа (откат к оригиналу)
  [u] - обновить файлы из GitHub
  Ваш выбор (r/u, пусто = выход): "; then
        log "нет терминала, чтобы спросить - запустите интерактивно (ssh)"
        exit 1
    fi
    case "$REPLY" in
        r | R | р | Р) restore ;;
        u | U | у | У) log "обновляем файлы из GitHub ..." ;;
        *) log "выход - ничего не менялось"; exit 0 ;;
    esac
fi

# --- базы скачивания ------------------------------------------------------
if [ -n "$UPDATE_BASE" ]; then
    BASES="$UPDATE_BASE"
else
    BASES="https://raw.githubusercontent.com/$REPO/main \
           https://raw.githubusercontent.com/$REPO/master"
fi

rm -rf "$WORK"
mkdir -p "$WORK" || { log "нет доступа к $WORK"; exit 1; }

# --- 1. скачать ВСЕ файлы (ничего не пишем в систему, пока не всё готово)
for rel in $FILES; do
    GOT=""
    for base in $BASES; do
        for p in "$rel" "update/$rel"; do
            if curl -fsSL -m 180 --connect-timeout 15 \
                    -o "$WORK/dl" "$base/$p"; then
                SZ="$(wc -c < "$WORK/dl" | tr -d ' ')"
                if [ "$SZ" -gt 200 ]; then
                    GOT="$base/$p"
                    break 2
                fi
            fi
        done
    done
    [ -n "$GOT" ] || {
        log "не скачался: $rel"
        log "  пробовали ветки main/master и пути <путь> / update/<путь>"
        log "  (репозиторий создан? он должен быть public?)"
        rm -rf "$WORK"
        exit 1
    }
    cp "$WORK/dl" "$WORK/staged_$(echo "$rel" | tr '/' '_')"
    log "скачан: $rel ($SZ байт) <- $GOT"
done

# --- 2. установить + бэкап оригинала перед перезаписью ---------------------
N=0
for rel in $FILES; do
    staged="$WORK/staged_$(echo "$rel" | tr '/' '_')"
    tgt="$ROOT/$rel"
    if [ -f "$tgt" ] && [ ! -f "$BAK/$rel" ]; then
        mkdir -p "$BAK/$(dirname "$rel")"
        cp -p "$tgt" "$BAK/$rel"
        log "бэкап оригинала: /$rel -> $BAK/$rel"
    fi
    mkdir -p "$(dirname "$tgt")"
    cp -p "$staged" "$tgt"
    chmod 755 "$tgt"   # curl отдаёт 644, а на роутере все эти файлы 755
    log "обновлён: /$rel"
    N=$((N + 1))
done

restart_lcd
log "готово: обновлено файлов: $N"
[ -d "$BAK" ] && log "оригиналы отложены в: $BAK (при следующем запуске спрошу r/u)"
log "расписание погоды подхватит weather_fetch.sh само, в течение 15 минут"
rm -rf "$WORK"
exit 0
