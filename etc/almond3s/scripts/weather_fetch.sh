#!/bin/sh
# weather_fetch.sh — caches current weather for lcd_ui dashboard
#
# Провайдер выбирается в UCI:
#   almond3s.weather.provider = openmeteo | wttr | metno | gismeteo
#
# Schedule (every 15 min) — /etc/crontabs/root:
#   */15 * * * * /etc/almond3s/scripts/weather_fetch.sh
#
# Кэши:
#   /tmp/lcd_weather.txt     — текущая погода: condition|temp|feels|hum|wind|city
#   /tmp/lcd_weather_fc.txt  — прогноз тремя слотами (+2/+4/+6 часа): HH:MM на экране UI считает сам из localtime(epoch)
#   UI при ротухшем (>2 ч) или битом файле откатывается на прежнюю тройку «Ощущается/Влажность/Ветер».
#                              

# WCITY/WLAT/WLON/WNAME из env: ui.uc передаёт их напрямую при смене города, т.к.
# ucur.commit не сразу виден фоновому процессу (фетч успевал прочитать СТАРЫЙ
# город - баг «открылся Воронеж»). Cron зовёт без env - берёт из uci.
#
# ВАЖНО: переменные читаются как ${WLAT-...}, а НЕ ${WLAT:-...}. Для пресета
# ui.uc зовёт скрипт с ЯВНО ПУСТЫМИ WLAT= WLON=, и «:-» тут откатился бы к
# uci - и в окне гонки commit подставил бы закреплённые координаты прошлого
# города (проверено: просили Москву - приехала погода Владивостока). Одно
# тире уважает переданное пустое значение, поэтому пресет геокодится по имени.

CITY="${WCITY:-${CITY:-$(uci -q get almond3s.weather.city)}}"
[ -n "$CITY" ] || CITY="$(uci -q get lcd.weather.city)"
[ -n "$CITY" ] || CITY="Moscow"
PROVIDER=$(uci -q get almond3s.weather.provider)
[ -n "$PROVIDER" ] || PROVIDER="openmeteo"

OUT="/tmp/lcd_weather.txt"
TMP="/tmp/lcd_weather.txt.tmp"
GEO="/tmp/lcd_weather.geo"
FC="/tmp/lcd_weather_fc.txt"
FCTMP="/tmp/lcd_weather_fc.txt.tmp"
CANDF="/tmp/lcd_weather_fc.cands"

# Удаление старых временных файлов.
rm -f "$CANDF" "$FCTMP"
NOW=$(date +%s)
CMODE="epoch"   # как pick_fc переводит key кандидата в epoch: epoch|utc|offset
COFF="0"        # city-local wall -> epoch: civil(wall) - COFF

# Remove newlines and field separator to prevent breaking the format.
# Keeps UTF-8 characters intact.
DISPLAY_CITY=$(printf '%s' "$CITY" | tr -d '\r\n|')

. /etc/almond3s/scripts/netfetch.sh

# fetch <url> [timeout: по умолчанию 8с]
fetch() {
    nf_fetch "$1" "${2:-8}"
}

# ============================================================
#  Условия погоды: один case - и на текущую погоду, и на слоты
#  прогноза (там применяется только к 3 выбранным слотам).
# ============================================================

wmo_cond() {
    case "$1" in
        0|1)   COND="Sunny" ;;
        2)     COND="Partly cloudy" ;;
        3)     COND="Overcast" ;;
        45)    COND="Fog" ;;
        48)    COND="Freezing fog" ;;
        51|53) COND="Light drizzle" ;;
        55)    COND="Dense drizzle" ;;
        56)    COND="Freezing drizzle" ;;
        57)    COND="Heavy freezing drizzle" ;;
        61)    COND="Light rain" ;;
        63)    COND="Moderate rain" ;;
        65)    COND="Heavy rain" ;;
        66)    COND="Light freezing rain" ;;
        67)    COND="Moderate or heavy freezing rain" ;;
        71|77) COND="Light snow" ;;
        73)    COND="Moderate snow" ;;
        75)    COND="Heavy snow" ;;
        80)    COND="Light rain shower" ;;
        81)    COND="Moderate or heavy rain shower" ;;
        82)    COND="Torrential rain shower" ;;
        85)    COND="Light snow showers" ;;
        86)    COND="Moderate or heavy snow showers" ;;
        95)    COND="Thundery outbreaks possible" ;;
        96|99) COND="Moderate or heavy rain with thunder" ;;
        *)     COND="Cloudy" ;;
    esac
}

