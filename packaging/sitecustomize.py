import os

os.environ.setdefault(
    "HF_ENDPOINT",
    "https://binary.alfabank.ru/artifactory/api/huggingfaceml/huggingface",
)
os.environ.setdefault("HF_HOME", "/workspace/hf-cache")
