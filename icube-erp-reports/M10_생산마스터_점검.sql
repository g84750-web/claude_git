/*==============================================================================================
  [ iCUBE ] M-10 예외재공 처리 현황  +  M-12 BOM 정합성 점검                         (Rev.1)
  ----------------------------------------------------------------------------------------------
  목적 : **상시 점검.** 생산 데이터가 정상 경로로 흐르고 있는지 본다.
           M-10  예외 재공 처리 (`LWIPIO.MAP_FG` 7~9) — 정상 매핑을 벗어난 재공 처리
           M-12  BOM 정합성 — BATCH BOM 불일치, 소요량 이상, 단위 불일치

  DBMS : MS-SQL Server (T-SQL)

  ----------------------------------------------------------------------------------------------
  [ B-02 와의 분담 ]
  ----------------------------------------------------------------------------------------------
     `B02_마스터점검팩.sql` 이 **BOM 미등록 · 순환참조 · 레벨 과다** 를 본다 (구조 문제).
     이 파일은 **BOM 내용의 정합성** 을 본다 (값 문제).
       · BATCH BOM(`SBOM_WF_B`) 과 `SITEM.FOQ_QT` 불일치
       · 소요량 0 / 음수 / 비정상
       · 모품목·자품목 단위 불일치
       · BOM 소요량 vs 실제 사용량 괴리

  ----------------------------------------------------------------------------------------------
  [ ★ MAP_FG 규칙 (재공처리) ]
  ----------------------------------------------------------------------------------------------
     1~3  실적별       정상 — 생산실적에 연동된 재공 처리
     4~6  지시별       정상 — 지시 투입자재 기준 재공 처리
     7~9  **예외**     비정상 — 수동 개입. 많으면 재공 데이터를 믿을 수 없다

     `WIP_NB` 접두 : WI 재공입고 / WM 재공이동 / **WA 재공조정**
     `WA` + `MAP_FG 7~9` 조합이 가장 위험하다 (근거 없는 수동 조정).
==============================================================================================*/

SET NOCOUNT ON;
SET ANSI_WARNINGS ON;

/*==============================================================================================
  0. 파라미터
==============================================================================================*/
DECLARE
     @CO_CD    NVARCHAR(4)  = N'1000'
    ,@DIV_CD   NVARCHAR(4)  = N'1000'
    ,@FR_DT    NVARCHAR(8)  = N'20260101'
    ,@TO_DT    NVARCHAR(8)  = N'20261231'
    ,@ITEM_CD  NVARCHAR(25) = NULL
    ,@TH_EXC   DECIMAL(5,1) = 10.0            -- 예외 비중 경고 (%)
    ,@TH_GAP   DECIMAL(5,1) = 20.0            -- BOM 대비 사용량 괴리 경고 (%)
;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @BOM NVARCHAR(30) = NULL, @BBOM NVARCHAR(30) = NULL;
DECLARE @HAS_WIPIO BIT = 0;
DECLARE @QTCOL NVARCHAR(30) = NULL;

IF    OBJECT_ID(N'dbo.SBOM_WF', N'U') IS NOT NULL SET @BOM = N'SBOM_WF';
ELSE IF OBJECT_ID(N'dbo.SBOM' , N'U') IS NOT NULL SET @BOM = N'SBOM';
IF OBJECT_ID(N'dbo.SBOM_WF_B', N'U') IS NOT NULL SET @BBOM = N'SBOM_WF_B';
IF OBJECT_ID(N'dbo.LWIPIO'   , N'U') IS NOT NULL SET @HAS_WIPIO = 1;

IF @BOM IS NOT NULL
    SELECT TOP 1 @QTCOL = name FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.' + @BOM)
      AND name IN (N'USE_QT', N'CITEM_QT', N'BOM_QT', N'REQ_QT', N'QT')
    ORDER BY CASE name WHEN N'USE_QT' THEN 1 WHEN N'CITEM_QT' THEN 2 ELSE 3 END;

