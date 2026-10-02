#The dev-only SAML IdP that stands in for SWAMID on sead.local: SimpleSAMLphp with
#local test accounts (exampleauth:UserPass). Never part of a prod deployment - it is
#defined in compose.override.yml, which deploy.sh disables in prod mode.
FROM docker.io/php:8.4-apache-trixie

ARG SIMPLESAMLPHP_VERSION=2.5.3.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl openssl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/simplesamlphp/simplesamlphp/releases/download/v${SIMPLESAMLPHP_VERSION}/simplesamlphp-${SIMPLESAMLPHP_VERSION}-full.tar.gz" \
        | tar -xz -C /var \
    && mv "/var/simplesamlphp-${SIMPLESAMLPHP_VERSION}" /var/simplesamlphp \
    && mkdir -p /var/cache/simplesamlphp \
    && chown www-data:www-data /var/cache/simplesamlphp

#The IdP's own signing key. A dev key, made per image build; the SP re-reads the IdP's
#metadata (and with it this certificate) every few minutes.
RUN mkdir -p /var/simplesamlphp/cert \
    && openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -sha256 \
        -subj "/CN=sead-idp.local" \
        -keyout /var/simplesamlphp/cert/idp.key -out /var/simplesamlphp/cert/idp.crt \
    && chown -R www-data:www-data /var/simplesamlphp/cert \
    && chmod 600 /var/simplesamlphp/cert/idp.key

RUN printf '%s\n' \
        'SetEnv SIMPLESAMLPHP_CONFIG_DIR /var/simplesamlphp/config' \
        'Alias /simplesaml /var/simplesamlphp/public' \
        '<Directory /var/simplesamlphp/public>' \
        '    Require all granted' \
        '</Directory>' \
        > /etc/apache2/conf-available/simplesamlphp.conf \
    && a2enconf simplesamlphp

COPY config/ /var/simplesamlphp/config/
COPY metadata/ /var/simplesamlphp/metadata/
