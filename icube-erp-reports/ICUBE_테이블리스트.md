# iCUBE 테이블 리스트

**출처**: 아이큐브테이블명세서.xls (610 테이블) + 세션 중 실무 쿼리·INSERT 스크립트로 확인된 **명세서 누락 테이블 30종**

| 모듈 | 명세서 등재 |
|---|---:|
| 인사 | 218 |
| 회계 | 186 |
| 물류 | 122 |
| 시스템 | 84 |
| **합계** | **610** |

---

## 1. ★ 명세서에 없지만 실제 존재하는 테이블 (확인 완료)

세션 전체에서 실무 쿼리·SP·INSERT 스크립트로 존재가 확인된 것들입니다. **개발 전 `sys.tables`로 실존 확인이 필요**합니다.

### 1-1. 재고·수불

| 테이블/뷰 | 내용 | 확인 근거 |
|---|---|---|
| `LINVTORY` | 창고 재고수불부 (평가 전) | 뷰테이블 목록, BOM역전개 SP |
| `LINVTORY_D` | 창고 + 작업실적입고/일괄생산실적 **통합** (`BASELOC_CD`/`LOC_CD` 추가) | 뷰테이블 목록 |
| `LINV_WIP` | 재공수불부 | 재고자산수불부 메모 |
| `LINV_MVFIFO` | 재고자산수불부 (평가 후) | 재고평가보고서 |
| `LINV_MVFIFO_WK` | 평가 작업본 (`*_AM_GAP` 차이금액 보유) | 재고입출고현황 |
| **`LX_LINVTORY`** | 재고조정금액현황(평가·마감기준) + **실수불집계, 창고/장소 있음** | 재고조정내역 쿼리 |
| `L_INVSUM_LC` | 연도/사업장/창고/장소별 집계 (**`GRP_FG` 포함**) | 뷰테이블 목록 |
| `LWIPIO` | 재공처리 (예외/실적별/지시별) | 재고자산수불부 메모, INSERT 스크립트 |
| `LSTKMOVE` / `LSTKMOVE_D` | 생산자재출고처리 | 다수 |

### 1-2. 생산·자재

| 테이블 | 내용 | 확인 근거 |
|---|---|---|
| **`LWO_REQ_WF`** | 작업지시 소요자재(청구) `REQ_QT`/`RCV_QT`/`USE_QT` | 지시별 자재현황 쿼리 |
| `LPRODUCTION` | 일괄생산실적 헤더 (`PITEM_CD`,`ITEM_QT`,`BASELOC_FG`) | 수율 쿼리, 원가 SP |
| `LOCLS_H` / `LOCLS_D` | 외주마감 (원가의 외주비 원천, `PJT_CD` 보유) | 원가계산 SP |
| `SBOM_WF` / `SBOM_WF_B` | BOM / BATCH BOM | BOM역전개 SP |

### 1-3. 영업·채권

| 테이블 | 내용 | 확인 근거 |
|---|---|---|
| **`LOPN_CRISU_CLS`** | 기초채권 **마감기준** (`LOPN_CRISU`=출고기준) | INSERT 스크립트 |
| **`LOPN_PAY`** | 기초채무 (`LOPN_PAY_CLS`=마감기준) | INSERT 스크립트 |
| **`LCR_LIMIT`** | **여신한도등록** `DAMBO_AM`/`SINYONG_AM`/`ETC_AM`/`YUSIN_AM`/`YUSIN_FG`/`TERMS` | INSERT 스크립트 |
| `LEBL` / `LEBL_D` | 수출선적 (매출마감 역할) | 매출마감 이관 쿼리 |
| `LIBL` / `LIBL_D` | 수입선적 | 〃 |
| `LTRADEMGM` | 물류실적담당자 (거래처별) `PLN_CD`/`PURPLN_CD`/`OUTPLN_CD`/`AREA_CD` | INSERT 스크립트 |
| `LPLNNERCD` / `LPLNNERSCD` | 실적담당자 / 담당그룹 | UDR 코퍼스 |
| `LPRTITEMTRD` | 고객별 출력품목등록 | INSERT 스크립트 |
| `LCUSTM_UM` | 거래처별 단가 (**`NO_SQ=999`가 현재단가**) | 단가 HISTORY SP |

### 1-4. 기준정보·기타

| 테이블 | 내용 |
|---|---|
| `LCTRL_MGM` / `LCTRL_MGM_D` | 관리내역(물류·생산). `CTRL_CD` = `LS`영업/`LP`구매/`LA`재고조정 |
| `LPO` | 발주 헤더 (`LPO_D`만 명세서 등재) |
| `LPURCLS` | 매입마감 헤더 (`DOCU_YN`/`DOCU_DT`/`DOCU_SQ`) |
| `LBAD` / `LBADGRP` | 불량유형 / 불량그룹 |

### 1-5. 원가 모듈 (`CIV_*`) — 명세서 미등재, 원가계산 SP로 전량 확인

| 테이블 | 내용 |
|---|---|
| `CIV_CHASU` | 원가계산 차수 (`P_YR`+`CHASU`, `SMM`~`FMM`, `CLS_YN`) |
| `CIV_TAV` | 경리수불집계 (`OPEN/RCV/RCVT/ISU/TRNS/INV` × `QT/UM/AM`) |
| **`CIV_PUR_TAV`** | 재료비 **출고단가** = (기초+입고+대체입고금액)/(수량) |
| `CIV_PRD_TAV` | 당기 제조원가분석 (`MTL_AM`/`LBR_AM`/`CONV_AM`/`PRD_UM`) |
| `CIV_PRD_TAV_D` | 당기 재료비분석 (`REAL_QT`=원단위, `USE_QT`, `MTL_UM`, `USE_AM`) |
| `CIV_PRD_QT` / `CIV_MTL_QT` | 제품별 생산량 / 사용자재량 |
| `CIV_LBR_AM` | 당기 외주비 |
| `CIV_CONVCST` / `CIV_CONVCST_D` / `CIV_OE` | 가공비 집계·배부 / 총액 |
| `CIV_ELEMENT` / `CIV_ACCTLINK` | 원가요소 / 계정 매핑 |
| `CIV_DIST_ITEM` | 원가요소 배부(품목별) |

### 1-6. 제공 뷰 (사이트별 상이 — 있으면 우선 사용)

| 뷰 | 용도 |
|---|---|
| `VL_LINVTORY_ALL` / `VL_LINVTORY_LX` | 창고 재고현황 |
| `VL_LINV_WIP_ALL` | 재공현황 |
| `VL_INVCO` / `VL_INVDIV` / `VL_INVLC` | 연도/회사/사업장/창고·장소별 현재고 집계 |
| **`VL_SO_ISU`** | 수주별 출고수량 합계 (`LDELIVER_D`) |
| `VL_RCV_CLS` | 입고별 매입마감 합계 |
| `VL_SLSCLS` | 출고별 매출마감 |
| **`VL_LWO_REQ_WF`** | 지시별 청구/투입/사용 현황 |
| `VL_PJT` | **프로젝트 수불 통합** (UDR 22건이 사용) |
| `VC_BOM` / `CX_PARTLIST` | BOM 다단계 전개 |
| `VL_PUMGM` / `VL_INVLC` / `VL_PUR_RCV` / `VL_SLMGM` | 구매의뢰 / 장소재고 / 구매입고 / 영업관리구분 |