metno_cond() {
    # symbol_code у met.no: суффиксы _day/_night/_polartwilight отбрасываем,
    # дальше разбор базового кода. Гроза - «...andthunder» (НЕ «...thunder»);
    # в кодах ливневого мокрого и снежного дождя у них опечатка с лишней «s»
    # после light («lightssleetshowersandthunder», «lightssnowshowersandthunder»,
    # задокументировано на api.met.no), поэтому ловим обе формы. Порядок
    # важен: гроза и light/heavy раньше общих rain/snow.
    case "${1%%_*}" in
        *andthunder)                          COND="Moderate or heavy rain with thunder" ;;
        clearsky)                             COND="Sunny" ;;
        fair|partlycloudy)                    COND="Partly cloudy" ;;
        cloudy)                               COND="Overcast" ;;
        fog)                                  COND="Fog" ;;
        lightrainshowers)                     COND="Light rain shower" ;;
        rainshowers)                          COND="Moderate or heavy rain shower" ;;
        heavyrainshowers)                     COND="Torrential rain shower" ;;
        lightsleetshowers|lightssleetshowers) COND="Light sleet showers" ;;
        sleetshowers|heavysleetshowers)       COND="Moderate or heavy sleet showers" ;;
        snowshowers|heavysnowshowers)         COND="Moderate or heavy snow showers" ;;
        lightsnowshowers|lightssnowshowers)   COND="Light snow showers" ;;
        heavyrain|heavysleet*)                COND="Heavy rain" ;;
        rain*)                                COND="Moderate rain" ;;
        lightsleet*|lightssleet*)             COND="Light sleet" ;;
        sleet*)                               COND="Moderate or heavy sleet" ;;
        lightrain*)                           COND="Light rain" ;;
        lightsnow*|lightssnow*)               COND="Light snow" ;;
        heavysnow*)                           COND="Heavy snow" ;;
        snow*)                                COND="Moderate snow" ;;
        *)                                    COND="Cloudy" ;;
    esac
}

gismeteo_cond() {
    # Нормализация: Cyrillic С (U+0421, так Gismeteo пишет «Сlear») -> c,
    # затем ASCII-lower. Порог отлова проверен на 15/15 наблюдавшихся descr
    # (gistest: cond_case_fixed.sh/verify_fix.py): туман раньше ловился ПОСЛЕ
    # «ясно/облачно», «Mainly cloudy» надо было отличать от «Cloudy», а
    # «snow and rain» уезжало в снег.
    DESC=$(printf '%s' "$1" | sed 's/С/c/g' | tr 'A-Z' 'a-z')
    case "$DESC" in
        *thunder*|*гроза*)                      COND="Moderate or heavy rain with thunder" ;;
        *rain*and*snow*|*snow*and*rain*|*sleet*|*мокрый*снег*) COND="Moderate rain" ;;
        *heavy*rain*|*сильный*дожд*)            COND="Heavy rain" ;;
        *light*rain*|*небольшой*дожд*)          COND="Light rain" ;;
        *rain*|*дожд*)                          COND="Moderate rain" ;;
        *heavy*snow*|*сильный*снег*)            COND="Heavy snow" ;;
        *light*snow*|*небольшой*снег*)          COND="Light snow" ;;
        *snow*|*снег*)                          COND="Moderate snow" ;;
        *fog*|*туман*)                          COND="Fog" ;;
        *clear*|*ясно*)                         COND="Sunny" ;;
        *partly*cloud*|*переменн*|*малооблачн*) COND="Partly cloudy" ;;
        *mainly*cloud*|*пасмурн*)               COND="Overcast" ;;
        *cloud*|*облачн*)                       COND="Cloudy" ;;
        *drizzle*|*морось*)                     COND="Light drizzle" ;;
        *)                                      COND="Cloudy" ;;
    esac
}

