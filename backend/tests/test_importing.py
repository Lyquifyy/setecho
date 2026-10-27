import io
from pathlib import Path

import openpyxl

from app import importing

FIXTURES = Path(__file__).parent / "fixtures" / "import"


def test_csv_passes_through():
    text = importing.sheet_to_text(FIXTURES / "synthetic_program.csv")
    assert text.startswith("Program,Prep Block 2")
    assert "Bench press,4,8,185,8,2:30" in text


def test_xlsx_becomes_csv_blocks(tmp_path):
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Week 1"
    ws.append(["Day", "Exercise", "Sets", "Reps", "Load"])
    ws.append(["Upper A", "Bench press", 4, 8, 185.0])
    ws.append([None, None, None, None, None])
    ws2 = wb.create_sheet("Notes")
    ws2.append(["Rest 2-3 min between sets"])
    buf = io.BytesIO()
    wb.save(buf)
    text = importing.xlsx_to_text(buf.getvalue())
    assert text == (
        "## Sheet: Week 1\nDay,Exercise,Sets,Reps,Load\nUpper A,Bench press,4,8,185\n\n"
        "## Sheet: Notes\nRest 2-3 min between sets"
    )


def test_image_detection():
    assert importing.is_image(Path("form.PNG"))
    assert not importing.is_image(Path("program.xlsx"))
