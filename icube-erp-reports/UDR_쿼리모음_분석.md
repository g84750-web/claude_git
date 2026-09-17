# 더존 사용자정의보고서(UDR) 쿼리모음 분석

**대상**: `D:\외장하드_복사본\0. 더존 보고 자료\6. MS-SQL 명령문외\0. 사용자정의보고서(07.12.12)\0. ERP X, ICUBE_모듈별 쿼리`

---

## 1. 규모

| 구분 | 수치 |
|---|---|
| 전체 파일 | 329개 |
| SQL 포함 텍스트 | **167개** (`.txt` 166, `.sql` 4 중 SELECT 보유분) |
| UDR 포맷 준수 | 163개 (`:SQL_BEGIN` ~ `:SQL_END`) |
| 문서(.doc) | 69개 — 모듈별 「사용자정의보고요약」 |
| 화면캡처(.gif/.jpg) | 52개 |
| 출력양식(.rds/.prt) | 16개 |

### 폴더별 보고서 수

| 폴더 | SQL 파일 | 성격 |
|---|---:|---|
| 영업관리 | 51 | 수주·출고·매출·판매계획·거래명세서 |
| 구매자재관리 | 62 | 발주·입고·재고수불·재고평가·MRP·프로젝트수불 |
| 생산관리 | 30 | 작업지시·실적·공정·외주·재공·생산계획 |
| 기초MASTER정보 | 11 | BOM·BATCH BOM·표준원가·품목관리대장 |
| 단가history관리 | 4 | 거래처단가 이력 SP + 조회 |
| 마이너스재고통제 | 2 | 출고 트리거 + SYSCFG 설정 |
| A_회계 / H_인사 / S_시스템 | 7 | 지급어음·전표·급상여이체·권한·품목현황 |

---

> **[갱신]** 공식 매뉴얼 정본을 확보해 [사용자정의메뉴_작성가이드.md](사용자정의메뉴_작성가이드.md) 에 정리했습니다.
> **사용자정의메뉴(GUI)와 사용자정의보고서(텍스트 DSL)는 별개 체계**이며, 이 코퍼스에 두 방식이
> 섞여 있던 이유가 그것입니다. 아래 2장은 역공학 결과로, 정본은 위 가이드를 보십시오.

## 2. UDR 포맷 명세 — 실무 가치가 가장 큰 발견

이 쿼리들은 단순 SQL이 아니라 **ERP 메뉴로 등록 가능한 사용자정의보고서 DSL**입니다. 포맷을 알면 우리가 만든 쿼리(원가/수율/MRP)를 그대로 ERP 메뉴에 올릴 수 있습니다.

```
제목 : 19.자재-MRP-주계획 현황

:SQL_BEGIN
SELECT ...
FROM LMPS M, SITEM S
WHERE M.CO_CD = :[00] AND M.MPS_DT >= :[01] AND M.MPS_DT <= :[02]
:SQL_END

[03]:@T사업장@H(DIV_CD);
[01]:@T기간 시작일@H(DT);
[02]:@T기간 종료일@H(DT);
[TITLE]:계획구분,계획납기일,품번,품명,규격,계획수량,단위;
[LENGTH]:8,20,10,4,8,5,8;
[SUM]:5,7;
```

### 규칙

| 요소 | 의미 |
|---|---|
| `:[00]` | **회사코드 고정 바인딩** (항상 00번) |
| `:[01]` ~ `:[nn]` | 사용자 입력 파라미터 (선언 순서 무관, 번호로 매칭) |
| `[nn]:@T라벨@H(타입);` | 파라미터 정의 — 라벨과 입력 도우미 타입 |
| `[TITLE]:` | 결과 컬럼 헤더 (콤마 구분, SELECT 순서와 1:1) |
| `[LENGTH]:` | 컬럼 출력 폭 |
| `[SUM]:` | 합계 표시할 컬럼 번호 (1-base) |
| `[GROUP]:` | 그룹 소계 기준 컬럼 |
| `[DATEMASK]:` | 날짜 컬럼 포맷 지정 |
| `[CTR_NB_02/03/06]:` | **소수점 자리수 적용 컬럼** — 02=수량, 03=단가, 06=금액 |

### 파라미터 타입 `@H(...)` — 실제 사용 빈도순

```
DT(149)  DIV_CD(107)  ITEM_CD(94)  TR_CD(93)  DT_S(61)  DT_T(51)
PJT_CD(40)  ACCT_FG(28)  BASELOC_CD_0~2(51)  EMP_CD(22)  YEAR(22)
TR_FG(22)  DEPT_CD(14)  STRING(11)  MGM_CD_LP(10)  YM(9)
ITEMGRP_CD(9)  LOC_CD_0~2(25)  MGM_CD_LS(8)  NUMERIC(6)  MONTH(6)  PLN_CD(4)
```

`BASELOC_CD_0/1/2`, `LOC_CD_0/1/2`의 접미 숫자는 창고/공정/외주 구분 필터를 뜻합니다. `MGM_CD_LP`(구매자재 관리구분) / `MGM_CD_LS`(영업 관리구분)처럼 모듈별 관리구분도 전용 타입이 있습니다.

`CTR_NB_02/03/06`은 원가계산 SP(`USP_COT0010_CALC_COST_TAV`)에서 본 `@P_CTR_NB_03`(단가 소수점) / `@P_CTR_NB_06`(금액 소수점)과 **같은 `SYSCFG` 통제코드**입니다. `소수점6자리` 폴더의 `소숫점자리수추가.xls`가 이 설정을 바꾸는 자료입니다.

---

## 3. 스키마 세대 — **이 모음은 전부 ERP-X 스키마입니다**