# ============================================================
#  Прогноз: выбор 3 слотов (+2/+4/+6 ч) из кандидатов провайдера
# ============================================================
#
# stdin : «key|temp|rawcond», где key =
#           epoch                      (mode=epoch, openmeteo)
#           wall UTC    «YYYY-MM-DDTHH:MM:SSZ» (mode=utc, metno)
#           wall городской (mode=offset: gismeteo valid / wttr date+time;
#           civil(wall) - COFF = epoch).
# stdout: ровно 3 (или меньше) строки «epoch|temp|rawcond» - ближайшие к
#         now+2ч/now+4ч/now+6ч, строго растущие по времени.
pick_fc() {
    awk -v mode="$CMODE" -v off="$COFF" -v now="$NOW" '
    function civil(s,   y, m, d, h, mi, se, yy, era, yoe, doy, doe) {
        y = substr(s, 1, 4) + 0; m = substr(s, 5, 2) + 0; d = substr(s, 7, 2) + 0;
        h = substr(s, 9, 2) + 0; mi = substr(s, 11, 2) + 0; se = substr(s, 13, 2) + 0;
        yy = (m <= 2) ? y - 1 : y;
        era = int((yy - (yy >= 0 ? 0 : 399)) / 400);
        yoe = yy - era * 400;
        doy = int((153 * ((m > 2) ? m - 3 : m + 9) + 2) / 5) + d - 1;
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
        return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se;
    }
    BEGIN { FS = "|"; n = 0 }
    {
        k = $1;
        if (mode == "epoch") {
            e = k + 0;
        } else {
            gsub(/[^0-9]/, "", k);
            if (length(k) < 14) { while (length(k) < 14) k = k "0"; }
            else if (length(k) > 14) k = substr(k, 1, 14);
            e = civil(k);
            if (mode == "offset") e -= off + 0;
        }
        if ($2 == "" || e < now - 60) next;
        found = 0;
        for (j = 1; j <= n; j++) if (E[j] == e) { found = 1; break }
        if (found) next;
        i = n;
        while (i > 0 && E[i] > e) {
            E[i + 1] = E[i]; T[i + 1] = T[i]; K[i + 1] = K[i]; i--;
        }
        E[i + 1] = e; T[i + 1] = $2; K[i + 1] = $3; n++;
    }
    END {
        prev = now - 60;
        for (s = 1; s <= 3; s++) {
            tgt = now + s * 7200;          # +2, +4, +6 часов
            best = -1; bd = 0;
            for (i = 1; i <= n; i++) {
                if (E[i] <= prev) continue;
                d = E[i] - tgt; if (d < 0) d = -d;
                if (best < 0 || d < bd) { best = i; bd = d }
            }
            if (best < 0) break;
            printf "%d|%s|%s\n", E[best], T[best], K[best];
            prev = E[best];
        }
    }'
}

# write_fc: кандидаты (CANDF) -> 3 слота -> перевод rawcond в COND -> атомарная
# запись FC. Меньше 3 валидных слотов или битая строка — прежний кэш не трогаем.
write_fc() {
    [ -f "$CANDF" ] || return 0
    pick_fc < "$CANDF" | while IFS='|' read -r e t rc; do
        case "$PROVIDER" in
            openmeteo) wmo_cond "${rc:-x}" ;;
            metno)     metno_cond "${rc:-x}" ;;
            gismeteo)  gismeteo_cond "${rc:-x}" ;;
            *)         # wttr: английский desc наружу как есть (как и текущая
                       # погода) - иконку и WCOND_RU в UI разберут.
                       COND=$(printf '%s' "$rc" | tr -d '\r\n|')
                       [ -n "$COND" ] || COND="Cloudy" ;;
        esac
        # Температура слота - в том же виде, что и в текущей погоде:
        # «+7°C» (кегль2, ° у числа, C отдельной единицей у split_unit).
        tv=$(awk -v v="$t" 'BEGIN{
            if (v ~ /^[-+]?[0-9]+([.][0-9]+)?$/) printf "%+.0f°C", v;
            else print v }')
        printf '%s|%s|%s\n' "$e" "$tv" "$COND"
    done > "$FCTMP"
    if awk -F'|' -v now="$NOW" '
        NF != 3              { bad = 1 }
        $1 !~ /^[0-9]+$/     { bad = 1 }
        $1 + 0 < now - 1800  { bad = 1 }
        $2 == "" || $3 == "" { bad = 1 }
        END { exit (NR == 3 && !bad) ? 0 : 1 }' "$FCTMP" 2>/dev/null
    then
        mv "$FCTMP" "$FC"
    else
        rm -f "$FCTMP"
    fi
    rm -f "$CANDF"
}

