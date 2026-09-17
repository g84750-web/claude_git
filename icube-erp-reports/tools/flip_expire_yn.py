#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""EXPIRE_YN 극성을 전 파일에서 한 번에 뒤집는다.

사이트 적용 절차 ② — 코드값 전제를 실측했더니 `'1'` 이 진행이 아니라면,
46개 파일에 흩어진 비교식을 손으로 고칠 수는 없다. 이 도구가 그 작업을 한다.

    python3 tools/flip_expire_yn.py            # 무엇이 바뀔지 미리보기 (기본)
    python3 tools/flip_expire_yn.py --apply    # 실제로 반영

바꾸는 것
    ISNULL(X.EXPIRE_YN, N'1') = N'1'   →   ISNULL(X.EXPIRE_YN, N'0') = N'0'
    D.EXPIRE_YN = N'0'                 →   D.EXPIRE_YN = N'1'
    동적 SQL 안의 이스케이프 형태(`N''1''`)도 같이 처리한다.

건드리지 않는 것
    주석 안의 설명문, `ISNULL(..., N'')` 처럼 빈 문자열을 기본값으로 둔 곳,
    `IN ('0','1')` 같은 목록 비교 — 이런 곳은 수동 확인 대상으로 따로 보고한다.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from tsql_parse import BLOCK_COMMENT, LINE_COMMENT, scan  # noqa: E402

#: `EXPIRE_YN [, 기본값 )] 연산자 비교값` — 따옴표는 1개(정적) 또는 2개(동적) 다
EXPR = re.compile(
    r"EXPIRE_YN"
    r"(?P<dflt>\s*,\s*N?'+[01]'+\s*\))?"
    r"(?P<op>\s*(?:=|<>|!=)\s*)"
    r"(?P<cmp>N?'+[01]'+)",
    re.I,
)
#: 목록 비교 — 자동으로 뒤집기 위험하므로 보고만 한다
LISTED = re.compile(r"EXPIRE_YN\s*(?:NOT\s+)?IN\s*\(", re.I)

_FLIP = {"0": "1", "1": "0"}


def flip_literal(text: str) -> str:
    return re.sub(r"[01]", lambda m: _FLIP[m.group(0)], text, count=1)


def comment_spans(raw: str):
    return [(s.start, s.end) for s in scan(raw)
            if s.kind in (LINE_COMMENT, BLOCK_COMMENT)]


def process(path: str):
    raw = open(path, "rb").read().decode("utf-8-sig")
    spans = comment_spans(raw)

    def in_comment(pos: int) -> bool:
        return any(a <= pos < b for a, b in spans)

    changes, manual = [], []
    out, last = [], 0

    for m in EXPR.finditer(raw):
        if in_comment(m.start()):
            continue
        new = "EXPIRE_YN"
        if m.group("dflt"):
            new += flip_literal(m.group("dflt"))
        new += m.group("op") + flip_literal(m.group("cmp"))
        line = raw.count("\n", 0, m.start()) + 1
        changes.append((line, m.group(0).strip(), new.strip()))
        out.append(raw[last:m.start()])
        out.append(new)
        last = m.end()

    out.append(raw[last:])

    for m in LISTED.finditer(raw):
        if not in_comment(m.start()):
            manual.append(raw.count("\n", 0, m.start()) + 1)

    return "".join(out), changes, manual


def main(argv=None) -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description="EXPIRE_YN 극성 일괄 반전")
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--apply", action="store_true", help="실제로 파일에 쓴다")
    args = ap.parse_args(argv)

    targets = args.paths or sorted(glob.glob(os.path.join(root, "*.sql")))
    total, files, manual_total = 0, 0, 0

    for path in targets:
        new, changes, manual = process(path)
        if not changes and not manual:
            continue
        name = os.path.basename(path)
        print(f"\n── {name}")
        for line, before, after in changes:
            print(f"  {line:>5}  {before}")
            print(f"         →  {after}")
        for line in manual:
            print(f"  {line:>5}  ★ IN (...) 목록 비교 — 수동 확인")
        total += len(changes)
        manual_total += len(manual)
        files += 1
        if args.apply and changes:
            raw = open(path, "rb").read()
            bom = b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b""
            open(path, "wb").write(bom + new.encode("utf-8"))

    print(f"\n{'=' * 78}")
    print(f"파일 {files}개 · 반전 {total}건 · 수동 확인 {manual_total}건"
          + ("  [반영함]" if args.apply else "  [미리보기 — 반영하려면 --apply]"))
    print("반영 후에는 tools/lint_icube_sql.py 를 다시 돌려 확인할 것.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
