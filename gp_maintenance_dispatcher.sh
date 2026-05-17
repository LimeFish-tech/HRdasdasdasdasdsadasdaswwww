#!/bin/bash
# gp_maintenance_dispatcher.sh – главный оркестратор автоматического обслуживания

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
echo "$(date '+%Y-%m-%d %H:%M:%S') ====== Запуск диспетчера ======"

# Шаг 1: сбор актуальной статистики
echo "Шаг 1: Запуск сбора статистики..."
bash "${SCRIPTS_DIR}/gp_collect_stats.sh"
if [ $? -ne 0 ]; then
    echo "Ошибка при сборе статистики, прерывание"
    exit 1
fi

# Шаг 2: планирование задач
echo "Шаг 2: Запуск планировщика..."
bash "${SCRIPTS_DIR}/gp_maintenance_scheduler.sh"
if [ $? -ne 0 ]; then
    echo "Ошибка при планировании, прерывание"
    exit 1
fi

# Шаг 3: получаем список pending-задач и запускаем их с учётом параллелизма
echo "Шаг 3: Запуск исполнителей..."
PENDING_JOBS=$(psql -d "$DBNAME" -t -A -c "SELECT id FROM public.gp_maintenance_queue WHERE status = 'pending' ORDER BY created_ts;")
if [ -z "$PENDING_JOBS" ]; then
    echo "Нет задач для выполнения"
    exit 0
fi

declare -A JOB_PIDS   # массив: JOB_ID -> PID процесса-исполнителя
RUNNING_COUNT=0

for JOB_ID in $PENDING_JOBS; do
    # Прежде чем запускать новый, проверяем, не освободилось ли место
    while [ $RUNNING_COUNT -ge $MAX_PARALLEL_JOBS ]; do
        # Ждём завершения любого из запущенных процессов
        for JID in "${!JOB_PIDS[@]}"; do
            PID="${JOB_PIDS[$JID]}"
            if ! kill -0 $PID 2>/dev/null; then
                # Процесс завершился
                wait $PID
                echo "Процесс задачи $JID (PID=$PID) завершился"
                unset JOB_PIDS[$JID]
                ((RUNNING_COUNT--))
                break
            fi
        done
        sleep 5
    done

    # Запускаем исполнителя для задачи
    echo "Запуск задачи $JOB_ID (всего запущено: $RUNNING_COUNT)"
    bash "${SCRIPTS_DIR}/gp_run_maintenance.sh" "$JOB_ID" &
    PID=$!
    JOB_PIDS[$JOB_ID]=$PID
    ((RUNNING_COUNT++))
    sleep 2   # небольшая пауза между стартами
done

# Дожидаемся завершения оставшихся процессов
echo "Ожидание завершения оставшихся задач..."
for JID in "${!JOB_PIDS[@]}"; do
    PID="${JOB_PIDS[$JID]}"
    if kill -0 $PID 2>/dev/null; then
        wait $PID
        echo "Процесс задачи $JID завершился"
    fi
done

echo "$(date '+%Y-%m-%d %H:%M:%S') ====== Диспетчер завершил работу ======"
exit 0
