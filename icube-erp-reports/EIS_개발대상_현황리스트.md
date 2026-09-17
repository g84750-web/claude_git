# iCUBE EIS 개발대상 현황 리스트

**대상 모듈**: 영업 · 구매자재 · 생산 · 원가
> **재고·수불 관련 항목(P-03/P-04/P-06/P-08/M-04/M-05/C-06)은 [재고수불_뷰테이블_레퍼런스.md](재고수불_뷰테이블_레퍼런스.md) 를 함께 보십시오.** 제공 뷰(`VL_INVLC`, `L_INVSUM_LC`, `VL_SO_ISU`, `VL_LWO_REQ_WF` 등)를 쓰면 원장 직접집계보다 훨씬 빠르고 정확합니다.

**근거**: iCUBE 테이블명세서 / API 연동규약서 / 원가계산 SP(`USP_COT0010_CALC_COST_TAV`) / BOM역전개 SP / 사용자정의보고서(UDR) 167건 / 임미정 실무 쿼리 모음 / NEO-X 레이아웃

---

## 0. 먼저 — 코드값 정정 및 확정 (모든 개발의 전제)

UDR 코퍼스 교차검증으로 **이전 산출물의 오류 1건을 포함해** 아래가 확정됐습니다.

### 0-1. `EXPIRE_YN` — 한글명에 속으면 안 됩니다 ⚠️

명세서 한글명이 테이블마다 "유효여부 / 마감여부"로 갈리지만 **실제 코드값은 전 테이블 공통**입니다.

```
EXPIRE_YN = '1'  →  유효 / 진행 / 미마감      ← 정상 데이터 조건
EXPIRE_YN = '0'  →  만료 / 마감
```

| 근거 쿼리 | 구문 |
|---|---|
| 수주진행현황 외 5건 | `LSO_D.EXPIRE_YN='1' THEN '진행' / ='0' THEN '마감'` |
| 주문총괄생산진행현황 | `PD.EXPIRE_YN='1' THEN '발주진행' / ='0' THEN '발주마감'` |
| 주문총괄생산진행현황 | `WF.EXPIRE_YN='1' THEN '생산진행' / ='0' THEN '생산마감'` |
| 테이블 DDL | `DEFAULT ('1')` |

> **[수정 완료]** 앞서 전달한 `원자재수급총괄현황_MRP.sql`에서 수주·발주 잔량을 `EXPIRE_YN <> '1'`로 걸었습니다. **정반대라 진행 중 수주가 전부 빠지는 버그**였습니다. `= '1'`로 고쳐 반영했습니다.

### 0-2. `ACCT_FG` (계정구분) — 완전 확정

```
0.원재료   1.부재료   2.제품   4.반제품   5.상품   (6.저장품/기타)
```

원가계산 SP의 `ACCT_FG IN ('0','1','2','4','5','6')`이 "상품 포함 전 재고자산"이라는 뜻임이 확인됩니다. 3은 미사용.

### 0-3. 그 외 확정 코드

| 컬럼 | 값 | 출처 |
|---|---|---|
| `SITEM.ODR_FG` (조달구분) | 0.구매 / 1.생산 | 재료비명세서 |
| `LPUR_REQ.REQODR_FG` (청구구분) | 0.구매 / 1.생산 | 주문총괄생산진행현황 |
| `LWO_WF.DOC_ST` (지시상태) | 0.계획 / 1.확정 / 2.마감 | 주문총괄생산진행현황 |
| `LWO_WF.WOC_FG` | 0.생산지시 2.임가공 4.외주발주 5.작업지시 | API + UDR |
| `LSTKMOVE` 생산자재출고 | `IO_FG='2' AND GRP_FG='0'` | 프로젝트별 생산투입자재비 |
| `LCUSTM_UM.NO_SQ` | 999=현재단가, <999=과거이력 | `CSP_LCUSTM_UM` |

> `DOC_ST`는 API 규약서(0.미처리/1.처리)와 UDR(0.계획/1.확정/2.마감)이 다릅니다. **버전·사이트 차이이므로 실 DB 분포 확인이 필수**입니다.

---

## 1. `LX_BOM_BACK_*` 분석 — 사전집계(Materialized) 패턴

첨부하신 2개 DDL은 **BOM 역전개 결과를 미리 계산해 적재하는 캐시 테이블**입니다.

### `LX_BOM_BACK_EXPANSION` — 역전개 전개 결과

| 컬럼 | 의미 |
|---|---|
| `TYPE_NB` | 전개 유형/회차 (조회 조건 세트 구분자) |
| `LEVEL_NB` | 전개 레벨 |
| `PITEM_CD` / `CITEM_CD` | 모품목 / 자품목 |
| `REAL_QT` | 누적 소요량 |

### `LX_BOM_BACK_INVTORY` — 역전개 × 재고수불 결합

| 컬럼 | 의미 |
|---|---|
| `LEVEL_NB`, `ITEM_CD`, `REAL_QT` | 전개 결과 |
| `WH_CD`, `LC_CD` | 창고 / 장소 |
| `IOPEN_QT` | 기초 |
| `IRCV_QT` | 입고 |
| **`PISU_QT`** | **생산출고** (`GRP_FG='0'`) |
| **`SISU_QT`** | **매출출고** (`GRP_FG='3'`) |
| **`EISU_QT`** | **기타출고** (`GRP_FG='6'` 조정·대체) |

출고를 **용도별 3분할**한 것이 핵심입니다. 단일 `IISU_QT`로는 "이 자재가 생산에 쓰였나, 팔렸나, 조정됐나"를 구분할 수 없습니다.

### 이 패턴이 주는 설계 지침 ★