PRINT N'[0] BOM=' + ISNULL(@BOM, N'없음')
    + N' / BATCH=' + ISNULL(@BBOM, N'없음')
    + N' / 소요량컬럼=' + ISNULL(@QTCOL, N'미확인')
    + N' / LWIPIO=' + CAST(@HAS_WIPIO AS NVARCHAR(1));


/*==============================================================================================
  ** 쿼리 A : 재공처리 유형별 집계  (M-10)  ★ 예외 비중이 핵심
==============================================================================================*/
IF @HAS_WIPIO = 1
BEGIN
    SET @SQL = N'
    ;WITH X AS (
        SELECT
             처리구분 = CASE LEFT(W.WIP_NB, 2) WHEN N''WI'' THEN N''1.재공입고''
                                               WHEN N''WM'' THEN N''2.재공이동''
                                               WHEN N''WA'' THEN N''3.★재공조정''
                                               ELSE N''9.'' + LEFT(W.WIP_NB, 2) END
            ,매핑구분 = CASE WHEN W.MAP_FG BETWEEN N''1'' AND N''3'' THEN N''1.실적별(정상)''
                             WHEN W.MAP_FG BETWEEN N''4'' AND N''6'' THEN N''2.지시별(정상)''
                             WHEN W.MAP_FG BETWEEN N''7'' AND N''9'' THEN N''3.★예외''
                             ELSE N''9.'' + ISNULL(W.MAP_FG, N''?'') END
            ,W.MAP_FG, W.ITEM_CD, W.WO_CD, W.WIP_DT, W.EMP_CD
        FROM   dbo.LWIPIO W WITH (NOLOCK)
        WHERE  W.CO_CD = @p_CO
          AND  W.WIP_DT BETWEEN @p_FR AND @p_TO
          AND  ISNULL(W.USE_YN, N''1'') = N''1''
          AND  (@p_DIV  IS NULL OR W.DIV_CD  = @p_DIV)
          AND  (@p_ITEM IS NULL OR W.ITEM_CD = @p_ITEM)
    )
    SELECT
         N''[A] 재공처리 유형별'' AS REPORT_NM
        ,X.처리구분
        ,X.매핑구분
        ,X.MAP_FG                   AS 매핑코드
        ,처리건수 = COUNT(*)
        ,품목수   = COUNT(DISTINCT X.ITEM_CD)
        ,지시수   = COUNT(DISTINCT NULLIF(X.WO_CD, N''''))
        ,처리자수 = COUNT(DISTINCT NULLIF(X.EMP_CD, N''''))
        ,최초일   = MIN(X.WIP_DT)
        ,최종일   = MAX(X.WIP_DT)
        ,건수비중_PCT = CAST(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(5,1))
        ,판정 = CASE
             WHEN X.매핑구분 = N''3.★예외'' AND X.처리구분 = N''3.★재공조정''
                  THEN N''1.★★근거 없는 수동 조정 - 최우선 점검''
             WHEN X.매핑구분 = N''3.★예외''
                  THEN N''2.★예외 처리 - 사유 확인 필요''
             WHEN X.처리구분 = N''3.★재공조정''
                  THEN N''3.조정 - 원인 추적 필요''
             ELSE N''0.정상'' END
    FROM   X
    GROUP BY X.처리구분, X.매핑구분, X.MAP_FG
    ORDER BY 판정, 처리건수 DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT, @p_ITEM=@ITEM_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[A] 재공처리 유형별' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT N'[A] 재공처리 유형별' AS REPORT_NM, N'LWIPIO 없음 - 재공처리 점검 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 B : 예외 재공 처리 상세  (MAP_FG 7~9)  ★ 건별 확인 대상
==============================================================================================*/
IF @HAS_WIPIO = 1
BEGIN
    SET @SQL = N'
    SELECT TOP 300
         N''[B] 예외 재공 처리 상세'' AS REPORT_NM
        ,위험도 = CASE WHEN LEFT(W.WIP_NB, 2) = N''WA'' THEN N''1.★★조정+예외''
                       ELSE N''2.★예외'' END
        ,W.WIP_DT                   AS 처리일
        ,W.WIP_NB                   AS 처리번호
        ,처리구분 = CASE LEFT(W.WIP_NB, 2) WHEN N''WI'' THEN N''재공입고''
                                           WHEN N''WM'' THEN N''재공이동''
                                           WHEN N''WA'' THEN N''재공조정''
                                           ELSE LEFT(W.WIP_NB, 2) END
        ,W.MAP_FG                   AS 매핑코드
        ,W.ITEM_CD                  AS 품번
        ,I.ITEM_NM                  AS 품명
        ,I.UNIT_CD                  AS 단위
        ,W.WO_CD                    AS 지시번호
        ,지시존재 = CASE WHEN O.WO_CD IS NULL THEN N''★ 지시 없음'' ELSE N''있음'' END
        ,지시상태 = CASE ISNULL(O.EXPIRE_YN, N'''') WHEN N''1'' THEN N''진행''
                                                    WHEN N''0'' THEN N''마감'' ELSE N''-'' END
        ,W.EMP_CD                   AS 처리자
        ,E.EMP_NM                   AS 처리자명
        ,확인사항 = CASE
             WHEN O.WO_CD IS NULL
                  THEN N''★ 지시 없는 재공 처리 - 근거 확인 필요''
             WHEN ISNULL(O.EXPIRE_YN, N'''') = N''0''
                  THEN N''★ 마감된 지시에 재공 처리 - 원가 영향 확인''
             ELSE N''예외 처리 사유 확인'' END
    FROM       dbo.LWIPIO W WITH (NOLOCK)
    LEFT  JOIN SITEM  I WITH (NOLOCK) ON I.CO_CD = W.CO_CD AND I.ITEM_CD = W.ITEM_CD
    LEFT  JOIN LWO_WF O WITH (NOLOCK) ON O.CO_CD = W.CO_CD AND O.WO_CD   = NULLIF(W.WO_CD, N'''')
    LEFT  JOIN SEMP   E WITH (NOLOCK) ON E.CO_CD = W.CO_CD AND E.EMP_CD  = W.EMP_CD
    WHERE  W.CO_CD = @p_CO
      AND  W.WIP_DT BETWEEN @p_FR AND @p_TO
      AND  ISNULL(W.USE_YN, N''1'') = N''1''
      AND  W.MAP_FG BETWEEN N''7'' AND N''9''
      AND  (@p_DIV  IS NULL OR W.DIV_CD  = @p_DIV)
      AND  (@p_ITEM IS NULL OR W.ITEM_CD = @p_ITEM)
    ORDER BY 위험도, W.WIP_DT DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT, @p_ITEM=@ITEM_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[B] 예외 재공 상세' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END


/*==============================================================================================
  ** 쿼리 C : BOM 소요량 이상  (M-12)  ★ 값 자체가 잘못된 BOM
==============================================================================================*/
IF @BOM IS NOT NULL AND @QTCOL IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[C] BOM 소요량 이상'' AS REPORT_NM
        ,이상유형 = CASE
             WHEN CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6)) = 0
                  THEN N''1.★소요량 0 - 자재가 청구되지 않는다''
             WHEN CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6)) < 0
                  THEN N''2.★소요량 음수''
             WHEN B.ITEM_CD = B.CITEM_CD
                  THEN N''3.★자기 자신을 자재로 등록''
             WHEN PI.ITEM_CD IS NULL
                  THEN N''4.★모품목이 마스터에 없음''
             WHEN CI.ITEM_CD IS NULL
                  THEN N''5.★자품목이 마스터에 없음''
             WHEN ISNULL(CI.S_CD, N'''') = N''Z00''
                  THEN N''6.★단종 자재가 BOM 에 등록됨''
             WHEN ISNULL(PI.UNIT_CD, N'''') <> ISNULL(CI.UNIT_CD, N'''')
                  AND CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6)) > 1000
                  THEN N''7.단위 상이 + 소요량 과다 - 단위 환산 확인''
             ELSE N''8.소요량 과다(1000 초과)'' END
        ,B.ITEM_CD                  AS 모품번
        ,PI.ITEM_NM                 AS 모품명
        ,PI.UNIT_CD                 AS 모품단위
        ,계정구분 = CASE PI.ACCT_FG WHEN N''2'' THEN N''제품'' WHEN N''4'' THEN N''반제품''
                                    ELSE PI.ACCT_FG END
        ,B.CITEM_CD                 AS 자품번
        ,CI.ITEM_NM                 AS 자품명
        ,CI.UNIT_CD                 AS 자품단위
        ,소요량 = CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6))
        ,단종여부 = CASE WHEN ISNULL(CI.S_CD, N'''') = N''Z00'' THEN N''★단종'' ELSE N''-'' END
        ,지시사용여부 = CASE WHEN EXISTS (SELECT 1 FROM LWO_WF W WITH (NOLOCK)
                                          WHERE W.CO_CD = @p_CO AND W.ITEM_CD = B.ITEM_CD
                                            AND W.ORD_DT BETWEEN @p_FR AND @p_TO)
                             THEN N''★ 이 BOM 으로 생산 중'' ELSE N''생산 없음'' END
        ,영향 = N''MRP 소요량 전개와 자재 청구가 잘못된다''
    FROM       dbo.' + @BOM + N' B WITH (NOLOCK)
    LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = B.CO_CD AND PI.ITEM_CD = B.ITEM_CD
    LEFT  JOIN SITEM CI WITH (NOLOCK) ON CI.CO_CD = B.CO_CD AND CI.ITEM_CD = B.CITEM_CD
    WHERE  B.CO_CD = @p_CO
      AND  ISNULL(B.USE_YN, N''1'') = N''1''
      AND  (@p_ITEM IS NULL OR B.ITEM_CD = @p_ITEM)
      AND  ( CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6)) <= 0
          OR B.ITEM_CD = B.CITEM_CD
          OR PI.ITEM_CD IS NULL
          OR CI.ITEM_CD IS NULL
          OR ISNULL(CI.S_CD, N'''') = N''Z00''
          OR CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6)) > 1000 )
    ORDER BY 이상유형, B.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8), @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_FR=@FR_DT, @p_TO=@TO_DT, @p_ITEM=@ITEM_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[C] BOM 소요량 이상' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT N'[C] BOM 소요량 이상' AS REPORT_NM
          ,N'BOM 테이블 또는 소요량 컬럼 미확인 - 생략' AS 결과;


