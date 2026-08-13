#!/usr/bin/env bash
# Проверяет собранный архив: распаковывает его в чистом контейнере и запускает
# интерпретатор из архива. Контейнер без GPU, поэтому cuda_available здесь
# всегда False - это ожидаемо, реальная проверка CUDA только на сервере.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PACK_NAME="${PACK_NAME:-ai-toolkit-cu126}"
PACK_OUT_DIR="${PACK_OUT_DIR:-$REPO_ROOT/../out_build}"
PACK_OUT_DIR="$(cd "$PACK_OUT_DIR" && pwd)"

docker run --rm -i \
    -v "$PACK_OUT_DIR:/in:ro" \
    -e PACK_NAME="$PACK_NAME" \
    public.ecr.aws/ubuntu/ubuntu:24.04 bash -s <<'EOF'
set -euo pipefail

cd /in
sha256sum -c "${PACK_NAME}.sha256"
echo "CHECKSUM_OK"

mkdir -p /workspace
tar -xzf "/in/${PACK_NAME}.tar.gz" -C /workspace
echo "EXTRACT_OK"

# run.py кладёт в sys.path текущую директорию, поэтому всё запускается
# из корня инструмента - и здесь, и на сервере.
cd /workspace/ai-toolkit
PY=/workspace/ai-toolkit/.venv/bin/python

# torchcodec намеренно не импортируется: он dlopen'ит системный FFmpeg,
# которого в архиве нет. Нужен только для видео- и аудиодатасетов.
"$PY" - <<'PY'
import sys

import accelerate
import av
import cv2
import diffusers
import peft
import tensorboard
import torch
import torchvision
import transformers
from torch.utils.tensorboard import SummaryWriter

from toolkit.job import get_job

print("python", sys.version.split()[0])
print("torch", torch.__version__)
print("torchvision", torchvision.__version__)
print("transformers", transformers.__version__)
print("diffusers", diffusers.__version__)
print("peft", peft.__version__)
print("accelerate", accelerate.__version__)
print("opencv", cv2.__version__)
print("av", av.__version__)
print("tensorboard", tensorboard.__version__)
print("cuda_available", torch.cuda.is_available())
PY

"$PY" /workspace/ai-toolkit/run.py --help >/dev/null
echo "ENTRYPOINT_OK"
EOF
