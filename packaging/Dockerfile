# Окружение собирается по тому же абсолютному пути, по которому будет лежать
# на сервере, поэтому shebang'и в .venv/bin и pyvenv.cfg остаются валидными
# после распаковки.
#
# Ubuntu 24.04 повторяет glibc 2.39 целевого сервера. Образ берётся из зеркала
# AWS ECR, потому что Docker Hub с этой машины недоступен.
FROM public.ecr.aws/ubuntu/ubuntu:24.04

# Версии повторяют manager/spec.py: на них upstream проверял весь набор колёс.
# Отличается только сборка CUDA - spec.py требует драйвер, сообщающий CUDA 12.6,
# а на целевом сервере драйвер 535 сообщает 12.2. Колёса cu126 на нём работают
# по CUDA minor version compatibility (нужен драйвер от 525.60.13).
ARG PY_VERSION=3.12
ARG CUDA_FLAVOR=cu126
ARG TORCH_VERSION=2.13.0
ARG TORCHVISION_VERSION=0.28.0
ARG TORCHAUDIO_VERSION=2.11.0
# В requirements.txt закреплён torchcodec 0.9.1 под torch 2.10. Ставится поверх
# версия из spec.py, собранная против нашего torch.
ARG TORCHCODEC_VERSION=0.15.0

# UV_HTTP_TIMEOUT поднят с дефолтных 30 секунд: torch 2.13 тянет за собой около
# 2.5 ГБ колёс nvidia-*, часть из них с pypi.nvidia.com, и при параллельной
# закачке отдельные соединения не укладываются в дефолт.
ENV PREFIX=/workspace/ai-toolkit \
    UV_PYTHON_INSTALL_DIR=/workspace/ai-toolkit/python \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_LINK_MODE=copy \
    UV_HTTP_TIMEOUT=300 \
    DEBIAN_FRONTEND=noninteractive

# git нужен только на сборке: diffusers в requirements_base.txt закреплён
# git-ссылкой на коммит. В архив git не попадает и на сервере не требуется.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git pigz \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR ${PREFIX}

# Интерпретатор кладём внутрь PREFIX, чтобы на сервере не требовался
# системный Python подходящей версии.
RUN uv python install ${PY_VERSION}

RUN uv venv --relocatable --python ${PY_VERSION} ${PREFIX}/.venv

ENV VIRTUAL_ENV=${PREFIX}/.venv \
    TORCH_INDEX=https://download.pytorch.org/whl/${CUDA_FLAVOR}

RUN uv pip install --index-url ${TORCH_INDEX} \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}"

# В requirements.txt torch не закреплён, но объявлен транзитивно у timm, peft,
# accelerate и torchvision. Без жёстких ограничений резолвер не сообщает
# о конфликте, а молча откатывается на сборку с PyPI - и torchvision остаётся
# слинкованным с исчезнувшим libtorch.
#
# find-links задаётся поштучно, а не через extra-index-url: индекс pytorch
# зеркалит ещё и numpy, pillow, setuptools, и лишний индекс выиграл бы для них
# тоже, закрепив случайные устаревшие копии.
RUN printf '%s\n' \
        "torch==${TORCH_VERSION}+${CUDA_FLAVOR}" \
        "torchvision==${TORCHVISION_VERSION}+${CUDA_FLAVOR}" \
        "torchaudio==${TORCHAUDIO_VERSION}+${CUDA_FLAVOR}" \
        > /etc/torch-constraints.txt

ENV TORCH_PINS="--constraint /etc/torch-constraints.txt \
--find-links ${TORCH_INDEX}/torch/ \
--find-links ${TORCH_INDEX}/torchvision/ \
--find-links ${TORCH_INDEX}/torchaudio/"

# Зависимости ставятся до копирования исходников, чтобы правки в коде
# и конфигах не инвалидировали слой с torch.
COPY requirements.txt requirements_base.txt ${PREFIX}/

RUN uv pip install ${TORCH_PINS} -r requirements.txt

RUN uv pip install ${TORCH_PINS} --upgrade \
        "torchcodec==${TORCHCODEC_VERSION}" ipykernel

# opencv-python тянет из системы libGL и libglib, которых на сервере может
# не оказаться. GUI-функции OpenCV здесь не используются, headless-сборка
# делает архив независимым от системных библиотек. Версия берётся та же,
# что выбрал резолвер, - пакеты выпускаются синхронно.
#
# --reinstall-package обязателен: headless уже стоит (его тянет транзитивная
# зависимость), оба пакета кладут файлы в один и тот же cv2/, и удаление
# opencv-python сносит их по своему RECORD. Без принудительной переустановки
# в окружении остаётся запись о headless и ни одного файла модуля.
RUN OPENCV_VERSION="$(uv pip show opencv-python | sed -n 's/^Version: //p')" && \
    uv pip uninstall opencv-python && \
    uv pip install ${TORCH_PINS} --reinstall-package opencv-python-headless \
        "opencv-python-headless==${OPENCV_VERSION}"

COPY . ${PREFIX}

# huggingface_hub читает HF_ENDPOINT при старте интерпретатора.
# sitecustomize задаёт зеркало и кеш, чтобы на сервере ничего не настраивать.
# setdefault: явный export в окружении по-прежнему сильнее.
RUN cp ${PREFIX}/packaging/sitecustomize.py \
        ${PREFIX}/.venv/lib/python${PY_VERSION}/site-packages/sitecustomize.py

RUN uv cache clean
