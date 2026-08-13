# ai-toolkit: упаковка и доставка в закрытый контур

Автономный архив с Python-окружением и зависимостями. На сервере нет ни
интернета, ни Docker: архив распаковывается и работает как есть.

Упаковывается консольный путь (`run.py`). Веб-интерфейс (`ui/`) в архив
не собирается.

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

1. Окружение собирается внутри контейнера **по тому же абсолютному пути**,
   по которому будет лежать на сервере. Поэтому shebang'и в `.venv/bin/*`
   и `pyvenv.cfg` остаются валидными после распаковки.
2. В архив кладётся **собственный интерпретатор** (standalone CPython 3.12
   в `python/`). От сервера требуются только ядро, glibc и драйвер NVIDIA.
3. `huggingface_hub` ходит на Hugging Face через зеркало Artifactory. Endpoint
   и кеш (`/workspace/hf-cache`) заданы в `sitecustomize.py` внутри `.venv`,
   поэтому любой вызов `.venv/bin/python` подхватывает их сам.

Архив создаётся `tar` внутри контейнера, а не на хосте: файловая система Windows
не умеет представлять симлинки и биты прав, которые есть в venv.

`toolkit` не устанавливается пакетом - `run.py` кладёт в `sys.path` текущую
директорию. Поэтому всё запускается из `/workspace/ai-toolkit`.

## Шаг 1. Сборка

Из PowerShell, из корня репозитория инструмента:

```powershell
cd ai-toolkit
bash packaging/pack.sh
```

`bash` - это bash из WSL (ставится вместе с Docker Desktop на WSL2). Он
транслирует текущую папку в `/mnt/c/...`, `docker` виден через WSL-интеграцию.

Результат в `../out_build/`: `ai-toolkit-cu126.tar.gz` и файл с контрольной
суммой. Переменными можно переопределить `PACK_OUT_DIR`, `PACK_IMAGE`,
`PACK_NAME` - префикс `PACK_` нужен потому, что `NAME` и `IMAGE` уже заняты
в окружении WSL.

Требования к сборочной машине: Docker и прямой доступ к `pypi.org`,
`download.pytorch.org`, `pypi.nvidia.com`, `github.com`, `ghcr.io`,
`public.ecr.aws`. Docker Hub не нужен - базовый образ из зеркала AWS ECR.
`github.com` нужен: diffusers в `requirements_base.txt` закреплён git-ссылкой.

Сборка занимает около 17 минут, архив выходит примерно 3.8 ГБ. В Docker Desktop
стоит заранее поднять лимит дискового образа WSL2.

## Шаг 2. Проверка архива

```powershell
bash packaging/verify.sh
```

Скрипт распаковывает архив в чистом контейнере без доустановленных пакетов
и запускает интерпретатор из архива. `cuda_available` там всегда `False` -
у контейнера нет GPU, это ожидаемо.

Ожидаемый вывод:

```
python 3.12.13
torch 2.13.0+cu126
transformers 5.5.3
diffusers 0.39.0.dev0
opencv 4.11.0
cuda_available False
hf_endpoint https://binary.alfabank.ru/artifactory/api/huggingfaceml/huggingface
hf_home /workspace/hf-cache
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

`HF_HUB_DISABLE_XET=1` обязателен. Без него Xet-бэкенд встаёт на середине
многогигабайтного файла без ошибки. Переменная действует только в текущем
окне PowerShell.

Если встанет - `Ctrl+C` и та же команда снова: уже загруженные части повторно
не отправляются.

## Шаг 4. Скачивание на сервер

Зеркало Artifactory проксирует Hugging Face, токен не нужен.

```bash
cd /workspace
BASE=https://binary.alfabank.ru/artifactory/api/huggingfaceml/huggingface/motionmaksim/environment/resolve/main
curl -L -C - -O "$BASE/ai-toolkit-cu126.tar.gz"
```

`-C -` продолжает закачку с места обрыва.

Файл `.sha256` через зеркало тянуть бесполезно: маленькие файлы Artifactory
отдаёт служебным указателем, и `sha256sum -c` на нём падает.

## Шаг 5. Проверка и распаковка

Сверяем размер и хеш с тем, что напечатал `pack.sh` в конце сборки:

```bash
cd /workspace
ls -l ai-toolkit-cu126.tar.gz
sha256sum ai-toolkit-cu126.tar.gz
tar -xzf ai-toolkit-cu126.tar.gz
```

Размер в байтах должен совпасть точно. Если не совпало - удалить архив и
скачать заново.

Распаковка создаёт `/workspace/ai-toolkit`. Путь менять нельзя: окружение
собрано под него.

## Шаг 6. Проверка окружения

```bash
cd /workspace/ai-toolkit
.venv/bin/python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.device_count(), torch.cuda.get_device_name(0))"
```

Ожидаемый вывод: `2.13.0+cu126 True 2 NVIDIA H200`.

Если `torch.cuda.is_available()` вернёт `False` при живом `nvidia-smi`,
пересобрать с `--build-arg CUDA_FLAVOR=cu124`, `TORCH_VERSION=2.6.0`,
`TORCHVISION_VERSION=0.21.0`, `TORCHAUDIO_VERSION=2.6.0`.

Интерпретатор вызывается по полному пути, активировать окружение не нужно.

## Справка

### Выбор версии CUDA

Версии torch повторяют `manager/spec.py`. Отличается только сборка CUDA:
`spec.py` требует драйвер, сообщающий CUDA 12.6, и на 535 падает. Проверка
там сравнивает версию из `nvidia-smi` и не учитывает CUDA minor version
compatibility, по которой колёса любого тулкита 12.x работают на драйвере
от 525.60.13.

На индексе `cu124` torch обрывается на 2.6.0, а `transformers 5.5.3`,
diffusers 2026 года и `torchcodec` рассчитаны на torch 2.1x, поэтому
сборка идёт с `cu126`.

Версии задаются аргументами `CUDA_FLAVOR`, `TORCH_VERSION`,
`TORCHVISION_VERSION`, `TORCHAUDIO_VERSION`, `TORCHCODEC_VERSION`.

### Закрепление сборки torch

В `requirements.txt` torch не закреплён, но объявлен транзитивно у `timm`,
`peft`, `accelerate` и `torchvision`. Без ограничений резолвер молча
откатывается на сборку с PyPI. Все установки после torch идут с
constraints-файлом на точные пины `+cu126` и поштучными `--find-links`
на страницы пакетов индекса pytorch, а не `--extra-index-url`.

### Замена opencv-python на headless

`opencv-python` подгружает системные `libGL.so.1` и `libglib2.0`. Пакет
заменяется на `opencv-python-headless` той же версии с `--reinstall-package`:
headless уже стоит транзитивно, оба пакета кладут файлы в один `cv2/`,
и удаление `opencv-python` сносит их по своему RECORD.

### torchcodec и FFmpeg

`torchcodec` ставится версии 0.15.0 поверх пина 0.9.1 из `requirements.txt`
(0.9.1 собран под torch 2.10). Системный FFmpeg в архив не кладётся:
импорт ленивый, нужен только для видео- и аудиодатасетов. `av` несёт
FFmpeg внутри колеса.

### Что не входит в сборку

- Веб-интерфейс `ui/`
- `flash-attn` и NATTEN
- Веса моделей (скачиваются через зеркало в `/workspace/hf-cache`)
