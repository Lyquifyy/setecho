from fastapi import FastAPI

from app import meta

app = FastAPI(title="Setecho API", version="0.1.0")


@app.get("/health")
def health() -> dict:
    return {"ok": True, "spark_model": meta.SPARK_MODEL, "sam_model": meta.SAM_MODEL}