### 1-7. 사용자 정의 집계 테이블 (`LX_*` 패턴)

야간 배치로 사전집계하는 관례. 직접 만들 때도 이 명명을 따르는 것이 좋습니다.

| 테이블 | 내용 |
|---|---|
| `LX_WH_W` / `LX_LC_W` / `LX_DIV_W` / `LX_PJT_W` | 공정별/작업장별/사업장별/프로젝트별 현재공 집계 |
| `LX_LINVTORY_LS` / `LX_LC_LS` / `LX_LOTLC_LS` | 규격형 재고 집계 |
| `LX_BOM_BACK_EXPANSION` | BOM 역전개 결과 캐시 (`TYPE_NB`/`LEVEL_NB`/`REAL_QT`) |
| `LX_BOM_BACK_INVTORY` | 역전개 × 수불 (**출고 3분할** `PISU`생산/`SISU`매출/`EISU`기타) |

---

## 2. 기초데이터 구축용 INSERT 대상 테이블

이관·초기구축 시 직접 INSERT 하는 마스터입니다. (INSERT 스크립트 15종으로 확인)

| 업무 | 테이블 | 비고 |
|---|---|---|
| 계정과목등록 | `SACCT` | |
| 부서등록 | `SDEPT` | `DEPT_CD`+`CO_CD`+`SECT_CD`+`DIV_CD` |
| 품목군등록 | `SITEMGRP` | `LEAD_DT` 포함 |
| 관리내역등록(물류·생산) | `LCTRL_MGM_D` | `CTRL_CD`+`MGM_CD`, `MODULE_CD` |
| 고객별 출력품목등록 | `LPRTITEMTRD` | 거래처별 품목 별칭·환산 |
| 물류실적담당자등록 | `LTRADEMGM` | 영업/구매/외주 담당 + 지역 |
| **여신한도등록** | **`LCR_LIMIT`** | 담보·신용·기타·여신 한도 |
| 채권기초 (출고기준) | `LOPN_CRISU` | |
| 채권기초 (마감기준) | **`LOPN_CRISU_CLS`** | |
| 채무기초 | `LOPN_PAY` / `LOPN_PAY_CLS` | |
| 예외재공처리 | `LWIPIO` | `MAP_FG` 7~9 = 예외 |
| 급여 지급/공제 | `HPOMPPD` / `HPOMPDD` | UPDATE 방식 |

> **주의** — 이 테이블들에 직접 INSERT 하면 ERP 표준 검증·트리거를 우회합니다. 재고·회계에 영향을 주는 건은 반드시 백업 후, 가능하면 표준 메뉴나 API(`SetLSTOCK` 등)를 쓰십시오.

---

## 3. 모듈별 전체 테이블 (명세서 610종)

### 물류 (122)

**영업/수주** (18)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LEST` | 견적등록헤더 | 46 |
| `LEST_D` | 견적등록상세 | 48 |
| `LEST_D_LS` | 견적등록상세(규격정보) | 46 |
| `LFORECST_AM_D` | 판매계획(금액기준)_DETAIL | 27 |
| `LFORECST_D` | 판매계획(품목기준)_DETAIL | 28 |
| `LFORECST_SLS_D` | 판매계획(영업상세)_DETAIL | 16 |
| `LJUMUN_ISU` | 주문가출고처리_HEADER | 18 |
| `LJUMUN_ISU_D` | 주문가출고처리_DETAIL | 17 |
| `LSALE_COUNTR1` | 기초정보_고객별할인율등록 | 12 |
| `LSHCOMM_SHIPDOCU` | 품의등록(내역등록) | 35 |
| `LSHIPINFO` | 배송정보등록_헤드 | 26 |
| `LSHIPINFO_D` | 배송정보등록_디테일 | 17 |
| `LSHIP_BILL` | 기초정보_납품처등록 | 22 |
| `LSO` | 주문등록 | 59 |
| `LSO_ARS` | ARS주문등록 | 30 |
| `LSO_D` | 주문등록_디테일 | 97 |
| `LSO_D_LS` | 수주등록상세(규격정보) | 50 |
| `LSO_TEMP` | 주문(EXCEL IMPORT) | 72 |

**출고/매출** (9)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LDELIVER` | 출고처리(헤더) | 46 |
| `LDELIVER_D` | 출고처리(디테일) | 105 |
| `LDELIVER_D_LS` | 출고처리상세(규격정보) | 47 |
| `LPINVOICE_ADDINFO` | PROFORMA INVOICE 추가정보 테이블 | 7 |
| `LRENT` | 가출고의뢰등록(헤더) | 5 |
| `LSALECLS` | 매출마감(헤더) | 34 |
| `LSALECLS_D` | 매출마감(디테일) | 40 |
| `LSALECLS_D_LS` | 매출마감등록상세(규격정보) | 47 |
| `LSALECLS_TEMP` | 매출마감_TEMP | 24 |

**수금/채권** (6)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LCR_ADJUST` | 채권조정(출고기준) | 21 |
| `LOPN_CRISU` | 채권조정(출고기준) | 25 |
| `LRCP` | 수금등록 | 31 |
| `LRCPFG` | 수금등록_수금유형구분 | 7 |
| `LRCPS` | 수금등록_선수금정리 | 24 |
| `LRCP_D` | 수금등록상세 | 57 |

**구매/발주** (8)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LPO_D` | 발주등록(디테일) | 71 |
| `LPO_D_LS` | 발주등록상세(규격정보) | 46 |
| `LPO_TEMP` | 발주등록_TEMP | 26 |
| `LPURREQ_RLSE` | 품의등록_HEADER | 44 |
| `LPURREQ_RLSE_D` | 품의등록_DETAIL | 43 |
| `LPUR_REQ` | 구매요청_HEADER | 31 |
| `LPUR_REQ_D` | 구매요청_DETAIL | 45 |
| `LSTK_REQ` | 입고의뢰_HEADER | 33 |

**입고/매입** (6)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LPURCLS_D` | 매입마감_DETAIL | 40 |
| `LPURCLS_D_LS` | 매입마감등록상세(규격정보) | 47 |
| `LSTOCK` | 입고등록(헤더) | 37 |
| `LSTOCK_D` | 입고등록_DETAIL | 67 |
| `LSTOCK_D_LS` | 입고처리상세(규격정보) | 47 |
| `LSTOCK_TEMP` | 입고처리EXCEL IMPORT 중간 테이블 | 47 |

**지급/채무** (3)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LOPN_PAY_CLS` | 기초채무(마감+국내) | 22 |
| `LPAY` | 지급등록_HEAD | 27 |
| `LPAY_D` | 지급등록_DETAIL | 28 |