가장 중요한 주의사항입니다. 폴더명이 "ERP X, ICUBE"지만, 실제 테이블 참조를 세어 보면 **iCUBE 전용 테이블은 단 한 건도 쓰이지 않습니다.**

| 테이블 | 이 모음의 참조 수 | 현행 iCUBE | 판정 |
|---|---:|---|---|
| `LWO` | **15** | `LWO_WF` | `LWO_WF` 참조 **0건** → 치환 필수 |
| `SBOM` | **3** | `SBOM_WF` | `SBOM_WF` 참조 **0건** → 치환 필수 |
| `SBOM_B` | **3** | `SBOM_WF_B` | `SBOM_WF_B` 참조 **0건** → 치환 필수 |
| `LINV_TAV` | **8** | `LINV_MVFIFO` / `CIV_*` | `LINV_MVFIFO`도 3건 병존 (과도기) |

반면 아래 테이블들은 **두 세대에서 이름이 같아 그대로 재사용 가능**합니다.

```
SITEM  STRADE  SPJT  SEMP  SDEPT  SBASELOC  SLOC  SITEMGRP  SYSCFG
LSO / LSO_D    LPO / LPO_D    LSTOCK / LSTOCK_D    LDELIVER / LDELIVER_D
LSTKMOVE / LSTKMOVE_D    LORCV_H    LMTL_USE    LINVTORY    LMPS
LADJUST / LADJUST_D    LWOPEN / LWOPEN_D    LCUSTM_UM    LSSTD_UM
```

→ **영업·구매·회계·인사·시스템 모듈 보고서는 대체로 그대로 동작**합니다.
→ **생산·기초(BOM) 모듈은 `LWO`/`SBOM`/`SBOM_B` 치환이 반드시 필요**합니다.

> 참고: 이전 대화에서 확인한 `LWOBOM`(NEO-X의 작업지시 소요자재)과 `LMTLISU`는 이 모음에서
> **한 번도 참조되지 않습니다.** 현행 iCUBE의 `LWO_REQ_WF`와의 대응 관계는 이 자료로는
> 확인되지 않으므로, 실 DB에서 직접 확인해야 합니다.

---

## 4. 테이블 교차색인 (상위 30)

| 테이블 | 참조 보고서 수 | 테이블 | 참조 수 |
|---|---:|---|---:|
| `SITEM` | 121 | `LORCV_H` | 12 |
| `STRADE` | 75 | `LSHIP_BILL` | 11 |
| `LDELIVER` | 36 | `LINVTORY` | 10 |
| `SBASELOC` | 35 | `LSTKMOVE_D` | 10 |
| `LDELIVER_D` | 32 | `LRCP` / `LRCP_D` | 17 |
| `SLOC` | 23 | `SITEMGRP` | 9 |
| **`VL_PJT`** | **22** | `LPLNNERCD` | 8 |
| `LSTKMOVE` | 20 | `LINV_TAV` | 8 |
| `SPJT` | 16 | `LSO_D` | 8 |
| `LWO` / `LPO` | 30 | `LCUSTM_UM` | 5 |
| `LSTOCK` / `LSTOCK_D` | 28 | `LMTL_USE` | 4 |
| `LCTRL_MGM_D` | 14 | `LMPS` | 3 |
| `SEMP` / `SDEPT` | 25 | `SBOM` / `SBOM_B` | 6 |

---

## 5. 이번 작업(원가/수율/MRP)에 즉시 반영할 발견

### 5-1. 생산자재출고 필터가 확정됐습니다 ★

원가 보고서 부록에서 "`LSTKMOVE.GRP_FG` 값 확인 필요"로 남겨뒀던 항목입니다.

`생산-프로젝트별 생산투입자재비.txt`:

```sql
WHERE H.IO_FG = '2' AND H.GRP_FG = '0'   -- 출고 + 생산
  AND H.PJT_CD = :[05]
```

→ **생산자재출고 = `IO_FG='2' AND GRP_FG='0'`**. 코퍼스 전체에서 `GRP_FG=0`(9건) / `IO_FG=2`(11건) 조합이 일관되게 쓰입니다.

### 5-1b. `EXPIRE_YN` — 앞선 MRP 쿼리의 버그를 잡았습니다 ★★

명세서 한글명이 "유효여부/마감여부"로 갈려 반대로 해석했으나, 코퍼스 8건 이상이 **전 테이블 공통 `'1'=유효/진행, `'0'`=만료/마감**임을 증언합니다.

| 근거 | 구문 |
|---|---|
| 수주진행현황 외 5건 | `LSO_D.EXPIRE_YN='1' THEN '진행' / ='0' THEN '마감'` |
| 주문총괄생산진행현황 | `PD.EXPIRE_YN='1' THEN '발주진행' / ='0' THEN '발주마감'` |
| 주문총괄생산진행현황 | `WF.EXPIRE_YN='1' THEN '생산진행' / ='0' THEN '생산마감'` |
| 테이블 DDL | `DEFAULT ('1')` |

→ `원자재수급총괄현황_MRP.sql`의 수주·발주 잔량 조건을 `<> '1'` → **`= '1'`로 수정 반영 완료**.

### 5-1c. `ACCT_FG`(계정구분) 완전 확정 ★

`주문총괄생산진행현황` 쿼리: `0.원재료 1.부재료 2.제품 4.반제품 5.상품` (3은 미사용). 원가계산 SP의 `ACCT_FG IN ('0','1','2','4','5','6')`이 "상품 포함 전 재고자산"임이 확인됩니다.

### 5-1d. 그 외 확정 코드 ★

| 컬럼 | 값 | 출처 |
|---|---|---|
| `LPUR_REQ.REQODR_FG` | 0.구매 / 1.생산 | 주문총괄생산진행현황 |
| `LWO_WF.DOC_ST` | 0.계획 / 1.확정 / 2.마감 | 동일 (API의 0.미처리/1.처리와 상이 → 실 DB 확인 필요) |

### 5-2. `SITEM.ODR_FG` 코드값 확정 ★

`재료비 명세서(BOM다단계지원-거래처단가)`:

```sql
CASE SI.ODR_FG WHEN '0' THEN '구매' WHEN '1' THEN '생산' ELSE ' ' END
```

→ **`ODR_FG` 0.구매 / 1.생산**. MRP에서 발주 대상(구매품)과 작업지시 대상(생산품)을 나누는 기준입니다. 현재 MRP 쿼리는 BOM 최하위(LEAF)로 판정하는데, `ODR_FG='0'`을 병행 조건으로 쓰면 더 정확합니다.

### 5-3. `LMPS`(주계획) — MRP 소요 원천 확장 ★

MRP 파일 부록 5에서 "판매계획/주계획 기반 소요는 미구현"으로 적었던 부분입니다.

```sql
CASE M.EXP_FG WHEN '0' THEN '판매계획' WHEN '1' THEN '수주기준'
              WHEN '2' THEN '모의계획' WHEN '3' THEN '생산계획' END
