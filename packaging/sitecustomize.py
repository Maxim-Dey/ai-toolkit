import os

os.environ.setdefault(
    "HF_ENDPOINT",
    "https://binary.alfabank.ru/artifactory/api/huggingfaceml/huggingface",
)
os.environ.setdefault("HF_HOME", "/workspace/hf-cache")
# Зеркало не проксирует Xet API (xet-read-token → 404). run.py по умолчанию
# включает Xet, поэтому выключаем здесь, до любого импорта huggingface_hub.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
