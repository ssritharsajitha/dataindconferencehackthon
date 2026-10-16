-- Supplier Risk Radar: Snowflake setup
-- Prerequisites: AUTO_MFG_DW with SUPPLY_CHAIN.SUPPLIERS, SUPPLY_CHAIN.PURCHASE_ORDERS,
-- QUALITY.DEFECTS, QUALITY.WARRANTY_CLAIMS; a warehouse (DEFAULT_WH below); Cortex AI function access.
-- Run top to bottom as a role that can create schemas, semantic views and agents.

CREATE SCHEMA IF NOT EXISTS AUTO_MFG_DW.SUPPLIER_RADAR;

-- 1. Supplier risk score (0-100, higher is riskier)
CREATE OR REPLACE VIEW AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK AS
WITH d AS (
  SELECT SUPPLIER_ID,
    COUNT(*) total_defects,
    COUNT_IF(SEVERITY='CRITICAL') critical_defects,
    COUNT_IF(SEVERITY='MAJOR') major_defects,
    COUNT_IF(DISCOVERED_DATE >= DATEADD(day,-90,CURRENT_DATE())) defects_last_90d,
    COUNT_IF(DISCOVERED_DATE <  DATEADD(day,-90,CURRENT_DATE()) AND DISCOVERED_DATE >= DATEADD(day,-180,CURRENT_DATE())) defects_prior_90d
  FROM AUTO_MFG_DW.QUALITY.DEFECTS GROUP BY 1),
po AS (
  SELECT SUPPLIER_ID, COUNT(*) total_orders, COUNT(DISTINCT PART_ID) parts_supplied,
         SUM(QUANTITY_ORDERED*UNIT_PRICE) spend
  FROM AUTO_MFG_DW.SUPPLY_CHAIN.PURCHASE_ORDERS GROUP BY 1),
w AS (
  SELECT po.SUPPLIER_ID, COUNT(DISTINCT c.WARRANTY_CLAIM_ID) warranty_claims, SUM(c.REPAIR_COST) warranty_cost
  FROM (SELECT DISTINCT SUPPLIER_ID, PART_ID FROM AUTO_MFG_DW.SUPPLY_CHAIN.PURCHASE_ORDERS) po
  JOIN AUTO_MFG_DW.QUALITY.WARRANTY_CLAIMS c ON c.PART_ID = po.PART_ID
  GROUP BY 1),
base AS (
  SELECT s.SUPPLIER_ID, s.SUPPLIER_NAME, s.SUPPLIER_TIER, s.STATUS, s.COUNTRY_CODE,
    s.QUALITY_RATING, LEAST(s.ON_TIME_DELIVERY_PCT,100) ON_TIME_PCT,
    COALESCE(d.total_defects,0) total_defects, COALESCE(d.critical_defects,0) critical_defects,
    COALESCE(d.major_defects,0) major_defects,
    COALESCE(d.defects_last_90d,0) defects_last_90d, COALESCE(d.defects_prior_90d,0) defects_prior_90d,
    COALESCE(po.total_orders,0) total_orders, COALESCE(po.parts_supplied,0) parts_supplied,
    COALESCE(po.spend,0) spend, COALESCE(w.warranty_claims,0) warranty_claims,
    COALESCE(w.warranty_cost,0) warranty_cost,
    COALESCE(d.total_defects,0)*1000/NULLIF(po.total_orders,0) defects_per_1000_orders,
    COALESCE(d.critical_defects,0)/NULLIF(d.total_defects,0) critical_share
  FROM AUTO_MFG_DW.SUPPLY_CHAIN.SUPPLIERS s
  LEFT JOIN d ON d.SUPPLIER_ID=s.SUPPLIER_ID
  LEFT JOIN po ON po.SUPPLIER_ID=s.SUPPLIER_ID
  LEFT JOIN w ON w.SUPPLIER_ID=s.SUPPLIER_ID),
scored AS (
  SELECT *,
    ROUND(
      0.25*(100-QUALITY_RATING)
    + 0.20*(100-ON_TIME_PCT)*2
    + 0.25*LEAST(COALESCE(defects_per_1000_orders,0)/5,100)
    + 0.10*COALESCE(critical_share,0)*100
    + 0.10*LEAST(GREATEST(defects_last_90d-defects_prior_90d,0)*10,100)
    + 0.10*PERCENT_RANK() OVER (ORDER BY warranty_cost)*100
    ,1) risk_score
  FROM base)
SELECT *,
  CASE WHEN risk_score>=40 THEN 'HIGH' WHEN risk_score>=25 THEN 'MEDIUM' ELSE 'LOW' END risk_band,
  CASE WHEN STATUS='SUSPENDED' THEN 'Already suspended - confirm exit plan'
       WHEN risk_score>=40 AND critical_defects>=5 THEN 'Audit supplier and issue corrective action request'
       WHEN risk_score>=40 THEN 'Escalate and qualify a second source'
       WHEN risk_score>=25 THEN 'Monitor closely; review at next business review'
       ELSE 'No action' END recommended_action
FROM scored;

-- 2. AI summaries of defect themes for HIGH-risk suppliers (~140K input tokens at time of build)
CREATE OR REPLACE TABLE AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_ISSUE_SUMMARY AS
SELECT d.SUPPLIER_ID,
  AI_AGG(
    d.DEFECT_TYPE||' | '||d.SEVERITY||' | '||COALESCE(d.DESCRIPTION,'')||' | '||COALESCE(d.ROOT_CAUSE_ANALYSIS,''),
    'You are given manufacturing defect records for one supplier (type | severity | description | root cause). Summarize in 2-3 sentences for a supplier quality manager: the recurring defect themes, the most common root causes, and anything severe.'
  ) AS ISSUE_SUMMARY,
  CURRENT_TIMESTAMP() AS GENERATED_AT
