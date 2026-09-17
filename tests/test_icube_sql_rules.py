# -*- coding: utf-8 -*-
"""iCUBE 리포트 쿼리 정적 검사 회귀 테스트.

세 가지를 잠근다.

  1. 묶음 전체에 error 등급 지적이 없다.
  2. 규칙이 실제로 발동한다 — 아무것도 잡지 못하는 죽은 규칙을 막는다.
  3. 개발 중 실제로 겪은 오탐이 다시 나지 않는다.

3번이 특히 중요하다. 이 파일 묶음은 대부분이 동적 SQL 이고 별칭(`D`, `H`, `T`)이
구문마다 다른 테이블에 붙기 때문에, 순진하게 짠 규칙은 틀린 곳을 가리킨다.
"""

from __future__ import annotations

import glob
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACK = os.path.join(ROOT, "icube-erp-reports")
sys.path.insert(0, os.path.join(PACK, "tools"))

from rules import ALL_RULES, ERROR, SqlFile  # noqa: E402
from tsql_parse import build_units  # noqa: E402

HEADER = (
    "/*===\n  [ iCUBE ] 테스트\n  목적 : 규칙 발동 확인\n"
    "  [ 도입 전 확인 ]\n  [ 한계 ]\n===*/\nDECLARE @CO_CD NVARCHAR(4) = N'1000';\n"
)


def lint(body: str, *, header: bool = True, bom: bool = True, name: str = "T.sql"):
    raw = (HEADER if header else "") + body
    f = SqlFile(path=name, name=name, raw=raw, has_bom=bom, units=build_units(raw))
    out = []
    for rule in ALL_RULES:
        out.extend(rule(f))
    return {x.rule for x in out}


# ─────────────────────────────────────────────────────────────────────
# 1. 묶음 전체
# ─────────────────────────────────────────────────────────────────────

SQL_FILES = sorted(glob.glob(os.path.join(PACK, "*.sql")))


def test_pack_is_not_empty():
    assert len(SQL_FILES) == 46, "리포트 46개가 모두 있어야 한다"


@pytest.mark.parametrize("path", SQL_FILES, ids=os.path.basename)
def test_no_error_findings(path):
    """실 DB 에 올리기 전에 반드시 고쳐야 할 지적이 남아 있으면 안 된다."""
    import lint_icube_sql

    errors = [x for x in lint_icube_sql.check(path) if x.severity == ERROR]
    assert not errors, "\n".join(x.format() for x in errors)


@pytest.mark.parametrize("path", SQL_FILES, ids=os.path.basename)
def test_has_utf8_bom(path):
    """SSMS 가 한글을 CP949 로 잘못 읽지 않도록 BOM 이 있어야 한다."""
    assert open(path, "rb").read(3) == b"\xef\xbb\xbf"


# ─────────────────────────────────────────────────────────────────────
# 2. 규칙이 실제로 발동하는가
# ─────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("rule,body,kw", [
    ("VAL001", "SELECT 1 FROM LSO_D D WITH (NOLOCK) WHERE D.EXPIRE_YN = N'0';", {}),
    ("VAL002", "SELECT 1 FROM LRCP_D D WITH (NOLOCK) WHERE D.CO_CD = @CO_CD;", {}),
    ("VAL003", "SELECT A.PJT_CD FROM ADOCUD A WITH (NOLOCK);", {}),
    ("VAL004", "SELECT 1 FROM LINV_TAV T WITH (NOLOCK);", {}),
    ("VAL005", "SELECT 1 FROM SITEM I WITH (NOLOCK);", {}),
    ("REG003", "SELECT WD.LBR_AM FROM LWO_WF_D WD WITH (NOLOCK);", {}),
    ("REG005", "SELECT QT / B.BATCH_QT FROM SBOM B WITH (NOLOCK);", {}),
    ("REG006", "SELECT 1 FROM LWOBOM W WITH (NOLOCK);", {}),
    ("REG008", "SELECT 1 FROM SDEPT D WITH (NOLOCK) WHERE D.USE_YN = N'1';", {}),
    ("SAF001", "UPDATE SITEM SET STD_UM = 0;", {}),
    ("QUL001", "SELECT '단가' AS X;", {}),
    ("QUL002", "SELECT (1));", {}),
    ("QUL003", "SELECT 1 FROM SITEM I;", {}),
    ("HDR001", "SELECT 1;", {"header": False}),
    ("ENV001", "SELECT N'한글' AS 별칭;", {"bom": False}),
])
def test_rule_fires(rule, body, kw):
    """규칙마다 반드시 잡아야 할 최소 사례. 죽은 규칙을 막는다."""
    assert rule in lint(body, **kw)


def test_missing_doc_blocks_detected():
    raw = "/*===\n  목적 : x\n===*/\nDECLARE @A INT;\nSELECT 1;\n"
    f = SqlFile(path="T.sql", name="T.sql", raw=raw, has_bom=True, units=build_units(raw))
    hit = {x.rule for r in ALL_RULES for x in r(f)}
    assert {"HDR002", "HDR003"} <= hit


def test_missing_declare_detected():
    assert "PRM001" in lint("SELECT 1;\n", header=False).union(
        lint("/*===\n  목적 : x\n  [ 도입 전 확인 ]\n  [ 한계 ]\n===*/\nSELECT 1;\n",
             header=False))


