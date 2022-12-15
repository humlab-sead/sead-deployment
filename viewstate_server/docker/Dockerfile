FROM debian:buster-slim

RUN apt-get update && apt-get install -y curl software-properties-common

RUN curl -sL https://deb.nodesource.com/setup_14.x | bash -

RUN apt-get update && apt-get install -y nodejs git

RUN git clone https://github.com/humlab-sead/sqs_viewstate_server

WORKDIR /sqs_viewstate_server

RUN npm install

COPY config.json ./config.json

WORKDIR /sqs_viewstate_server/src

RUN ls -AlFh

CMD ["/usr/bin/node", "index.js"]
