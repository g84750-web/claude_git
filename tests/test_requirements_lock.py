# -*- coding: utf-8 -*-
"""CI 의존성 잠금 파일이 원본과 어긋나지 않는지 확인한다.

`requirements-ci.txt` 는 `requirements.txt` 를 고정한 결과물이다.
원본만 고치고 잠금을 다시 만들지 않으면, CI 는 옛 버전을 계속 설치하면서도
초록으로 통과한다. 어긋난 것을 아무도 모른 채 지나가는 것이 문제다.
"""

from __future__ import annotations

import os
import re

import pytest
from packaging.requirements import Requirement
from packaging.version import Version

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "requirements.txt")
LOCK = os.path.join(ROOT, "requirements-ci.txt")


def _read(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        return [ln.rstrip() for ln in fh]


def _lock_pins() -> dict[str, Version]:
    """잠금 파일의 `이름==버전` 을 모은다. 뒤따르는 --hash 줄은 건너뛴다."""
    pins: dict[str, Version] = {}
    for line in _read(LOCK):
        if not line or line[0].isspace() or line.startswith("#"):
            continue
        req = Requirement(line.rstrip("\\").strip())
        spec = list(req.specifier)
        assert len(spec) == 1 and spec[0].operator == "==", f"== 로 고정되지 않았다: {line}"
        pins[req.name.lower()] = Version(spec[0].version)
    return pins


def _src_reqs() -> list[Requirement]:
    out = []
    for line in _read(SRC):
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(Requirement(line))
    return out


def test_lock_file_exists():
    assert os.path.exists(LOCK), "requirements-ci.txt 가 없다"


def test_every_pin_is_exact_and_hashed():
    """모든 항목이 == 로 고정되고 해시를 갖는다. --require-hashes 의 전제다."""
    pins = _lock_pins()
    assert pins, "잠금 항목이 하나도 없다"

    text = open(LOCK, encoding="utf-8").read()
    for name in pins:
        block = re.search(
            rf"^{re.escape(name)}==.*?(?=^\S|\Z)", text, re.M | re.S | re.I
        )
        assert block, f"{name} 블록을 찾지 못했다"
        assert "--hash=sha256:" in block.group(0), f"{name} 에 해시가 없다"


@pytest.mark.parametrize("req", _src_reqs(), ids=lambda r: r.name)
def test_source_requirement_is_locked(req: Requirement):
    """requirements.txt 의 각 항목이 잠금 파일에 있고 제약을 만족한다."""
    pins = _lock_pins()
    name = req.name.lower()
    assert name in pins, (
        f"{req.name} 이 requirements-ci.txt 에 없다. "
        f"원본을 고쳤다면 잠금 파일도 다시 만들어야 한다"
    )
    got = pins[name]
    assert req.specifier.contains(got, prereleases=True), (
        f"{req.name}: 잠긴 {got} 이 원본 제약 '{req.specifier}' 를 만족하지 않는다"
    )
