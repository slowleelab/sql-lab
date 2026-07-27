DROP TABLE IF EXISTS t_sales;
CREATE TABLE t_sales (
    id          BIGINT      NOT NULL AUTO_INCREMENT,
    product_id  BIGINT      NOT NULL,
    category    VARCHAR(20) NOT NULL,
    region      VARCHAR(20) NOT NULL,
    amount      DECIMAL(12,2) NOT NULL,
    qty         INT         NOT NULL,
    sale_date   DATE        NOT NULL,
    PRIMARY KEY (id),
    KEY idx_category (category),
    KEY idx_region (region),
    KEY idx_date (sale_date)
);
