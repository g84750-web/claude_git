# -*- coding: utf-8 -*-
"""T-SQL 원문 분해기.

이 파일 묶음은 대부분이 `sp_executesql` 로 실행되는 **동적 SQL** 이다.
동적 SQL 본문은 문자열 리터럴 안에 `''` 이스케이프 형태로 들어 있어서,
원문을 그대로 정규식으로 훑으면 두 가지 오류가 동시에 난다.

  - 한글 주석에 적힌 설명문("EXPIRE_YN='0' 으로 걸면 안 된다")이 코드로 잡힌다  → 오탐
  - 동적 SQL 안의 실제 코드는 문자열이라 아예 안 보인다                        → 미탐

그래서 검사 전에 원문을 **분석 단위(Unit)** 로 나눈다.

    Unit 0    정적 코드      주석을 지운 원문
    Unit 1..n 동적 SQL 본문  `''` 를 `'` 로 되돌린 문자열 리터럴

각 Unit 은 원문 줄번호로 되돌릴 수 있는 `linemap` 을 들고 다닌다.
동적 SQL 을 되돌려도 줄 수는 변하지 않으므로 줄번호는 정확히 일치한다.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import List, Tuple

#: 조각 종류
CODE, LINE_COMMENT, BLOCK_COMMENT, STRING, BRACKET = (
    "code",
    "line_comment",
    "block_comment",
    "string",
    "bracket",
)

HANGUL = re.compile(r"[가-힣]")

#: 동적 SQL 로 볼 최소 조건 — 이 키워드가 들어 있어야 SQL 본문으로 취급한다
_SQL_HINT = re.compile(r"\b(SELECT|INSERT|UPDATE|DELETE|FROM|JOIN|WHERE)\b", re.I)

#: 동적 SQL 에 끼워 넣은 식을 대신하는 자리표시자 — 식별자 하나로 취급된다
_GAP = "QQ_EXPR"


@dataclass(frozen=True)
class Segment:
    kind: str
    start: int
    end: int
    #: 문자열 조각에 한해, `N` 접두가 붙어 있었는지
    n_prefixed: bool = False

    @property
    def inner(self) -> Tuple[int, int]:
        """따옴표를 뺀 내용 구간. 문자열 조각에서만 의미가 있다."""
        lo = self.start + (2 if self.n_prefixed else 1)
        return lo, self.end - 1


def scan(text: str) -> List[Segment]:
    """원문을 주석 / 문자열 / 대괄호 식별자 / 그 밖의 코드로 나눈다.

    T-SQL 의 블록 주석은 중첩을 허용하므로 깊이를 세어 닫는다.
    문자열 안의 `''` 는 이스케이프이므로 종료로 보지 않는다.
    """
    out: List[Segment] = []
    n = len(text)
    i = 0
    start = 0

    def flush(upto: int) -> None:
        if start < upto:
            out.append(Segment(CODE, start, upto))

    while i < n:
        ch = text[i]

        if ch == "-" and text.startswith("--", i):
            flush(i)
            end = text.find("\n", i)
            end = n if end == -1 else end
            out.append(Segment(LINE_COMMENT, i, end))
            i = start = end

        elif ch == "/" and text.startswith("/*", i):
            flush(i)
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append(Segment(BLOCK_COMMENT, i, j))
            i = start = j

        elif ch == "'" or (ch in "Nn" and i + 1 < n and text[i + 1] == "'"):
            flush(i)
            n_pre = ch in "Nn"
            j = i + (2 if n_pre else 1)
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append(Segment(STRING, i, j, n_pre))
            i = start = j

        elif ch == "[":
            flush(i)
            j = text.find("]", i)
            j = n if j == -1 else j + 1
            out.append(Segment(BRACKET, i, j))
            i = start = j

        else:
            i += 1

    flush(n)
    return out


def blank(text: str, segments) -> str:
    """지정한 조각을 공백으로 덮는다. 줄바꿈은 남겨 줄번호를 보존한다."""
    buf = list(text)
    for seg in segments:
        for k in range(seg.start, seg.end):
            if buf[k] != "\n":
                buf[k] = " "
    return "".join(buf)


def _linemap(text: str, base: int = 1) -> List[int]:
    """각 문자 위치의 1-based 줄번호 배열."""
    out: List[int] = []
    line = base
    for ch in text:
        out.append(line)
        if ch == "\n":
            line += 1
    out.append(line)  # 끝 위치 조회용 보초
    return out


@dataclass
class Unit:
    """검사 대상 한 덩어리."""

    kind: str  # 'static' | 'dynamic'
    #: 주석이 지워진 SQL 본문
    text: str
    #: 문자열 리터럴까지 지워진 본문 — 테이블·컬럼 패턴 검사용
    code: str
    #: 이 Unit 안의 문자열 리터럴 조각
    strings: List[Segment] = field(default_factory=list)
    #: 문자 위치 → 원문 줄번호
    linemap: List[int] = field(default_factory=list)

    def line_at(self, pos: int) -> int:
        if not self.linemap:
            return 0
        return self.linemap[min(pos, len(self.linemap) - 1)]

    def snippet(self, pos: int, width: int = 110) -> str:
        lo = self.text.rfind("\n", 0, pos) + 1
        hi = self.text.find("\n", pos)
        hi = len(self.text) if hi == -1 else hi
        return self.text[lo:hi].strip()[:width]


def _make_unit(kind: str, text: str, linemap: List[int]) -> Unit:
    segs = scan(text)
    stripped = blank(text, [s for s in segs if s.kind in (LINE_COMMENT, BLOCK_COMMENT)])
    strings = [s for s in scan(stripped) if s.kind == STRING]
    return Unit(
        kind=kind,
        text=stripped,
        code=blank(stripped, strings),
        strings=strings,
        linemap=linemap,
    )


def _merge_concatenated(text: str, segs: List[Segment]) -> List[List[tuple]]:
    """`N'...' + QUOTENAME(@X) + N'...'` 처럼 이어붙인 문자열을 한 덩어리로 묶는다.

    동적 SQL 은 컬럼명·테이블명을 변수로 끼워 넣어 조립하는 일이 흔하다.
    조각을 따로 보면 여는 괄호는 앞 조각에, 닫는 괄호는 뒤 조각에 남아
    없는 괄호 오류를 만들고, `FROM` 과 `WITH(NOLOCK)` 도 갈라진다.

    반환하는 각 덩어리는 항목의 나열이다.
        ('s', Segment)  문자열 조각
        ('g', line)     끼워 넣은 식(式) 자리 — 식별자 하나로 대체한다
    """
    groups: List[List[tuple]] = []
    cur: List[tuple] = []
    prev_end = -1

    for seg in segs:
        if seg.kind != STRING:
            continue
        if cur and prev_end >= 0:
            between = text[prev_end : seg.start]
            if re.fullmatch(r"[\s+]*", between):
                cur.append(("s", seg))
                prev_end = seg.end
                continue
            # `+` 로 이어지면 같은 문자열 식의 일부다.
            # 끼워 넣는 식 안에 또 문자열이 있을 수 있어(`ISNULL(@BOM, N'SBOM_WF')`)
            # 한쪽 끝에만 `+` 가 붙는 경우까지 받는다.
            squeezed = between.strip()
            if ";" not in squeezed and (
                squeezed.startswith("+") or squeezed.endswith("+")
            ):
                cur.append(("g", text.count("\n", 0, prev_end) + 1))
                cur.append(("s", seg))
                prev_end = seg.end
                continue
        if cur:
            groups.append(cur)
        cur = [("s", seg)]
        prev_end = seg.end

    if cur:
        groups.append(cur)
    return groups


def build_units(raw: str) -> List[Unit]:
    """원문 → 정적 코드 1개 + 동적 SQL n개."""
    segs = scan(raw)

    static = _make_unit(
        "static",
        blank(raw, [s for s in segs if s.kind in (LINE_COMMENT, BLOCK_COMMENT)]),
        _linemap(raw),
    )
    units = [static]

    for group in _merge_concatenated(raw, segs):
        chunks: List[str] = []
        lines: List[int] = []
        for kind, item in group:
            if kind == "g":
                chunks.append(_GAP)
                lines.extend([item] * len(_GAP))
                continue
            lo, hi = item.inner
            base = raw.count("\n", 0, lo) + 1
            # `''` → `'` 는 줄 수를 바꾸지 않으므로 줄번호가 그대로 보존된다
            unescaped = raw[lo:hi].replace("''", "'")
            chunks.append(unescaped)
            lines.extend(_linemap(unescaped, base)[:-1])

        body = "".join(chunks)
        if len(body) < 40 or not _SQL_HINT.search(body):
            continue
        lines.append(lines[-1] if lines else 0)
        units.append(_make_unit("dynamic", body, lines))

    return units
