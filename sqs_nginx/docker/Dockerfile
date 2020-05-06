FROM debian:buster-slim

RUN apt-get update && apt-get install -y curl

RUN curl -sL https://deb.nodesource.com/setup_12.x | bash -

RUN apt-get update && apt-get install -y nodejs nginx certbot python-certbot-nginx git

RUN git clone https://github.com/humlab-sead/seadbrowserclient

RUN cd seadbrowserclient && npm install && npm run build:prod && cp -R dist/* /var/www/

CMD certbot --non-interactive --email johan.von.boer@umu.se --text --agree-tos --nginx --domains $DOMAIN && /usr/sbin/nginx

