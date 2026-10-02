#The router is also the SAML Service Provider: nginx talks to shibd through the
#nginx-http-shibboleth module. Debian, because Alpine does not package the Shibboleth SP.
ARG DEBIAN_IMAGE=docker.io/debian:trixie-slim

#nginx-http-shibboleth is the one piece Debian does not package. It is built here as a
#dynamic module against the source of the very nginx version the final stage installs -
#a module built for any other version will not load.
FROM ${DEBIAN_IMAGE} AS shib-module
ARG NGINX_SHIB_MODULE_REF=v2.0.2
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx ca-certificates curl git build-essential \
        libpcre2-dev zlib1g-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
RUN NGINX_VERSION="$(dpkg-query -W -f='${Version}' nginx | sed -E 's/^[0-9]+://; s/-.*$//')" \
    && echo "Building nginx-http-shibboleth ${NGINX_SHIB_MODULE_REF} for nginx ${NGINX_VERSION}" \
    && curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" | tar -xz -C /usr/src \
    && git clone --depth 1 --branch "${NGINX_SHIB_MODULE_REF}" https://github.com/nginx-shib/nginx-http-shibboleth.git /usr/src/nginx-http-shibboleth \
    && cd "/usr/src/nginx-${NGINX_VERSION}" \
    && ./configure --with-compat --add-dynamic-module=/usr/src/nginx-http-shibboleth \
    && make modules \
    && cp objs/ngx_http_shibboleth_module.so /usr/src/ngx_http_shibboleth_module.so

FROM ${DEBIAN_IMAGE}

ARG DOMAIN=localhost
ENV DOMAIN=${DOMAIN}

#nginx and headers-more (to strip client-sent attribute headers), the Shibboleth SP
#(shibd and its FastCGI authorizer/responder), supervisord to keep them all running,
#spawn-fcgi to start the FastCGI programs, htpasswd + envsubst for the entrypoint.
#The FastCGI programs live under a multiarch path, so they are given a fixed one.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        nginx libnginx-mod-http-headers-more-filter \
        shibboleth-sp-utils supervisor spawn-fcgi \
        apache2-utils gettext-base curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default \
    && mkdir -p /usr/local/lib/shibboleth \
    && ln -s "$(dpkg -L shibboleth-sp-utils | grep '/shibauthorizer$')" /usr/local/lib/shibboleth/shibauthorizer \
    && ln -s "$(dpkg -L shibboleth-sp-utils | grep '/shibresponder$')" /usr/local/lib/shibboleth/shibresponder

COPY --from=shib-module /usr/src/ngx_http_shibboleth_module.so /usr/lib/nginx/modules/ngx_http_shibboleth_module.so
RUN echo 'load_module modules/ngx_http_shibboleth_module.so;' > /etc/nginx/modules-enabled/50-mod-http-shibboleth.conf

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY shibd.logger native.logger /etc/shibboleth/

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

#Only nginx decides whether the router is healthy. A broken shibd breaks SAML login and
#nothing else, and supervisord reports it.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS -o /dev/null -H "Host: ${DOMAIN}" http://127.0.0.1/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