FROM LMPS M
-- MPS_DT(계획납기일), MPS_QT(계획수량), DIV_CD, ITEM_CD
```

→ `LMPS.EXP_FG` 코드까지 확정. MRP의 `#SO`에 `LMPS`를 `UNION`하면 MTO+MTS 혼합 소요가 됩니다.

### 5-4. `LCUSTM_UM`(거래처별 단가) + 단가 이력 메커니즘 ★

원가 보고서의 표준단가는 `SITEM.PURCH_UM`(전사 단일 구매단가)를 씁니다. 거래처별로 단가가 다른 사이트는 `LCUSTM_UM`(CO_CD + TR_CD + ITEM_CD → `PUR_UM`, `EXCH_CD`)이 정답입니다.

`CSP_LCUSTM_UM.SQL`이 밝히는 이력 규칙:

```
LCUSTM_UM.NO_SQ = 999  →  현재 유효 단가
LCUSTM_UM.NO_SQ < 999  →  과거 이력 (신규 등록 시 기존 999가 MAX+1로 밀려남)
```

→ 현재 단가 조회는 반드시 `NO_SQ = 999` 조건이 필요합니다. 이 규칙을 모르면 이력 전부가 중복 조인됩니다.

### 5-5. `VC_BOM` / `CX_PARTLIST` — BOM 다단계 전개 뷰

재귀 CTE로 직접 전개하는 대신 사이트에 이 뷰가 있으면 그대로 쓸 수 있습니다.

- `VC_BOM` : `ITEMPARENT_CD` → `ITEMCHILD_CD` 다단계 전개 + `REAL_QT`(누적 소요량)
- `CX_PARTLIST` : BOM 재료비 계산서용 PART LIST (3개 보고서가 사용)

우리 쿼리는 재귀 CTE로 자체 구현했으므로 이식성이 더 높습니다. 다만 **사이트에 이 뷰가 있으면 결과 대사용으로 쓰기 좋습니다.**

### 5-6. 재료비 단가 대안 — `LINV_TAV.ISU_UM`

`생산-프로젝트별 생산투입자재비` / `생산-공정별 투입자재비`가 쓰는 방식:

```sql
LEFT OUTER JOIN LINV_TAV U
  ON U.ITEM_CD = D.ITEM_CD
 AND SUBSTRING(H.MOVE_DT,1,6) >= U.SMM
 AND SUBSTRING(H.MOVE_DT,1,6) <= U.FMM
WHERE U.DIV_CD = H.DIV_CD
```

→ 재고평가(`LINV_TAV`) 기간(`SMM`~`FMM`)에 출고일을 매칭해 `ISU_UM`을 가져옵니다. 원가 보고서의 `@UM_BASE_FG='TAV'`(CIV_PUR_TAV)와 같은 개념의 구버전입니다. 원가모듈을 안 쓰는 사이트는 이쪽이 대안입니다.

### 5-7. 마이너스 재고 통제

```sql
INSERT INTO SYSCFG VALUES('1000','S','13','(-)마이너스재고통제여부',...,'여:1 부:0',...)
```

`SYSCFG` 모듈 `'S'` / 통제코드 `'13'`. `TI_LDELIVER_D` / `TU_LDELIVER_D` 트리거가 출고 시 재고를 검증합니다. **MRP의 현재고가 음수로 나오는 사이트는 이 설정이 `0`(허용)일 가능성이 높습니다** — 가용재고 계산의 신뢰도에 직결됩니다.

---

## 6. 그 외 주목할 자산

### 뷰 (사이트에 있으면 우선 사용)

| 뷰 | 참조 | 용도 |
|---|---:|---|
| `VL_PJT` | 22 | **프로젝트 수불 통합 뷰** — 프로젝트별 입고/출고/수불현황 전반 |
| `VL_PUMGM` | 3 | 구매의뢰/청구 현황 |
| `CX_PARTLIST` | 3 | BOM PART LIST 전개 |
| `VL_INVDIV` / `VL_INVLC` | 4 | 사업장/장소별 재고 |
| `VC_BOM` | 1 | BOM 다단계 전개 |
| `VL_PUR_RCV`, `VL_SLMGM`, `VL_MUSANG_SUM` | 3 | 구매입고 / 영업관리구분 / 무상 집계 |

`VL_PJT`가 22개 보고서에서 쓰인다는 건 **프로젝트 축 조회의 사실상 표준 소스**라는 뜻입니다. 우리 프로젝트별 원가 보고서도 이 뷰가 있으면 대사해 볼 가치가 있습니다.

### 바로 참고할 만한 보고서

