FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y curl software-properties-common git

RUN curl -fsSL https://deb.nodesource.com/setup_16.x | bash -

RUN apt-get update && apt-get install -y nodejs

RUN git clone https://github.com/humlab-sead/sqs_viewstate_server

WORKDIR /sqs_viewstate_server

RUN npm install

COPY config.json ./config.json

WORKDIR /sqs_viewstate_server/src

RUN ls -AlFh

CMD ["/usr/bin/node", "index.js"]