if [ "$PROVIDER" = wttr ]; then
    CU=$(printf '%s' "$CITY" | tr ' ' '+')
    # %T = местное время с смещением зоны («16:03:28+0300»): оно же - ключ к
    # переводу почасовых слотов j1 (они местные) в epoch. Если wttr вдруг не
    # знает токен и пустит весь ответ (так бывает), повторяем старый формат:
    # текущая погода важнее прогноза.
    R=$(fetch "https://wttr.in/${CU}?format=%C|%t|%f|%h|%w|%T&m")
    TZP=${R##*|}
    COFF=$(awk -v s="$TZP" 'BEGIN{
        if (length(s) < 5) exit 1;
        o = substr(s, length(s) - 4);
        if (o !~ /^[+-][0-9][0-9][0-9][0-9]$/) exit 1;
        v = (substr(o, 2, 2) + 0) * 3600 + (substr(o, 4, 2) + 0) * 60;
        if (substr(o, 1, 1) == "-") v = -v;
        print v }') || COFF=""
    if [ -n "$COFF" ] && [ -n "$R" ]; then
        R=${R%|*}                      # отрезали поле %T - в OUT его не надо
    elif [ -n "$R" ]; then
        # %T не пришёл: последнее поле - либо ветер (оставляем), либо мусор
        # (срезаем, иначе он уедет в кэш вместо города).
        case "$TZP" in
            *km/h*|*mph*|*m/s*|*kph*|*calm*) ;;
            *) R=${R%|*} ;;
        esac
        COFF=""
    fi
    if [ -z "$R" ]; then
        COFF=""
        R=$(fetch "https://wttr.in/${CU}?format=%C|%t|%f|%h|%w&m")
    fi
    [ -n "$R" ] || exit 0
    printf '%s|%s\n' "$R" "$DISPLAY_CITY" > "$TMP"

    # Прогноз: j1 с почасовыми слотами на 3 дня (местное время города).
    # Лучше-усердие: сбоя тут не должно ронять уже записанную текущую погоду.
    if [ -n "$COFF" ]; then
        J=$(fetch "https://wttr.in/${CU}?format=j1&m" 12)
        if [ -n "$J" ]; then
            CMODE=offset
            : > "$CANDF"
            for d in 0 1 2; do
                DD=$(printf '%s' "$J" | jsonfilter -e "@.weather[$d].date" 2>/dev/null)
                [ -n "$DD" ] || break
                TS=$(printf '%s' "$J" | jsonfilter -e "@.weather[$d].hourly[*].time" 2>/dev/null)
                TP=$(printf '%s' "$J" | jsonfilter -e "@.weather[$d].hourly[*].tempC" 2>/dev/null)
                DS=$(printf '%s' "$J" | jsonfilter -e "@.weather[$d].hourly[*].weatherDesc[*].value" 2>/dev/null)
                awk -v dt="$DD" -v ts="$TS" -v tp="$TP" -v ds="$DS" 'BEGIN{
                    nt = split(ts, T, "\n"); split(tp, P, "\n"); split(ds, D, "\n");
                    dd = dt; gsub(/[^0-9]/, "", dd);
                    for (i = 1; i <= nt; i++) {
                        if (P[i] == "" || D[i] == "") continue;
                        desc = D[i];
                        gsub(/^[ \t]+|[ \t]+$/, "", desc);
                        gsub(/\|/, "", desc);
                        if (desc == "") continue;
                        printf "%s%04d|%s|%s\n", dd, T[i] + 0, P[i], desc;
                    }}' >> "$CANDF"
            done
        fi
    fi