/*==============================================================================================
  ** 쿼리 D : BATCH BOM 정합성  (M-12)  ★ SBOM_WF_B vs SITEM.FOQ_QT
     ─ BATCH BOM 은 "한 배치에 몇 개" 를 정의한다. `SITEM.FOQ_QT`(배치 크기)와 맞아야 한다.
       어긋나면 소요량 전개가 배치 배수만큼 틀어진다.
==============================================================================================*/
IF @BBOM IS NOT NULL
BEGIN
    SET @SQL = N'
    SELECT
         N''[D] BATCH BOM 정합성'' AS REPORT_NM
        ,B.ITEM_CD                  AS 모품번
        ,I.ITEM_NM                  AS 품명
        ,I.UNIT_CD                  AS 단위
        ,I.FOQ_QT                   AS 마스터_배치크기
        ,BATCH_행수 = COUNT(*)
        ,BATCH_자품목수 = COUNT(DISTINCT B.CITEM_CD)
        ,일반BOM_존재 = CASE WHEN EXISTS (SELECT 1 FROM dbo.' + ISNULL(@BOM, N'SBOM_WF') + N' X WITH (NOLOCK)
                                          WHERE X.CO_CD = B.CO_CD AND X.ITEM_CD = B.ITEM_CD
                                            AND ISNULL(X.USE_YN, N''1'') = N''1'')
                             THEN N''O'' ELSE N''X'' END
        ,판정 = CASE
             WHEN ISNULL(I.FOQ_QT, 0) = 0
                  THEN N''1.★BATCH BOM 있는데 SITEM.FOQ_QT 미등록 - 배치 크기 불명''
             WHEN NOT EXISTS (SELECT 1 FROM dbo.' + ISNULL(@BOM, N'SBOM_WF') + N' X WITH (NOLOCK)
                              WHERE X.CO_CD = B.CO_CD AND X.ITEM_CD = B.ITEM_CD
                                AND ISNULL(X.USE_YN, N''1'') = N''1'')
                  THEN N''2.BATCH BOM 만 있고 일반 BOM 없음 - 정상일 수 있음''
             ELSE N''0.정상'' END
        ,비고 = N''BATCH BOM 은 배치 단위 소요량이다. FOQ_QT 와 함께 써야 전개가 맞는다''
    FROM       dbo.' + @BBOM + N' B WITH (NOLOCK)
    LEFT  JOIN SITEM I WITH (NOLOCK) ON I.CO_CD = B.CO_CD AND I.ITEM_CD = B.ITEM_CD
    WHERE  B.CO_CD = @p_CO
      AND  ISNULL(B.USE_YN, N''1'') = N''1''
      AND  (@p_ITEM IS NULL OR B.ITEM_CD = @p_ITEM)
    GROUP BY B.ITEM_CD, B.CO_CD, I.ITEM_NM, I.UNIT_CD, I.FOQ_QT
    ORDER BY 판정, B.ITEM_CD';
    BEGIN TRY
        EXEC sp_executesql @SQL, N'@p_CO NVARCHAR(4), @p_ITEM NVARCHAR(25)'
            ,@p_CO=@CO_CD, @p_ITEM=@ITEM_CD;
    END TRY
    BEGIN CATCH
        SELECT N'[D] BATCH BOM 정합성' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END
