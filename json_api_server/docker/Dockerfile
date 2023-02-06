FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y curl

RUN curl -sL https://deb.nodesource.com/setup_16.x | bash -

RUN apt-get update && apt-get install -y nodejs git nano

WORKDIR /

#No caching from this point onwards
#ADD "https://www.random.org/cgi-bin/randbyte?nbytes=10&format=h" skipcache

RUN git clone https://github.com/humlab-sead/seaddataserver.git

WORKDIR /seaddataserver

RUN npm install

CMD node /seaddataserver/src/index.js
