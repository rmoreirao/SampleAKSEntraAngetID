FROM node:22.18.0-alpine3.22 AS build
WORKDIR /src
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
ENV VITE_API_BASE_URL=
RUN npm run build

FROM nginx:1.28.0-alpine3.21
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist /usr/share/nginx/html
RUN chown -R nginx:nginx /var/cache/nginx /var/run /usr/share/nginx/html && \
    touch /var/run/nginx.pid && chown nginx:nginx /var/run/nginx.pid
USER nginx
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
