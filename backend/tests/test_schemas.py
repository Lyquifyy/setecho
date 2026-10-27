from datetime import UTC, datetime

from app.schemas import (
    CheckInTemplateOut,
    ProgramOut,
    slug,
    strict_schema,
    to_program,
    to_template,
)


def _objects(node, path="$"):
    """Yield (path, dict) for every object schema node, walking $defs, properties, items and anyOf."""
    if isinstance(node, dict):
        if node.get("type") == "object" or "properties" in node:
            yield path, node
        for key, value in node.items():
            yield from _objects(value, f"{path}.{key}")
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from _objects(value, f"{path}[{i}]")


def _walk(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from _walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from _walk(v)


def assert_strict(schema: dict) -> None:
    assert schema["type"] == "object"
    for key in ("anyOf", "oneOf", "allOf", "enum", "not"):
        assert key not in schema, f"root may not carry {key}"
    for path, obj in _objects(schema):
        assert obj.get("additionalProperties") is False, f"{path} allows extra properties"
        assert sorted(obj.get("required", [])) == sorted(obj["properties"].keys()), (
            f"{path} required != properties"
        )
    for node in _walk(schema):
        assert "oneOf" not in node and "allOf" not in node
        assert "title" not in node


def test_program_schema_is_strict():
    assert_strict(strict_schema(ProgramOut))


def test_template_schema_is_strict():
    assert_strict(strict_schema(CheckInTemplateOut))


def test_optional_plain_types_collapse_to_type_list():
    schema = strict_schema(ProgramOut)
    planned_set = schema["$defs"]["PlannedSet"]["properties"]
    assert planned_set["reps"]["type"] == ["integer", "null"]
    assert planned_set["loadLb"]["type"] == ["number", "null"]


def test_schema_is_byte_stable():
    assert strict_schema(ProgramOut) == strict_schema(ProgramOut)


def test_slug():
    assert slug("Average daily steps") == "average_daily_steps"
    assert slug("Energy levels (scale 1-10)") == "energy_levels_scale_1_10"
    assert slug("***") == "item"


def test_to_program_assigns_unique_ids():
    out = ProgramOut.model_validate(
        {
            "name": "Block",
            "weeks": [
                {
                    "number": 1,
                    "days": [
                        {
                            "name": "Upper A",
                            "exercises": [
                                {"name": "Bench press", "sets": [], "restSeconds": None, "notes": None},
                                {"name": "Bench press", "sets": [], "restSeconds": None, "notes": None},
                            ],
                        },
                        {"name": "Upper A", "exercises": []},
                    ],
                }
            ],
            "flags": [],
        }
    )
    program = to_program(out, datetime(2026, 10, 27, tzinfo=UTC))
    days = program.weeks[0].days
    assert [d.id for d in days] == ["w1_upper_a", "w1_upper_a_2"]
    assert [e.id for e in days[0].exercises] == ["w1_upper_a_bench_press", "w1_upper_a_bench_press_2"]
    assert program.model_dump(mode="json")["importedAt"].startswith("2026-10-27")


def test_to_template_orders_fields():
    out = CheckInTemplateOut.model_validate(
        {
            "fields": [
                {"label": "Current body weight", "prompt": None, "kind": "number",
                 "source": {"type": "data", "key": "currentWeight"}},
                {"label": "Energy levels", "prompt": "(scale 1-10)", "kind": "scale10",
                 "source": {"type": "voice", "key": None}},
            ],
            "carriedBlocks": [{"title": "Supplements", "text": "Creatine 5 g daily"}],
        }
    )  # fmt: skip
    t = to_template(out)
    assert [(f.id, f.order) for f in t.fields] == [("current_body_weight", 0), ("energy_levels", 1)]
    assert t.fields[0].source.key == "currentWeight"
    assert t.carriedBlocks[0].title == "Supplements"