**생산/지시** (25)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LDEMAND` | 소요량전개_HEADER | 33 |
| `LDEMAND_D` | 소요량전개_DETAIL | 20 |
| `LDEMAND_STORY` | 소요량전개 원인수량정보테이블 | 16 |
| `LMETHOD` | 메서드코드 마스터 | 6 |
| `LMETHOD_BOM` | 메서드BOM 마스터 | 7 |
| `LMPS` | 주계획작성등록 | 31 |
| `LORCV_H` | 실적등록 | 45 |
| `LORCV_H_YIELD` | 임가공자재 출고_반품 | 1 |
| `LPRDINWH` | 실적입고 | 27 |
| `LPRODUCTION_D` | 일괄생산실적 디테일 | 29 |
| `LPRODUCTION_D_LS` | 간편생산실적별자재사용(규격정보) | 46 |
| `LPRODUCTION_LS` | 간편생산실적(규격정보) | 45 |
| `LRESUSE` | 사용자원등록 | 24 |
| `LROUTING` | 공정경로 헤드 | 20 |
| `LROUTING_D` | 공정경로 디테일 | 14 |
| `LROUT_HST` | 재공이동 | 10 |
| `LROUT_ITEM` | 공정경로품목배정 | 16 |
| `LTUIP` | 투입지시 | 15 |
| `LTUIP_D` | 투입지시 디테일 | 15 |
| `LWOPEN` | 기초재공 헤드 | 22 |
| `LWOPEN_D` | 기초재공 디테일 | 25 |
| `LWO_IMAGE` | 제조시방서 | 7 |
| `LWO_MV` | 작업지시공정이동 | 10 |
| `LWO_WF` | 작업지시공정이동 | 55 |
| `LWO_WF_D` | 지시등록 디테일 | 29 |

**자재사용/재공** (4)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LMTL_USE` | 실적별사용자재보고 | 38 |
| `LMTL_USEWO` | 지시별사용자재보고 | 31 |
| `LWADJUST` | 재공조정 | 10 |
| `LWADJUST_D` | 재공조정 | 11 |

**품질** (3)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LQC_INSP` | 일괄생산실적 디테일 | 34 |
| `LQC_INSP_D` | 실적검사  디테일(불량내역) | 17 |
| `LQC_INSP_DOCU` | 실적검사 디테일(검사내역) | 18 |

**재고/수불** (32)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LADJUST` | 재고조정헤더 | 27 |
| `LADJUST_D` | 재고조정상세 | 34 |
| `LADJUST_TEMP` | 재고조정_TEMP | 29 |
| `LDISJOIN` | 해체조정등록 헤더 | 25 |
| `LDISJOIN_D` | 해체조정등록 디테일 | 22 |
| `LDISJOIN_D_LS` | 품목(규격)대체처리상세 | 46 |
| `LDISJOIN_LS` | 품목(규격)대체처리 | 45 |
| `LDISJOIN_SCRAP` | 품목(규격)대체처리(스크랩) | 13 |
| `LDIVMOVE` | 사업장이동_HEADER | 29 |
| `LDIVMOVE_D` | 사업장이동_DETAIL | 25 |
| `LDIVMOVE_D_LS` | 사업장이동처리상세(규격정보) | 46 |
| `LINVINSP` | 재고실사 | 25 |
| `LINVINSP_D` | 재고실사 | 21 |
| `LINVINSP_D_WIP` | 재공실사 디테일 | 16 |
| `LINVINSP_EXCEL_TEMP` | 재고실사(EXCEL IMPORT) | 23 |
| `LINVINSP_TEMP` | 재고실사 IF 테이블 | 24 |
| `LINVINSP_WIP` | 재공실사 헤더 | 19 |
| `LINVOPENW` | 재공초기이월 | 22 |
| `LINVOPEN_LS` | 재고이월(규격정보) | 41 |
| `LINV_MVFIFO` | 재고조정_HEADER | 38 |
| `LINV_MVFIFO_WK` | 재고조정_HEADER | 32 |
| `LINV_TAV` | 재고평가 | 30 |
| `LINV_TAV_DT` | 일별재고평가 | 8 |
| `LSTKMOVE_D_LS` | 재고이동처리상세(규격정보) | 46 |
| `LSTKMOVE_TEMP` | 재고이동 EXCEL IMPORT 중간테이블 | 7 |
| `LX_DIV_W` | 사업장별현재공집계 | 7 |
| `LX_LC_LS` | 규격형 장소별 재고집계 | 45 |
| `LX_LC_W` | 작업장별현재공집계 | 9 |
| `LX_LINVTORY_LS` | 규격형 재고관리 | 45 |
| `LX_LOTLC_LS` | 규격형 장소별 LOT재고집계 | 46 |
| `LX_PJT_W` | 프로젝트별현재공집계 | 10 |
| `LX_WH_W` | 공정별현재공집계 | 8 |

**기준/기타** (8)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `LCTRL_MTL` | 기초정보_시스템통제DATA(물류) | 15 |
| `LEXIMPORT_MGM` | 기초정보_EXCEL IMPORT_항목정보 | 34 |
| `LSSTD_UM` | 기초정보_생산표준원가등록 | 39 |
| `LSSTD_UM_LS` | 규격형 표준원가 | 59 |
| `LSTANDARD` | 규격등록 | 15 |
| `LSTANDARD_COLUMNS` | 규격등록(규격기본명칭설정) | 11 |
| `LSTANDARD_D` | 규격등록(사용자정의관리항목) | 13 |
| `LSTANDARD_SITEM` | 품목등록(규격설정) | 13 |

