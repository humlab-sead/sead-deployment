FROM docker.io/nginx:alpine

ARG DOMAIN=localhost
ENV DOMAIN=${DOMAIN}

# tools: htpasswd + envsubst
RUN apk add --no-cache apache2-utils gettext

# tiny entrypoint
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q --spider http://${DOMAIN}/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
