FROM nginx:alpine

# tools: htpasswd + envsubst
RUN apk add --no-cache apache2-utils gettext

# tiny entrypoint
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