재귀 CTE로 매번 BOM을 전개하면 품목 수천 개 × 레벨 10단계에서 **초 단위가 아니라 분 단위**가 나옵니다. EIS(대시보드)는 응답속도가 생명이므로:

```
[야간 배치]  BOM 전개 + 수불 집계  →  LX_* 테이블 적재
[주간 조회]  LX_* 테이블만 SELECT  →  1초 이내 응답
```

- 명명 규칙 `LX_` = iCUBE 집계 테이블 관례 (`LX_LINVTORY_LS`, `LX_PJT_W`, `LX_WH_W` 등과 동일)
- `TYPE_NB`로 여러 조회 조건 세트를 한 테이블에 공존시킴
- **본 문서의 모든 "실시간" 현황은 이 패턴을 전제**로 설계했습니다 (E-04 참조)

---

## 2. EIS 현황 리스트 — 전체 32건

난이도: ★=단순조회 ★★=다중조인/집계 ★★★=재귀/배치/복합계산

| ID | 현황명 | 모듈 | 유형 | 난이도 | 상태 |
|---|---|---|---|:---:|---|
| **S-01** | 수주 진행 총괄 현황 | 영업 | 진행현황 | ★★★ | 신규 |
| **S-02** | 주문 미납 현황 (납기경과 구간) | 영업 | 진행현황 | ★★ | 신규 |
| **S-03** | 납기 준수율 KPI | 영업 | KPI | ★★ | 신규 |
| **S-04** | 매출·수금 KPI 대시보드 | 영업 | KPI | ★★ | 신규 |
| **S-05** | 담당자별 매출이익 현황 | 영업 | KPI | ★★★ | 신규 |
| **S-06** | 미수채권·여신한도 현황 | 영업 | 진행현황 | ★★ | 신규 |
| **S-07** | 영업계획 대비 실적 | 영업 | KPI | ★★ | 신규 |
| **S-08** | 거래처·품목군별 판매추이 | 영업 | 추이 | ★ | 신규 |
| **P-01** | 청구→발주→입고 진행현황 | 구매자재 | 진행현황 | ★★ | 신규 |
| **P-02** | 발주 납기 준수/지연 현황 | 구매자재 | KPI | ★★ | 신규 |
| **P-03** | 실시간 재고 추적 (창고·장소·LOT) | 구매자재 | 실시간 | ★★★ | 신규 |
| **P-04** | 재고자산 수불부 (용도별 출고분할) | 구매자재 | 진행현황 | ★★★ | 신규 |
| **P-05** | 안전재고 미달 / 과잉재고 알람 | 구매자재 | KPI | ★★ | 신규 |
| **P-06** | 재고회전율·체화재고(ABC) | 구매자재 | KPI | ★★★ | 신규 |
| **P-07** | 매입단가 추이·거래처 단가비교 | 구매자재 | 추이 | ★★ | 신규 |
| **P-08** | 원자재 수급 총괄 (MRP) | 구매자재 | 실시간 | ★★★ | **개발완료** |
| **M-01** | 작업지시 진행 현황 | 생산 | 진행현황 | ★★ | 신규 |
| **M-02** | 생산 일보·월보 | 생산 | KPI | ★★ | 신규 |
| **M-03** | 생산지시별 작업수율 현황 | 생산 | KPI | ★★★ | **개발완료** |
| **M-04** | 공정별 재공 실시간 현황 | 생산 | 실시간 | ★★★ | 신규 |
| **M-05** | 자재 청구/출고/사용 대비 현황 | 생산 | 진행현황 | ★★ | 신규 |
| **M-06** | 불량 Pareto·품질 KPI | 생산 | KPI | ★★ | 신규 |
| **M-07** | 외주 진행·마감 현황 | 생산 | 진행현황 | ★★ | 신규 |
| **M-08** | 설비·작업팀별 생산성 | 생산 | KPI | ★★ | 신규 |
| **C-01** | 프로젝트별 생산원가 | 원가 | KPI | ★★★ | **개발완료** |
| **C-02** | 당기 재료비 분석 | 원가 | KPI | ★★ | 신규 |
| **C-03** | 제품별 원가 구성 (재료/노무/경비) | 원가 | KPI | ★★★ | 신규 |
| **C-04** | 표준원가 대비 실제원가 차이분석 | 원가 | KPI | ★★★ | 신규 |
| **C-05** | 매출이익 분석 (품목·거래처·담당) | 원가 | KPI | ★★★ | 신규 |
| **C-06** | 재고평가 현황 | 원가 | 진행현황 | ★★ | 신규 |
| **E-01** | 경영 KPI 통합 대시보드 | 공통 | 대시보드 | ★★★ | 신규 |
| **E-02** | 수주→출하 리드타임 분석 | 공통 | KPI | ★★★ | 신규 |

---

## 3. 상세 명세

### S-01. 수주 진행 총괄 현황 ★★★

**목적** — 수주 1건이 청구·발주·생산·입고·출고·마감 중 **어느 단계에 멈춰 있는지** 한 줄로 보여준다. 영업이 "언제 나가냐"는 문의에 ERP 화면 5개를 돌지 않게 하는 것이 목적.

**대상** — 영업담당, 생산관리, 경영층

**소스 체인**
```
LSO / LSO_D  (수주)
  → LPUR_REQ / LPUR_REQ_D  (청구)         REQ_NB + REQ_SQ + ITEM_CD
  → [REQODR_FG='0'] LPO / LPO_D (발주)    → LSTOCK_D (입고)   PO_NB + PO_SQ + ITEM_CD
  → [REQODR_FG='1'] LWO_WF / LWO_WF_D (지시) → LORCV_H (실적) → LPRDINWH (실적입고)
  → LDELIVER / LDELIVER_D  (출고)         SO_NB + SO_SQ + ITEM_CD
  → LSALECLS / LSALECLS_D  (매출마감)
```

