# ai-toolkit: упаковка, доставка и запуск в закрытом контуре

Полный путь от сборки на рабочей машине до обучения LoRA на сервере DES.
Собирается автономный архив с Python-окружением и всеми зависимостями:
на целевом сервере нет ни интернета, ни Docker, поэтому архив распаковывается
и работает как есть.

Упаковывается только консольный путь - `run.py`. Веб-интерфейс (`ui/`, Next.js)
в архив не собирается: он потребовал бы Node и собранный фронтенд, а обучение
запускается одной командой без него.

## Целевой сервер

| Параметр | Значение |
| --- | --- |
| GPU | 2x NVIDIA H200, `sm_90` |
| Драйвер | 535.247.01 (CUDA 12.2) |
| ОС | Ubuntu 24.04, glibc 2.39, x86_64 |
| Путь развёртывания | `/workspace/ai-toolkit` |

CUDA Toolkit на сервере не нужен: колёса torch несут свой CUDA runtime внутри,
требуется только драйвер.

## Как устроена переносимость

Два решения, на которых всё держится:

1. Окружение собирается внутри контейнера **по тому же абсолютному пути**,
   по которому будет лежать на сервере. Поэтому shebang'и в `.venv/bin/*`
   и `pyvenv.cfg` остаются валидными после распаковки.
2. В архив кладётся **собственный интерпретатор** (standalone CPython 3.12
   в `python/`), а не системный. От сервера требуются только ядро, glibc
   и драйвер NVIDIA.

Архив создаётся `tar` внутри контейнера, а не на хосте: файловая система Windows
не умеет представлять симлинки и биты прав, которые есть в venv.

`toolkit` не устанавливается пакетом - `run.py` кладёт в `sys.path` текущую
директорию. Поэтому всё запускается из `/workspace/ai-toolkit`.

## Шаг 1. Сборка

Запускается из PowerShell, из корня репозитория инструмента:

```powershell
cd ai-toolkit
bash packaging/pack.sh
```

`bash` здесь - это bash из WSL, который ставится вместе с Docker Desktop
на WSL2-бэкенде. Он сам транслирует текущую папку в `/mnt/c/...`, поэтому
относительные пути внутри скриптов работают, и `docker` виден через
WSL-интеграцию. Ничего доустанавливать не нужно.

Результат в `../out_build/`: `ai-toolkit-cu126.tar.gz` и файл с контрольной
суммой. Переменными можно переопределить `PACK_OUT_DIR`, `PACK_IMAGE`,
`PACK_NAME` - префикс `PACK_` нужен потому, что `NAME` и `IMAGE` уже заняты
в окружении WSL.

Требования к сборочной машине: Docker и прямой доступ к `pypi.org`,
`download.pytorch.org`, `pypi.nvidia.com`, `github.com`, `ghcr.io`,
`public.ecr.aws`. Docker Hub не нужен - базовый образ берётся из зеркала
AWS ECR. `github.com` нужен потому, что diffusers в `requirements_base.txt`
закреплён git-ссылкой на конкретный коммит.

Сборка занимает около 17 минут, архив выходит примерно 3.8 ГБ. В Docker Desktop
стоит заранее поднять лимит дискового образа WSL2.

## Шаг 2. Проверка архива

```powershell
bash packaging/verify.sh
```

Скрипт распаковывает архив в чистом контейнере без доустановленных пакетов
и запускает интерпретатор из архива. Так ловятся зависимости от системных
библиотек, которых на сервере может не быть. `cuda_available` там всегда
`False` - у контейнера нет GPU, это ожидаемо.

Ожидаемый вывод:

```
python 3.12.13
torch 2.13.0+cu126
transformers 5.5.3
diffusers 0.39.0.dev0
opencv 4.11.0
cuda_available False
ENTRYPOINT_OK
```

## Шаг 3. Заливка на Hugging Face

Репозиторий `motionmaksim/environment`, тип - model (обычный, без
`--repo-type`): именно такой путь понимает зеркало Artifactory.

```powershell
cd ..\out_build
$env:HF_HUB_DISABLE_XET = "1"
hf upload motionmaksim/environment ai-toolkit-cu126.tar.gz
```

`HF_HUB_DISABLE_XET=1` обязателен. Без него включается Xet-бэкенд, который
льёт файл в много параллельных соединений и намертво встаёт на середине -
прогресс-бар стоит, ошибки нет. Переменная действует только в текущем окне
PowerShell, при новом окне её нужно задать снова.

Если всё же встанет, прервать по `Ctrl+C` и запустить ту же команду снова:
уже загруженные части повторно не отправляются.

## Шаг 4. Скачивание на сервер

Зеркало Artifactory проксирует Hugging Face, токен не нужен.

```bash
cd /workspace
BASE=https://binary.alfabank.ru/artifactory/api/huggingfaceml/huggingface/motionmaksim/environment/resolve/main
curl -L -C - -O "$BASE/ai-toolkit-cu126.tar.gz"
```

`-C -` продолжает закачку с места обрыва, поэтому при разрыве достаточно
повторить ту же команду.

