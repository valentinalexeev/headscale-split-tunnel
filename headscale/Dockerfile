FROM jauderho/headscale:latest

RUN apk add --no-cache curl bash jq ca-certificates

COPY scripts/approve-gateway-routes.sh /usr/local/bin/approve-gateway-routes.sh
COPY scripts/cron-approve-routes.sh /usr/local/bin/cron-approve-routes.sh

RUN chmod +x /usr/local/bin/approve-gateway-routes.sh \
    /usr/local/bin/cron-approve-routes.sh

COPY ./headscale.yaml /etc/headscale/config.yaml
COPY ./acl.json /etc/headscale/acl.json

ENTRYPOINT []