**산출로직**
```sql
진행단계 = CASE
    WHEN 매출마감 있음                          THEN '9.마감'
    WHEN SO_QT - ISU_QT <= 0                    THEN '8.출고완료'
    WHEN ISU_QT > 0                             THEN '7.부분출고'
    WHEN 실적입고 있음                          THEN '6.생산입고'
    WHEN 생산실적 있음                          THEN '5.생산중'
    WHEN 작업지시 있음 (DOC_ST='1')             THEN '4.지시확정'
    WHEN 입고 있음                              THEN '3.입고'
    WHEN 발주 있음 (EXPIRE_YN='1')              THEN '2.발주진행'
    WHEN 청구 있음                              THEN '1.청구'
    ELSE '0.미착수' END

지연일수 = DATEDIFF(DAY, LSO_D.DUE_DT, GETDATE())   -- 미출고 건만
```

**작업포인트**
1. `REQODR_FG`(0.구매/1.생산)로 **구매 경로와 생산 경로를 분기**해야 한다. 한 SELECT에 `CASE`로 합치는 방식이 주문총괄생산진행현황의 검증된 패턴.
2. 수주 1건 → 청구 N건 → 발주 N건이므로 **행 증식(fan-out) 주의**. 단계별 존재여부는 `EXISTS` 또는 `OUTER APPLY (SELECT TOP 1 ...)`로 잡아야 수주 1행이 유지된다.
3. 청구가 수주와 연결되지 않는 사이트가 많다(`LPUR_REQ_D`에 `SO_NB` 없음). 이 경우 품목+납기 근사매칭이 필요하며 **정확도가 크게 떨어진다** → 선결조건 확인 필수.
4. `EXPIRE_YN='1'`이 진행. 반대로 걸면 결과가 비어버린다.

**선결조건** — 청구 사용 여부, 청구↔수주 연결 여부. 미사용이면 `LSO_D → LWO_WF.SO_NB/LN_SQ` 직결 경로로 단순화.

---

### S-03. 납기 준수율 KPI ★★

**목적** — 고객 약속 납기를 지켰는가. 영업·생산 공통 최상위 KPI.

**소스** — `LSO_D.DUE_DT` vs `LDELIVER.ISU_DT`

**산출로직** (대기정밀 쿼리 검증 + 보정)
```sql
지연일수   = DATEDIFF(DAY, LSO_D.DUE_DT, LDELIVER.ISU_DT)
지연플래그 = CASE WHEN 지연일수 > 0 THEN 1 ELSE 0 END      -- ★ 보정
지연수량   = LDELIVER_D.ISU_QT * 지연플래그

납기준수율 = (1 - SUM(지연수량) / SUM(주문량)) * 100        -- 수량기준
건수기준   = COUNT(지연플래그=0) / COUNT(*) * 100
평균지연일 = AVG(CASE WHEN 지연일수>0 THEN 지연일수 END)
```

**작업포인트**
1. **원본 쿼리의 결함을 고쳐야 한다.** 참조 쿼리는 `CASE DATEDIFF(...) WHEN '0' THEN '0' ELSE '1'`로 되어 있어 **조기납품(음수)도 지연으로 계산**된다. `> 0`으로 바꿔야 정상.
2. 완결 건만 대상: `SO_QT - ISU_QT = 0`. 미납 건을 섞으면 분모가 왜곡된다.
3. 분할출고 시 출고가 여러 건 → **최종 출고일 기준**(`MAX(ISU_DT)`)이 실무 정의에 맞다.
4. 거래처가 납기를 변경한 경우 원납기/변경납기 구분이 필요하면 `LSO_D.DUMMY*` 또는 관리항목 사용 여부 확인.

**대시보드 표현** — 월별 추이 라인 + 거래처별 하위 20 바 + 지연 사유 코드 분포

---

### P-01. 청구→발주→입고 진행현황 ★★

**목적** — 구매 요청이 발주되었는지, 입고되었는지, 어디서 막혔는지.

**소스 체인** (청구별 발주 입고 진행현황 쿼리 검증)
```
LPUR_REQ / LPUR_REQ_D          청구  (REQ_NB + REQ_SQ + ITEM_CD)
  └→ LPO_D                     발주  (동일 키로 조인)
       └→ LSTOCK_D             입고  (PO_NB + PO_SQ + ITEM_CD)
            └→ LPURCLS_D       매입마감
```

**산출로직**
```sql
진행단계 = CASE WHEN 마감 있음            THEN '4.마감'
                WHEN RCV_QT >= PO_QT      THEN '3.입고완료'
                WHEN RCV_QT > 0           THEN '2.부분입고'
                WHEN PO_NB IS NOT NULL    THEN '1.발주'
                ELSE '0.미발주' END
미발주수량 = PREQ_QT - ISNULL(발주합계, 0)
미입고수량 = PO_QT - RCV_QT
발주소요일 = DATEDIFF(DAY, REQ_DT, PO_DT)      -- 구매팀 처리속도 KPI
입고지연일 = DATEDIFF(DAY, PO_D.DUE_DT, RCV_DT)
```

**작업포인트**
1. 청구 1건 → 발주 분할, 발주 1건 → 입고 분할이 흔하다. **집계 후 조인**(발주합계/입고합계를 서브쿼리로 만든 뒤 붙임)하지 않으면 금액이 부풀려진다.
2. `발주소요일`은 구매팀 KPI로 유용하지만, 긴급발주(청구 없이 직발주)는 `REQ_NB IS NULL`로 별도 집계해야 왜곡되지 않는다.
3. 수입 건은 `LSTOCK.LC_YN='1'`이며 입고 시점이 통관 기준이라 국내와 분리 집계 권장.

