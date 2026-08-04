<?php
// ---------------------------------------------------------------------------
// Deployment override of app/Files/include/db_conn.php
//
// Upstream hardcodes localhost/root/"" — unusable in Kubernetes. This version
// reads connection details from environment variables instead.
//
// Everything BELOW the connection block (page_protect) is copied VERBATIM from
// upstream. Every dashboard page does `require '../../include/db_conn.php'`
// and then calls page_protect(), so dropping it breaks the entire admin area.
// ---------------------------------------------------------------------------

// PHP 8.1 changed mysqli's default error mode to throw exceptions.
// Upstream code was written for pre-8.1 semantics: it checks
// mysqli_connect_errno() and tests query results for truthiness. Without this
// line, any failed query becomes an uncaught mysqli_sql_exception instead.
mysqli_report(MYSQLI_REPORT_OFF);

$host     = getenv('DB_HOST')     ?: 'mysql';            // Host name
$username = getenv('DB_USER')     ?: 'sportsclub';       // Mysql username
$password = getenv('DB_PASSWORD') ?: '';                 // Mysql password
$db_name  = getenv('DB_NAME')     ?: 'sports_club_db';   // Database name

// Connect to server and select databse.
$con = mysqli_connect($host, $username, $password, $db_name);

// Check connection
if (mysqli_connect_errno()) {
    // Log the real reason for operators; never leak it to the browser.
    error_log('DB connection failed: ' . mysqli_connect_error());
    http_response_code(503);
    exit('Service temporarily unavailable');
}
?>
<?php
function page_protect()
{
    session_start();

    global $db;

    /* Secure against Session Hijacking by checking user agent */
    if (isset($_SESSION['HTTP_USER_AGENT'])) {
        if ($_SESSION['HTTP_USER_AGENT'] != md5($_SERVER['HTTP_USER_AGENT'])) {
            session_destroy();
            echo "<meta http-equiv='refresh' content='0; url=../login/'>";
            exit();
        }
    }

    // before we allow sessions, we need to check authentication key - ckey and ctime stored in database

    /* If session not set, check for cookies set by Remember me */
    if (!isset($_SESSION['user_data']) && !isset($_SESSION['logged']) && !isset($_SESSION['auth_level'])) {
        session_destroy();
        echo "<meta http-equiv='refresh' content='0; url=../login/'>";
        exit();
    } else {

    }

}
?>