Файл `.sha256` через зеркало тянуть бесполезно: маленькие файлы Artifactory
отдаёт не содержимым, а служебным указателем, и `sha256sum -c` на нём падает
с `no properly formatted checksum lines found`.

## Шаг 5. Проверка и распаковка

Сверяем размер и хеш с тем, что напечатал `pack.sh` в конце сборки:

```bash
cd /workspace
ls -l ai-toolkit-cu126.tar.gz
sha256sum ai-toolkit-cu126.tar.gz
tar -xzf ai-toolkit-cu126.tar.gz
```

Размер в байтах должен совпасть точно - это уже отсекает оборванную закачку.
Если не совпало - удалить архив и скачать заново, распаковывать бессмысленно.

Распаковка создаёт `/workspace/ai-toolkit`. Путь менять нельзя: окружение
собрано под него, при переносе в другое место сломаются пути внутри `.venv`.

## Шаг 6. Проверка окружения

```bash
cd /workspace/ai-toolkit
.venv/bin/python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.device_count(), torch.cuda.get_device_name(0))"
```

Ожидаемый вывод: `2.13.0+cu126 True 2 NVIDIA H200`.

Если `torch.cuda.is_available()` вернёт `False` при живом `nvidia-smi`, значит
драйвер не тянет колёса cu126 - пересобрать с `--build-arg CUDA_FLAVOR=cu124`,
`TORCH_VERSION=2.6.0`, `TORCHVISION_VERSION=0.21.0`, `TORCHAUDIO_VERSION=2.6.0`
(см. раздел про выбор CUDA).

Активировать окружение не нужно нигде: интерпретатор вызывается по полному
пути. Отдельное ядро для Jupyter, если нужно запускать из ноутбуков:

```bash
.venv/bin/python -m ipykernel install --user --name ai-toolkit
```

## Шаг 7. Настройка загрузки весов

Веса в архив не входят - ai-toolkit скачивает их сам. Когда
`model.name_or_path` - идентификатор репозитория (`Qwen/Qwen-Image-2512`),
`QwenImageModel.load_model` передаёт его в `from_pretrained`, и
`huggingface_hub` тянет `transformer`, `text_encoder`, `tokenizer` и `vae`.
Ключ `extras_name_or_path` по умолчанию равен `name_or_path`, поэтому все
компоненты берутся из одного репозитория.

Ходить наружу он должен через то же зеркало Artifactory, откуда качался архив.
`huggingface_hub` собирает адрес как `{HF_ENDPOINT}/{repo}/resolve/{rev}/{file}`,
то есть достаточно задать `HF_ENDPOINT` базой зеркала - получится ровно тот URL,
которым выкачивался архив на шаге 4.

Задаётся это один раз, файлом `.env` в корне инструмента. `run.py` первой же
строкой вызывает `load_dotenv()`, до импорта `huggingface_hub`, поэтому
переменные подхватываются сами при каждом запуске - экспортировать их руками
в командах обучения не нужно:

```bash
cd /workspace/ai-toolkit
cat > .env <<'EOF'
HF_ENDPOINT=https://binary.alfabank.ru/artifactory/api/huggingfaceml/huggingface
HF_HOME=/workspace/hf-cache
EOF
```

`HF_HOME` уводит кеш в рабочий раздел: по умолчанию `huggingface_hub` пишет
в `~/.cache/huggingface`, а Qwen-Image-2512 в bf16 - это десятки гигабайт.

В архив `.env` не кладётся намеренно: архив лежит в публичном репозитории
на Hugging Face, и внутренних адресов в нём быть не должно. Поэтому файл
создаётся на сервере после распаковки.

Проверка до запуска обучения:

```bash
cd /workspace/ai-toolkit
set -a; . ./.env; set +a
.venv/bin/python -c "
from huggingface_hub import HfApi, hf_hub_download
print(len(HfApi().list_repo_files('Qwen/Qwen-Image-2512')), 'files')
print(hf_hub_download('Qwen/Qwen-Image-2512', 'model_index.json'))
"
```

`set -a; . ./.env` нужен только здесь: это ручной запуск python, а не `run.py`,
и `load_dotenv()` в нём не отрабатывает.

Первая строка проверяет API со списком файлов, вторая - собственно скачивание.
`from_pretrained` пользуется обоими. Если файл качается, а список репозитория
не отдаётся, автозакачка не заработает: тогда веса выкачиваются `curl`-ом
по тому же базовому URL и складываются в папку, а в `name_or_path` пишется
путь к ней. Локальный путь распознаётся по `os.path.exists`, и при наличии
внутри подпапки `text_encoder` папка считается полным чекпоинтом.

## Шаг 8. Обучение LoRA

Конфиги берутся из `config/examples/` и кладутся в `config/` - так устроен
сам инструмент, `config/*` у него в `.gitignore`. Для LoRA по Qwen-Image
отправная точка - `config/examples/train_lora_qwen_image_24gb.yaml`.

Что в нём поправить под этот сервер: `model.name_or_path` на
`Qwen/Qwen-Image-2512`, `quantize`, `quantize_te` и `low_vram` в `false`
(141 ГБ VRAM хватает на bf16), `datasets[0].folder_path` на свой датасет
и `log_dir` - без него `BaseTrainProcess` не создаёт `SummaryWriter`,
обучение идёт, а графиков нет.