---

### P-03. 실시간 재고 추적 (창고·장소·LOT) ★★★

**목적** — "지금 이 품목이 어느 창고 어느 장소에 몇 개, 어느 LOT으로 있는가"를 즉시.

**소스** — 계층별로 나눠 쓴다 (레퍼런스 1장 참조)
```
현재고(최속)      VL_INVDIV / VL_INVLC          P_YR+CO_CD+DIV_CD(+WH_CD+LC_CD)+ITEM_CD
수불유형별 현재고  L_INVSUM_LC                   + GRP_FG
과거일 기준       LINVTORY  (+ IO_DT <= 기준일)  ← 집계뷰엔 IO_DT 없음
창고+실적입고 통합 LINVTORY_D                    + BASELOC_CD, LOC_CD
재공              VL_LINV_WIP_ALL / LINV_WIP    창고재고와 별도 테이블
```

**산출로직**
```sql
현재고 = SUM(IOPEN_QT) + SUM(IRCV_QT) - SUM(IISU_QT)
         WHERE P_YR = 해당연도 AND IO_DT <= 기준일

-- 용도별 출고 분할 (LX_BOM_BACK_INVTORY 패턴)
생산출고 PISU_QT = SUM(CASE WHEN GRP_FG='0' AND IO_FG='2' THEN IISU_QT END)
매출출고 SISU_QT = SUM(CASE WHEN GRP_FG='3' AND IO_FG='2' THEN IISU_QT END)
기타출고 EISU_QT = SUM(CASE WHEN GRP_FG='6' AND IO_FG='2' THEN IISU_QT END)

가용재고 = 현재고 - 주문출고예정 - 가출고 - 자재할당 + 입고예정 - 안전재고
           (LDEMAND_STORY 산식 — P-08 MRP와 동일)
```

**작업포인트**
1. **연도 경계 주의.** `P_YR`로 파티션되므로 연초 조회 시 전년도 이월(`GRP_FG='6'`, `IO_NB='XY'`)이 기초로 넘어왔는지 확인해야 한다. 안 넘어왔으면 전년 잔고를 별도 합산.
2. 재공은 `LINVTORY`가 아니라 **`LINV_WIP`(재공수불부)**에 있다. 공정 재고까지 보려면 두 테이블을 UNION해야 한다 (M-04 참조).
3. **마이너스 재고가 나오면 `SYSCFG` 모듈`'S'`/코드`'13'`(마이너스재고통제여부)를 확인**하라. `0`(허용)이면 데이터 자체가 음수일 수 있고, 가용재고 계산 신뢰도가 떨어진다.
4. LOT 관리 품목만 LOT 단위로 의미가 있다 → `SITEM.LOT_FG='1'` 필터.
5. 실시간성이 중요하면 **증분 배치**(전일 마감 스냅샷 + 당일 수불만 합산)로 응답속도를 확보한다.
6. **`S_CD <> 'Z00'`(단종품) 필터를 기본 적용**한다. 실무 쿼리 다수가 공통으로 거는 관례이며, 빼면 단종품이 재고 리스트를 오염시킨다.
7. `SETITEM_FG`(SET품여부)로 세트완제품을 분리하면 완제품 재고 해석이 명확해진다.

---

### P-05. 안전재고 미달 / 과잉재고 알람 ★★

**목적** — 결품 위험과 과잉 재고를 동시에 잡는 양방향 알람.

**산출로직**
```sql
안전재고     = SITEM.SAFESTOCK_QT
현재고       = (P-03 산출)
가용재고     = (P-03 산출)

부족율       = (안전재고 - 가용재고) / NULLIF(안전재고,0) * 100
과잉배수     = 현재고 / NULLIF(안전재고,0)
일평균사용량 = 최근 N개월 출고합계 / 일수
소진예상일수 = 가용재고 / NULLIF(일평균사용량,0)

알람등급 = CASE WHEN 가용재고 < 0                        THEN '1.결품'
                WHEN 소진예상일수 < SITEM.LEAD_DT        THEN '2.조달불가(긴급)'
                WHEN 가용재고 < 안전재고                 THEN '3.안전재고 미달'
                WHEN 과잉배수 > 5 AND 최근6개월출고 = 0  THEN '8.체화'
                WHEN 과잉배수 > 3                        THEN '9.과잉'
                ELSE '0.정상' END
```

**작업포인트**
1. **`소진예상일수 < LEAD_DT`가 가장 실용적인 지표**다. 단순 "안전재고 미달"보다 조치 시급성이 명확하다.
2. `SAFESTOCK_QT` 미등록 품목이 많으면 알람이 무의미하다. 도입 전 등록률을 반드시 측정하고, 미등록이면 `일평균사용량 × LEAD_DT × 안전계수`로 **자동 제안값**을 함께 제시하는 편이 실무 채택률이 높다.
3. 계절성 품목은 최근 N개월 평균이 왜곡된다 → 전년 동기 대비 옵션 제공.

---

### M-01. 작업지시 진행 현황 ★★

**목적** — 지시가 계획/확정/진행/완료/마감 중 어디인지, 잔량이 얼마인지.

**소스** — `LWO_WF` + `LWO_WF_D`(공정) + `LORCV_H`(실적) + `LPRDINWH`(실적입고)

