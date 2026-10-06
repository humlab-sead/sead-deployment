FROM node:22-alpine

#For the compose healthcheck
RUN apk add --no-cache curl

ENV PGDATABASE=sead_staging
ENV PGHOST=postgresql
ENV PGPORT=5432
ENV PGUSER=sead_ro
ENV PGPASSWORD=
ENV PGSSL=false

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY main.js ./

EXPOSE 4000

CMD ["npm", "start"]