ELSE
    SELECT N'[D] BATCH BOM 정합성' AS REPORT_NM
          ,N'SBOM_WF_B 없음 - BATCH BOM 미운영 (정상)' AS 결과;


/*==============================================================================================
  ** 쿼리 E : BOM 소요량 vs 실제 사용량 괴리  (M-12)  ★ BOM 이 현실과 맞는가
     ─ BOM 표준 원단위와 실제 투입 원단위를 비교한다. 지속적으로 벌어지면 BOM 이 낡은 것이다.
==============================================================================================*/
IF @BOM IS NOT NULL AND @QTCOL IS NOT NULL
BEGIN
    SET @SQL = N'
    ;WITH ACT AS (
        -- 실제 사용 원단위 = 자재사용량 / 생산량
        SELECT
             W.ITEM_CD     AS PITEM_CD
            ,U.ITEM_CD     AS CITEM_CD
            ,USE_QT  = SUM(CAST(ISNULL(U.USE_QT, 0) AS DECIMAL(19,6)))
            ,PRD_QT  = SUM(CAST(ISNULL(R.GOOD, 0) AS DECIMAL(19,6)))
            ,WO_CNT  = COUNT(DISTINCT W.WO_CD)
        FROM       LMTL_USE U WITH (NOLOCK)
        INNER JOIN LORCV_H  X WITH (NOLOCK) ON X.CO_CD = U.CO_CD AND X.WR_CD = U.WR_CD
        INNER JOIN LWO_WF   W WITH (NOLOCK) ON W.CO_CD = X.CO_CD AND W.WO_CD = X.WO_CD
        CROSS APPLY (SELECT GOOD = CASE WHEN ISNULL(X.SUB_TP,N''0'')=N''0''
                                         AND ISNULL(X.BAD_YN,N''0'')=N''0''
                                        THEN X.ITEM_QT ELSE 0 END) R
        WHERE  U.CO_CD = @p_CO
          AND  X.WR_DT BETWEEN @p_FR AND @p_TO
          AND  ISNULL(U.USE_YN, N''1'') = N''1''
          AND  (@p_ITEM IS NULL OR W.ITEM_CD = @p_ITEM)
        GROUP BY W.ITEM_CD, U.ITEM_CD
        HAVING SUM(CAST(ISNULL(R.GOOD,0) AS DECIMAL(19,6))) > 0
    )
    SELECT
         N''[E] BOM vs 실사용 괴리'' AS REPORT_NM
        ,A.PITEM_CD                 AS 모품번
        ,PI.ITEM_NM                 AS 모품명
        ,A.CITEM_CD                 AS 자품번
        ,CI.ITEM_NM                 AS 자품명
        ,CI.UNIT_CD                 AS 단위
        ,BOM_소요량 = CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6))
        ,A.PRD_QT                   AS 생산량
        ,A.USE_QT                   AS 실사용량
        ,실사용_원단위 = CAST(A.USE_QT / NULLIF(A.PRD_QT, 0) AS DECIMAL(19,6))
        ,괴리율_PCT = CAST(CASE WHEN ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) <> 0
                                THEN ((A.USE_QT / NULLIF(A.PRD_QT,0))
                                      / CAST(B.' + QUOTENAME(@QTCOL) + N' AS DECIMAL(19,6)) - 1) * 100
                                END AS DECIMAL(9,1))
        ,A.WO_CNT                   AS 지시건수
        ,판정 = CASE
             WHEN B.CITEM_CD IS NULL
                  THEN N''1.★BOM 에 없는 자재를 투입 - BOM 등록 누락''
             WHEN ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) = 0
                  THEN N''2.★BOM 소요량 0''
             WHEN ABS((A.USE_QT/NULLIF(A.PRD_QT,0))
                      / CAST(B.' + QUOTENAME(@QTCOL) + N' AS DECIMAL(19,6)) - 1) * 100 > @p_GAP
                  THEN N''3.★BOM 과 실사용 괴리 큼 - BOM 갱신 검토''
             ELSE N''0.일치'' END
        ,조치 = CASE
             WHEN B.CITEM_CD IS NULL THEN N''BOM 에 이 자재를 추가할 것''
             WHEN A.USE_QT/NULLIF(A.PRD_QT,0) > CAST(ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) AS DECIMAL(19,6))
                  THEN N''실사용이 BOM 보다 많다 - 손실률 반영 또는 낭비 확인''
             ELSE N''실사용이 BOM 보다 적다 - BOM 과다 설정 확인'' END
    FROM       ACT A
    LEFT  JOIN dbo.' + @BOM + N' B WITH (NOLOCK)
            ON B.CO_CD = @p_CO AND B.ITEM_CD = A.PITEM_CD AND B.CITEM_CD = A.CITEM_CD
           AND ISNULL(B.USE_YN, N''1'') = N''1''
    LEFT  JOIN SITEM PI WITH (NOLOCK) ON PI.CO_CD = @p_CO AND PI.ITEM_CD = A.PITEM_CD
    LEFT  JOIN SITEM CI WITH (NOLOCK) ON CI.CO_CD = @p_CO AND CI.ITEM_CD = A.CITEM_CD
    WHERE  B.CITEM_CD IS NULL
       OR  ISNULL(B.' + QUOTENAME(@QTCOL) + N',0) = 0
       OR  ABS((A.USE_QT/NULLIF(A.PRD_QT,0))
               / NULLIF(CAST(B.' + QUOTENAME(@QTCOL) + N' AS DECIMAL(19,6)), 0) - 1) * 100 > @p_GAP
    ORDER BY 판정, ABS(ISNULL(괴리율_PCT, 999)) DESC';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)
              ,@p_ITEM NVARCHAR(25), @p_GAP DECIMAL(5,1)'
            ,@p_CO=@CO_CD, @p_FR=@FR_DT, @p_TO=@TO_DT, @p_ITEM=@ITEM_CD, @p_GAP=@TH_GAP;
    END TRY
    BEGIN CATCH
        SELECT N'[E] BOM vs 실사용 괴리' AS REPORT_NM, N'조회 실패 : ' + ERROR_MESSAGE() AS 결과;
    END CATCH
