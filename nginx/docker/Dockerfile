FROM debian:bullseye

RUN apt-get update && apt-get install -y curl

RUN curl -sL https://deb.nodesource.com/setup_16.x | bash -

RUN apt-get update && apt-get install -y nodejs nginx git procps

RUN git clone https://github.com/humlab-sead/sead_browser_client

RUN cd sead_browser_client && npm install && npm run build:dev && cp -R dist/* /var/www/html/

CMD /usr/sbin/nginx -g 'daemon off;'
