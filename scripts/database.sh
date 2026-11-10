#!/usr/bin/env bash
# Use the same bundled connection settings and PHP driver as Scalar.
# This checks connectivity only; it never creates or upgrades the database.
set -euo pipefail
docker compose exec -T --user nginx scalar php <<'PHP'
<?php
define('BASEPATH', '/usr/local/share/scalar/system/');
require '/usr/local/share/scalar/system/application/config/database.php';
$settings = $db['default'];
if (empty($settings['username']) || empty($settings['database'])) {
    fwrite(STDERR, "Set SCALAR_DB_USERNAME and SCALAR_DB_DATABASE in .env.\n");
    exit(1);
}
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
$deadline = microtime(true) + 60;
do {
    try {
        $connection = mysqli_init();
        $connection->options(MYSQLI_OPT_CONNECT_TIMEOUT, 2);
        $connection->options(MYSQLI_OPT_READ_TIMEOUT, 2);
        $connection->real_connect($settings['hostname'], $settings['username'],
            $settings['password'], $settings['database'], (int) ($settings['port'] ?? 3306));
        $connection->query('SELECT 1');
        $connection->close();
        echo "Scalar application database connection succeeded.\n";
        exit(0);
    } catch (mysqli_sql_exception $error) {
        // Do not expose credentials or connection details in deployment logs.
    }
    sleep(2);
} while (microtime(true) < $deadline);
fwrite(STDERR, "Database check timed out. Check the HAProxy listener, Galera health, and application credentials.\n");
exit(1);
PHP
