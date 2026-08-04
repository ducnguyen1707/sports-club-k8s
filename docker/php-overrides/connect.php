<?php
// ---------------------------------------------------------------------------
// Deployment override of app/Files/connect.php
//
// Upstream reads:
//     mysqli_connect("localhost","root","","tms") or die("Can't Connect...");
//
// Two problems fixed here:
//   1. hardcoded localhost/root/"" — unusable in Kubernetes
//   2. database "tms" DOES NOT EXIST in sports_club_db.sql. This file appears
//      to be dead code (index.php / secure_login.php include db_conn.php
//      instead), but if anything ever reaches it, upstream would die() with a
//      connection error. Pointed at the real database rather than left broken.
// ---------------------------------------------------------------------------

mysqli_report(MYSQLI_REPORT_OFF);

$link = mysqli_connect(
    getenv('DB_HOST')     ?: 'mysql',
    getenv('DB_USER')     ?: 'sportsclub',
    getenv('DB_PASSWORD') ?: '',
    getenv('DB_NAME')     ?: 'sports_club_db'
);

if (mysqli_connect_errno()) {
    error_log('DB connection failed (connect.php): ' . mysqli_connect_error());
    http_response_code(503);
    exit('Service temporarily unavailable');
}
?>