### 시스템 (84)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `SACBANKD` | 전표발행_하단 | 68 |
| `SACBANKH` | 전표발행_상단 | 47 |
| `SACCOUNT_BANK` | 은행계좌관리 | 54 |
| `SACCOUNT_BANK_SECURITY` | 계좌/카드별 사용자권한 | 3 |
| `SACCT` | 계정과목코드 | 65 |
| `SACCTFG` | 계정구분2 | 5 |
| `SACCTFGL` | 계정구분 | 6 |
| `SACCTGR` | 계정그룹지정 | 34 |
| `SACCT_FG` | 계정구분 맵핑 | 13 |
| `SBANK` | 금융기관 | 8 |
| `SBANKE` | 은행/카드 | 5 |
| `SBASELOC` | 창고공정마스터테이블 | 19 |
| `SBEBGONG` | 법정동테이블 | 8 |
| `SBILL` | 받을어음테이블 | 40 |
| `SBILL_D` | 받을어음 디테일 | 14 |
| `SBOM` | BOM 등록 | 21 |
| `SBOM_LS` | BOM등록(규격형) | 86 |
| `SBOM_REVISION` | BOM변경이력관리 헤더 | 16 |
| `SBOM_REVISION_D` | BOM변경이력관리 디테일 | 30 |
| `SBOM_REVISION_D_LOCATION` | BOM변경이력관리 LOCATION | 15 |
| `SCLOSE` | 마감처리 | 14 |
| `SCLOSE_IFRS` | IFRS 회계마감처리 | 7 |
| `SCO` | 회사등록 | 62 |
| `SCOUNTRY` | 국가(국세청) | 3 |
| `SCREDIT_DC` | 등급설명 | 5 |
| `SCTRL` | 관리내역상위 | 21 |
| `SCTRL_D` | 관리내역 디테일 | 23 |
| `SDATA_CHECK` | 데이터 체크 | 11 |
| `SDATA_CHECK_REPORT` | 데이터 체크 히스토리 | 9 |
| `SDBCFG` | DB환경설정 | 25 |
| `SDEPT` | 부서등록 | 18 |
| `SDIV` | 사업장등록 | 57 |
| `SDIVGR` | 사업장 그룹등록 | 5 |
| `SDIVGR_D` | 사업장 그룹등록 디테일 | 4 |
| `SECURITY` | 사용자권한설정 | 17 |
| `SEMAIL_MSG` | 이메일내용저장 | 7 |
| `SEMP` | 사원등록 | 143 |
| `SENCRYPT` | 개인정보암호화 헤더 | 11 |
| `SENCRYPT_D` | 개인정보암호화 디테일 | 15 |
| `SENCRYPT_HISTORY` | 암호화 이력관리 | 8 |
| `SEXIMPORT_MGM` | Excel Import 컬럼명세 양식 | 38 |
| `SHCFG` | 사회보험환경등록 | 83 |
| `SHMEMO` | 인사메모현황 | 13 |
| `SITEM` | 품목등록 | 160 |
| `SITEMGRP` | 관리내역 | 15 |
| `SITEM_ETC` | 해외품목등록 | 15 |
| `SITEM_LS` | 품목별표준규격등록 | 43 |
| `SJEONJA_IDPW` | 전자세금계산서 로그인 | 4 |
| `SJEONJA_ST` | 전자세금계산서발행이력 | 10 |
| `SLABELPRT` | 라벨출력 관리 테이블 | 20 |
| `SLOC` | 장소작업장마스터테이블 | 19 |
| `SLOTAXGUBUN` | 주민세개인법인구분 | 9 |
| `SM2MOD` | 모듈정보(구) | 6 |
| `SM3MOD` | 모듈정보 | 9 |
| `SMEMO` | 메모 | 3 |
| `SMENU_APP` | 전자결재사용권한설정 | 13 |
| `SMENU_INFO` | 메뉴관련 정보 1분동영상 주석 정보 | 9 |
| `SMENU_SUB` | 관련메뉴 | 15 |
| `SMENU_UNUSE` | 회사 유형별 메뉴설정 | 7 |
| `SM_TYPE` | 재물분류항목등록_중분류_테이블 | 10 |
| `SPCFG` | 서비스팩환경설정 | 9 |
| `SPCFG_MENU` | 서비스팩관련메뉴 | 9 |
| `SPJT` | 프로젝트등록 | 42 |
| `SPJTGRP` | 프로젝트분류등록 | 17 |
| `SPJT_D` | 프로젝트 사원권한 테이블 | 18 |
| `SPJT_TEMP` | 프로젝트 중간테이블 | 25 |
| `SPOST` | 우편번호 | 12 |
| `SRMKCD` | 적요코드명 | 16 |
| `SSECT` | 부문등록 | 16 |
| `SSESMGM_D` | 업그레이드 세션 | 1 |
| `SSESMGM_H` | 업그레이드 세션 | 1 |
| `SS_TYPE` | 재물분류항목등록_소분류_테이블 | 11 |
| `STAXO` | 관할세무서 | 6 |
| `STRADE` | 거래처 | 123 |
| `STRADEGRP` | 거래처분류테이블 | 17 |
| `STRADE_EMPGRP` | 거래처 고객담당그룹 | 17 |
| `STRADE_REC` | 거래처상세(고객담당) | 36 |
| `STRADE_SMPP` | 거래처 기업성격 | 13 |
| `STRADE_TEMP` | 거래처중간테이블 | 80 |
| `SUSER_MAKE_CONTROL` | 사용자정의메뉴_컨트롤정보 | 12 |
| `SUSER_MAKE_MENU` | 사용자정의메뉴_메인 | 20 |
| `SUSER_MAKE_MENU_INFO` | 사용자정의메뉴_메뉴정보 | 3 |
| `SWHAGENT` | 제출자정보 | 14 |
| `SYSCFG` | 시스템환경설정 | 24 |