elif [ "$PROVIDER" = metno ]; then
    LAT=""; LON=""; NM=""
        ULAT="${WLAT-$(uci -q get almond3s.weather.lat)}"
        ULON="${WLON-$(uci -q get almond3s.weather.lon)}"
    if [ -n "$ULAT" ] && [ -n "$ULON" ]; then
        LAT="$ULAT"; LON="$ULON"
        NM="${WNAME-$(uci -q get almond3s.weather.name)}"
    else
        if [ -f "$GEO" ] && [ "$(cut -f1 "$GEO")" = "$CITY" ]; then
            LAT=$(cut -f2 "$GEO"); LON=$(cut -f3 "$GEO"); NM=$(cut -f4 "$GEO")
        fi
        if [ -z "$LAT" ] || [ -z "$LON" ]; then
            CU=$(printf '%s' "$CITY" | tr ' ' '+')
            G=$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=${CU}&count=1&language=ru&format=json")
            LAT=$(printf '%s' "$G" | jsonfilter -e '@.results[0].latitude' 2>/dev/null)
            LON=$(printf '%s' "$G" | jsonfilter -e '@.results[0].longitude' 2>/dev/null)
            NM=$(printf  '%s' "$G" | jsonfilter -e '@.results[0].name' 2>/dev/null | tr -d '|')
            [ -n "$LAT" ] && [ -n "$LON" ] && printf '%s\t%s\t%s\t%s\n' "$CITY" "$LAT" "$LON" "$NM" > "$GEO"
        fi
    fi
    [ -n "$LAT" ] && [ -n "$LON" ] || exit 0
    [ -n "$NM" ] && DISPLAY_CITY=$(printf '%s' "$NM" | tr -d '\r\n|')

    # met.no 403-ит запрос без User-Agent с уникальным идентификатором и
    # контактом (см. их Terms of Service), поэтому адрес - реальный репозиторий,
    # из которого ставится этот скрипт (update.sh тянет оттуда же).
    # NF_UA читает netfetch.sh - без поддержки переменной запрос уйдёт без UA.
    NF_UA="almond3s-lcd-ui/1.0 (+https://github.com/zipfo/almond3s-gismeteo)"
    W=$(fetch "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=${LAT}&lon=${LON}")
    NF_UA=""
    [ -n "$W" ] || exit 0

    T=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.air_temperature' 2>/dev/null)
    F=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.apparent_temperature' 2>/dev/null)
    H=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.relative_humidity' 2>/dev/null)
    WS=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.wind_speed' 2>/dev/null)
    WD=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.wind_from_direction' 2>/dev/null)
    SYM=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.next_1_hours.summary.symbol_code' 2>/dev/null)
    [ -n "$T" ] || exit 0
    [ -n "$F" ] || F="$T"

    metno_cond "$SYM"

    TEMP=$(awk  -v v="$T"  'BEGIN{printf "%+.0f", v}')"°C"
    FEELS=$(awk -v v="$F"  'BEGIN{printf "%+.0f", v}')"°C"
    HUM=$(awk   -v v="$H"  'BEGIN{printf "%.0f", v}')"%"
    KMH=$(awk   -v v="$WS" 'BEGIN{printf "%.0f", v*3.6}')   # m/s -> km/h
    ARROW=$(awk -v d="$WD" 'BEGIN{
        if (d=="") { print "→"; exit }
        split("↑ ↗ → ↘ ↓ ↙ ← ↖", a, " ");
        to=(d+180)%360; s=int((to+22.5)/45)%8;
        print a[s+1];
    }')
    printf '%s|%s|%s|%s|%s%s|%s\n' "$COND" "$TEMP" "$FEELS" "$HUM" "$ARROW" "${KMH}km/h" "$DISPLAY_CITY" > "$TMP"

    # Прогноз: первые ~24 записи timeseries - почасовые (потом6-часовые),
    # время ISO в UTC. next_1_hours у6-часовых записей нет - берём6-часовой
    # символ начала периода.
    CMODE=utc
    : > "$CANDF"
    mi=0
    while [ "$mi" -lt 24 ]; do
        TI=$(printf '%s' "$W" | jsonfilter -e "@.properties.timeseries[$mi].time" 2>/dev/null)
        [ -n "$TI" ] || break
        TP=$(printf '%s' "$W" | jsonfilter -e "@.properties.timeseries[$mi].data.instant.details.air_temperature" 2>/dev/null)
        SY=$(printf '%s' "$W" | jsonfilter -e "@.properties.timeseries[$mi].data.next_1_hours.summary.symbol_code" 2>/dev/null)
        [ -n "$SY" ] || SY=$(printf '%s' "$W" | jsonfilter -e "@.properties.timeseries[$mi].data.next_6_hours.summary.symbol_code" 2>/dev/null)
        [ -n "$TP" ] && printf '%s|%s|%s\n' "$TI" "$TP" "${SY:-unknown}" >> "$CANDF"
        mi=$((mi + 1))
    done