FROM AUTO_MFG_DW.QUALITY.DEFECTS d
JOIN AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK r USING (SUPPLIER_ID)
WHERE r.RISK_BAND='HIGH'
GROUP BY d.SUPPLIER_ID;

-- 3. Semantic view for Cortex Analyst
CREATE OR REPLACE SEMANTIC VIEW AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK_SV
  TABLES (
    risk AS AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK PRIMARY KEY (SUPPLIER_ID) COMMENT = 'One row per supplier with a 0-100 risk score (higher is riskier), band (HIGH/MEDIUM/LOW), and recommended action',
    defects AS AUTO_MFG_DW.QUALITY.DEFECTS PRIMARY KEY (DEFECT_ID) COMMENT = 'Quality defects traced to suppliers and parts',
    summ AS AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_ISSUE_SUMMARY PRIMARY KEY (SUPPLIER_ID) COMMENT = 'AI-generated summary of recurring defect themes and root causes, for HIGH-risk suppliers only'
  )
  RELATIONSHIPS (
    defects (SUPPLIER_ID) REFERENCES risk,
    summ (SUPPLIER_ID) REFERENCES risk
  )
  FACTS (
    risk.f_risk_score AS RISK_SCORE,
    risk.f_quality AS QUALITY_RATING,
    risk.f_on_time AS ON_TIME_PCT,
    risk.f_warranty_cost AS WARRANTY_COST,
    risk.f_spend AS SPEND,
    risk.f_critical AS CRITICAL_DEFECTS,
    risk.f_d90 AS DEFECTS_LAST_90D,
    risk.f_p90 AS DEFECTS_PRIOR_90D
  )
  DIMENSIONS (
    risk.supplier_id AS SUPPLIER_ID,
    risk.supplier_name AS SUPPLIER_NAME WITH SYNONYMS = ('vendor','supplier'),
    risk.supplier_tier AS SUPPLIER_TIER,
    risk.supplier_status AS STATUS,
    risk.country AS COUNTRY_CODE,
    risk.risk_band AS RISK_BAND WITH SYNONYMS = ('risk level'),
    risk.risk_score AS RISK_SCORE COMMENT = 'Risk score 0-100, higher is riskier',
    risk.quality_rating AS QUALITY_RATING,
    risk.on_time_pct AS ON_TIME_PCT,
    risk.warranty_cost AS WARRANTY_COST,
    risk.recommended_action AS RECOMMENDED_ACTION,
    defects.defect_type AS DEFECT_TYPE,
    defects.severity AS SEVERITY,
    defects.defect_status AS STATUS,
    defects.discovered_date AS DISCOVERED_DATE,
    defects.root_cause AS ROOT_CAUSE_ANALYSIS,
    summ.issue_summary AS ISSUE_SUMMARY COMMENT = 'AI summary of recurring defect themes and root causes'
  )
  METRICS (
    risk.avg_risk_score AS AVG(risk.f_risk_score) COMMENT = 'Average supplier risk score (0-100, higher is riskier)',
    risk.supplier_count AS COUNT(DISTINCT risk.supplier_id),
    risk.avg_quality_rating AS AVG(risk.f_quality),
    risk.avg_on_time_pct AS AVG(risk.f_on_time),
    risk.total_warranty_cost AS SUM(risk.f_warranty_cost),
    risk.total_spend AS SUM(risk.f_spend),
    risk.sum_defects_last_90d AS SUM(risk.f_d90) COMMENT = 'Defects in the last 90 days',
    risk.sum_defects_prior_90d AS SUM(risk.f_p90) COMMENT = 'Defects in the 90 days before that',
    risk.sum_critical_defects AS SUM(risk.f_critical),
    defects.defect_count AS COUNT(defects.DEFECT_ID)
  )
  COMMENT = 'Supplier risk radar: supplier risk scores, delivery and quality performance, defects, warranty cost, and AI issue summaries';

-- 4. Cortex Agent (change the warehouse name if DEFAULT_WH is not available)
CREATE OR REPLACE AGENT AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK_AGENT
  COMMENT = 'Ranks supplier risk and recommends actions for supplier quality managers'
  PROFILE = '{"display_name": "Supplier Risk Radar", "color": "red"}'
  FROM SPECIFICATION
  $$
  orchestration:
    budget:
      seconds: 60
      tokens: 20000
  instructions:
    response: "Be concise. Lead with a ranked list (supplier name, risk score, band). For each supplier give the evidence (quality rating, on-time %, defects, warranty cost) and end with the recommended action. Never invent numbers."
    orchestration: "Use Analyst for all supplier, defect and risk questions. Risk score is 0-100, higher is riskier; bands are HIGH (>=40), MEDIUM (25-40), LOW (<25). The ISSUE_SUMMARY dimension holds an AI summary of defect themes and exists only for HIGH-risk suppliers; use it when asked why a supplier is risky. Use RECOMMENDED_ACTION for what to do."
    sample_questions:
      - question: "Which 5 suppliers are the highest risk and why?"
      - question: "Which suppliers have more defects in the last 90 days than the prior 90 days?"
      - question: "What should we do about our suspended or probation suppliers?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "SupplierAnalyst"
        description: "Answers questions about supplier risk scores, quality, delivery, defects, warranty cost, and defect issue summaries"
    - tool_spec:
        type: "data_to_chart"
        name: "data_to_chart"
        description: "Generates charts from data"
  tool_resources:
    SupplierAnalyst:
      semantic_view: "AUTO_MFG_DW.SUPPLIER_RADAR.SUPPLIER_RISK_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "DEFAULT_WH"
  $$;
