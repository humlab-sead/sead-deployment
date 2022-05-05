FROM debian:bullseye

RUN apt-get update && apt-get install -y curl

RUN curl -sL https://deb.nodesource.com/setup_16.x | bash -

RUN apt-get update && apt-get install -y nodejs nginx git procps

#No caching from this point onwards
ADD "https://www.random.org/cgi-bin/randbyte?nbytes=10&format=h" skipcache

RUN git clone https://github.com/humlab-sead/seadbrowserclient

RUN cd seadbrowserclient && npm install && npm run build:prod && cp -R dist/* /var/www/html/

CMD /usr/sbin/nginx -g 'daemon off;'