END


/*==============================================================================================
  ** 쿼리 F : 종합 판정
==============================================================================================*/
DECLARE @EXC_CNT INT = 0, @TOT_CNT INT = 0;
IF @HAS_WIPIO = 1
BEGIN
    SET @SQL = N'
        SELECT @o1 = SUM(CASE WHEN MAP_FG BETWEEN N''7'' AND N''9'' THEN 1 ELSE 0 END)
              ,@o2 = COUNT(*)
        FROM   dbo.LWIPIO WITH (NOLOCK)
        WHERE  CO_CD = @p_CO AND WIP_DT BETWEEN @p_FR AND @p_TO
          AND  ISNULL(USE_YN, N''1'') = N''1''
          AND  (@p_DIV IS NULL OR DIV_CD = @p_DIV)';
    BEGIN TRY
        EXEC sp_executesql @SQL
            ,N'@p_CO NVARCHAR(4), @p_DIV NVARCHAR(4), @p_FR NVARCHAR(8), @p_TO NVARCHAR(8)
              ,@o1 INT OUTPUT, @o2 INT OUTPUT'
            ,@p_CO=@CO_CD, @p_DIV=@DIV_CD, @p_FR=@FR_DT, @p_TO=@TO_DT
            ,@o1=@EXC_CNT OUTPUT, @o2=@TOT_CNT OUTPUT;
    END TRY BEGIN CATCH END CATCH
