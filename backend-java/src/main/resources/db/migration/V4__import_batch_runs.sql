-- 导入批次的运行历史（issue #43）
--
-- 问题：batch_id 由 Python 对 source_id 集合做哈希得出，不含运行序号；
-- 同一天重跑会命中同一主键，`import_batch` 的计数被覆盖，看不到"跑了几轮、每轮结果如何"。
-- 阶段 1 定的"不做短路回放、每次真实 upsert"必须保留（否则验收 D3 永不生效），
-- 所以这里不动幂等语义，只在旁边记一份逐次运行明细。

ALTER TABLE import_batch
    ADD COLUMN run_count INT         NOT NULL DEFAULT 0 COMMENT '该 batch_id 被提交的次数（含第一次）' AFTER rejected,
    ADD COLUMN last_run_at DATETIME(3) NULL               COMMENT '最后一次提交时间，用于发现"同一批反复重跑"' AFTER run_count;

CREATE TABLE IF NOT EXISTS import_batch_run
(
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    batch_id    VARCHAR(128)    NOT NULL COMMENT '关联 import_batch.batch_id',
    run_seq     INT             NOT NULL COMMENT '第几次运行，从 1 开始，按上报顺序递增',
    inserted    INT             NOT NULL DEFAULT 0,
    updated     INT             NOT NULL DEFAULT 0,
    unchanged   INT             NOT NULL DEFAULT 0,
    rejected    INT             NOT NULL DEFAULT 0,
    errors      JSON            NULL COMMENT '本次运行的 rejected 明细，与 import_batch.errors 同结构',
    started_at  DATETIME(3)     NOT NULL,
    finished_at DATETIME(3)     NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_batch_run (batch_id, run_seq),
    KEY idx_batch_started (batch_id, started_at),
    CONSTRAINT fk_batch_run_batch FOREIGN KEY (batch_id)
        REFERENCES import_batch (batch_id) ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci COMMENT ='导入批次的逐次运行明细：同一天重跑不会覆盖历史';

-- 存量批次补一次运行记录，让"第一次"也有迹可循。
-- run_count 默认 0，这里把已有行视为跑过 1 次（它们确实留下了一条统计）。
UPDATE import_batch
   SET run_count = 1,
       last_run_at = IFNULL(finished_at, started_at)
 WHERE run_count = 0;

INSERT INTO import_batch_run (batch_id, run_seq, inserted, updated, unchanged, rejected,
                              errors, started_at, finished_at)
SELECT batch_id, 1, inserted, updated, unchanged, rejected, errors, started_at, finished_at
  FROM import_batch
 WHERE run_count = 1
   AND last_run_at IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM import_batch_run r WHERE r.batch_id = import_batch.batch_id);