| 파일 | 왜 |
|---|---|
| `구매자재관리/자재-MRP-주계획 현황.txt` | LMPS 기반 MRP 원천 |
| `구매자재관리/자재-청구건의진행현황.txt` | 청구→발주→입고 진행 추적 |
| `구매자재관리/자재-재고평가-생산자재비(재공 X, 선입선출).txt` | 선입선출 재고평가 |
| `구매자재관리/PROJECT 수불현황(PROJECT 별).txt` | 프로젝트 수불 (VL_PJT) |
| `생산관리/생산-프로젝트별 생산투입자재비.txt` | 프로젝트 재료비 (우리 원가 보고서의 구버전) |
| `생산관리/생산-실적집계-수량단가금액(표준원가).txt` | 실적 금액환산 |
| `생산관리/생산-재공관리-실적검사현황.txt` | 검사/불량 (수율 보고서 연계) |
| `기초MASTER정보/재료비 명세서(BOM다단계지원-거래처단가)` | BOM 다단계 + 거래처단가 + 환종 환산 |
| `기초MASTER정보/BATCH BOM(품목단가합계).txt` | SBOM_B 활용 |

---

## 7. 권고

1. **재사용 전 세대 확인**. 이 모음은 전부 ERP-X 스키마입니다. 생산·BOM 계열은 `LWO→LWO_WF`, `SBOM→SBOM_WF`, `SBOM_B→SBOM_WF_B` 치환이 필수입니다. 영업·구매·회계·인사는 테이블명이 같아 대체로 그대로 동작합니다.
2. **우리가 만든 3개 보고서를 UDR 포맷으로 감싸면 ERP 메뉴로 등록 가능**합니다. `:[00]`=회사코드 고정, 나머지 파라미터를 `@H(DIV_CD)` / `@H(DT)` / `@H(PJT_CD)` / `@H(ITEM_CD)`로 선언하면 됩니다. 다만 현재 쿼리는 임시테이블·동적SQL을 쓰므로 **단일 SELECT로 평탄화**해야 하고, 그 과정에서 성능이 나빠질 수 있습니다. 필요하시면 저장프로시저로 만들고 UDR에서는 `EXEC`만 호출하는 형태를 권합니다.
3. **먼저 반영할 3가지**: ① 생산자재출고 필터 `IO_FG='2' AND GRP_FG='0'` ② `ODR_FG` 0.구매/1.생산 ③ `LCUSTM_UM.NO_SQ=999` 규칙.

---

## 부록. 전체 카탈로그

### 기초MASTER정보 (11건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| BATCH BOM(인쇄용)-2.TXT | BATCH BOM (인쇄용)   담당: 이절로  작성:김경한 | SBOM_B, SITEM, STRADE |
| BATCH BOM(인쇄용).TXT | BATCH BOM (인쇄용) | SBOM_B, SITEM, STRADE |
| BATCH BOM(품목단가합계).txt | BATCH BOM (인쇄용)   담당: 이절로  작성:김경한 | SBOM_B, SITEM, STRADE |
| BOM(품목단가합계).txt | BOM  출력(인쇄용)   담당: 이절로  작성:김경한 | SBOM, SITEM, STRADE |
| 기초-사원별-거래처보유.txt | 22.기초정보관리-사원별거래처보유현황 | STRADE |
| 기초-제공예제.txt | 04.기초재공 출력물 입니다 (2002/01/09) | LWOPEN, LWOPEN_D, SITEM |
| 기초-표준원가 리스트.txt | 20.기초정보-표준원가 리스트 | LSSTD_UM |
| 기초-품목관리 계정별구분.txt | 21.기초정보-품목관리대장 (계정구분별) | SITEM |
| 기초-품목관리대장.txt | 17. 기초정보-품목관리대장 | SITEM |
| 재료비 명세서(BOM다단계지원-거래처단가)-디지텍.txt | 재료비 계산서 | LCUSTM_UM, SITEM, STRADE, VC_BOM |
| 재료비명세서(BOM구매단가).txt |  | SBOM, SITEM, STRADE |

