# =============================================================================
# Sports Club Management System — container image
#
# Upstream is a XAMPP-era PHP app (github.com/shreyansh225/Sports-Club-Management-System).
# It has no Docker support of its own; everything below adapts it for Kubernetes
# WITHOUT modifying the vendored source in app/.
# =============================================================================
FROM php:8.3-apache

# --- PHP extensions --------------------------------------------------------
# mysqli: the only DB extension the app uses (verified — source calls
#         mysqli_* exclusively, no legacy mysql_* or PDO).
# redis:  required by zz-app.ini's shared session handler. Built from PECL,
#         which needs a toolchain that we remove again in the same layer.
#         `yes ''` accepts PECL's igbinary/lzf/zstd prompts with defaults.
RUN set -eux; \
    docker-php-ext-install mysqli; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
    yes '' | pecl install redis; \
    docker-php-ext-enable redis; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/*

# --- Apache hardening ------------------------------------------------------
# - no directory listings (upstream ships browsable asset dirs)
# - no version banner in headers or error pages
# - TRACE disabled
# - ServerName set to silence the FQDN startup warning
RUN set -eux; \
    printf '%s\n' \
      'ServerName localhost' \
      'ServerTokens Prod' \
      'ServerSignature Off' \
      'TraceEnable Off' \
      '<Directory /var/www/html>' \
      '    Options -Indexes +FollowSymLinks' \
      '    AllowOverride None' \
      '</Directory>' \
      > /etc/apache2/conf-available/z-hardening.conf; \
    a2enconf z-hardening

# --- Application source ----------------------------------------------------
# Only Files/ becomes the docroot. This is required, not cosmetic: every
# dashboard page does `require '../../include/db_conn.php'`, which only
# resolves if Files/ is the web root. It also conveniently excludes the repo's
# PDF/PPTX/DOCX/ER-diagram, which have no business being web-served.
COPY app/Files/ /var/www/html/

# --- Remove files that must NOT be publicly downloadable -------------------
# Upstream ships these INSIDE Files/, so with Files/ as the docroot they would
# be reachable at https://<host>/sports_club_db.sql — and that dump contains
# the default admin credentials in plaintext:
#     INSERT INTO `admin` VALUES ('admin1','admin1','admin1','Sports Club Manager');
RUN rm -f '/var/www/html/sports_club_db.sql' \
          '/var/www/html/SPORTS CLUB.pptx'

# --- Deployment overrides --------------------------------------------------
# Replace the two hardcoded-credential DB files with env-var-driven versions.
# db_conn.php's copy preserves page_protect() verbatim — see that file's header.
COPY docker/php-overrides/db_conn.php /var/www/html/include/db_conn.php
COPY docker/php-overrides/connect.php /var/www/html/connect.php
COPY docker/php-overrides/zz-app.ini  /usr/local/etc/php/conf.d/zz-app.ini
# Probe endpoint — see the file header for why probes must not hit index.php
COPY docker/php-overrides/healthz.php /var/www/html/healthz.php

RUN chown -R www-data:www-data /var/www/html

# No HEALTHCHECK: Kubernetes ignores it in favour of the liveness/readiness
# probes declared on the Deployment, so it would only add a curl dependency.
EXPOSE 80
