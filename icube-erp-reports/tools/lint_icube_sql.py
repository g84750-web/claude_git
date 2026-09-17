#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iCUBE ERP 리포트 쿼리 정적 검사기.

실 DB 없이 잡을 수 있는 오류를 전부 잡는 것이 목적이다.
CLAUDE.md 2장(확정 코드값)·4장(기왕 오류)·6장(작성 규칙)을 규칙으로 옮겼다.

    python3 tools/lint_icube_sql.py                 # 전체 검사
    python3 tools/lint_icube_sql.py S04*.sql        # 일부만
    python3 tools/lint_icube_sql.py --severity error
    python3 tools/lint_icube_sql.py --format json

종료코드 0 = error 없음, 1 = error 있음.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from collections import Counter
from typing import List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rules import ALL_RULES, ERROR, NOTE, WARN, Finding, SqlFile  # noqa: E402
from tsql_parse import build_units  # noqa: E402

BOM = "﻿"


def load(path: str) -> SqlFile:
    data = open(path, "rb").read()
    has_bom = data.startswith(BOM.encode("utf-8"))
    raw = data.decode("utf-8-sig")
    return SqlFile(
        path=path,
        name=os.path.basename(path),
        raw=raw,
        has_bom=has_bom,
        units=build_units(raw),
    )


def check(path: str) -> List[Finding]:
    f = load(path)
    out: List[Finding] = []
    for rule in ALL_RULES:
        out.extend(rule(f))
    out.sort(key=lambda x: (x.line, x.rule))
    return out


def main(argv: List[str] | None = None) -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    ap = argparse.ArgumentParser(description="iCUBE 리포트 쿼리 정적 검사")
    ap.add_argument("paths", nargs="*", help="검사할 .sql (생략하면 전체)")
    ap.add_argument("--severity", choices=[ERROR, WARN, NOTE], help="이 등급만 출력")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    ap.add_argument("--rule", action="append", help="이 규칙만 (여러 번 지정 가능)")
    args = ap.parse_args(argv)

    targets = args.paths or sorted(glob.glob(os.path.join(root, "*.sql")))
    if not targets:
        print("검사할 .sql 파일이 없다", file=sys.stderr)
        return 2

    findings: List[Finding] = []
    for path in targets:
        findings.extend(check(path))

    if args.severity:
        findings = [x for x in findings if x.severity == args.severity]
    if args.rule:
        wanted = {r.upper() for r in args.rule}
        findings = [x for x in findings if x.rule.upper() in wanted]

    if args.format == "json":
        print(json.dumps([x.__dict__ for x in findings], ensure_ascii=False, indent=2))
    else:
        by_file: dict = {}
        for x in findings:
            by_file.setdefault(x.path, []).append(x)
        for name in sorted(by_file):
            print(f"\n── {name}")
            for x in by_file[name]:
                print("  " + x.format().split("\n", 1)[0][2:])
                if x.snippet:
                    print(f"       {x.snippet}")

        counts = Counter(x.rule for x in findings)
        by_sev = Counter(x.severity for x in findings)
        print(f"\n{'=' * 78}")
        print(f"파일 {len(targets)}개 · 지적 {len(findings)}건 "
              f"(error {by_sev[ERROR]} / warn {by_sev[WARN]} / note {by_sev[NOTE]})")
        if counts:
            print("규칙별: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))

    return 1 if any(x.severity == ERROR for x in findings) else 0


if __name__ == "__main__":
    raise SystemExit(main())
