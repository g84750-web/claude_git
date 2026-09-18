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
    assert len(SQL_FILES) == 47, "리포트 46개 + 이전 점검 Z-01 이 모두 있어야 한다"


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
    ("ENV002", "SELECT LAG(X) OVER (ORDER BY Y) FROM T WITH (NOLOCK);", {}),
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


# ─────────────────────────────────────────────────────────────────────
# 4. ENV002 — 요구 엔진 버전
#
# 사이트가 2008 R2 로 남아 있는 경우가 실제로 있다. 2012 전용 구문은 그 서버에서
# 구문 오류로 거부되므로, 어느 파일이 걸리는지 헤더와 Z00 진단이 함께 알아야 한다.
# 여기서 잠그는 것은 세 가지다 — 경계선이 맞는가, 동적 SQL 안도 보는가,
# 그리고 헤더·Z00·규칙 세 곳의 목록이 서로 어긋나지 않는가.
# ─────────────────────────────────────────────────────────────────────

import re  # noqa: E402

from rules import WARN, engine_2012_required, lint_ignored, needs_2012  # noqa: E402

HDR_2012 = HEADER.replace(
    "[ iCUBE ] 테스트", "[ iCUBE ] 테스트\n  DBMS : MS-SQL Server 2012 이상 (T-SQL)")


def _findings(body, header=HEADER):
    raw = header + body
    f = SqlFile(path="T.sql", name="T.sql", raw=raw, has_bom=True, units=build_units(raw))
    return [x for r in ALL_RULES for x in r(f)]


def _env002(body, header=HEADER):
    return [x for x in _findings(body, header) if x.rule == "ENV002"]


def test_ranking_over_order_by_is_fine_on_2008r2():
    """ROW_NUMBER() OVER (ORDER BY ..) 는 2005 부터 된다 — 잡으면 안 된다."""
    body = "SELECT ROW_NUMBER() OVER (ORDER BY A.X) FROM T A WITH (NOLOCK);"
    assert _env002(body) == []


def test_aggregate_over_order_by_needs_2012():
    """반면 집계함수에 ORDER BY 가 붙으면 2012 가 필요하다."""
    body = "SELECT SUM(A.X) OVER (ORDER BY A.Y) FROM T A WITH (NOLOCK);"
    assert [x.rule for x in _env002(body)] == ["ENV002"]


def test_window_frame_needs_2012():
    body = ("SELECT SUM(A.X) OVER (PARTITION BY A.G ORDER BY A.Y"
            " ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)"
            " FROM T A WITH (NOLOCK);")
    assert [x.rule for x in _env002(body)] == ["ENV002"]


def test_env002_reads_inside_dynamic_sql():
    """C03 은 2012 전용 구문이 동적 SQL 문자열 안에만 있었다 — 그래서 놓쳤었다."""
    body = ("DECLARE @S NVARCHAR(MAX) = N'SELECT SUM(A.X) OVER (ORDER BY A.Y)"
            " FROM T A WITH (NOLOCK)';\nEXEC sp_executesql @S;")
    assert [x.rule for x in _env002(body)] == ["ENV002"]


def test_declared_header_silences_env002():
    body = "SELECT LAG(A.X) OVER (ORDER BY A.Y) FROM T A WITH (NOLOCK);"
    assert [x.rule for x in _env002(body)] == ["ENV002"]   # 선언이 없으면 잡고
    assert _env002(body, HDR_2012) == []                   # 선언하면 조용하다


def test_declaring_2012_without_using_it_warns():
    """2008 R2 사이트에서 쓸 수 있는 파일을 못 쓰게 표시해두는 것도 오류다."""
    body = "SELECT ROW_NUMBER() OVER (ORDER BY A.X) FROM T A WITH (NOLOCK);"
    got = _env002(body, HDR_2012)
    assert [x.severity for x in got] == [WARN]


# ── 헤더 · Z00 · 규칙 세 곳이 어긋나지 않는가 ────────────────────────