END

SELECT
     N'[F] 생산 마스터 점검 종합'                   AS REPORT_NM
    ,@FR_DT + N' ~ ' + @TO_DT                       AS 기간
    ,BOM_테이블   = ISNULL(@BOM , N'★없음')
    ,BATCH_테이블 = ISNULL(@BBOM, N'미운영')
    ,소요량컬럼   = ISNULL(@QTCOL, N'★미확인')
    ,LWIPIO_존재  = CASE WHEN @HAS_WIPIO = 1 THEN N'O' ELSE N'X' END
    ,재공처리건수 = @TOT_CNT
    ,예외처리건수 = @EXC_CNT
    ,예외비중_PCT = CAST(@EXC_CNT * 100.0 / NULLIF(@TOT_CNT, 0) AS DECIMAL(5,1))
    ,판정 = CASE
         WHEN @BOM IS NULL
              THEN N'1.★BOM 테이블 없음 - BOM 점검 불가'
         WHEN @QTCOL IS NULL
              THEN N'2.★BOM 소요량 컬럼 미확인 - 아래 확인 쿼리로 컬럼명을 확인할 것'
         WHEN @HAS_WIPIO = 1 AND @EXC_CNT * 100.0 / NULLIF(@TOT_CNT, 0) > @TH_EXC
              THEN N'3.★예외 재공 처리가 ' + CAST(@TH_EXC AS NVARCHAR(10))
                   + N'% 초과 - 재공 데이터 신뢰도 낮음'
         WHEN @HAS_WIPIO = 0
              THEN N'4.LWIPIO 없음 - 재공처리 점검 생략 (BOM 점검만 유효)'
         ELSE N'0.정상' END
    ,권장조치 = N'쿼리 C(BOM 값 이상) → 쿼리 E(BOM vs 실사용) 순서로 BOM 을 정비한 뒤 MRP 를 돌릴 것'