**산출로직**
```sql
지시상태  = LWO_WF.DOC_ST     -- 0.계획 1.확정 2.마감  ※ 사이트 확인 필요
진행상태  = LWO_WF.EXPIRE_YN  -- 1.생산진행 0.생산마감
실적수량  = SUM(LORCV_H.ITEM_QT)  WHERE SUB_TP='0' AND BAD_YN='0'
지시잔량  = LWO_WF.ITEM_QT - 실적수량
진척률    = 실적수량 / NULLIF(ITEM_QT,0) * 100
입고율    = SUM(LPRDINWH.INWH_QT) / NULLIF(실적수량,0) * 100
경과일    = DATEDIFF(DAY, ORD_DT, ISNULL(완료일, GETDATE()))
납기리스크 = CASE WHEN COMP_DT < 오늘 AND 지시잔량 > 0 THEN '납기경과' ... END
```

**작업포인트**
1. `DOC_ST` 코드가 API(0.미처리/1.처리)와 UDR(0.계획/1.확정/2.마감)로 갈린다. **`SELECT DOC_ST, COUNT(*) FROM LWO_WF GROUP BY DOC_ST`로 먼저 확인**하고 라벨을 확정할 것.
2. 부산물(`SUB_TP='1'`)·부적합(`BAD_YN='1'`)을 실적수량에 합산하면 진척률이 부풀려진다.
3. 다공정 지시는 `LWO_WF_D.WOOP_SQ` 순서로 **공정별 진척**을 별도 표현해야 병목이 보인다.

---

### M-04. 공정별 재공 실시간 현황 ★★★

**목적** — 지금 각 공정/작업장에 재공이 얼마나 쌓여 있는가. 생산 병목의 직접 지표.

**소스**
```
LINV_WIP    재공수불부        IOPEN_QT / IRCV_QT / IISU_QT, WH_CD(공정), LC_CD(작업장)
LWIPIO      재공처리          WIP_NB : WI 재공입고 / WM 재공이동 / WA 재공조정
                              MAP_FG : 1~3 실적별, 4~6 지시별(투입자재), 7~9 예외
LX_WH_W     공정별현재공집계   (있으면 우선 사용)
LX_LC_W     작업장별현재공집계
LX_PJT_W    프로젝트별현재공집계
```

**산출로직**
```sql
현재공 = SUM(IOPEN_QT) + SUM(IRCV_QT) - SUM(IISU_QT)   -- 공정/작업장/품목별
체류일수 = DATEDIFF(DAY, MIN(최초 재공입고일), 기준일)
재공금액 = 현재공 × 단가(CIV_PUR_TAV.ISU_UM 또는 LINV_TAV.ISU_UM)
병목지수 = 공정별 현재공 / 공정별 일평균 처리량
```

**작업포인트**
1. **`LX_WH_W` / `LX_LC_W` 집계 테이블이 이미 있으면 그걸 쓴다.** iCUBE가 제공하는 표준 집계이므로 재계산보다 빠르고 정합성도 보장된다. 없을 때만 `LINV_WIP`을 직접 집계.
2. 재공은 창고재고(`LINVTORY`)와 **별도 테이블**이다. 통합 재고를 보려면 UNION이 필요하고, 이때 `BASELOC_FG`(0.창고/1.공정)로 구분해야 중복되지 않는다.
3. 체류일수가 긴 재공 = 사장재공. **금액 기준 상위 20건만 뽑아도 개선 효과가 크다.**
4. 재공 실사(`LINVINSP_WIP`)와의 차이를 같이 보여주면 데이터 신뢰도 점검이 된다.

---

### M-05. 자재 청구/출고/사용 대비 현황 ★★

**목적** — 지시에 청구된 자재가 출고되고 실제 투입되었는지. **원가 마감 전 최우선 점검 항목.**

**소스 체인** (검증 완료)
```
LWO_REQ_WF (청구)  CO_CD+DIV_CD+WO_CD+WOBOM_SQ+ITEM_CD   REQ_QT
  → LSTKMOVE_D (출고)   + WO_CD + ITEM_CD + WOBOM_SQ + ITEMPARENT_CD   MOVE_QT
  → LMTL_USE (실적별사용) WR_CD=LORCV_H.DOC_CD + WOBOM_SQ              USE_QT
    또는 LMTL_USEWO (지시별사용) WO_CD + WOBOM_SQ
```

**산출로직**
```sql
진행구분 = CASE WHEN REQ_QT<>0 AND 출고없음              THEN '출고대기'
                WHEN 출고>0    AND 사용없음              THEN '사용대기'
                WHEN REQ_QT > MOVE_QT                    THEN '출고중'
                WHEN MOVE_QT = USE_QT                    THEN '사용완료'
                WHEN MOVE_QT > USE_QT                    THEN '사용중(잔량)'
                WHEN REQ_QT=0 AND 출고>0                 THEN '청구없는출고' END
출고미사용량 = MOVE_QT - USE_QT
출고미사용금액 = 출고미사용량 × 단가        ← 원가에 반영 안 된 잠재 재료비
```

**작업포인트**
1. **`출고미사용금액`이 이 현황의 핵심 산출물**이다. 원가 마감 시 이 금액만큼 재료비가 과소 계상되거나 재공으로 남는다.
2. 사용보고를 아예 안 하는 사이트가 있다. `SELECT COUNT(*) FROM LMTL_USE`가 0이면 출고를 사용으로 간주하는 모드로 전환.
3. `LWO_REQ_WF`는 테이블명세서에 없다(실무 쿼리로 확인). **존재 확인 후 개발 착수**.
4. 이미 개발된 `PJT_생산원가_보고서.sql` 쿼리 C가 이 로직을 포함한다 — **재사용 가능**.

---

### C-03. 제품별 원가 구성 (재료비/노무비/경비) ★★★

**목적** — 제품 1단위 원가가 무엇으로 이루어졌는가. 판가 결정과 원가절감 과제 도출의 기초.

