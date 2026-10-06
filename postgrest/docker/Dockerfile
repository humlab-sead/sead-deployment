#The official PostgREST image holds nothing but the static postgrest binary - no shell and no
#curl - so the compose healthcheck (curl, run through /bin/sh) can never run in it. This image
#is the same binary on Alpine, with curl added for the healthcheck.
ARG POSTGREST_IMAGE=docker.io/postgrest/postgrest:v12.2.8
ARG ALPINE_IMAGE=docker.io/alpine:3.23

FROM ${POSTGREST_IMAGE} AS postgrest

FROM ${ALPINE_IMAGE}
RUN apk add --no-cache curl
COPY --from=postgrest /bin/postgrest /bin/postgrest
#The OpenSSL configuration the static binary was built to look for
COPY --from=postgrest /nix /nix
USER 1000
CMD ["/bin/postgrest"]
