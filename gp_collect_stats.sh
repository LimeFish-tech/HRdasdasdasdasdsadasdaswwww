#!/bin/bash
# gp_collect_stats.sh – снимает текущие значения pg_stat_user_tables и сохраняет в лог

SCRIPT_NAME=$(basename "$0")
CONFIG_FILE="${SCRIPTS_DIR:-/usr/local/bin}/gp_maintenance.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Ошибка: конфиг $CONFIG_FILE не найден" >&2
    exit 1
fi

# Настройка логирования
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}.log"
exec >> "$LOG_FILE" 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') --- Запуск $SCRIPT_NAME ---"

# Проверка доступности psql
if ! command -v psql &> /dev/null; then
    echo "psql не найден, проверьте окружение Greenplum"
    exit 1
fi

# Создание таблицы лога, если её нет (на всякий случай)
psql -d "$DBNAME" -v ON_ERROR_STOP=1 -c "
CREATE TABLE IF NOT EXISTS public.gp_maintenance_stats_log (
    snapshot_ts timestamp default current_timestamp,
    schema_name text,
    table_name text,
    n_tup_ins bigint,
    n_tup_upd bigint,
    n_tup_del bigint,
    n_live_tup bigint,
    n_dead_tup bigint
) DISTRIBUTED BY (schema_name, table_name);
" || exit 1

# Вставка актуальной статистики по всем пользовательским таблицам
psql -d "$DBNAME" -v ON_ERROR_STOP=1 -c "
INSERT INTO public.gp_maintenance_stats_log
    (schema_name, table_name, n_tup_ins, n_tup_upd, n_tup_del, n_live_tup, n_dead_tup)
SELECT
    schemaname,
    relname,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    n_live_tup,
    n_dead_tup
FROM pg_stat_user_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit');
" || exit 1

echo "$(date '+%Y-%m-%d %H:%M:%S') --- $SCRIPT_NAME успешно завершён ---"
exit 0