**소스** — 원가모듈 결과 테이블 직접 조회
```
CIV_PRD_TAV     당기 제조원가분석  ITEM_CD, PRD_QT, MTL_UM/MTL_AM(재료비),
                                   LBR_UM/LBR_AM(외주비), CONV_AM(가공비), PRD_AM/PRD_UM
CIV_PRD_TAV_D   당기 재료비분석    PITEM_CD, CITEM_CD, USE_QT, REAL_QT(원단위), MTL_UM, USE_AM
CIV_LBR_AM      당기 외주비        ITEM_CD, LBR_AM
CIV_CONVCST /   가공비 집계·배부
CIV_OE          가공비 총액
CIV_CHASU       원가차수 (P_YR + CHASU, SMM~FMM, CLS_YN)
```

**산출로직**
```sql
제품단위원가 PRD_UM = (MTL_AM + LBR_AM + CONV_AM) / PRD_QT
재료비율 = MTL_AM / NULLIF(PRD_AM,0) * 100
외주비율 = LBR_AM / NULLIF(PRD_AM,0) * 100
가공비율 = CONV_AM / NULLIF(PRD_AM,0) * 100
전차수대비 = 당차수 PRD_UM / 전차수 PRD_UM - 1
```

**작업포인트**
1. **원가계산(`USP_COT0010_CALC_COST_TAV`)이 실행된 차수만 데이터가 있다.** `CIV_CHASU.CLS_YN='1'`(마감)인 차수를 기준으로 조회해야 하며, 미마감 차수는 값이 불완전하다.
2. 원가모듈은 **프로젝트 축이 없다**. 프로젝트별 원가는 `C-01`(개발완료)처럼 별도 산출해야 한다.
3. 가공비 배부방법(`CIV_CONVCST.METHOD_FG`)이 사이트마다 다르다(수량/금액/시간/중량 기준 등 7종). 배부기준을 같이 표시해야 현업이 납득한다.
4. **전차수 대비 증감이 가장 많이 쓰이는 컬럼**이다. 차수 2개를 self-join 하는 구조를 처음부터 넣을 것.

---

### C-04. 표준원가 대비 실제원가 차이분석 ★★★

**목적** — 계획(표준) 대비 실제가 왜 벌어졌는지를 **수량차이 / 단가차이로 분해**.

**산출로직** (표준원가 차이분석 정석)
```sql
표준원가     = 표준사용량(BOM) × 표준단가(SITEM.PURCH_UM)
실제원가     = 실제사용량       × 실제단가(CIV_PUR_TAV.ISU_UM)

수량차이금액 = (실제사용량 - 표준사용량) × 표준단가     -- Quantity Variance
단가차이금액 = (실제단가   - 표준단가  ) × 실제사용량   -- Price Variance
총차이       = 실제원가 - 표준원가  ( = 수량차이 + 단가차이 )

(+) 불리(원가상승) / (-) 유리(원가절감)
```

**작업포인트**
1. **책임 부서가 갈린다**: 수량차이=생산, 단가차이=구매. 분해하지 않으면 개선 주체가 정해지지 않는다.
2. 표준단가를 `SITEM.PURCH_UM`으로 할지 `SITEM.STANDARD_UM`(생산표준원가)으로 할지, 거래처별 단가(`LCUSTM_UM`, `NO_SQ=999`)로 할지 **먼저 합의**해야 한다.
3. `PJT_생산원가_보고서.sql`이 이 로직을 이미 구현했다 — **프로젝트 축을 제거하면 그대로 전사 버전**이 된다.

---

### E-01. 경영 KPI 통합 대시보드 ★★★

**구성 제안** — 상단 KPI 타일 8개 + 중단 추이 4개 + 하단 이상징후 리스트

| 영역 | KPI | 산출 | 목표선 |
|---|---|---|---|
| 영업 | 수주액 / 매출액 (당월·누계) | `LSO_D.SOG_AM` / `LSALECLS_D` | 계획 대비 % |
| 영업 | 납기준수율 | S-03 | 95% |
| 영업 | 미수채권 / 여신소진율 | S-06 | 한도 90% |
| 생산 | 생산달성률 | M-01 진척률 가중평균 | 95% |
| 생산 | 작업수율(양품률) | M-03 | 97% |
| 구매 | 결품 품목수 | P-05 알람등급 1·2 | 0 |
| 구매 | 재고금액 / 회전율 | P-06 | 회전 12회 |
| 원가 | 원가차이율 | C-04 총차이/표준원가 | ±3% |

**작업포인트**
1. **타일마다 원천이 다르므로 갱신주기를 나눈다.** 수주·재고는 실시간(5~10분), 원가는 차수 마감 시점(월 1회). 한 화면에서 갱신주기가 다른 지표를 섞을 때는 **각 타일에 기준시각을 반드시 표시**해야 신뢰를 잃지 않는다.
2. 원가 KPI는 **미마감 차수에서 값이 튄다**. `CIV_CHASU.CLS_YN='1'`만 표시하고, 미마감이면 "집계중"으로 표기.
3. 드릴다운 경로를 미리 설계: KPI 타일 → 해당 상세 현황(S/P/M/C) → 전표·지시 단위.

---

### E-02. 수주→출하 리드타임 분석 ★★★

**목적** — 수주부터 출하까지 실제 며칠 걸리는가, 어느 구간이 긴가.

