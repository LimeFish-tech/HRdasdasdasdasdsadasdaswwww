#!/bin/bash
# gp_maintenance_scheduler.sh – анализирует статистику, проверяет блокировки и планирует задачи

SCRIPT_NAME=$(basename "$0")
CONFIG_FILE="${SCRIPTS_DIR:-/usr/local/bin}/gp_maintenance.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Ошибка: конфиг $CONFIG_FILE не найден" >&2
    exit 1
fi

LOG_FILE="$LOG_DIR/${SCRIPT_NAME}.log"
mkdir -p "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') --- Запуск $SCRIPT_NAME ---"

# Получаем список таблиц, для которых нужно планировать обслуживание,
# исключая те, которые уже есть в очереди в статусе 'pending' или 'running'
PLAN_QUERY=$(cat <<EOF
WITH last_two_snapshots AS (
    SELECT
        schema_name,
        table_name,
        snapshot_ts,
        n_tup_ins,
        n_tup_upd,
        n_tup_del,
        n_live_tup,
        n_dead_tup,
        ROW_NUMBER() OVER (PARTITION BY schema_name, table_name ORDER BY snapshot_ts DESC) AS rn
    FROM public.gp_maintenance_stats_log
),
snapshot_pairs AS (
    SELECT
        s1.schema_name,
        s1.table_name,
        s1.n_dead_tup AS current_dead,
        s1.n_live_tup AS current_live,
        (s1.n_tup_ins - COALESCE(s2.n_tup_ins, 0)) AS delta_ins,
        (s1.n_tup_upd - COALESCE(s2.n_tup_upd, 0)) AS delta_upd,
        (s1.n_tup_del - COALESCE(s2.n_tup_del, 0)) AS delta_del,
        CASE WHEN s1.n_live_tup > 0 THEN s1.n_dead_tup::float / s1.n_live_tup ELSE 0 END AS dead_ratio
    FROM last_two_snapshots s1
    LEFT JOIN last_two_snapshots s2
        ON s1.schema_name = s2.schema_name
        AND s1.table_name = s2.table_name
        AND s2.rn = 2
    WHERE s1.rn = 1
),
excluded_tables AS (
    SELECT table_name, op_type
    FROM public.gp_maintenance_queue
    WHERE status IN ('pending', 'running')
)
SELECT
    sp.schema_name || '.' || sp.table_name AS full_name,
    sp.current_dead,
    sp.current_live,
    sp.dead_ratio,
    sp.delta_ins,
    sp.delta_upd,
    sp.delta_del,
    CASE
        WHEN sp.dead_ratio >= ${MIN_DEAD_RATIO_FULL} AND sp.current_dead >= ${MIN_DEAD_TUPLES_FULL}
             AND NOT EXISTS (SELECT 1 FROM excluded_tables et WHERE et.table_name = sp.schema_name || '.' || sp.table_name AND et.op_type = 'vacuum_full_analyze')
             THEN 'vacuum_full_analyze'
        WHEN sp.dead_ratio >= ${MIN_DEAD_RATIO_VACUUM} AND sp.current_dead >= ${MIN_DEAD_TUPLES_VACUUM}
             AND NOT EXISTS (SELECT 1 FROM excluded_tables et WHERE et.table_name = sp.schema_name || '.' || sp.table_name AND et.op_type = 'vacuum')
             THEN 'vacuum'
        WHEN (sp.delta_ins + sp.delta_upd + sp.delta_del) >= ${MIN_ANALYZE_DELTA_ROWS}
             AND NOT EXISTS (SELECT 1 FROM excluded_tables et WHERE et.table_name = sp.schema_name || '.' || sp.table_name AND et.op_type = 'analyze')
             THEN 'analyze'
        ELSE NULL
    END AS needed_op
FROM snapshot_pairs sp
WHERE (sp.dead_ratio >= ${MIN_DEAD_RATIO_VACUUM} AND sp.current_dead >= ${MIN_DEAD_TUPLES_VACUUM})
   OR (sp.delta_ins + sp.delta_upd + sp.delta_del) >= ${MIN_ANALYZE_DELTA_ROWS}
EOF
)

# Выполняем планирование: для каждой таблицы с флагом needed_op проверяем доступность блокировки (NOWAIT)
psql -d "$DBNAME" -t -A -F'|' -c "$PLAN_QUERY" | while IFS='|' read full_name current_dead current_live dead_ratio delta_ins delta_upd delta_del needed_op; do
    if [ -z "$needed_op" ]; then
        continue
    fi

    echo "Планируем $needed_op для $full_name (dead=$current_dead, live=$current_live, ratio=$dead_ratio, deltas: ins=$delta_ins upd=$delta_upd del=$delta_del)"

    # Проверка возможности получения блокировки без ожидания
    lock_mode=""
    case "$needed_op" in
        vacuum|vacuum_full_analyze)
            lock_mode="ACCESS EXCLUSIVE"
            ;;
        analyze)
            lock_mode="SHARE UPDATE EXCLUSIVE"
            ;;
    esac

    if psql -d "$DBNAME" -v ON_ERROR_STOP=0 -c "BEGIN; LOCK TABLE $full_name IN $lock_mode MODE NOWAIT; COMMIT;" >/dev/null 2>&1; then
        echo "Блокировка для $full_name получена, добавляем задачу в очередь"
        psql -d "$DBNAME" -c "
            INSERT INTO public.gp_maintenance_queue (table_name, op_type, status)
            VALUES ('$full_name', '$needed_op', 'pending')
        "
    else
        echo "Не удалось получить блокировку $lock_mode для $full_name, пропускаем (будет повторно проверена при следующем запуске планировщика)"
    fi
done

echo "$(date '+%Y-%m-%d %H:%M:%S') --- $SCRIPT_NAME завершён ---"
exit 0