### 회계 (186)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `ABILLDEB` | 지급어음 | 28 |
| `ABILLDEB_D` | 지급어음 디테일 | 12 |
| `ACARD_CHUNGGU` | 법인카드청구PKG | 28 |
| `ACARD_SALE` | 카드매출 | 22 |
| `ACARD_SUNGIN` | 법인카드승인PKG | 41 |
| `ACARD_SUNGIN_TEMP` | 법인카드승인EXCEL IMPORT PKG | 18 |
| `ACASHCD` | 자금과목 | 15 |
| `ACASHDP` | 자금계획입력 | 24 |
| `ACASHFIX` | 고정자금입력 | 20 |
| `ACASHLINK` | 자금수지입출금과목 | 7 |
| `ACATALOG` | 자산업종코드 | 4 |
| `ACCTLINKD` | 연결계정 디테일(출력용) | 11 |
| `ACCTLINKH` | 연결계정 헤더(출력용) | 11 |
| `ACCT_D` | 연동항목 | 5 |
| `ACFCD` | 현금흐름표과목 | 13 |
| `ACFCD_GAAP` | K-GAAP용 현금흐름표과목 | 15 |
| `ACFCD_GAAP_D` | K-GAAP용 현금흐름표과목 계정연결 | 9 |
| `ACFCD_IFRS` | IFRS용 현금흐름표과목 | 15 |
| `ACFCD_IFRS_D` | IFRS용 현금흐름표과목 계정연결 | 9 |
| `ACFLOW` | 현금흐름표 | 12 |
| `ACFLOW_GAAP` | K-GAAP용 현금흐름표 | 10 |
| `ACFLOW_IFRS` | IFRS용 현금흐름표 | 10 |
| `ACOMBICD` | 중분류 등록 | 17 |
| `ACOMBIGR` | 대분류등록 | 15 |
| `ACOMBIITEM` | 중분류계정설정등록 | 12 |
| `ACORPCARD` | 국세청 사업용 신용카드 | 32 |
| `ACORP_ACCT` | 국세청사업용신용카드 전표분개설정 버튼 | 6 |
| `ACOTAX_EFFECT` | 포괄손익계산서 법인세효과 | 12 |
| `ACTPRT_TEMP` | 공급자등록 | 16 |
| `ADATA_CHECK` | 데이터체크 | 12 |
| `ADATA_CHECK_REPORT` | 데이터체크 일괄변경 저장 | 6 |
| `ADOCUD` | 전표 디테일 | 79 |
| `ADOCUD_IFRS` | IFRS용 전표입력 디테일 | 73 |
| `ADOCUH` | 전표입력 헤더 | 36 |
| `ADOCUH_IFRS` | IFRS용 전표입력 상단 | 34 |
| `ADOCUH_KEY` | 결의일자/번호저장테이블 | 3 |
| `ADOCUSEQ` | 승인전표 년/월별순번 | 11 |
| `ADPREM` | 고정자산월상각테이블 | 19 |
| `ADPREM_IFRS` | IFRS 고정자산 월상각 | 17 |
| `ADPREY` | 고정자산년상각테이블 | 23 |
| `ADPREY_IFRS` | IFRS 고정자산 년상각 | 28 |
| `ADSUM` | 일집계화일 | 7 |
| `ADSUM_IFRS` | IFRS용 일집계 | 7 |
| `AEBANK_COLLECT` | 집금테이블PKG | 27 |
| `AEBANK_TRAN` | 거래구분PKG | 4 |
| `AEXCH` | 환종 | 3 |
| `AFOREIGN` | 외국인관광객면세물품판매및환급실적명세서 | 21 |
| `AFSCCFG` | 원가종류 | 6 |
| `AFSCHANGES` | 자본변동표 | 14 |
| `AFSCHANGES_ACCT` | 자본변동표 계정설정 | 4 |
| `AFSCHANGES_ACCT_IFRS` | IFRS자본변동표 계저설정 | 4 |
| `AFSCHANGES_IFRS` | IFRS자본변동표 | 12 |
| `AFSCLSACCT` | 결산자료계정 | 10 |
| `AFSCLSACCT_IFRS` | IFRS결산자료계정 | 10 |
| `AFSCLSD` | 결산자료입력 | 24 |
| `AFSCLSD_D` | 결산자료입력 입력_분개대상금액 | 15 |
| `AFSCLSEDIT` | 결산자료입력타이틀 | 11 |
| `AFSCLSEDIT_IFRS` | IFRS결산자료입력타이틀 | 2 |
| `AFSDEF` | 기본양식 | 3 |
| `AFSDEF_I` | 중국용 기본 양식 | 3 |
| `AFSDEF_IFRS` | IFRS용 기본 양식 | 3 |
| `AFSEDIT` | 원가보고서항목 | 9 |
| `AFSFRACCT` | 양식그룹 | 8 |
| `AFSFRCALC` | 그룹별계산 귀속그룹등록 | 4 |
| `AFSFRG` | 양식그룹등록 | 21 |
| `AFSFRSJ` | 회사별 양식제목설정 | 8 |
| `AFSFRSJ_I` | 중국용 회사별 양식제목설정 | 8 |
| `AFSFRSJ_NP` | 비영리용 회사별 양식제목설정 | 7 |
| `AFSINIT` | 전기재무제표 | 14 |
| `AFSINVENTORY` | 재고자산표시 | 6 |
| `AJEONJA_DEMAND` | 전자청구서발행 | 79 |
| `AJEONJA_DEMAND_ACCTLINK` | 전자청구 분개유형 설정 | 11 |
| `AJEONJA_DEMAND_DOCUD` | 전자청구 분개 | 22 |
| `ALEND` | 대여금 | 42 |
| `ALEND_D` | 대여금 회수 | 11 |
| `ALINK_DAILY_D` | 일일데이터전송연결디테일 | 3 |
| `ALINK_DAILY_H` | 일일데이터계정연결헤더 | 12 |
| `ALINK_KDBI` | 재무제표전송 계정연결 | 5 |
| `ALINK_KDBI_HELP` | 재무제표계정미연결코드도움 | 3 |
| `ALOAN` | 차입금 | 52 |
| `ALOAN_D` | 차입금 상환 | 11 |
| `ALOCALTAX` | 내국신용장 | 2 |
| `AMODIFY_NAME` | 전자세금계산서 수정사유 | 2 |
| `ANIMAL` | 동물진료용역매출명세서 | 16 |
| `AORIGIN` | 원산지확인서 발급세액공제신고서(갑) | 11 |
| `AORIGIN_D` | 원산지확인서 발급세액공제신고서(을) | 16 |
| `APAYMENTD` | 지급이체테이블 하단 | 23 |
| `APAYMENTH` | 지급이체테이블 상단 | 29 |
| `APAYMENTSBJ` | 지급데이터작성조건 상단 | 26 |
| `APAYMENTSBJ_D` | 지급데이터작성조건 하단 | 5 |
| `APJTDISP` | PJT별 원가명세서 | 13 |
| `APJTDISP_ACCTRATIOH` | 계정과목별 안분비율 | 4 |
| `APJTDISP_ACCTRT` | 계정과목별 안분율 설정 | 4 |
| `APJTDISP_ACCTRTH` | 계정과목별 안분비율헤드 | 3 |
| `APJTDISP_GIJUN` | PJT별 원가명세서 안분방법 | 9 |
| `APJTDISP_MGIJUN` | PJT별 원가명세서 자동안분 계산 | 13 |
| `APJT_PL_ACCTGIJUN` | PJT별 손익안분명세 안분과목 | 7 |
| `APJT_PL_DISP_D` | PJT별 손익안분명세 | 3 |
| `APJT_PL_GIJUN` | 손익안분기준설정 | 5 |
| `APJT_PL_MGIJUN` | 안분계산계산값 | 5 |
| `APLUSACCT` | 세무조정환경설정 계정연결 | 3 |
| `APMPROXY` | 대리납부신고서(사업자양수자용) | 17 |
| `APREV` | 회계초기이월 | 53 |
| `APREV_D` | 초기이월 재무제표 | 15 |
| `APREV_D_IFRS` | IFRS용 초기이월 재무제표 | 15 |
| `APREV_IFRS` | IFRS 초기이월 | 52 |
| `APREV_PJT` | PJT별 초기이월 | 10 |
| `APROFIT` | 이익잉여금처분계산서 | 15 |
| `APROFIT_IFRS` | IFRS용 이익잉여금처분계산서 | 15 |
| `ASSET` | 고정자산등록 | 49 |
| `ASSETBARCFG` | 바코드프린터설정 | 6 |
| `ASSETCD_FORM` | 자산코드 사용자정의 | 12 |
| `ASSETCD_REG` | 사용자정의 코드등록 | 20 |
| `ASSETCFG` | 자산실사 미처리, 미실사, 정상처리 이력테이블 | 10 |
| `ASSETRT` | 상각률 | 4 |
| `ASSET_ADD` | 자산 마스터 | 62 |
| `ASSET_ADD_CFG` | 고정자산 기본정보 설정 | 7 |
| `ASSET_ADD_EXCEL` | 자산 엑셀 임포트 | 42 |
| `ASSET_ADD_LABEL_CONFIG` | 자산 라벨 설정 | 34 |
| `ASSET_ADD_PRN_CONFIG` | 자산 라벨 항목 설정 | 21 |
| `ASSET_ADD_SUB` | 자산 세부데이터 | 28 |
| `ASSET_CTRL_IFRS_D` | IFRS 자산유형설정 디테일 | 14 |
| `ASSET_CTRL_IFRS_H` | IFRS 자산유형설정 헤더 | 11 |
| `ASSET_D` | 고정자산 추가등록 | 21 |
| `ASSET_DAMAGE_IFRS` | IFRS 고정자산 손상등록 | 18 |
| `ASSET_D_EXCEL` | 고정자산 추가등록 EXCEL IMPORT | 20 |
| `ASSET_D_IFRS` | IFRS 고정자산 변동등록 | 18 |
| `ASSET_EXCEL` | 고정자산EXCEL IMPORT | 31 |
| `ASSET_IFRS` | IFRS 고정자산 마스터 | 27 |
| `ASSET_IFRS_EXCEL` | IFRS 고정자산 EXCEL IMPORT | 25 |
| `ASSET_RCV_DATA` | 데이터 수신 임시테이블 | 7 |
| `ASSET_REVAL_IFRS` | IFRS_고정자산재평가 등록 | 14 |
| `ATAX` | 부가세 | 64 |
| `ATAXCARD` | 신용카드발행집계표,수취명세 | 32 |
| `ATAXSUM` | 계산서/세금계산서합계표 | 36 |
| `ATAX_EXCEL` | 부가세엑셀업로드 | 23 |
| `ATAX_ITEM` | 부가세 품목 | 16 |
| `ATAX_JEONJA_TEMP` | 전자세금계산서다운로드 | 89 |
| `ATAX_P` | 부가세 디테일 | 45 |
| `ATAX_TEMP` | 매입매출장 EXCEL IMPORT | 15 |
| `ATBLAPPO` | 카드매입_승인_카드사 | 33 |
| `ATBLAPPOBUY` | 카드매입_매입결과_카드사 | 21 |
| `ATBLCFAPPODE` | 카드매출(승인_여신) | 14 |
| `ATBLCFBUYDE` | 카드매출(매입결과_여신) | 19 |
| `ATBLCLOSE` | 휴폐업조회 | 8 |
| `ATBLCSCARDBUY` | 카드매입결과_국세청현금영수증 | 23 |
| `ATBLTRAN` | 통장거래내역 | 15 |
| `ATERMCOST` | 기간비용현황 | 30 |
| `ATERMCOST_D` | 기간비용현황 디테일 | 19 |
| `ATOTAC` | 통합계정설정 | 8 |
| `ATOTRL` | 통합계정연결 | 10 |
| `ATTACH_ST` | 명세서 | 8 |
| `ATYSUM` | 관리항목집계 | 9 |
| `ATYSUM_IFRS` | IFRS용 관리항목집계 | 9 |
| `AVASSET` | 건물등감가상각취득명세서 | 4 |
| `AVASSET2` | 건물등감가상각자산취득명세서 | 7 |
| `AVATRPT` | 부가가치세신고서 | 24 |
| `AVBIL` | 대손세액공제신청서 | 19 |
| `AVDEDUCT` | 전자신고세액공제신청서 | 17 |
| `AVDISUSE` | 재활용폐자원세액공제신고서 | 33 |
| `AVDISUSESUM` | 재활용폐자원세액공제신고서_집계 | 3 |
| `AVDIV_D` | 주(총괄납부)사업장등록 디테일 | 4 |
| `AVDIV_H` | 주(총괄납부)사업장등록 헤더 | 3 |
| `AVDRAWBACK` | 관세환급금등명세서 | 16 |
| `AVEST` | 부동산임대공급가액명세서 | 28 |
| `AVEST_EXCEL` | 부동산임대공급가액명세서 EXCEL IMPORT | 27 |
| `AVEXPO` | 수출실적명세서 | 26 |
| `AVFOREIGN` | 외국인물품(외교관면세)판매기록표 | 26 |
| `AVFOREOBTAIN` | 외화획득명세서 | 21 |
| `AVFTAX` | 영세율첨부서류 | 20 |
| `AVGURI` | 구리스크랩명세 | 29 |
| `AVGURISUM` | 구리스크랩 신고서 합계 | 23 |
| `AVINCOME` | 수입금액명세서(구) | 28 |
| `AVJEONJA` | 전자신고첨부서식목록 | 11 |
| `AVMONSALE` | 월별판매액합계표 | 4 |
| `AVNON2` | 매입세액불공제내역 | 27 |
| `AVREGARD` | 의제매입세액공제신고서_매입내역 | 36 |
| `AVREGARDSUM` | 의제매입세액공제신고서_집계 | 4 |
| `AVSTRREV` | 과표 수정신고서 및 추가자진납부계산서, 과표 및 세액 결정(경정)청구서 | 1 |
| `AVTOTDIV` | 사업장별과표 및 세액신고서 | 3 |
| `AVTOTDIV3` | 사업다단위과세 사업장별세액명세서 | 23 |
| `AVTOTRL` | 부가세계정등록 | 3 |
| `AVTRAN` | 사업양도신고서 | 21 |
| `AZEROTAX` | 영세율매출명세서 | 8 |
| `AZEROTAX_FORM` | 영세율매출서식 | 3 |
| `AZEROTAX_MAP` | 영세율매출연결서식 | 3 |