Датасет - папка с картинками, подпись к каждой лежит рядом в `.txt` с тем же
именем.

```bash
mkdir -p /workspace/logs
LOG="/workspace/logs/aitk_qwen_lora_$(date +%Y%m%d_%H%M%S).log"

VENV="/workspace/ai-toolkit/.venv/bin"
CFG="config/train_lora_qwen_image_2512.yaml"
GPU="0"                                     # "0" или "1"

cd /workspace/ai-toolkit || exit 1
export CUDA_VISIBLE_DEVICES="$GPU"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

stdbuf -oL -eL "$VENV/python" run.py "$CFG" -l "$LOG"
```

`-l` - собственный ключ `run.py`: он дублирует stdout и stderr в файл, внешний
`tee` не нужен. `HF_ENDPOINT` и `HF_HOME` здесь не задаются - их подхватит
`.env` из шага 7.

Первый запуск дольше остальных: на нём скачиваются веса. Дальше они берутся
из кеша в `HF_HOME`.

Обучение однопроцессное, `CUDA_VISIBLE_DEVICES` выбирает одну карту.

### Куда смотреть

- Лог запуска: `/workspace/logs/aitk_qwen_lora_<дата>_<время>.log`
- Чекпоинты и сэмплы: `training_folder` из конфига
- Кривые TensorBoard: `log_dir` из конфига

```bash
/workspace/ai-toolkit/.venv/bin/tensorboard \
    --logdir "<log_dir из конфига>" \
    --host 0.0.0.0 --port 6006
```

## Справка

### Выбор версии CUDA

Версии torch повторяют `manager/spec.py` - на них upstream проверял весь набор
колёс. Отличается только сборка CUDA: `spec.py` требует драйвер, сообщающий
CUDA 12.6, и на нашем 535 падает с `NVIDIA driver only supports CUDA 12.2`.
Проверка там консервативная - она сравнивает версию, которую печатает
`nvidia-smi`, и не учитывает CUDA minor version compatibility, по которой
колёса любого тулкита 12.x работают на драйвере от 525.60.13.

Спуститься до `cu124`, как у musubi-tuner, нельзя: на этом индексе torch
обрывается на 2.6.0 (январь 2025), а `transformers 5.5.3`, diffusers 2026 года
и `torchcodec` рассчитаны на torch 2.1x.

Версии задаются аргументами сборки `CUDA_FLAVOR`, `TORCH_VERSION`,
`TORCHVISION_VERSION`, `TORCHAUDIO_VERSION`, `TORCHCODEC_VERSION`.

### Закрепление сборки torch

В `requirements.txt` torch не закреплён, но объявлен транзитивно у `timm`,
`peft`, `accelerate` и `torchvision`. Если этого не ограничить, резолвер
не сообщает о конфликте, а молча откатывается на сборку с PyPI - и `torchvision`
остаётся слинкованным с исчезнувшим libtorch. Поэтому все установки после torch
идут с constraints-файлом на точные пины `+cu126` и поштучными `--find-links`
на страницы пакетов индекса pytorch. Поштучно, а не `--extra-index-url`, потому
что индекс pytorch зеркалит ещё и numpy, pillow, setuptools - лишний индекс
выиграл бы и для них.

### Замена opencv-python на headless

`opencv-python` подгружает системные `libGL.so.1` и `libglib2.0`, наличие
которых на сервере не гарантировано. GUI-функции OpenCV здесь не используются,
поэтому пакет заменяется на `opencv-python-headless` той же версии.

Замена делается с `--reinstall-package`: headless уже стоит как транзитивная
зависимость, оба пакета кладут файлы в один и тот же `cv2/`, и удаление
`opencv-python` сносит их по своему RECORD. Без принудительной переустановки
в окружении остаётся запись о headless и ни одного файла модуля -
`ModuleNotFoundError: No module named 'cv2'` уже на сервере.

### torchcodec и FFmpeg

`torchcodec` ставится версии из `spec.py` (0.15.0) поверх пина 0.9.1
из `requirements.txt`: 0.9.1 собран под torch 2.10 и с нашим torch не
загрузится.

Работает он только при наличии системного FFmpeg - его разделяемые библиотеки
`torchcodec` открывает через `dlopen`. В архив FFmpeg не кладётся, и для
обучения на картинках он не нужен: импорт `torchcodec` ленивый и происходит
только на видео- и аудиодатасетах. Если такие датасеты понадобятся, FFmpeg 8
нужно будет доставить на сервер отдельно и прописать в `LD_LIBRARY_PATH`.

`av` (PyAV) импортируется в основном пути загрузчика данных, но его колёса
несут FFmpeg внутри и системных библиотек не требуют.

### Что не входит в сборку

- Веб-интерфейс `ui/`: нужен Node и собранный Next.js, консольный запуск
  без него полноценен.
- `flash-attn` и NATTEN: требуют колёс под конкретную пару torch+CUDA,
  обучение работает и без них через torch SDPA.
- Веса моделей.
