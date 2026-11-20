<?php

declare(strict_types=1);

/**
 * Database Migration CLI Runner.
 *
 * Usage:
 *   php database/migrate.php              # Run all pending migrations
 *   php database/migrate.php --status     # Show migration status
 *   php database/migrate.php --down 1     # Rollback last 1 migration
 *   php database/migrate.php --down 2     # Rollback last 2 migrations
 *
 * Logica reaplicavel esta em database/runner.php (consumido tambem por
 * inc/auto_migrate.php no bootstrap web/api, evitando esquecimento manual).
 */

require_once __DIR__ . '/runner.php';
require_once __DIR__ . '/../config/config.php';
require_once __DIR__ . '/../config/logger.php';
require_once __DIR__ . '/../config/database.php';

$db = db();
$pdo = $db->getConnection();

ensureMigrationsTable($pdo);

// --status
$args = array_slice($_SERVER['argv'] ?? [], 1);
if (in_array('--status', $args, true)) {
    $files = getMigrationFiles();
    $applied = getAppliedMigrations($pdo);

    echo "Migration Status:\n";
    echo str_repeat('-', 60) . "\n";

    foreach ($files as $timestamp => $file) {
        $name = basename($file, '.php');
        $status = in_array($timestamp, $applied, true) ? '[APPLIED]' : '[PENDING]';
        echo "{$status} {$name}\n";
    }

    $appliedPhp = array_values(array_intersect(array_keys($files), $applied));
    $pendingCount = count(array_diff(array_keys($files), $applied));
    echo str_repeat('-', 60) . "\n";
    echo "Total: " . count($files) . " | Applied: " . count($appliedPhp) . " | Pending: {$pendingCount}\n";
    $legacyCount = count($applied) - count($appliedPhp);
    if ($legacyCount > 0) {
        echo "Nota: {$legacyCount} migration(s) legada(s) .sql registrada(s) no schema.\n";
    }
    exit(0);
}

// --down N
if (in_array('--down', $args, true)) {
    $downIndex = array_search('--down', $args);
    $count = isset($args[$downIndex + 1]) ? max(1, (int)$args[$downIndex + 1]) : 1;

    $result = rollbackMigrations($pdo, $count);

    foreach ($result['rolled_back'] as $ts) {
        echo "Rolled back: {$ts} OK\n";
    }
    foreach ($result['failed'] as $fail) {
        echo "FAILED: {$fail['migration']} — {$fail['error']}\n";
    }
    echo "Rolled back " . count($result['rolled_back']) . " migration(s).\n";
    exit(empty($result['failed']) ? 0 : 1);
}

// default: run pending
$result = applyPendingMigrations($pdo);

foreach ($result['applied'] as $ts) {
    echo "Migrating: {$ts} OK\n";
}
foreach ($result['skipped'] as $ts) {
    echo "Migrating: {$ts} OK (already applied, skipped)\n";
}
foreach ($result['failed'] as $fail) {
    echo "FAILED: {$fail['migration']} — {$fail['error']}\n";
}

if (empty($result['applied']) && empty($result['skipped']) && empty($result['failed'])) {
    echo "No pending migrations.\n";
    exit(0);
}
if (!empty($result['failed'])) {
    exit(1);
}
echo "All migrations applied successfully.\n";
exit(0);
