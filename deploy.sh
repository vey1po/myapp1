#!/bin/bash

# --- Проверка, запущен ли скрипт от root ---
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт деплоя должен быть запущен с правами root (sudo)."
   exit 1
fi

# --- Парсинг аргументов ---
APP_NAME=""
VERSION=""
ENVIRONMENT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --app=*)
      APP_NAME="${1#*=}"
      shift
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --env=*)
      ENVIRONMENT="${1#*=}"
      shift
      ;;
    *)
      echo "Неизвестный аргумент: $1"
      exit 1
      ;;
  esac
done

# --- Проверка обязательных аргументов ---
if [[ -z "$APP_NAME" || -z "$VERSION" || -z "$ENVIRONMENT" ]]; then
  echo "Ошибка: Не все аргументы (--app, --version, --env) указаны."
  exit 1
fi

echo "Начинаю деплой для приложения: $APP_NAME, версия: $VERSION, окружение: $ENVIRONMENT"

# --- Функция для проверки зависимостей ---
check_dependency() {
  if ! command -v "$1" &> /dev/null; then
    echo "Ошибка: $1 не найден в PATH."
    exit 1
  fi
}

echo "Проверка зависимостей..."
check_dependency git
check_dependency docker
check_dependency nginx
echo "Все зависимости установлены."

# --- Клонирование/обновление репозитория ---
REPO_URL="https://github.com/vey1po/myapp1.git"
DEPLOY_DIR="/tmp/$APP_NAME-deploy"

if [[ -d "$DEPLOY_DIR/.git" ]]; then
  echo "Обновление репозитория в $DEPLOY_DIR"
  cd "$DEPLOY_DIR"
  git fetch origin
  git reset --hard HEAD # Сбросить локальные изменения
  git checkout main
  git pull origin main
else
  echo "Клонирование репозитория в $DEPLOY_DIR"
  git clone "$REPO_URL" "$DEPLOY_DIR"
  cd "$DEPLOY_DIR"
fi


# --- Создание резервной копии текущей версии ---
CURRENT_DEPLOY_PATH="/var/www/html" # Пример пути для Nginx
BACKUP_PATH="/tmp/${APP_NAME}_backup_$(date +%s)"

if [[ -d "$CURRENT_DEPLOY_PATH" ]]; then
  echo "Создание резервной копии в $BACKUP_PATH"
  # Используем sudo для операций с /var/www/
  cp -r "$CURRENT_DEPLOY_PATH" "$BACKUP_PATH"
  if [[ $? -ne 0 ]]; then
    echo "Ошибка при создании резервной копии."
    exit 1
  fi
else
  echo "Текущая директория развертывания не существует, пропускаю бэкап."
fi

# --- Сборка и запуск нового контейнера Docker ---
IMAGE_NAME="$APP_NAME:$VERSION"
CONTAINER_NAME="$APP_NAME-$VERSION-deployment"

echo "Сборка Docker-образа $IMAGE_NAME"
cd "$DEPLOY_DIR"
# Предполагается, что Docker настроен на запуск от root, т.к. скрипт запущен от root
docker build -t "$IMAGE_NAME" .

if [[ $? -ne 0 ]]; then
  echo "Ошибка сборки Docker-образа."
  exit 1
fi

echo "Запуск нового контейнера $CONTAINER_NAME"
docker run -d --name "$CONTAINER_NAME" -p 9000:80 "$IMAGE_NAME"

if [[ $? -ne 0 ]]; then
  echo "Ошибка запуска Docker-контейнера."
  exit 1
fi

# --- Проверка здоровья приложения ---
HEALTH_CHECK_URL="http://localhost:9000"
MAX_RETRIES=30
RETRY_COUNT=0
HEALTHY=false

echo "Проверка состояния приложения на $HEALTH_CHECK_URL (максимум $MAX_RETRIES попыток)..."

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
  if curl --connect-timeout 5 --max-time 10 -f -s "$HEALTH_CHECK_URL" > /dev/null; then
    HEALTHY=true
    break
  else
    sleep 2
    ((RETRY_COUNT++))
  fi
done

if [[ "$HEALTHY" == true ]]; then
  echo "Приложение работает."
  
  # --- Перенос файлов из работающего контейнера в директорию Nginx ---
  echo "Копирование файлов из контейнера в $CURRENT_DEPLOY_PATH"
  # Используем sudo для записи в /var/www/
  sudo mkdir -p "$CURRENT_DEPLOY_PATH"
  sudo docker cp "$CONTAINER_NAME:/usr/share/nginx/html/." "$CURRENT_DEPLOY_PATH"
  
  if [[ $? -eq 0 ]]; then
    echo "Deploy successful"
    
    # --- Остановка и удаление старого контейнера ---
    OLD_CONTAINER_ID=$(sudo docker ps -q --filter "name=$APP_NAME-[0-9]*-[0-9]*-[0-9]*-deployment" --filter "status=running")
    if [[ -n "$OLD_CONTAINER_ID" && "$OLD_CONTAINER_ID" != "$CONTAINER_NAME" ]]; then
      echo "Остановка старого контейнера: $OLD_CONTAINER_ID"
      sudo docker stop "$OLD_CONTAINER_ID"
      sudo docker rm "$OLD_CONTAINER_ID"
    fi
    
    # --- Удаление нового контейнера после деплоя ---
    echo "Удаление временного контейнера: $CONTAINER_NAME"
    sudo docker stop "$CONTAINER_NAME"
    sudo docker rm "$CONTAINER_NAME"
    
    exit 0
  else
    echo "Ошибка: Не удалось скопировать файлы из контейнера."
    IS_FAILURE=true
  fi
else
  echo "Ошибка: Приложение не ответило на проверку состояния."
  IS_FAILURE=true
fi

# --- Откат при неудаче ---
if [[ "$IS_FAILURE" == true ]]; then
  if [[ -d "$BACKUP_PATH" ]]; then
    echo "Выполняется откат к резервной копии из $BACKUP_PATH"
    # Используем sudo для операций с /var/www/
    sudo rm -rf "$CURRENT_DEPLOY_PATH"
    sudo mv "$BACKUP_PATH" "$CURRENT_DEPLOY_PATH"
    if [[ $? -eq 0 ]]; then
      echo "Откат выполнен успешно."
    else
      echo "Ошибка при восстановлении резервной копии. Ручное вмешательство требуется."
    fi
  else
    echo "Резервная копия не найдена. Невозможно выполнить откат."
  fi

  echo "Деплой завершился неудачно."
  # Используем sudo для остановки и удаления контейнера
  sudo docker stop "$CONTAINER_NAME" 2>/dev/null
  sudo docker rm "$CONTAINER_NAME" 2>/dev/null
  exit 1
fi