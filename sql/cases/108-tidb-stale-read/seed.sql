DELIMITER $$
DROP PROCEDURE IF EXISTS sp_seed_t_stale $$
CREATE PROCEDURE sp_seed_t_stale()
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE v_item VARCHAR(100);
    SET autocommit = 0;
    WHILE i < 100000 DO
        SET v_item = CASE i % 30
            WHEN 0 THEN 'Laptop'
            WHEN 1 THEN 'Monitor'
            WHEN 2 THEN 'Keyboard'
            WHEN 3 THEN 'Mouse'
            WHEN 4 THEN 'Desk'
            WHEN 5 THEN 'Chair'
            WHEN 6 THEN 'Headset'
            WHEN 7 THEN 'Webcam'
            WHEN 8 THEN 'Tablet'
            WHEN 9 THEN 'Phone'
            WHEN 10 THEN 'Printer'
            WHEN 11 THEN 'Scanner'
            WHEN 12 THEN 'Router'
            WHEN 13 THEN 'Switch'
            WHEN 14 THEN 'Server'
            WHEN 15 THEN 'Backup Drive'
            WHEN 16 THEN 'USB Hub'
            WHEN 17 THEN 'Power Strip'
            WHEN 18 THEN 'Cable Organizer'
            WHEN 19 THEN 'Desk Lamp'
            WHEN 20 THEN 'Whiteboard'
            WHEN 21 THEN 'Projector'
            WHEN 22 THEN 'Adapter'
            WHEN 23 THEN 'Docking Station'
            WHEN 24 THEN 'Microphone'
            WHEN 25 THEN 'Speaker'
            WHEN 26 THEN 'Charger'
            WHEN 27 THEN 'Battery Pack'
            WHEN 28 THEN 'Memory Card'
            ELSE 'Stand'
        END;
        INSERT INTO t_stale (item, qty, price, updated_at)
        VALUES (
            CONCAT(v_item, '-', LPAD(i, 5, '0')),
            FLOOR(1 + RAND() * 1000),
            ROUND(10 + RAND() * 9990, 2),
            DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY)
        );
        SET i = i + 1;
        IF i % 5000 = 0 THEN COMMIT; END IF;
    END WHILE;
    COMMIT;
    SET autocommit = 1;
END $$
DELIMITER ;

CALL sp_seed_t_stale();
DROP PROCEDURE IF EXISTS sp_seed_t_stale;

SELECT COUNT(*) AS t_stale_rows FROM t_stale;
