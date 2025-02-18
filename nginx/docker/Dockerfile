FROM debian:bullseye

RUN apt-get update && apt-get install -y curl

#RUN curl -sL https://deb.nodesource.com/setup_16.x | bash -

RUN apt-get update
RUN apt-get install -y ca-certificates curl gnupg
RUN mkdir -p /etc/apt/keyrings
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

ENV NODE_MAJOR=16
RUN echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list

RUN apt-get update
RUN apt-get install nodejs -y


RUN apt-get update && apt-get install -y nodejs nginx-extras git procps geoip-database

RUN git clone --recurse-submodules https://github.com/humlab-sead/sead_browser_client

WORKDIR /sead_browser_client

RUN git checkout ${CLIENT_RELEASE}

RUN git submodule update --init --recursive

#RUN git checkout 2023-09.2

RUN npm install && npm run build:dev && cp -R dist/* /var/www/html/

CMD /usr/sbin/nginx -g 'daemon off;'

