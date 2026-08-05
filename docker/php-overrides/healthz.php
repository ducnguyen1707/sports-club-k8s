<?php
// Probe target for Kubernetes liveness/readiness.
//
// Deliberately does NOT call session_start() and does NOT touch the database.
// The app's own index.php starts a session on line 3, and with
// session.save_handler = redis that means every probe would open a Redis
// connection and create a throwaway session (~18/min across 2 replicas, each
// retained for gc_maxlifetime). It would also couple app liveness to Redis
// being up, which is the wrong failure coupling.
//
// This confirms exactly one thing: PHP is executing and Apache is serving.
http_response_code(200);
header('Content-Type: text/plain');
echo 'ok';