;


GO


/*==============================================================================================
  [ 상시 점검 운영 ]
  ----------------------------------------------------------------------------------------------
  실행 시점 : BOM 대량 변경 후 / MRP 결과가 이상할 때 / 분기 1회
  실행 순서 : ① B02_마스터점검팩.sql 쿼리 B·C (BOM 구조 — 미등록·순환참조)
              ② 이 파일 쿼리 C·D·E   (BOM 값 — 소요량·BATCH·실사용 괴리)
              ③ 쿼리 A·B             (재공 처리 예외)
              ④ BOM 정비 후 원자재수급총괄현황_MRP.sql 재실행

  [ 도입 전 확인 ]
  ----------------------------------------------------------------------------------------------
  -- (1) BOM 소요량 컬럼  ★ 쿼리 C·E 의 전제. 본 쿼리는 자동 탐색한다
     SELECT name, TYPE_NAME(user_type_id) FROM sys.columns
     WHERE object_id = OBJECT_ID('SBOM_WF') ORDER BY column_id;
     --> 후보 : USE_QT, CITEM_QT, BOM_QT, REQ_QT, QT
        없으면 0번 블록의 IN (...) 에 추가할 것.

  -- (2) BATCH BOM 운영 여부
     SELECT COUNT(*) FROM SBOM_WF_B WHERE CO_CD='1000';
     SELECT COUNT(*) FROM SITEM WHERE CO_CD='1000' AND ISNULL(FOQ_QT,0) > 0;
     --> BATCH BOM 이 있는데 FOQ_QT 가 없으면 전개가 틀어진다 (쿼리 D).

  -- (3) MAP_FG 분포  ★ 예외 비중 실측
     SELECT MAP_FG, LEFT(WIP_NB,2) 구분, COUNT(*) FROM LWIPIO
     WHERE CO_CD='1000' GROUP BY MAP_FG, LEFT(WIP_NB,2) ORDER BY 1,2;
     --> 7~9 가 10% 넘으면 재공 데이터를 원가에 그대로 쓰면 안 된다.

  -- (4) 자재 사용보고 운영  ★ 쿼리 E 의 전제
     SELECT COUNT(*) FROM LMTL_USE WHERE CO_CD='1000';
     --> 0 이면 쿼리 E 가 비어 나온다. 지시 단위 사용보고(LMTL_USEWO)를 쓰는 사이트면
        그 테이블로 바꿔야 한다.

  [ 한계 ]
  ----------------------------------------------------------------------------------------------
  1) **쿼리 E 의 실사용 원단위는 손실률을 포함**한다. BOM 에 손실률이 반영되어 있지 않으면
     실사용이 항상 BOM 보다 크게 나오는 것이 정상이다. 괴리율의 절대값이 아니라
     **품목 간 상대 비교**로 보고, 유독 괴리가 큰 품목을 찾는 용도로 쓸 것.

  2) **다단 BOM 을 한 단계만 본다.** 반제품을 거치는 구조에서는 모품목-자품목 직접 관계만
     비교하므로, 반제품 레벨의 낭비가 최종 제품에 드러나지 않는다.

  3) `소요량 과다(1000 초과)` 판정은 **단위에 의존**한다. g/ml 단위 자재는 정상적으로
     1000 을 넘으므로 오탐이 많다. 쿼리 C 의 `이상유형 8` 은 참고용으로만 볼 것.

  4) 예외 재공(MAP_FG 7~9)의 **의미는 사이트마다 다를 수 있다.** 도입 시 생산 담당자에게
     실제 어떤 상황에서 7~9 가 발생하는지 확인할 것. 정상 업무 절차일 수도 있다.

  [ 관련 산출물 ]
  ----------------------------------------------------------------------------------------------
   B02_마스터점검팩.sql        : BOM 구조 점검 (미등록·순환참조·레벨)
   M04_공정별재공_현황.sql     : 재공 현황 (쿼리 E 에 재공처리 유형 집계)
   원자재수급총괄현황_MRP.sql  : BOM 이 정비되어야 정확해진다
   C04_표준원가_차이분석.sql   : BOM 표준 대비 실제 사용량 차이 (원가 관점)
==============================================================================================*/