### 생산관리 (30건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| [실적관리]생산일보(프로젝트추가).txt |  | LORCV_H, LWO, SBASELOC, SITEM, SLOC, SPJT |
| [작업지시관리]작업실적현황(품목군별).txt |  | LORCV_H, LWO, SBASELOC, SITEM, SITEMGRP |
| [기초정보관리]다단계BOM.txt |  | SBOM |
| [실적관리]실적별사용자재보고현황.txt |  | LINV_TAV, LMTL_USE, LMTL_USEWO, LWO, SBASELOC, SITEM |
| [임가공관리]고객별사급자재입고현황.txt |  | SITEM, SITEMGRP, STRADE, VL_MUSANG_SUM |
| BOM대비재료비(VIEW작성).sql |  | CX_PARTLIST, SITEM |
| [기초정보관리]BOM 재료비계산서(금액표시).txt |  | CX_PARTLIST, K2H_BOM, SITEM, STRADE |
| [외주관리]외주발주대비실적미납현황.txt |  | LORCV_H, LWO, SBASELOC, SITEM, SLOC |
| [기초정보관리]BOM 재료비계산서(재고평가금액기준).txt |  | CX_PARTLIST, LINV_TAV, SITEM, STRADE |
| 생산-공정별 투입자재비.txt | 공정별 투입자재비 | LINV_TAV, LSTKMOVE, LSTKMOVE_D, SITEM |
| 생산-기간공정별 작업량.txt | 대전지점-기간별공정별 작업량집계 | LROUT_HST, LWO, SBASELOC, SITEM, SLOC |
| 생산-기간별공정별작업량집계.txt |  | LORCV_H, SITEM |
| 생산-불량보고예제.txt | 02.간단한 불량보고서의 예제 입니다 (2001/12/14) | LORCV_H |
| 생산-생산일보.txt | 생산일보  담당:박상곤  작성 : 김경한 | LSTKMOVE, SBASELOC, SITEM, SLOC |
| 생산-실적관리-사용자재 모품목별집계.txt | 생산-실적관리-사용자재 모품목별 집계 | LMTL_USE, LWO, SBASELOC, SITEM, SLOC |
| 생산-실적집계-수량단가금액 표준원가.txt | 생산-실적집계-수량단가금액(표준원가) | LORCV_H, LWO, SBASELOC, SITEM |
| 생산-실적집계-수량단가금액(표준원가).txt | 생산-실적집계-수량단가금액(표준원가) | LORCV_H, LWO, SBASELOC, SITEM |
| 생산-실적집계-수량단가금액.txt | 생산-실적집계-수량단가금액(표준원가) | LORCV_H, LWO, SBASELOC, SITEM |
| 생산-외주관리 마감현황.txt | 생산-외주관리-외주마감현황 (단순양식) | LOCLS_D, LOCLS_H, STRADE |
| 생산-외주관리-외주마감현황 (단순양식).txt | 생산-외주관리-외주마감현황 (단순양식) | LOCLS_D, LOCLS_H, STRADE |
| 생산-일작별생산계획현황.txt | 일자별생산계획현황 | LMPS, SITEM |
| 생산-작업량집계 실적포함.txt | 대전지점-작업량집계-다시수정-실적포함 | LORCV_H, LROUT_HST, LWO, SBASELOC, SITEM, SLOC |
| 생산-작업지시예제.txt | 06.작업지시 일자별 조회 (2002/01/11) | LCTRL_MGM_D, LWO, SBASELOC, SITEM |
| 생산-재공관리-기초재공(외주포함).txt | 생산-재공관리-기초재공(외주포함) | LWOPEN, LWOPEN_D, SBASELOC, SITEM, SLOC |
| 생산-재공관리-실적검사현황.txt | 12.생산-재공관리-실적검사현황 | LQC_INSP, SITEM |
| 생산-재공관리-지시검사현황.txt | 13.생산-재공관리-지시검사현황 | LQC_INSPWO, SITEM |
| 생산-재공품현황.txt | 대전지점--재공품현황 | LORCV_H, LWO |
| 생산-품목별생산계획현황.txt | 품목별생산계획현황 | LMPS, SITEM |
| 생산-프로젝트별 공정투입현황.txt | 프로젝트별 생산투입자재비 | LINV_TAV, LSTKMOVE, LSTKMOVE_D, SITEM |
| 생산-프로젝트별 생산투입자재비.txt | 프로젝트별 생산투입자재비 | LINV_TAV, LSTKMOVE, LSTKMOVE_D, SITEM |