**산출로직** — 구간별 소요일수 분해
```sql
① 수주→청구      DATEDIFF(DAY, LSO.SO_DT,        LPUR_REQ.REQ_DT)
② 청구→발주/지시  DATEDIFF(DAY, REQ_DT,           LPO.PO_DT / LWO_WF.ORD_DT)
③ 발주→입고      DATEDIFF(DAY, PO_DT,            LSTOCK.RCV_DT)
④ 지시→실적      DATEDIFF(DAY, ORD_DT,           LORCV_H.DOC_DT)
⑤ 실적→입고      DATEDIFF(DAY, DOC_DT,           LPRDINWH.INWH_DT)
⑥ 입고→출고      DATEDIFF(DAY, INWH_DT,          LDELIVER.ISU_DT)
총 리드타임      DATEDIFF(DAY, SO_DT, ISU_DT)
```

**작업포인트**
1. 구간별 **중앙값(median)**을 함께 보여야 한다. 평균은 이상치 몇 건에 끌려간다. `PERCENTILE_CONT(0.5)` 사용.
2. `SITEM.LEAD_DT`(등록 조달일수)와 **실측 리드타임의 괴리**를 같이 표시하면 MRP 정확도 개선 과제가 자동 도출된다 — P-08 MRP의 예정발주일 신뢰도와 직결.
3. 품목군별·거래처별로 나눠야 의미가 있다. 전사 평균은 행동으로 이어지지 않는다.

---

## 4. 나머지 현황 요약

| ID | 소스 핵심 | 산출로직 요약 | 주요 작업포인트 |
|---|---|---|---|
| **S-02** | `LSO_D` + `LDELIVER_D` | 미납량=`SO_QT-ISU_QT`, 경과일 구간(0/1-7/8-30/31+) | `EXPIRE_YN='1'` 진행분만. 반품(음수) 분리 |
| **S-04** | `LSALECLS_D`, `LRCP`/`LRCP_D` | 매출·수금 당월/누계, 회수율=수금/매출 | 매출마감 기준 vs 출고 기준 정의 합의 |
| **S-05** | `LSALECLS_D` + `CIV_PRD_TAV` | 이익=매출-원가, 담당자=`LPLNNERCD` | 원가 미마감 시 표준원가 대체 로직 필요 |
| **S-06** | `LCR_ADJUST`, `LOPN_CRISU`, `STRADE` | 채권잔액, 여신소진율, 연령분석(AR Aging) | 여신한도 등록 여부 확인. 연령구간 합의 |
| **S-07** | `LFORECST_D`, `LFORECST_SLS_D` | 계획 대비 실적 %, 고객/담당/부서/품목군 축 | 계획 등록 단위와 실적 집계 단위 일치 필요 |
| **S-08** | `LSALECLS_D` + `SITEMGRP` | 월별 판매 추이, 전년동기 대비 | 품목군 미등록 품목 '기타' 처리 |
| **P-02** | `LPO_D` + `LSTOCK` | 지연일=`RCV_DT - DUE_DT`, 거래처별 준수율 | 분할입고 시 최종입고일 기준 |
| **P-04** | `LINVTORY` / `LINV_MVFIFO` | 기초+입고-출고=기말, 출고 3분할(P/S/E) | 평가 전/후 구분. `CLS_NB` 앞2자리로 수불유형 분류 |
| **P-06** | `LINVTORY` + `CIV_TAV` | 회전율=출고금액/평균재고금액, ABC 파레토 | 체화=최근N개월 출고 0. 기준월수 합의 |
| **P-07** | `LSTOCK_D`, `LPURCLS_D`, `LCUSTM_UM` | 월별 가중평균 매입단가 추이, 거래처 비교 | `LCUSTM_UM.NO_SQ=999`가 현재단가 |
| **M-02** | `LORCV_H` + `LPRDINWH` | 일자별 생산량·양품·불량, 부서/공정 축 | 부산물·재작업 분리 |
| **M-06** | `LQC_INSP`, `LQC_INSP_D`, `LBAD` | 불량률, 코드별 Pareto·누적구성비 | `LBAD`/`LBADGRP` 존재 확인 |
| **M-07** | `LWO_WF`(WOC_FG='4'), `LOCLS_H`/`LOCLS_D` | 외주 지시→입고→마감, 외주비 | 외주마감이 원가의 외주비 원천 |
| **M-08** | `LORCV_H`(EQUIP_CD, WTEAM_CD, WSHFT_CD) | 설비·작업팀·작업조별 생산량/불량률 | 설비코드 등록률 확인 |
| **C-02** | `CIV_PRD_TAV_D` | 제품×자재 사용량·원단위·금액 | ERP 화면 `USP_COT0020_SELECT`와 동일 |
| **C-05** | `LSALECLS_D` + `CIV_PRD_TAV` | 매출이익=매출-매출원가, 품목/거래처/담당 | 선입선출 평가 사용 시 `LINV_MVFIFO` |
| **C-06** | `LINV_TAV`, `LINV_MVFIFO`, `CIV_TAV` | 평가 전후 비교, 단가 차이 | 평가 미실행 기간 주의 |

---

## 5. 개발 로드맵 제안

### 1차 (즉시 — 이미 확보한 자산 활용)

| 항목 | 근거 |
|---|---|
| P-08 원자재 수급 총괄(MRP) | 개발완료 · `EXPIRE_YN` 수정 반영됨 |
| M-03 작업수율 현황 | 개발완료 |
| C-01 프로젝트별 생산원가 | 개발완료 |
| M-05 자재 청구/출고/사용 | C-01 쿼리 C 재사용 |
| C-04 표준원가 차이분석 | C-01에서 프로젝트 축 제거 |

### 2차 (진행현황 — 현업 체감 효과 최대)

S-01 수주 진행 총괄 · P-01 청구→발주→입고 · M-01 작업지시 진행 · P-03 실시간 재고

> 이 4개가 "ERP 화면 여러 개 도는 수고"를 가장 많이 줄여줍니다. 현업 채택률이 가장 높은 구간.