### 인사 (218)

| 테이블 | 한글명 | 컬럼수 |
|---|---|---:|
| `HACCTSUM` | 계정과목집계 | 8 |
| `HBANK` | 은행 | 4 |
| `HBIZFM` | 기부금명세 | 23 |
| `HBIZIN` | 사업소득연말정산 주현근무지자료 | 54 |
| `HBIZJOB` | 사업소득연말정산 종전근무지자료 | 21 |
| `HBIZOUT` | 사업소득 연말정산결과 | 49 |
| `HBIZ_FAMILY` | 사업소득자 가족정보 | 16 |
| `HBMFMLY` | (구)사업소득자가족 | 14 |
| `HBTRIBT` | 사업소득자기부금명세(구) | 17 |
| `HCERNUM` | 증명서발급기준 | 24 |
| `HCERTIFY` | 증명서발급 | 20 |
| `HCTRIBT` | 기부금명세 | 29 |
| `HCTRIBT2` | 사업소득기부금명세 | 26 |
| `HCTRIBT3` | 기부금조정명세 | 20 |
| `HCTRIBT3_D` | 기부금조정명세_공제금액계산 | 21 |
| `HCTRIBT4` | 사업소득 기부금조정명세 | 21 |
| `HDAYPAYDT` | 일용직급여지급일 | 15 |
| `HDAYSUM` | 일용급여집계 | 33 |
| `HEARNER` | 사업/기타/이자배당소득자 | 48 |
| `HEDUINFO` | 교육관리 | 23 |
| `HEDUPER` | 사원별교육정보 | 24 |
| `HEISPAY` | 수당등록 | 3 |
| `HEITAXTABLE` | 간이세액테이블 | 5 |
| `HELMEDM` | 전산매체자릿수 | 12 |
| `HELMEDS` | 전산매체내역 | 11 |
| `HENOTAX` | 연말정산 비과세 | 6 |
| `HFAMILY` | 연말정산 부양가족명세 | 97 |
| `HFAMLSN` | 연말정산인적공제 | 29 |
| `HFIXPAY` | 책정임금일괄변경 | 13 |
| `HFOODCODE` | 식수코드등록 | 17 |
| `HFOODDATA` | 식수데이타 등록 | 17 |
| `HFOODSUM` | 식수데이터집계 | 16 |
| `HFOOD_TXT` | 식수TXT데이터 | 13 |
| `HFOT_OPT` | 근태대장출력항목 | 5 |
| `HHCPYST` | 호봉테이블 | 14 |
| `HHCPYST_MP` | 월별호봉승급 | 16 |
| `HHFAACC` | 출결마감기준일 | 11 |
| `HHISTORY` | 사원이력정보 | 14 |
| `HHMBTIF` | 출장정보 | 14 |
| `HHMCPIF` | 동호회정보 | 8 |
| `HHMCRER` | 경력사항 | 12 |
| `HHMEDIF` | 교육정보 | 8 |
| `HHMEPAD` | 인사기록카드상세정보 | 89 |
| `HHMFMLY` | 가족정보 | 35 |
| `HHMFMLY_SHC` | 가족수당 | 12 |
| `HHMGTIS` | 보증보험 | 9 |
| `HHMIDWT` | 인보증 | 12 |
| `HHMLSCT` | 자격면허 | 11 |
| `HHMPPVS` | 여권비자정보 | 11 |
| `HHMSCIF` | 학력정보 | 17 |
| `HHOAATP` | 인사발령대상자 | 17 |
| `HHOAATP_D` | 발령내역및사원이력관리 | 18 |
| `HHOANAP` | 인사발령헤더 | 15 |
| `HHRSTAT` | 인원통계 | 24 |
| `HICHICT` | 건강보험보수월액표 | 14 |
| `HICHSE` | 사회보험등급변경 | 18 |
| `HIFISCG` | 사회보험사업장정보 | 34 |
| `HIFNPCT` | 국민연금보수월액표 | 14 |
| `HIHPTRG` | 조별근무시간 | 39 |
| `HIHTMRG` | 조별정산시간등록 | 21 |
| `HINCOME` | 사업/기타/이자배당소득 | 58 |
| `HINITECH` | 대출신청 | 13 |
| `HIREDIF` | 개산보험신고서 | 31 |
| `HIREIFR_D` | 개산보험신고서임금총액 | 10 |
| `HIRIDIF` | 고용산재보험신고서 | 66 |
| `HIRTRDN` | 고용보험이직확인서 | 58 |
| `HISTORY` | 자산 실사 이력테이블 | 21 |
| `HLNOTAX` | 연말정산결과비과세 | 5 |
| `HLTAXCODE` | 법정동테이블 | 5 |
| `HMEDICAL` | 연말정산의료비명세 | 24 |
| `HMRMATL` | 월차관리 | 26 |
| `HNONTAXCD` | 비과세코드 | 11 |
| `HNONTAXUSER` | 비과세코드설정 | 8 |
| `HNOTAX` | 급여비과세 | 11 |
| `HNTCODE` | 비과세코드 | 8 |
| `HORGTBT` | 조직도 | 10 |
| `HPASTAT` | 통계리포트 | 27 |
| `HPAYDATE` | 급여지급연월 | 3 |
| `HPAYEXP_D` | 수당,경비설정 디테일 | 12 |
| `HPAYEXP_H` | 수당, 경비설정 헤더 | 11 |
| `HPAYGROUP_D` | 급여명세 그룹설정_테이블 항목 | 18 |
| `HPAYGROUP_H` | 급여명세 그룹설정_테이블그룹 | 18 |
| `HPAYMENTD` | 급/상여이체자료처리_디테일 | 22 |
| `HPAYMENTH` | 급/상여이체자료처리 | 23 |
| `HPDUP_TEMP` | 급여수당일괄업로드(신) | 17 |
| `HPEFEMA_H` | 고과정보 | 14 |
| `HPENSION` | 연금저축명세(근로소득) | 19 |
| `HPENSION2` | 연금저축명세서(사업연말) | 19 |
| `HPFCFGC` | 분류계산코드 헤더 | 14 |
| `HPFCFGC_D` | 지급공제항목등록 분류계산코드_디테일 | 24 |
| `HPFLBCT` | 근로소득연말정산소득공제조견표 | 9 |
| `HPFLICH` | 근로소득세액공제조견표 | 10 |
| `HPFSTIA` | 간이세액 수입금액조정 | 8 |
| `HPFTITC` | 근로소득 기본세율 조견표 | 9 |
| `HPFTITC_HDAY` | 일용직 기본세율조견표 | 9 |
| `HPHFXPD` | 책정임금내역 | 14 |
| `HPHONPD` | 급여지급구분 | 17 |
| `HPHPOYM` | 지급대상년월 | 14 |
| `HPHPYFQ` | 급상여지급일자 등록 | 17 |
| `HPHWTPT` | 지급직종및급여형태 | 22 |
| `HPITMDD` | 근태공제내역 | 21 |
| `HPITMPD` | 근태지급내역 | 21 |
| `HPMABLB` | (구)연말정산 국외근로자료 | 15 |
| `HPMABPT` | (구)연말정산 외국납부세액 | 16 |
| `HPMBFOC` | 연말정산근무처별소득내역 | 54 |
| `HPMBIBO` | 사업연말근무처별소득정보 | 25 |
| `HPMBNIN` | (구)사업소득자 | 29 |
| `HPMBNIN_D` | 사업소득지급내역 | 22 |
| `HPMETIC` | (구)기타소득자 | 36 |
| `HPMETIC_D` | 기타소득지급내역 | 40 |
| `HPMFLTE` | (구)외국인근로자 세액감면 | 15 |
| `HPMLBEC` | 연말정산명세 | 78 |
| `HPMLNIF` | 대출정보 | 9 |
| `HPMPDFM` | 급여지급구분 | 40 |
| `HPMPXTX` | 세무대리인 | 14 |
| `HPMSVIF` | 저축 | 10 |
| `HPOBIEC` | 사업소득연말정산결과 | 37 |
| `HPOLBEC` | 연말정산추가자료입력 | 203 |
| `HPOMNPY` | 급여집계 | 85 |
| `HPOMNPY_DELETE` | 급여삭제로그 | 10 |
| `HPOMPDD` | 급여공제 | 25 |
| `HPOMPPD` | 급여지급 | 27 |
| `HPOPRIT` | 출력항목 | 12 |
| `HPOTLPM_D` | 일용직급여내역 | 46 |
| `HPRINTID` | 출력물설정 | 4 |
| `HPRIPEN` | 상벌관리 | 13 |
| `HPRLBEC` | 연말정산결과 | 135 |
| `HPRLBEC_200806` | 연말정산명세 | 10 |
| `HPRLBEC_20090121` | 연말정산명세 | 10 |
| `HPRLBEC_200908` | 연말정산명세 | 10 |
| `HPRLTPR` | 고용산재개산보험신고서 임금총액탭 | 12 |
| `HPRWPMA` | 원천세신고서 | 6 |
| `HPRWPSR` | 원천세신고서 | 20 |
| `HPRWPSR_D` | 원천세신고상세 | 18 |
| `HPRWPSR_S` | 전자신고 | 5 |
| `HPSACCT` | 계정과목설정 | 8 |
| `HPSPBCO` | 주민세특별징수계산서 | 11 |
| `HPSPBEC` | 주민세특별징수명세서 | 10 |
| `HPSPBEC_SUB` | 주민세특별징수명세서 | 9 |
| `HPSTOTCD` | 환경등록(지급공제 집계) | 11 |
| `HREAL_CNT` | 연도별인원 | 5 |
| `HREAL_DVS` | division등록 | 3 |
| `HREAL_SEMP` | 사원테이블 | 2 |
| `HREAL_TMP` | 임시직등록 | 16 |
| `HRECOMD` | 추천 | 12 |
| `HREFUNDD_CODY` | 퇴직연금_CODY | 13 |
| `HREFUNDH_CODY` | 퇴직연금 납입일자 | 11 |
| `HRENT` | 월세액등명세서 | 31 |
| `HREPROAP` | 누진테이블 | 11 |
| `HRESTDT` | 휴직테이블 | 16 |
| `HRETIRE1` | 퇴직금주(현)근무지 | 101 |
| `HRETIRE1_D` | 퇴직금지급항목 | 13 |
| `HRETIRE2` | 퇴직종전근무지 | 46 |
| `HRETIRE3` | 과세이연계좌 | 9 |
| `HRETURN` | 원천징수세액환급신청서 | 10 |
| `HRFCWPM` | 근속누진 | 5 |
| `HRFECPM` | 임원누진 | 5 |
| `HRFRIDT` | 퇴직소득공제조견표 | 9 |
| `HRFRPSC` | 퇴직기준설정 | 54 |
| `HRFRPSC_P` | 퇴직기준설정_개인별 | 40 |
| `HRMRPDC` | 퇴직금공제항목 | 10 |
| `HRMRPPC` | 퇴직금지급항목 | 10 |
| `HRORPET` | 퇴직금추계코드등록 | 20 |
| `HRORPET_D` | 퇴직금추계코드등록 | 31 |
| `HRORTBO` | 퇴직종전근무지 | 40 |
| `HRPAYIT` | 퇴직금급여내역 | 18 |
| `HRPAYIT2` | 퇴직금급여상여연차지급내역 | 16 |
| `HRPLIST` | 급여상여지급항목 | 4 |
| `HRTCODE` | 사업기타지급공제항목설정 | 8 |
| `HSEMP_CUST` | 사원정보 전용개발 항목 | 9 |
| `HSHLINS` | 사회보험취득신고서 | 33 |
| `HSHREAR` | 건강보험피부양자신고서 | 19 |
| `HSIMULD` | 급여시뮬레이션기준등록 | 9 |
| `HSIMULDD` | 급여시뮬레이션결과 | 13 |
| `HSIMULM` | 급여시뮬레이션코드등록 | 10 |
| `HSK_LOAN_D` | 월상환스케쥴 | 11 |
| `HSK_LOAN_H` | 사원별대출정보등록 | 10 |
| `HSLOREG` | 국민고용상실신고서 | 22 |
| `HSLPECA` | 국민연금취득신고서 | 19 |
| `HSMARTYEAR` | 스마트연말정산관리 | 15 |
| `HSOINDE` | 사회보험관리 | 22 |
| `HSPERINFO` | 개인정보출력설정 | 22 |
| `HSREIFR` | 고용보험취득신고서 | 24 |
| `HSRTPRT` | 건강보험상실신고서 | 31 |
| `HTABLE_COPY` | 테이블복사 | 17 |
| `HTAXDEDUCT` | 퇴직금세액공제 | 12 |
| `HTAXDEDUCT2` | 퇴직금세액공제 | 13 |
| `HTDFOOD` | 식수관리 | 1 |
| `HTFRTTF` | 식사휴식시간등록 | 15 |
| `HTFTMRG` | 근무시간등록 | 25 |
| `HTFTMRG_D` | 분처리기준설정 | 15 |
| `HTHPWRG` | 월별근무조건등록 | 44 |
| `HTHPWRG_T` | 월별근무조건등록TEMP | 42 |
| `HTOBRCD_N` | 출입카드하단전송데이터 | 13 |
| `HTOBRCD_N_T` | 출입카드상단데이터 | 12 |
| `HTOBRCD_TXT` | 바코드원시데이터 | 10 |
| `HTOCLED` | 근태카렌다 | 21 |
| `HTOFOOD` | 식수 | 1 |
| `HTOPACR` | 개인별출결조정 | 68 |
| `HTOPRIT` | 근태대장출력항목 | 11 |
| `HTOPRIT2` | 근태출력항목 | 8 |
| `HTORPEC` | 퇴직금정산 | 81 |
| `HTORPEC_D` | 퇴직금지급내역 | 16 |
| `HTOSTAT` | 통계리포트코드 | 25 |
| `HTOWEEK` | 구.주간근태 | 5 |
| `HTOWTDR` | 근무일시간결과 | 25 |
| `HTOWTRT` | 근태결과 | 24 |
| `HTX_TAXDATA_D` | 간소화 디테일 | 58 |
| `HTX_TAXDATA_H` | 간소화헤더 | 26 |
| `HYRMATL` | 연차관리 | 37 |
| `HYRMATL_D` | 월별사용연차 | 11 |
| `HYRMATL_H` | 월별사용연차헤더 | 14 |
| `HYUDANL` | 1년미만 입사자 연차관리 | 25 |
| `IBK_ERP_ICHE_DATA` | 기업은행 지급이체자료전송 | 22 |
| `IB_IBPS` | 중국신한업무구분 | 6 |
| `INHABIT_H` | 주민세특별징수신고서 | 33 |
| `INT_I_CORP_AREA` | 마스터정보 | 1 |
| `INT_O_BIZ_AREA` | 사업자등록번호 | 9 |
