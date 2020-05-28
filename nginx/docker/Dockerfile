FROM debian:buster-slim

RUN apt-get update && apt-get install -y curl

RUN curl -sL https://deb.nodesource.com/setup_12.x | bash -

RUN apt-get update && apt-get install -y nodejs nginx certbot python-certbot-nginx git procps

RUN git clone https://github.com/humlab-sead/seadbrowserclient

RUN cd seadbrowserclient && npm install && npm run build:prod && cp -R dist/* /var/www/html/

COPY start.sh /start.sh

RUN chmod +x /start.sh

CMD /start.sh

#CMD echo "Retrieving cert for domain $DOMAIN with email $ADMIN_EMAIL\n" && certbot --non-interactive --email $ADMIN_EMAIL --text --agree-tos --nginx --domains $DOMAIN && /usr/sbin/nginx
