# -*- coding: utf-8 -*-
"""CLAUDE.md 의 확정 사항을 코드로 옮긴 검사 규칙.

규칙 번호는 근거를 가리킨다.

    HDR/PRM/QUL  CLAUDE.md 6장  모든 파일이 지키는 작성 규칙
    VAL          CLAUDE.md 2장  확정 코드값 — 전 파일의 전제
    REG          CLAUDE.md 4장  개발 중 바로잡은 오류 (재발 감시)
    SAF          README         조회 전용 — 데이터를 변경하지 않는다
    ENV          CLAUDE.md 9장  실행 환경 (SSMS 한글)

심각도
    error  실 DB 에 올리기 전에 반드시 고친다
    warn   사람이 한 번 보고 판단한다 (의도적일 수 있다)
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Iterable, List, Optional

from tsql_parse import HANGUL, Unit, scan

ERROR = "error"
WARN = "warn"
#: 리포트 성격·사이트 정책에 따라 갈리는 항목 — 결함이 아니라 확인 목록이다
NOTE = "note"


@dataclass
class Finding:
    rule: str
    severity: str
    path: str
    line: int
    message: str
    snippet: str = ""

    def format(self) -> str:
        tag = {ERROR: "✗", WARN: "!"}.get(self.severity, "·")
        head = f"{tag} {self.path}:{self.line}  [{self.rule}] {self.message}"
        return head + (f"\n      {self.snippet}" if self.snippet else "")


@dataclass
class SqlFile:
    path: str
    name: str
    raw: str
    has_bom: bool
    units: List[Unit]

    @property
    def dynamic(self) -> List[Unit]:
        return [u for u in self.units if u.kind == "dynamic"]

    def all_code(self) -> str:
        """문자열·주석을 뺀 전체 코드 (파일 단위 존재 여부 판정용)."""
        return "\n".join(u.code for u in self.units)

    def all_text(self) -> str:
        """주석만 뺀 전체 본문 (리터럴 값까지 봐야 할 때)."""
        return "\n".join(u.text for u in self.units)


def in_string(unit: Unit, pos: int) -> bool:
    return any(s.start <= pos < s.end for s in unit.strings)


_BINDING = re.compile(
    r"\b(?:FROM|JOIN|MERGE|UPDATE|INTO|APPLY)\s+([#@\w.\[\]]+)"
    r"(?:\s+WITH\s*\([^)]*\))?\s+(?:AS\s+)?(\w+)\b",
    re.I,
)
#: 별칭 자리에 올 수 없는 예약어
_NOT_ALIAS = {
    "ON", "WHERE", "GROUP", "ORDER", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
    "JOIN", "UNION", "WITH", "HAVING", "SELECT", "AND", "OR", "OPTION", "FOR",
    "SET", "VALUES", "AS", "WHEN", "THEN", "USING", "APPLY", "EXCEPT", "INTERSECT",
}


def resolve_alias(unit: Unit, alias: str, pos: int) -> Optional[str]:
    """별칭이 가리키는 테이블을 찾는다.

    두 가지를 함께 처리해야 한다.

      - `SELECT A.PJT_CD FROM ADOCUD A`  선언이 사용보다 **뒤에** 온다.
        SELECT 목록의 컬럼 참조가 늘 이 모양이라 앞쪽만 뒤지면 대부분을 놓친다.
      - 한 파일 안에서 같은 별칭(`D`, `H`, `T`)이 구문마다 다른 테이블에 붙는다.
        파일 전체에서 아무 선언이나 집으면 엉뚱한 테이블로 읽는다.

    그래서 `;` 로 끊은 같은 구문 안에서 **가장 가까운** 선언을 쓴다.
    구문 안에 없으면(동적 SQL 조각은 `;` 가 없을 수 있다) 앞쪽에서 가장 가까운
    선언으로 물러선다.
    """
    want = alias.upper()
    code = unit.code

    lo = code.rfind(";", 0, pos) + 1
    hi = code.find(";", pos)
    hi = len(code) if hi == -1 else hi

    def nearest(start: int, end: int) -> Optional[str]:
        best, best_d = None, None
        for m in _BINDING.finditer(code[start:end]):
            if m.group(2).upper() in _NOT_ALIAS or m.group(2).upper() != want:
                continue
            d = abs((start + m.start(2)) - pos)
            if best_d is None or d < best_d:
                best, best_d = m.group(1), d
        return best

    return nearest(lo, hi) or nearest(0, pos)


def alias_is(unit: Unit, alias: str, pos: int, table: str) -> bool:
    got = resolve_alias(unit, alias, pos)
    return bool(got) and got.split(".")[-1].strip("[]").upper() == table.upper()


def iter_code(f: SqlFile, pattern: re.Pattern):
    """모든 Unit 의 코드 영역에서 패턴을 찾는다."""
    for unit in f.units:
        for m in pattern.finditer(unit.code):
            yield unit, m


def iter_text(f: SqlFile, pattern: re.Pattern):
    """리터럴 값이 필요한 검사용. 중첩 문자열 안의 매치는 버린다.

    정적 Unit 에서 동적 SQL 본문은 문자열이라 걸러지고, 같은 코드가
    동적 Unit 에서 다시 검사되므로 중복 보고가 생기지 않는다.
    """
    for unit in f.units:
        for m in pattern.finditer(unit.text):
            if not in_string(unit, m.start()):
                yield unit, m


# ----------------------------------------------------------------------------
# ENV / HDR / PRM — 작성 규칙과 실행 환경
# ----------------------------------------------------------------------------

def rule_bom(f: SqlFile) -> List[Finding]:
    if f.has_bom or not HANGUL.search(f.raw):
        return []
    return [
        Finding(
            "ENV001", ERROR, f.name, 1,
            "UTF-8 BOM 이 없다. SSMS 는 BOM 없는 파일을 시스템 ANSI(CP949)로 열어 "
            "한글 별칭과 N'' 판정문이 깨진다",
        )
    ]


def rule_header(f: SqlFile) -> List[Finding]:
    head = f.raw[:4000]
    if not head.lstrip("﻿").lstrip().startswith("/*"):
        return [Finding("HDR001", ERROR, f.name, 1, "파일 첫머리에 헤더 주석 블록이 없다")]
    if "목적" not in head:
        return [Finding("HDR001", ERROR, f.name, 1, "헤더 주석에 [목적] 이 없다")]
    return []


def _missing_block(f: SqlFile, markers, rule: str, label: str) -> List[Finding]:
    """제목 뒤에 꼬리말이 붙거나(`[ 한계 — 근사치 ]`) 이름이 다른 동등 블록도 인정한다."""
    pattern = r"\[[^\]\n]*(?:" + "|".join(markers) + r")[^\]\n]*\]"
    if re.search(pattern, f.raw):
        return []
    return [Finding(rule, ERROR, f.name, 1, f"파일 하단에 [ {label} ] 블록이 없다")]


#: 같은 역할을 하는 제목들 — 파일마다 표기가 조금씩 다르다
_CHECK_MARKERS = ("도입 전 확인", "적용 전 확인", "사전 확인", "확인이 필요한 항목")
_LIMIT_MARKERS = ("한계", "커버되지 않는", "알 수 없는")


def rule_checkblock(f: SqlFile) -> List[Finding]:
    return _missing_block(f, _CHECK_MARKERS, "HDR002", "도입 전 확인")


def rule_limitblock(f: SqlFile) -> List[Finding]:
    return _missing_block(f, _LIMIT_MARKERS, "HDR003", "한계")


_DECLARE = re.compile(r"^[ \t]*DECLARE\b", re.I | re.M)


def rule_declare(f: SqlFile) -> List[Finding]:
    if _DECLARE.search(f.units[0].code):
        return []
    return [Finding("PRM001", ERROR, f.name, 1, "상단 파라미터 DECLARE 블록이 없다")]


# ----------------------------------------------------------------------------
# SAF — 조회 전용 보장
# ----------------------------------------------------------------------------

_DML = re.compile(
    r"(?<!THEN\s)\b(INSERT\s+INTO|MERGE(?:\s+INTO)?|TRUNCATE\s+TABLE|DROP\s+TABLE|"
    r"ALTER\s+TABLE|CREATE\s+TABLE|UPDATE|DELETE)\b\s+(?:TOP\s*\([^)]*\)\s*)?"
    r"([#@\w.\[\]]+)",
    re.I,
)
#: `WHEN MATCHED THEN UPDATE SET ...` 처럼 대상 없이 오는 MERGE 절
_MERGE_CLAUSE = re.compile(r"\bTHEN\s+(?:UPDATE|INSERT|DELETE)\b", re.I)


def rule_readonly(f: SqlFile) -> List[Finding]:
    out: List[Finding] = []
    for unit, m in iter_code(f, _DML):
        verb, target = m.group(1).upper(), m.group(2)
        if target.startswith(("#", "@")):
            continue
        # MERGE 의 WHEN 절은 대상을 적지 않는다 — MERGE 문 자체에서 이미 판정했다
        if _MERGE_CLAUSE.search(unit.code[max(0, m.start() - 12) : m.end()]):
            continue
        # UPDATE/DELETE 는 대상이 별칭일 수 있다. 같은 문장 안에 임시테이블이
        # 있으면 임시테이블 갱신으로 본다.
        if verb in ("UPDATE", "DELETE"):
            tail = unit.code[m.end() : m.end() + 600]
            stop = tail.find(";")
            if "#" in (tail[:stop] if stop != -1 else tail):
                continue
        out.append(
            Finding(
                "SAF001", ERROR, f.name, unit.line_at(m.start()),
                f"조회 전용 규칙 위반 — 임시객체가 아닌 대상에 {verb} ({target})",
                unit.snippet(m.start()),
            )
        )
    return out


# ----------------------------------------------------------------------------
# VAL — 확정 코드값 (CLAUDE.md 2장)
# ----------------------------------------------------------------------------

_EXPIRE = re.compile(
    r"EXPIRE_YN\s*(?:,\s*N?'[^']*'\s*\))?\s*(=|<>|!=|NOT\s+IN|IN)\s*\(?\s*N?'([^']*)'",
    re.I,
)


def rule_expire_yn(f: SqlFile) -> List[Finding]:
    """`'1'` 이 진행/유효. 반대로 걸면 전 건이 사라진다 (오류 #1, #2)."""
    out: List[Finding] = []
    for unit, m in iter_text(f, _EXPIRE):
        op, val = m.group(1).upper(), m.group(2)
        ok = (op == "=" and val == "1") or (op in ("<>", "!=") and val == "0")
        if ok:
            continue
        out.append(
            Finding(
                "VAL001", WARN, f.name, unit.line_at(m.start()),
                f"EXPIRE_YN {op} '{val}' — '1' 이 진행/유효다. 만료 건을 일부러 "
                "고르는 것이 아니면 방향이 뒤집힌 것이다",
                unit.snippet(m.start()),
            )
        )
    return out


def _uses(f: SqlFile, token: str) -> bool:
    return re.search(r"\b" + token + r"\b", f.all_code(), re.I) is not None


def rule_rcpam_fg(f: SqlFile) -> List[Finding]:
    """수금 집계에는 `RCPAM_FG='0'`(영업모듈) 필터가 필수다 (오류 #9)."""
    if not _uses(f, "LRCP_D") or _uses(f, "RCPAM_FG"):
        return []
    line = 1
    for unit, m in iter_code(f, re.compile(r"\bLRCP_D\b", re.I)):
        line = unit.line_at(m.start())
        break
    return [
        Finding(
            "VAL002", ERROR, f.name, line,
            "LRCP_D 로 수금을 집계하면서 RCPAM_FG 필터가 없다. 타 모듈 수금이 "
            "섞여 S04·S06·E01·A05 의 수금액과 대사되지 않는다",
        )
    ]


def rule_pjtcd_ty(f: SqlFile) -> List[Finding]:
    """`ADOCUD.PJT_CD` 는 `PJTCD_TY` 에 따라 프로젝트(D1)/사원(D4)이다."""
    out: List[Finding] = []
    for unit in f.units:
        if re.search(r"\bPJTCD_TY\b", unit.code, re.I):
            continue
        for m in re.finditer(r"\b(\w+)\.PJT_CD\b", unit.code, re.I):
            if not alias_is(unit, m.group(1), m.start(), "ADOCUD"):
                continue
            out.append(
                Finding(
                    "VAL003", ERROR, f.name, unit.line_at(m.start()),
                    f"ADOCUD 별칭 {m.group(1)} 의 PJT_CD 를 쓰면서 PJTCD_TY='D1' 필터가 "
                    "없다. 사원 코드(D4)가 프로젝트로 집계된다",
                    unit.snippet(m.start()),
                )
            )
    return out


def rule_linv_tav_gisu(f: SqlFile) -> List[Finding]:
    """LINV_TAV 조인키에는 기수(GISU)가 반드시 들어간다."""
    if not _uses(f, "LINV_TAV") or _uses(f, "GISU"):
        return []
    line = 1
    for unit, m in iter_code(f, re.compile(r"\bLINV_TAV\b", re.I)):
        line = unit.line_at(m.start())
        break
    return [
        Finding(
            "VAL004", ERROR, f.name, line,
            "LINV_TAV 를 쓰면서 조인키에 GISU(기수)가 없다. 과거 기수가 중복 조인된다",
        )
    ]


def rule_discontinued(f: SqlFile) -> List[Finding]:
    """단종품(S_CD='Z00') 제외는 실무 쿼리 공통 관례다."""
    if not _uses(f, "SITEM"):
        return []
    if re.search(r"Z00", f.all_text(), re.I):
        return []
    return [
        Finding(
            "VAL005", NOTE, f.name, 1,
            "SITEM 을 쓰면서 단종품 제외(S_CD <> 'Z00')가 없다. 의도한 것인지 확인",
        )
    ]


# ----------------------------------------------------------------------------
# REG — 이미 바로잡은 오류의 재발 감시 (CLAUDE.md 4장)
# ----------------------------------------------------------------------------

def rule_outsourcing_cost(f: SqlFile) -> List[Finding]:
    """외주가공비 소스는 LOCLS_H/D 다. LWO_WF_D.LBR_AM 은 지시상 예정치다 (오류 #3).

    LOCLS 를 우선 쓰고 없을 때만 LWO_WF_D 로 내려가는 구성은 정상이므로,
    파일이 LOCLS 를 아예 쓰지 않을 때만 지적한다.
    """
    if re.search(r"\bLOCLS_[HD]\b", f.all_code(), re.I):
        return []
    out: List[Finding] = []
    for unit in f.units:
        for m in re.finditer(r"\b(\w+)\.LBR_AM\b", unit.code, re.I):
            if not alias_is(unit, m.group(1), m.start(), "LWO_WF_D"):
                continue
            out.append(
                Finding(
                    "REG003", ERROR, f.name, unit.line_at(m.start()),
                    "외주가공비를 LWO_WF_D.LBR_AM(지시상 예정치)에서만 뽑고 있다. "
                    "원가계산 SP 5-4 단계와 같은 LOCLS_H/LOCLS_D 를 써야 한다",
                    unit.snippet(m.start()),
                )
            )
    return out


_BATCH_DIV = re.compile(r"/\s*(?:NULLIF\s*\(\s*)?[\w.]*\bBATCH_QT\b", re.I)


def rule_batch_qt(f: SqlFile) -> List[Finding]:
    """BATCH BOM 의 기준수량은 SBOM_WF_B + SITEM.FOQ_QT 다 (오류 #5)."""
    return [
        Finding(
            "REG005", ERROR, f.name, unit.line_at(m.start()),
            "SBOM.BATCH_QT 로 나누고 있다. BATCH BOM 기준수량은 "
            "SBOM_WF_B 와 SITEM.FOQ_QT 에서 온다",
            unit.snippet(m.start()),
        )
        for unit, m in iter_code(f, _BATCH_DIV)
    ]


def rule_phantom_tables(f: SqlFile) -> List[Finding]:
    """존재하지 않는 추정 테이블/컬럼 (오류 #6, #8)."""
    out: List[Finding] = []
    for unit, m in iter_code(f, re.compile(r"\bLWOBOM\b", re.I)):
        out.append(
            Finding(
                "REG006", ERROR, f.name, unit.line_at(m.start()),
                "LWOBOM 은 없는 테이블이다. 자재청구는 LWO_REQ_WF 다",
                unit.snippet(m.start()),
            )
        )
    for unit in f.units:
        for m in re.finditer(r"\b(\w+)\.USE_YN\b", unit.code, re.I):
            if not alias_is(unit, m.group(1), m.start(), "SDEPT"):
                continue
            out.append(
                Finding(
                    "REG008", ERROR, f.name, unit.line_at(m.start()),
                    "SDEPT 에는 USE_YN 컬럼이 없다. 유효기간은 REG_DT/TO_DT 로 관리한다",
                    unit.snippet(m.start()),
                )
            )
    return out


# ----------------------------------------------------------------------------
# QUL — T-SQL 품질
# ----------------------------------------------------------------------------

def rule_unicode_literal(f: SqlFile) -> List[Finding]:
    """한글 리터럴에는 N 접두가 필요하다.

    동적 SQL 안에서 `''한글''` 로 쓰면 실행 시점에 N 없는 리터럴이 되어,
    DB 콜레이션이 한국어가 아니면 물음표로 떨어진다.
    """
    out: List[Finding] = []
    for unit in f.units:
        for seg in unit.strings:
            if seg.n_prefixed:
                continue
            lo, hi = seg.inner
            body = unit.text[lo:hi]
            if not HANGUL.search(body):
                continue
            out.append(
                Finding(
                    "QUL001", ERROR, f.name, unit.line_at(seg.start),
                    f"한글 리터럴에 N 접두가 없다 — '{body[:30]}'",
                    unit.snippet(seg.start),
                )
            )
    return out


def rule_paren_balance(f: SqlFile) -> List[Finding]:
    out: List[Finding] = []
    for unit in f.units:
        depth = 0
        bad: Optional[int] = None
        for i, ch in enumerate(unit.code):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth < 0 and bad is None:
                    bad = i
                    break
        if bad is not None:
            out.append(
                Finding("QUL002", ERROR, f.name, unit.line_at(bad),
                        f"괄호가 맞지 않는다 — 닫는 괄호가 더 많다 ({unit.kind})",
                        unit.snippet(bad)))
        elif depth > 0:
            out.append(
                Finding("QUL002", ERROR, f.name, unit.line_at(len(unit.code) - 1),
                        f"괄호가 맞지 않는다 — 여는 괄호가 {depth}개 남았다 ({unit.kind})"))
    return out


def rule_quote_balance(f: SqlFile) -> List[Finding]:
    """따옴표가 닫히지 않으면 그 뒤 전체가 문자열로 먹힌다."""
    segs = scan(f.raw)
    for seg in segs:
        if seg.kind != "string":
            continue
        if not f.raw[seg.end - 1 : seg.end] == "'":
            line = f.raw.count("\n", 0, seg.start) + 1
            return [Finding("QUL005", ERROR, f.name, line, "닫히지 않은 문자열 리터럴이 있다")]
    return []


_FROM_JOIN = re.compile(r"\b(FROM|JOIN)\s+((?!\()[#@\w.\[\]]+)(\s+(?:AS\s+)?(\w+))?", re.I)
_SKIP_TABLE = re.compile(
    r"^(sys\.|INFORMATION_SCHEMA|#|@|OPENJSON|STRING_SPLIT)", re.I)
#: 동적 SQL 조립 자리표시자 — 실제 테이블이 아니다
_PLACEHOLDER = re.compile(r"QQ_EXPR", re.I)
_KEYWORD_ALIAS = {
    "ON", "WHERE", "GROUP", "ORDER", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS",
    "JOIN", "UNION", "WITH", "HAVING", "SELECT", "AND", "OR", "OPTION", "FOR",
}


def rule_nolock(f: SqlFile) -> List[Finding]:
    out: List[Finding] = []
    for unit in f.units:
        # CTE 는 컬럼 목록을 달고 선언되기도 한다 — `;WITH T (a, b) AS (`
        ctes = {
            m.group(1).upper()
            for m in re.finditer(r"\b(\w+)\s*(?:\([^()]*\))?\s+AS\s*\(", unit.code, re.I)
        }
        for m in _FROM_JOIN.finditer(unit.code):
            table = m.group(2)
            if _SKIP_TABLE.match(table) or table.upper() in ctes:
                continue
            if _PLACEHOLDER.search(table) or table.rstrip(".") in ("dbo", ""):
                continue
            if table.upper() in _KEYWORD_ALIAS:
                continue
            tail = unit.code[m.end() : m.end() + 60]
            if re.search(r"NOLOCK", m.group(0) + tail, re.I):
                continue
            out.append(
                Finding("QUL003", WARN, f.name, unit.line_at(m.start()),
                        f"{table} 에 WITH(NOLOCK) 이 없다 (조회 전용 규칙)",
                        unit.snippet(m.start())))
    return out


ALL_RULES: List[Callable[[SqlFile], List[Finding]]] = [
    rule_bom,
    rule_header,
    rule_checkblock,
    rule_limitblock,
    rule_declare,
    rule_readonly,
    rule_expire_yn,
    rule_rcpam_fg,
    rule_pjtcd_ty,
    rule_linv_tav_gisu,
    rule_discontinued,
    rule_outsourcing_cost,
    rule_batch_qt,
    rule_phantom_tables,
    rule_unicode_literal,
    rule_paren_balance,
    rule_quote_balance,
    rule_nolock,
]