### 3차 (KPI — 목표선 합의 필요)

S-03 납기준수율 · P-05 재고알람 · M-06 품질 KPI · C-03 원가구성

### 4차 (대시보드 통합)

E-01 경영 KPI 대시보드 · E-02 리드타임 분석

---

## 6. 공통 작업포인트 (전 항목 적용)

### 6-1. 필수 선행 검증

```sql
-- 코드값 실분포 (라벨 확정 전 필수)
SELECT DOC_ST, COUNT(*) FROM LWO_WF GROUP BY DOC_ST;          -- 0/1/2 어느 체계인가
SELECT EXPIRE_YN, COUNT(*) FROM LSO_D GROUP BY EXPIRE_YN;     -- '1'이 다수여야 정상
SELECT ACCT_FG, COUNT(*) FROM SITEM GROUP BY ACCT_FG;

-- 테이블 실존 확인 (명세서 누락분)
SELECT name FROM sys.tables
WHERE name IN ('LWO_REQ_WF','LSTKMOVE','LSTKMOVE_D','LINVTORY','LINV_WIP','LOCLS_H','LOCLS_D',
               'LPO','LBAD','LBADGRP','SBOM_WF','CIV_PUR_TAV','CIV_PRD_TAV','LX_WH_W','LX_LC_W')
ORDER BY name;

-- 제공 뷰 확인 (있으면 우선 사용)
SELECT name FROM sys.views WHERE name LIKE 'VL\_%' ESCAPE '\' OR name LIKE 'VC\_%' ESCAPE '\';

-- 마스터 등록률 (미등록이면 KPI가 무의미)
SELECT COUNT(*) 전체,
       SUM(CASE WHEN ISNULL(LEAD_DT,0)=0 THEN 1 ELSE 0 END) 조달일수미등록,
       SUM(CASE WHEN ISNULL(SAFESTOCK_QT,0)=0 THEN 1 ELSE 0 END) 안전재고미등록,
       SUM(CASE WHEN ISNULL(PURCH_UM,0)=0 THEN 1 ELSE 0 END) 구매단가미등록
FROM SITEM WHERE USE_YN='1' AND ACCT_FG IN ('0','1');
```

### 6-2. 설계 원칙

1. **`EXPIRE_YN='1'`, `USE_YN='1'`을 모든 트랜잭션 테이블에 기본 적용.** 빠뜨리면 폐기 데이터가 섞인다.
2. **행 증식 방지.** 1:N 관계 조인 시 반드시 집계 서브쿼리 또는 `OUTER APPLY (SELECT TOP 1 ...)`를 쓴다. 금액이 배수로 부풀려지는 사고가 가장 흔하다.
3. **소수점 자리수는 `SYSCFG`를 따른다.** 모듈`'S'` 통제코드 `02`(수량) `03`(단가) `06`(금액), 끝전처리 `10`. 하드코딩하면 ERP 화면과 숫자가 안 맞는다.
4. **대용량 전개·집계는 야간 배치로 `LX_*` 테이블에 적재.** `LX_BOM_BACK_*` 패턴(`TYPE_NB`로 조건세트 구분, `LEVEL_NB`로 레벨 보존)을 그대로 차용한다.
5. **UDR 포맷으로 감싸면 ERP 메뉴 등록이 가능**하다. 단 UDR은 단일 SELECT만 허용하므로, 임시테이블·동적SQL을 쓰는 복잡한 현황은 **저장프로시저로 만들고 UDR에서 `EXEC`만 호출**하는 구조를 권한다.

### 6-3. 성능 인덱스 (공통)

```sql
LSO_D      (CO_CD, DUE_DT)       INCLUDE (SO_NB, SO_SQ, ITEM_CD, SO_QT, ISU_QT, EXPIRE_YN)
LDELIVER_D (CO_CD, SO_NB, SO_SQ) INCLUDE (ITEM_CD, ISU_QT)
LPO_D      (CO_CD, ITEM_CD)      INCLUDE (PO_NB, PO_SQ, PO_QT, RCV_QT, EXPIRE_YN)
LSTOCK_D   (CO_CD, PO_NB, PO_SQ) INCLUDE (ITEM_CD, RCV_QT, RCV_UM)
LORCV_H    (CO_CD, DOC_DT)       INCLUDE (WO_CD, ITEM_CD, ITEM_QT, BAD_YN, SUB_TP)
LMTL_USE   (CO_CD, WR_CD)        /  LWO_REQ_WF (CO_CD, WO_CD, WOBOM_SQ)
LSTKMOVE_D (CO_CD, WO_CD, ITEM_CD, WOBOM_SQ)
LINVTORY   (CO_CD, DIV_CD, P_YR, ITEM_CD, IO_DT)
SBOM_WF    (CO_CD, ITEMPARENT_CD, START_DT, END_DT) / (CO_CD, ITEMCHILD_CD)
```

---

## 7. 확인이 필요한 항목

1. **`LWO_WF.DOC_ST` 코드체계** — API(0.미처리/1.처리) vs UDR(0.계획/1.확정/2.마감). 실 DB 분포로 확정 필요.
2. **청구↔수주 연결 여부** — S-01의 정확도를 좌우. `LPUR_REQ_D`에 수주번호 컬럼이 있는지 확인.
3. **`LX_WH_W` / `LX_LC_W` / `LX_PJT_W` 존재 여부** — 있으면 M-04를 훨씬 단순하게 만들 수 있음.
4. **원가차수 운영 주기** — 월 1회인지 수시인지에 따라 C-03/C-04의 갱신주기와 "집계중" 표기 정책이 달라짐.
5. **여신한도 등록 여부** — S-06의 여신소진율 산출 가능 여부를 결정.
