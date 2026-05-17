#!/bin/bash
# gp_run_maintenance.sh – выполняет задачу обслуживания с таймаутом, корректно завершает зависшие процессы

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

JOB_ID=$1
if [ -z "$JOB_ID" ]; then
    echo "Использование: $0 <job_id из gp_maintenance_queue>"
    exit 1
fi

# Читаем параметры задачи из очереди
read -r TABLE_NAME OP_TYPE STATUS <<< $(psql -d "$DBNAME" -t -A -F' ' -c \
    "SELECT table_name, op_type, status FROM public.gp_maintenance_queue WHERE id = $JOB_ID;")

if [ -z "$TABLE_NAME" ]; then
    echo "Задача с ID=$JOB_ID не найдена"
    exit 1
fi

if [ "$STATUS" != "pending" ]; then
    echo "Задача $JOB_ID уже в статусе '$STATUS', запуск невозможен"
    exit 0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') --- Запуск задачи $JOB_ID: $OP_TYPE на $TABLE_NAME ---"

# Обновляем статус на running и сохраняем PID текущего shell (не psql)
psql -d "$DBNAME" -c "UPDATE public.gp_maintenance_queue SET status = 'running', start_ts = now(), pid = pg_backend_pid() WHERE id = $JOB_ID AND status = 'pending';" || exit 1

# Получаем PID сессии, из которой будем запускать обслуживание (он будет родителем psql)
# Для контроля используем application_name
APP_NAME="gp_maint_${JOB_ID}"

# Определяем таймаут
case "$OP_TYPE" in
    vacuum)            TIMEOUT_MIN=$TIMEOUT_VACUUM ;;
    analyze)           TIMEOUT_MIN=$TIMEOUT_ANALYZE ;;
    vacuum_full_analyze) TIMEOUT_MIN=$TIMEOUT_VACUUM_FULL ;;
    *)                 echo "Неизвестный тип операции: $OP_TYPE"; exit 1 ;;
esac
TIMEOUT_SEC=$((TIMEOUT_MIN * 60))

# Запускаем psql с кастомным application_name и сразу получаем его PID
psql -d "$DBNAME" \
    -v ON_ERROR_STOP=0 \
    -c "SET application_name TO '${APP_NAME}'; ${OP_TYPE^^} ${TABLE_NAME};" &
PSQL_PID=$!
echo "Фоновый процесс psql запущен с PID=$PSQL_PID, ожидание не более ${TIMEOUT_MIN} мин."

# Ждём завершения с контролем времени
START_TS=$(date +%s)
while kill -0 $PSQL_PID 2>/dev/null; do
    CURRENT_TS=$(date +%s)
    ELAPSED=$((CURRENT_TS - START_TS))
    if [ $ELAPSED -ge $TIMEOUT_SEC ]; then
        echo "Таймаут ${TIMEOUT_MIN} мин. превышен, отменяем операцию..."
        # Находим backend pid с нашим application_name
        BACKEND_PID=$(psql -d "$DBNAME" -t -A -c \
            "SELECT pid FROM pg_stat_activity WHERE application_name = '${APP_NAME}' AND state = 'active' LIMIT 1;")
        if [ -n "$BACKEND_PID" ]; then
            # Мягкая отмена
            psql -d "$DBNAME" -c "SELECT pg_cancel_backend($BACKEND_PID);" >/dev/null
            sleep 5
            if kill -0 $PSQL_PID 2>/dev/null; then
                echo "Мягкая отмена не сработала, выполняем pg_terminate_backend..."
                psql -d "$DBNAME" -c "SELECT pg_terminate_backend($BACKEND_PID);" >/dev/null
                sleep 2
            fi
        fi
        # Обновляем статус задачи
        psql -d "$DBNAME" -c "UPDATE public.gp_maintenance_queue SET status = 'cancelled', end_ts = now(), error_message = 'Timeout exceeded' WHERE id = $JOB_ID;"
        exit 0
    fi
    sleep 10
done

wait $PSQL_PID
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "Операция $OP_TYPE для $TABLE_NAME завершена успешно"
    psql -d "$DBNAME" -c "UPDATE public.gp_maintenance_queue SET status = 'completed', end_ts = now() WHERE id = $JOB_ID;"
else
    echo "Операция завершилась с кодом $EXIT_CODE"
    psql -d "$DBNAME" -c "UPDATE public.gp_maintenance_queue SET status = 'failed', end_ts = now(), error_message = 'Exit code $EXIT_CODE' WHERE id = $JOB_ID;"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') --- Задача $JOB_ID завершена ---"
exit 0