def _pack_needs_2012():
    """면제 선언까지 반영한 목록 — 규칙·Z00·헤더가 모두 이 기준을 따라야 한다."""
    from lint_icube_sql import load
    return {os.path.basename(p) for p in SQL_FILES if engine_2012_required(load(p))}


def _z00_v12_list():
    z = open(os.path.join(PACK, "Z00_사이트진단.sql"), encoding="utf-8-sig").read()
    seg = z[z.index("INSERT INTO #V12"):]
    seg = seg[: seg.index("\n;")]
    return set(re.findall(r"N'([^']+\.sql)'", seg))


def test_z00_engine_list_matches_rule():
    """Z00 의 #V12 목록이 규칙 판정과 어긋나면 진단이 거짓말을 한다."""
    assert _z00_v12_list() == _pack_needs_2012()


def test_headers_match_rule():
    """각 파일 헤더의 'DBMS : … 2012 이상' 선언이 실제 코드와 일치한다."""
    need = _pack_needs_2012()
    wrong = []
    for path in SQL_FILES:
        name = os.path.basename(path)
        head = open(path, encoding="utf-8-sig").read(4000)
        declared = re.search(r"^\s*DBMS\s*:.*2012\s*이상", head, re.M) is not None
        if declared != (name in need):
            wrong.append(f"{name}: 헤더={declared} 실제={name in need}")
    assert not wrong, "헤더 선언과 코드가 어긋난다\n  " + "\n  ".join(wrong)


def test_z00_declares_nothing_it_cannot_run():
    """진단 파일 자신은 2008 R2 에서 돌아야 한다 — 안 돌면 진단을 못 본다."""
    assert "Z00_사이트진단.sql" not in _pack_needs_2012()


# ── 면제 선언 ────────────────────────────────────────────────────────
#
# 구버전에서 실패하는 것이 **의도**인 파일이 하나 있다 — Z-01 이전 점검은 2012
# 구문을 일부러 실행해 보고 실패를 TRY/CATCH 로 받는다. 그것까지 error 로 잡으면
# 규칙이 옳은 코드를 막는다. 다만 사유 없는 면제는 규칙을 끄는 것과 같으므로
# 받지 않는다.

PROBE = "SELECT LAG(A.X) OVER (ORDER BY A.Y) FROM T A WITH (NOLOCK);"


def _hdr_with(line):
    return HEADER.replace("[ iCUBE ] 테스트", "[ iCUBE ] 테스트\n  " + line)


def test_lint_ignore_with_reason_is_honoured():
    head = _hdr_with("lint-ignore : ENV002 — 구버전에서 실패하는 것이 이 파일의 동작이다")
    assert _env002(PROBE, head) == []


def test_lint_ignore_without_reason_is_not_honoured():
    """사유를 안 적으면 면제가 아니다 — 규칙을 조용히 끄는 통로를 만들지 않는다."""
    assert [x.rule for x in _env002(PROBE, _hdr_with("lint-ignore : ENV002"))] == ["ENV002"]
    assert [x.rule for x in _env002(PROBE, _hdr_with("lint-ignore : ENV002 —"))] == ["ENV002"]


def test_lint_ignore_does_not_leak_to_other_rules():
    """ENV002 면제가 다른 규칙까지 풀어주면 안 된다."""
    head = _hdr_with("lint-ignore : ENV002 — 사유")
    rules_hit = {x.rule for x in _findings("UPDATE SITEM SET STD_UM = 0;", head)}
    assert "SAF001" in rules_hit


def test_only_the_migration_check_is_exempt():
    """면제가 조용히 늘어나지 않게 잠근다. 늘리려면 이 테스트를 함께 고쳐야 한다."""
    from lint_icube_sql import load
    exempt = {os.path.basename(p) for p in SQL_FILES if lint_ignored(load(p), "ENV002")}
    assert exempt == {"Z01_인스턴스이전_점검.sql"}
    # 면제된 파일은 실제로 2012 구문을 쓰고 있어야 한다 — 쓰지도 않으면서 면제받는 것은 군더더기다
    for name in exempt:
        f = load(os.path.join(PACK, name))
        assert needs_2012(f), name
