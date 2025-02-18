FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y ca-certificates curl gnupg
RUN mkdir -p /etc/apt/keyrings
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
ENV NODE_MAJOR=16
RUN echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
RUN apt-get update && apt-get install -y nodejs git nano

RUN apt-get update && apt-get install -y nodejs git nano

WORKDIR /

RUN git clone https://github.com/humlab-sead/sead_json_server.git

WORKDIR /sead_json_server

RUN npm install

CMD node /sead_json_server/src/index.js
