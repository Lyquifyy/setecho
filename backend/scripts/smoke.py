"""One cheap call to prove the key, base URL and model ids work. Run: make smoke"""

import time

from app import meta


def main() -> None:
    c = meta.client()
    ids = sorted(m.id for m in c.models.list().data)
    print("models:", ", ".join(ids))
    t = time.time()
    r = c.responses.create(
        model=meta.SPARK_MODEL, input="Reply with exactly: setecho ok", reasoning={"effort": "low"}
    )
    print(f"{meta.SPARK_MODEL}: {r.output_text!r} in {time.time() - t:.1f}s")
    print("usage:", r.usage.model_dump())


if __name__ == "__main__":
    main()