### 구매자재관리 (62건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| [발주관리]프로잭트별 발주현황.txt |  | LPO, LPO_D, SITEM, SPJT, STRADE |
| [발주관리]프로잭트별발주대비입고미납현황.txt |  | LPO_D, LSTOCK, SITEM, SPJT, STRADE |
| [발주관리]프로잭트별발주 미납현황.txt |  | LPO, LPO_D, SITEM, SPJT, STRADE, VL_PUR_RCV |
| [입고관리]입고현황.txt |  | LSTOCK, LSTOCK_D, SBASELOC, SITEM, STRADE, VL_PJT |
| [재고수불관리]재고이동현황.TXT |  | LSTKMOVE, LSTKMOVE_D, SBASELOC, SITEM, SLOC, SPJT |
| [재고수불관리]창고별재고이동금액.txt |  | LSTKMOVE, SBASELOC, SITEM |
| [재고수불관리]일별결품현황.TXT |  | LINVTORY, SBASELOC, SITEM, STRADE |
| [재고수불관리]현재고현황.txt |  | LINVTORY, SBASELOC, SITEM |
| [입고관리]국내매입미마감금액현황.txt |  | LCTRL_MGM_D, LPURCLS_D, LSTOCK, SITEM, STRADE |
| [재고수불관리]현재고현황(품목군별).txt |  | LINVTORY, SBASELOC, SITEM, SITEMGRP |
| [MRP]청구등록의뢰현황.txt |  | LCTRL_MGM_D, LPUR_REQ, SDEPT, SEMP, SITEM, SPJT |
| [입고관리]입고현황(거래처별합계만출력).txt |  | LSTOCK, LSTOCK_D, SITEM, STRADE, VL_PJT |
| [입고관리]입고현황(일자별합계만출력).txt |  | LSTOCK, LSTOCK_D, SITEM, STRADE, VL_PJT |
| [입고관리]입고현황(품목별합계만출력).txt |  | LSTOCK, LSTOCK_D, SITEM, SITEMGRP, STRADE, VL_PJT |
| [재고수불관리]생산외주자재출고현황.TXT |  | LINV_TAV, LSTKMOVE, LSTKMOVE_D, SITEM |
| [발주입고관리]프로젝트별매입현황표.txt |  | LPO, LPO_D, LPURCLS_D, LSTOCK, LSTOCK_D, SPJT |
| [재고수불관리]생산자재출고현황(프로젝트별).TXT |  | LSTKMOVE, LSTKMOVE_D, SBASELOC, SITEM, SLOC, VL_PJT |
| [재고수불관리]외주자재출고현황(프로젝트별).TXT |  | LSTKMOVE, LSTKMOVE_D, SBASELOC, SITEM, SLOC, VL_PJT |
| [재고수불관리]적정재고리스트.TXT |  | LINVTORY, SBASELOC, SITEM, STRADE |
| [재고평가]품목군별재고평가현황.txt |  | LINV_TAV, SITEM, SITEMGRP |
| [재고수불현황]프로잭트수불부(재고평가금액표시).txt |  | LINVTORY, LINV_TAV, SITEM, SPJT, VL_PJT |
| [재고수불현황]프로잭트수불부(표준원가및구매단가적용).txt |  | LDELIVER_D, LINVTORY, LSTOCK_D, SITEM, SPJT, VL_PJT |
| PROJECT 별 입고현황-코닉.TXT | PROJECT별 입고금액 현황 담당자:이절로 업체명: 코닉시스템  작성자 | LSTOCK, LSTOCK_D, SITEM, STRADE, VL_PJT |
| PROJECT 별 출고현황-코닉.TXT | PROJECT별 출고금액 현황 담당자:이절로 업체명: 코닉시스템  작성자 | LDELIVER, LDELIVER_D, SITEM, STRADE, VL_PJT |
| PROJECT 수불현황(PROJECT 별).txt | PROJECT 수불 현황(PROJECT별) | LINVTORY, SBASELOC, SITEM, SLOC, VL_PJT |
| PROJECT 수불현황(전체).txt | PROJECT 수불 현황 | LINVTORY, SBASELOC, SITEM, SLOC, VL_PJT |
| lot_no 사용시 매입원가.txt |  | LDELIVER, LSHIP_BILL, LSTOCK, SITEM, STRADE |
| lot_no별 제품별사용자재.txt |  | LMTL_USE, LWO, SBASELOC, SITEM, SLOC |
| 구매-고객별 단가등록.txt | 고객별 단가등록(구매단가) | LCUSTM_UM |
| 구매-국내(국외)발주대비입고현황.txt |  | LPO, LPO_D, LSTOCK, LSTOCK_D, SITEM, STRADE |
| 구매-국내(국외)입고현황.txt |  | LSTOCK, LSTOCK_D, SITEM, STRADE |
| 구매-발주대비 입고현황.txt | 발주대비입고현황(담당사원별) for 이직스 | LPO, LPO_D, LSTOCK_D |
| 구매요청의뢰.TXT | 구매요청의뢰 | LCTRL_MGM, LCTRL_MGM_D, LPUR_REQ, LPUR_REQ_D, SEMP, SITEM |
| 구매의뢰요청현황-수정2.txt | 구매요청의뢰현황 | LCTRL_MGM_D, LPO_D, LPUR_REQ, SDEPT, SEMP, SITEM |
| 구매의뢰요청현황.txt | 구매요청의뢰현황 | LCTRL_MGM_D, LPO_D, LPUR_REQ, SDEPT, SEMP, SITEM |
| 미수채권현황(출고기준 -담당자별)-신일CPS.txt | 미수채권현황(출고기준 -담당자별)  담당:이절로  작성 : 김경한 | LCR_ADJUST, LDELIVER, LDELIVER_D, LOPN_CRISU, LPLNNERCD, LRCP |
| 물품구매요청발주서.txt |  | LPO, LPO_D, SDIV, SEMP, SITEM, SPJT |
| 외주실적현황.txt | 외주실적  담당자:임황용 작성자:김경한 | LORCV_H, LWO, SITEM, SLOC |
| 외주처관리현황(내수)-실버크리너.TXT | 외주처현황 담당:이절로 업체:실버크리너  날짜: 2002년 8월 26일 | LOUTCST, LSTKMOVE, LSTKMOVE_D, SBASELOC, SITEM, SLOC |
| 외주처관리현황(수출)-실버크리너.TXT | 외주처현황 담당:이절로 업체:실버크리너  날짜: 2002년 8월 26일 | LOUTCST, LSTKMOVE, LSTKMOVE_D, SBASELOC, SITEM, SLOC |
| 자재-MRP-주계획 현황.txt | 19.자재-MRP-주계획 현황 | LMPS |
| 자재-수입검사의 대상이되는거래처.txt | 수입검사의 대상이 되는 거래처(불량품 제공업체) | LBAD, LQC_INSPM, LQC_INSPM_D, LSTOCK, LSTOCK_D, SITEM |
| 자재-영문발주서.txt |  | LPO, SITEM, STRADE |
| 자재-자재수불현황-생산자재출고현황.txt |  | LSTKMOVE, SBASELOC, SITEM, SLOC |
| 자재-자재수불현황재고금액.txt |  | LINVTORY |
| 자재-재고수불-생산자재출고.txt | 자재-재고수불현황-생산자재출고현황(정렬수정) | LSTKMOVE, SBASELOC, SITEM, SLOC |
| 자재-재고수불-자재 제품별출고현황.txt | 자재-재고수불현황-자재 제품별 출고 현황 | LSTKMOVE, SBASELOC, SITEM, SLOC |
| 자재-재고수불관리-생산출고현황(모품목별).txt | 15.자재-재고수불관리-생산출고현황(모품목별) | LSTKMOVE, SBASELOC, SITEM, SLOC |
| 자재-재고수불관리-외주입고현황(생산없을때).txt | 14.자재-재고수불관리-외주입고현황(생산없을때) | LSTKMOVE, SBASELOC, SITEM, SLOC |
| 자재-재고수불관리-외주출고현황.txt | 16.자재-재고수불관리-외주출고현황 | LSTKMOVE, SBASELOC, SITEM, SLOC |
| 자재-재고이동표준원가.txt | 재고이동금액 - 표준원가로 | LSTKMOVE, SBASELOC, SITEM |
| 자재-재고이동현황금액.txt |  | LSTKMOVE, SBASELOC, SITEM |
| 자재-재고평가-생산자재비(재공 X, 선입선출).txt | 자재-재고평가-생산자재비(재공 X, 선입선출) | LINV_MVFIFO, LMTL_USE, LORCV_H, LWO |
| 자재-청구건의진행현황.txt | 청구건의 진행현황(부서별,사원별) | LPO, LPO_D, LPUR_REQ, LPUR_REQ_D, LSTOCK_D |
| 자재-청구등록현황(관리구분별조회).txt | 청구등록현황(관리구분별조회) | LCTRL_MGM_D, LPUR_REQ, LPUR_REQ_D |
| 프로젝트별출고금액현황(재고평가_선입선출_재고조정+생산자재출고처리).txt |  | LADJUST, LADJUST_D, LINV_MVFIFO, LSTKMOVE, LSTKMOVE_D, SITEM |
| 프로젝트별출고금액현황(재고평가_선입선출_재고조정_출고조정).txt |  | LADJUST, LADJUST_D, LINV_MVFIFO, SITEM, VL_PJT |
| 코닉-영문발주서.txt | 영문발주서  업체명:코닉  작성 : 이절로 | LPO, SITEM, STRADE |
| 한광자재-영문발주서.txt | 영문발주서  업체명:한광  작성 : 개발실 | LPO, SITEM, STRADE |
| 현재고현황(구매단가기준).txt | 현재고현황(구매단가기준) 작성 : 김경한 업체: XXX | SITEM, VL_INVDIV |
| 현재고현황(판매단가기준).txt | 현재고현황(판매단가기준) 작성 : 김경한 업체: XXX | SITEM, VL_INVDIV |
| 현재고현황-신한.txt |  | LINVTORY, SITEM |