# ─────────────────────────────────────────────────────────────────────
# 3. 겪었던 오탐이 재발하지 않는가
# ─────────────────────────────────────────────────────────────────────

def test_comment_text_is_not_code():
    """주석에 적힌 설명문을 코드로 읽으면 안 된다."""
    body = "-- EXPIRE_YN = '0' 으로 걸면 전 건이 사라진다\nSELECT 1;\n"
    assert "VAL001" not in lint(body)


def test_alias_resolves_to_nearest_binding():
    """같은 별칭 `D` 가 구문마다 다른 테이블에 붙는다.

    파일 어딘가에 `SDEPT D` 가 있다는 이유로 다른 구문의 `D.USE_YN` 을
    SDEPT 로 읽으면 엉뚱한 파일을 지적하게 된다.
    """
    body = (
        "SELECT 1 FROM SDEPT D WITH (NOLOCK) WHERE D.REG_DT <= @CO_CD;\n"
        "SELECT 1 FROM LRCP H WITH (NOLOCK)\n"
        "  INNER JOIN LRCP_D D WITH (NOLOCK) ON D.RCP_NB = H.RCP_NB\n"
        "  WHERE ISNULL(D.USE_YN, N'1') = N'1' AND D.RCPAM_FG = N'0';\n"
    )
    assert "REG008" not in lint(body)


def test_merge_into_temp_is_not_dml():
    """MERGE 의 `WHEN MATCHED THEN UPDATE SET` 은 대상을 적지 않는다."""
    body = (
        "MERGE #OPN AS T\n"
        "USING (SELECT TR_CD FROM LOPN_CRISU_CLS WITH (NOLOCK)) AS S ON S.TR_CD = T.TR_CD\n"
        "WHEN MATCHED THEN UPDATE SET OPN_CLS = 0\n"
        "WHEN NOT MATCHED THEN INSERT (TR_CD) VALUES (S.TR_CD);\n"
    )
    assert "SAF001" not in lint(body)


def test_interpolated_dynamic_sql_stays_balanced():
    """`N'...' + QUOTENAME(@X) + N'...'` 로 끊긴 조각을 따로 보면 괄호가 안 맞는다."""
    body = (
        "SET @SQL = N'SELECT CAST(ISNULL(B.' + QUOTENAME(@COL) + N', 0) AS DECIMAL(19,4))\n"
        "            FROM dbo.SBILL B WITH (NOLOCK) WHERE B.CO_CD = @p_CO';\n"
    )
    assert "QUL002" not in lint(body)


def test_interpolated_literal_inside_expression():
    """끼워 넣는 식 안에 또 문자열이 있는 경우 — `ISNULL(@BOM, N'SBOM_WF')`."""
    body = (
        "SET @SQL = N'SELECT 1 FROM dbo.' + ISNULL(@BOM, N'SBOM_WF') + N' X WITH (NOLOCK)\n"
        "            WHERE X.CO_CD = @p_CO';\n"
    )
    assert not ({"QUL002", "QUL003"} & lint(body))


def test_doc_block_with_trailing_text():
    """`[ 도입 전 확인 — ★ 순서를 지킬 것 ]` 처럼 꼬리말이 붙어도 인정한다."""
    raw = (
        "/*===\n  목적 : x\n  [ 도입 전 확인 — ★ 순서를 지킬 것 ]\n"
        "  [ 한계 — 근사치 ]\n===*/\nDECLARE @A INT;\nSELECT 1;\n"
    )
    f = SqlFile(path="T.sql", name="T.sql", raw=raw, has_bom=True, units=build_units(raw))
    hit = {x.rule for r in ALL_RULES for x in r(f)}
    assert not ({"HDR002", "HDR003"} & hit)


def test_escaped_literal_in_dynamic_sql_is_read():
    """동적 SQL 안의 `N''1''` 은 실행 시 `N'1'` 이다 — 빈 문자열 비교가 아니다."""
    body = "SET @SQL = N'SELECT 1 FROM LSO_D D WITH (NOLOCK) WHERE D.EXPIRE_YN = N''1''';\n"
    assert "VAL001" not in lint(body)


def test_dynamic_sql_body_is_inspected():
    """반대로, 동적 SQL 안의 진짜 문제는 잡아야 한다."""
    body = "SET @SQL = N'SELECT 1 FROM LSO_D D WITH (NOLOCK) WHERE D.EXPIRE_YN = N''0''';\n"
    assert "VAL001" in lint(body)


# ─────────────────────────────────────────────────────────────────────
# 4. 일괄 반전 도구
# ─────────────────────────────────────────────────────────────────────

def test_flip_round_trip(tmp_path):
    """두 번 뒤집으면 원본으로 돌아와야 한다."""
    import flip_expire_yn

    src = os.path.join(PACK, "A02_기표파이프라인_현황.sql")
    work = tmp_path / "A02.sql"
    work.write_bytes(open(src, "rb").read())

    once, changes, _ = flip_expire_yn.process(str(work))
    assert changes, "반전 대상이 있어야 의미 있는 검증이다"
    work.write_bytes(b"\xef\xbb\xbf" + once.encode("utf-8"))

    twice, _, _ = flip_expire_yn.process(str(work))
    assert twice == open(src, "rb").read().decode("utf-8-sig")