elif [ "$PROVIDER" = gismeteo ]; then
    LAT=""; LON=""; NM=""
        ULAT="${WLAT-$(uci -q get almond3s.weather.lat)}"
        ULON="${WLON-$(uci -q get almond3s.weather.lon)}"
    if [ -n "$ULAT" ] && [ -n "$ULON" ]; then
        LAT="$ULAT"; LON="$ULON"
        NM="${WNAME-$(uci -q get almond3s.weather.name)}"
    else
        if [ -f "$GEO" ] && [ "$(cut -f1 "$GEO")" = "$CITY" ]; then
            LAT=$(cut -f2 "$GEO"); LON=$(cut -f3 "$GEO"); NM=$(cut -f4 "$GEO")
        fi
        if [ -z "$LAT" ] || [ -z "$LON" ]; then
            CU=$(printf '%s' "$CITY" | tr ' ' '+')
            G=$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=${CU}&count=1&language=ru&format=json")
            LAT=$(printf '%s' "$G" | jsonfilter -e '@.results[0].latitude' 2>/dev/null)
            LON=$(printf '%s' "$G" | jsonfilter -e '@.results[0].longitude' 2>/dev/null)
            NM=$(printf  '%s' "$G" | jsonfilter -e '@.results[0].name' 2>/dev/null | tr -d '|')
            [ -n "$LAT" ] && [ -n "$LON" ] && printf '%s\t%s\t%s\t%s\n' "$CITY" "$LAT" "$LON" "$NM" > "$GEO"
        fi
    fi
    [ -n "$LAT" ] && [ -n "$LON" ] || exit 0
    [ -n "$NM" ] && DISPLAY_CITY=$(printf '%s' "$NM" | tr -d '\r\n|')

    GIS_API="https://services.gismeteo.ru/inform-service/inf_chrome"
    CITIES_XML=$(fetch "${GIS_API}/cities/?lat=${LAT}&lng=${LON}&count=10&lang=en")
    [ -n "$CITIES_XML" ] || exit 0

    CITY_ID=$(printf '%s' "$CITIES_XML" | tr '<' '\n' | sed -n 's/^item id="\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$CITY_ID" ] || exit 0

    FC_XML=$(fetch "${GIS_API}/forecast/?city=${CITY_ID}&lang=en")
    [ -n "$FC_XML" ] || exit 0

    VALUES_TAG=$(printf '%s' "$FC_XML" | tr '<' '\n' | grep '^values ' | head -n1)
    [ -n "$VALUES_TAG" ] || exit 0

    attr() { printf '%s' "$1" | sed -n "s/.* $2=\"\([^\"]*\)\".*/\1/p"; }

    T=$(attr "$VALUES_TAG" "t")
    F=$(attr "$VALUES_TAG" "tflt")
    H=$(attr "$VALUES_TAG" "hum")
    WS=$(attr "$VALUES_TAG" "ws")
    WD=$(attr "$VALUES_TAG" "wd")
    DESC=$(attr "$VALUES_TAG" "descr")

    [ -n "$T" ] || exit 0
    [ -n "$F" ] || F="$T"

    gismeteo_cond "$DESC"

    TEMP=$(awk  -v v="$T"  'BEGIN{printf "%+.0f", v}')"°C"
    FEELS=$(awk -v v="$F"  'BEGIN{printf "%+.0f", v}')"°C"
    HUM=$(awk   -v v="$H"  'BEGIN{printf "%.0f", v}')"%"
    KMH=$(awk   -v v="$WS" 'BEGIN{printf "%.0f", v*3.6}')   # m/s -> km/h
    ARROW=$(awk -v d="$WD" 'BEGIN{
        if (d=="") { print "→"; exit }
        split("↑ ↗ → ↘ ↓ ↙ ← ↖", a, " ");
        # wd у Gismeteo - сектор1..8 (1=С); сверено с Open-Meteo/met.no:
        # wd=1 -> 0°, wd=4 -> 135°. Старое (d%8)*45 давало сектором ВПЕРЁД.
        deg=(((d - 1) % 8 + 8) % 8) * 45;
        to=(deg+180)%360; s=int((to+22.5)/45)%8;
        print a[s+1];
    }')
    printf '%s|%s|%s|%s|%s%s|%s\n' "$COND" "$TEMP" "$FEELS" "$HUM" "$ARROW" "${KMH}km/h" "$DISPLAY_CITY" > "$TMP"

    # Прогноз: <forecast valid="YYYY-MM-DDTHH:MM:SS"> + <values t descr>.
    # valid - местное время города; tzone из <location> - смещение в минутах.
    TZO=$(printf '%s' "$FC_XML" | tr '<' '\n' | sed -n 's/.* tzone="\([^"]*\)".*/\1/p' | head -n1)
    case "$TZO" in
        ""|*[!0-9-]*) COFF="" ;;
        *) COFF=$((TZO * 60)) ;;
    esac
    CMODE=offset
    : > "$CANDF"
    if [ -n "$COFF" ]; then
        printf '%s' "$FC_XML" | tr '<' '\n' | awk '
            /^fact /      { infl = 0 }
            /^forecast /  { infl = match($0, /valid="[^"]*"/) ? 1 : 0;
                            valid = infl ? substr($0, RSTART + 7, RLENGTH - 8) : "" }
            /^values / && infl {
                t = ""; desc = "";
                if (match($0, / t="[^"]*"/))   t    = substr($0, RSTART + 4, RLENGTH - 5);
                if (match($0, / descr="[^"]*"/)) desc = substr($0, RSTART + 8, RLENGTH - 9);
                if (valid != "" && t != "" && desc != "")
                    printf "%s|%s|%s\n", valid, t, desc;
                infl = 0;
            }' >> "$CANDF"
    fi

else
    # Open-Meteo (default)
    LAT=""; LON=""; NM=""
        ULAT="${WLAT-$(uci -q get almond3s.weather.lat)}"
        ULON="${WLON-$(uci -q get almond3s.weather.lon)}"
    if [ -n "$ULAT" ] && [ -n "$ULON" ]; then
        LAT="$ULAT"; LON="$ULON"
        NM="${WNAME-$(uci -q get almond3s.weather.name)}"
    else
        if [ -f "$GEO" ] && [ "$(cut -f1 "$GEO")" = "$CITY" ]; then
            LAT=$(cut -f2 "$GEO"); LON=$(cut -f3 "$GEO"); NM=$(cut -f4 "$GEO")
        fi
        if [ -z "$LAT" ] || [ -z "$LON" ]; then
            CU=$(printf '%s' "$CITY" | tr ' ' '+')
            G=$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=${CU}&count=1&language=ru&format=json")
            LAT=$(printf '%s' "$G" | jsonfilter -e '@.results[0].latitude' 2>/dev/null)
            LON=$(printf '%s' "$G" | jsonfilter -e '@.results[0].longitude' 2>/dev/null)
            NM=$(printf  '%s' "$G" | jsonfilter -e '@.results[0].name' 2>/dev/null | tr -d '|')
            [ -n "$LAT" ] && [ -n "$LON" ] && printf '%s\t%s\t%s\t%s\n' "$CITY" "$LAT" "$LON" "$NM" > "$GEO"
        fi
    fi
    [ -n "$LAT" ] && [ -n "$LON" ] || exit 0
    [ -n "$NM" ] && DISPLAY_CITY=$(printf '%s' "$NM" | tr -d '\r\n|')

    # Один запрос и на текущую погоду, и на почасовой прогноз: hourly.time
    # при timeformat=unixtime - готовые epoch, никаких переводов времени.
    W=$(fetch "https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,weather_code&hourly=temperature_2m,weather_code&forecast_days=2&timezone=auto&timeformat=unixtime")
    [ -n "$W" ] || exit 0

    T=$(printf  '%s' "$W" | jsonfilter -e '@.current.temperature_2m' 2>/dev/null)
    F=$(printf  '%s' "$W" | jsonfilter -e '@.current.apparent_temperature' 2>/dev/null)
    H=$(printf  '%s' "$W" | jsonfilter -e '@.current.relative_humidity_2m' 2>/dev/null)
    WS=$(printf '%s' "$W" | jsonfilter -e '@.current.wind_speed_10m' 2>/dev/null)
    WD=$(printf '%s' "$W" | jsonfilter -e '@.current.wind_direction_10m' 2>/dev/null)
    WC=$(printf '%s' "$W" | jsonfilter -e '@.current.weather_code' 2>/dev/null)
    [ -n "$T" ] || exit 0
    [ -n "$F" ] || F="$T"

    wmo_cond "$WC"

    TEMP=$(awk  -v v="$T"  'BEGIN{printf "%+.0f", v}')"°C"
    FEELS=$(awk -v v="$F"  'BEGIN{printf "%+.0f", v}')"°C"
    HUM=$(awk   -v v="$H"  'BEGIN{printf "%.0f", v}')"%"
    KMH=$(awk   -v v="$WS" 'BEGIN{printf "%.0f", v}')   # Open-Meteo default is km/h
    ARROW=$(awk -v d="$WD" 'BEGIN{
        if (d=="") { print "→"; exit }
        split("↑ ↗ → ↘ ↓ ↙ ← ↖", a, " ");
        to=(d+180)%360; s=int((to+22.5)/45)%8;
        print a[s+1];
    }')
    printf '%s|%s|%s|%s|%s%s|%s\n' "$COND" "$TEMP" "$FEELS" "$HUM" "$ARROW" "${KMH}km/h" "$DISPLAY_CITY" > "$TMP"

    # Прогноз: три выровненных массива (время/температура/код), время - epoch.
    CMODE=epoch
    : > "$CANDF"
    OT=$(printf '%s' "$W" | jsonfilter -e '@.hourly.time[*]' 2>/dev/null)
    OP=$(printf '%s' "$W" | jsonfilter -e '@.hourly.temperature_2m[*]' 2>/dev/null)
    OC=$(printf '%s' "$W" | jsonfilter -e '@.hourly.weather_code[*]' 2>/dev/null)
    awk -v a="$OT" -v b="$OP" -v c="$OC" 'BEGIN{
        n = split(a, A, "\n"); split(b, B, "\n"); split(c, Cc, "\n");
        for (i = 1; i <= n; i++)
            if (A[i] != "" && B[i] != "")
                printf "%s|%s|%s\n", A[i], B[i], Cc[i]
    }' >> "$CANDF"
fi

# Sanity: exactly 6 fields — otherwise keep the previous working cache.
fields=$(awk -F'|' '{print NF}' "$TMP" 2>/dev/null)
if [ -n "$fields" ] && [ "$fields" -ge 6 ]; then
    mv "$TMP" "$OUT"
    write_fc
else
    rm -f "$TMP"
    rm -f "$CANDF"
fi