### 영업관리 (51건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| [가출고위탁관리]위탁관리수불현황(일자별).txt |  | LWESHIP, LWESHIP_D, LWETAK, LWETAK_D |
| [출고관리]출고현황(거래처별).txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE |
| [출고관리]매출미마감금액현황.txt |  | LCTRL_MGM_D, LDELIVER, LSALECLS_D, SITEM, STRADE |
| [출고관리]출고현황(물류담당자-지역별).txt |  | K2H_EMP, LCTRL_MGM_D, LDELIVER, LDELIVER_D, LPLNNERCD, LTRADEMGM |
| 수주대비출고현황(프로젝트기준).txt |  | LDELIVER, LSHIP_BILL, LSO_D, SITEM, SPJT, STRADE |
| [출고관리]매출순위표.txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE |
| [출고관리]출고현황(거래처별합계만출력).txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE, VL_PJT |
| [출고관리]출고현황(출고구분별합계만출력).txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE, VL_PJT, VL_SLMGM |
| [출고관리]출고현황(일자별합계만출력).txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE, VL_PJT |
| [출고관리]출고현황(품목별합계만출력).txt |  | LDELIVER, LDELIVER_D, SITEM, SITEMGRP, STRADE, VL_PJT |
| [출고관리]매출미마감현황(고객별).txt |  | LCTRL_MGM_D, LDELIVER, LSALECLS_D, SITEM, SPJT, STRADE |
| [출고관리]출고현황(고객납품처별).txt |  | LDELIVER, LDELIVER_D, LSHIP_BILL, STRADE |
| [출고관리]출고대비 수금현황.txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE, VL_PJT |
| [출고관리]매입매출비교분석표(그래프지원).txt |  | LDELIVER, LDELIVER_D, LEST, LEST_D, LPO, LPO_D |
| [출고관리]매입매출비교분석표.txt |  | LDELIVER, LDELIVER_D, LEST, LEST_D, LPO, LPO_D |
| [수금관리]미수채권상세현황(출고기준).txt |  | LDELIVER, LDELIVER_D, LRCP, LRCPFG, LRCP_D, SITEM |
| [수출관리]ORDER SHEET.txt |  | LPO, SDEPT, SEMP, SITEM, STRADE |
| [출고관리]거래내역서.txt |  | LCTRL_MGM_D, LDELIVER, LDELIVER_D, LPLNNERCD, LSHIP_BILL, SITEM |
| 거래명세서(미수채권포함).TXT | 거래명세서 (미수채권포함) 담당: 박상곤   업체명:금정기업 작성 : 김 | LCR_ADJUST, LDELIVER, LOPN_CRISU, LRCP, LSHIP_BILL, SITEM |
| 거래처별,품목군별 판매추이.txt |  | LEBL, LEBL_D, LSALECLS, LSALECLS_D, SITEM, SITEMGRP |
| 공간세라믹거래명세표.txt |  | LDELIVER, LDELIVER_D, SDIV, SITEM, STRADE |
| 납품처별현황.txt |  | LDELIVER, LDELIVER_D, LSHIP_BILL, STRADE |
| 미수채권 (출고기준)-담당자별.txt | 미수채권현황(출고기준 -담당자별)  담당:박상곤  작성 : 김경한 | LCR_ADJUST, LDELIVER, LDELIVER_D, LOPN_CRISU, LPLNNERCD, LRCP |
| 영업-견적대비 수주현황.txt | 견적대비수주현황(담당사원별) for 이직스 | LEST, LEST_D, LSO_D |
| 영업-계획관리-영업계획(고객품목군).txt | 영업-계획관리-영업계획(고객품목군) | LFORECST_SLS, LFORECST_SLS_D, LPLNNERCD, SDEPT, SITEMGRP, STRADE |
| 영업-계획관리-영업계획(고객품목별).txt | 영업-계획관리-영업계획(고객품목별) | LFORECST_SLS, LFORECST_SLS_ITEM, LPLNNERCD, SDEPT, SITEM, STRADE |
| 영업-계획관리-영업계획대비실적(고객).txt | 영업-계획관리-영업계획대비실적(고객) | LDELIVER, LDELIVER_D, LFORECST_SLS, LRCP, LRCP_D, STRADE |
| 영업-계획관리-영업계획대비실적(담당별).txt | 영업-계획관리-영업계획대비실적(담당별) | LDELIVER, LDELIVER_D, LFORECST_SLS, LPLNNERCD, LRCP, LRCP_D |
| 영업-계획관리-영업계획대비실적(부서별).txt | 영업-계획관리-영업계획대비실적(부서별) | LDELIVER, LDELIVER_D, LFORECST_SLS, LRCP, LRCP_D, SDEPT |
| 영업-계획관리-월별영업계획(고객).txt | 영업-계획관리-월별 영업계획(고객) | LFORECST_SLS, LPLNNERCD, SDEPT, STRADE |
| 영업-고객별 단가등록 판매단가.txt | 고객별 단가등록(판매단가) | LCUSTM_UM |
| 영업-국내(국외)판매현황.txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE |
| 영업-기초 품목단가등록 구매가.txt | 영업관리/기초정보관리/품목단가등록_구매단가 | SITEM |
| 영업-기초 품목단가등록 판매가.txt | 영업관리/기초정보관리/품목단가등록_판매단가 | SITEM |
| 영업-대여예제.txt | 07.영업-대여위탁관리-일별위탁재고 현황 | LCTRL_MGM_D, LWESHIP, LWETAK |
| 영업-대여위탁관리-일별위탁재고현황(소수점처리).txt | 11.영업-대여위탁관리-일별위탁재고현황(소수점처리) | LCTRL_MGM_D, LWESHIP, LWETAK |
| 영업-대여위탁관리-일별입출고현황(누계).txt | 18.영업-대여위탁관리-일별입출고현황(누계) | LCTRL_MGM_D, LWESHIP, LWETAK |
| 영업-수주납품수주미납.txt | 10.영업-수주관리-납품처별수주미납현황 | LDELIVER_D, LSHIP_BILL, LSO_D, SITEM, STRADE |
| 영업-수주납품처별.txt | 09.영업-수주관리-납품처별 수주현황 (2002/01/12) | LSHIP_BILL, LSO, LSO_D |
| 영업-연간판매계획현황(품목,월별).txt | 연간판매계획현황 (품목/월별) | LFORECST, LFORECST_D, SITEM |
| 영업-주문등록예제.txt | 05.주문 등록한 주문 현황 입니다 (2002/01/11) | LJUMUN, LJUMUN_D, LSHIP_BILL, SITEM, STRADE |
| 영업-출고처리-고객별납품현황(출고기간,고객).txt | 영업관리출고처리_고객별납품현황(출고기간,고객)_2002/01/26 | LDELIVER, LDELIVER_D, LSHIP_BILL, STRADE |
| 영업-출고처리-납품처별출고현황(납품처,기간,거래처).txt | 영업관리출고처리_납품처별출고현황(납품처,기간,거래처) | LDELIVER, LDELIVER_D, LSHIP_BILL, STRADE |
| 영업-판매일보예제.txt | 01.간단한 판매일보의 예제 입니다.. (2001년12월1일) | LDELIVER |
| 출고현황(고객별)-청계파마.txt | 출고현황(고객별)      청계파마 : 이절로 | LDELIVER, LDELIVER_D, SITEM, STRADE |
| 출고현황(고객별)-청계파마2.txt | 출고현황(고객별)      청계파마 : 이절로 | LDELIVER, LDELIVER_D, SITEM, STRADE |
| 출고현황(기본형식).txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE |
| 출고현황(주소,전화번호).txt | 출고현황(고객별)      청계파마 : 이절로 | LDELIVER, LDELIVER_D, SITEM, STRADE |
| 출고현황(환종별-원화금액).txt |  | LDELIVER, LDELIVER_D, SITEM, STRADE |
| 코닉-영문발주서.txt | 영문발주서  업체명:코닉  작성 : 이절로 | LPO, SITEM, STRADE |
| 영문발주서.txt |  | LPO, SITEM, STRADE |

