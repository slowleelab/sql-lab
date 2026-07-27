-- setup-good.sql: 为 JSON 字段建虚拟列 + 索引（MySQL 8.0）
-- 将 attrs->'$.color' 提取为虚拟列 color，并在其上建索引
-- 虚拟列不占存储空间（VIRTUAL），索引基于虚拟列值构建
ALTER TABLE t_product_json
    ADD COLUMN color VARCHAR(20)
        GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(attrs, '$.color'))) VIRTUAL,
    ADD KEY idx_color (color);
