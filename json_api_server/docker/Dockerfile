FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y curl

RUN curl -sL https://deb.nodesource.com/setup_16.x | bash -

RUN apt-get update && apt-get install -y nodejs git nano

WORKDIR /

RUN git clone https://github.com/humlab-sead/sead_json_server.git

WORKDIR /sead_json_server

RUN npm install

CMD node /sead_json_server/src/index.js