### 단가history관리 (4건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| CSP_LCUSTM_UM.SQL |  | LCUSTM_UM, SCO |
| 거래처단가HISTORY.TXT |  | LCUSTM_UM, SYSCFG |
| 사용자정의입력예제.txt |  | CUR_TD_LDELIVER_TEST_2, CUR_TI_LDELIVER_TEST_2, CUR_TU_LDELIVER_TEST_2, DELETED, FAILED, INSERTED |
| 유지보수관리.txt |  | SEMP, STRADE |

### 마이너스재고통제 (2건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| TI_LDELIVER_D.sql |  | CUR_TI_LDELIVER_D, INSERTED, LCTRL_MTL, LDELIVER, LSAL_REQ, LSO |
| TU_LDELIVER_D.sql |  | CUR_TU_LDELIVER_D, DELETED, LCTRL_MTL, LDELIVER_D, LEBL_D, LSALECLS |

### A_회계 관리_UDR (2건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| [자금관리]지급어음명세현황.txt |  | ABILLDEB, ACASHCD, STRADE |
| [전표장부관리]전표출력(고객사용전표).txt |  | ADOCUD, ADOCUH, SACCT, SACCTGR, SCO, SCTRL_D |

### H_인사 관리_UDR (2건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| 급상여이체현황.txt |  | HPHPYFQ, SBANK, SCTRL_D, SEMP, VH_PAYRPT |
| [근태관리]개인별출결현황(월별기준).txt |  | HTOPACR, SCTRL_D, SEMP |

### S_시스템관리_UDR (3건)

| 파일 | 제목 | 주요 테이블 |
|---|---|---|
| [시스템관리]부서담당별거래처현황.txt |  | SDEPT, SEMP, STRADE |
| [시스템관리]사용자별 권한현황.txt |  | SDEPT, SECURITY, SEMP, SMENU |
| [시스템관리] 사용자권한설정현황.txt |  | SDEPT, SECURITY, SEMP, SMENU |

